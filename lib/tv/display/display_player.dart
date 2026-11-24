import 'dart:async';

import 'display_native.dart';

/// What the TV is showing right now, for `player.report` and
/// `player.position`.
class PlayerSnapshot {
  const PlayerSnapshot({
    this.itemId,
    this.playing = false,
    this.positionMs = 0,
    this.durationMs,
    this.muted = false,
  });

  final String? itemId;
  final bool playing;
  final int positionMs;
  final int? durationMs;
  final bool muted;

  /// `idle` (no item), `playing` or `paused`: the Pi's player states.
  String get state => itemId == null
      ? 'idle'
      : playing
      ? 'playing'
      : 'paused';
}

/// The TV's player: one item at a time on the Media3 SurfaceView, driven by
/// the Pi (`display.load`, `display.control`).
///
/// The TV is authoritative for what is on screen: it reports its item and
/// position to the Pi (every [positionInterval] and after every change) and
/// asks it to move on when an item ends. When the Pi cannot be reached the
/// item loops locally.
class DisplayPlayer {
  DisplayPlayer({
    required this.native,
    this.reportEnded,
    this.reportPosition,
    this.positionInterval = const Duration(seconds: 10),
    this.statsInterval = const Duration(seconds: 1),
    this.errorRetry = const Duration(seconds: 3),
  }) {
    native.onEnded = _onNativeEnded;
  }

  final DisplayVideoNative native;

  /// Tells the Pi that [itemId] ended. Returns true when the Pi took it (it
  /// answers with the next `display.load`); false makes the item loop here.
  final Future<bool> Function(String itemId)? reportEnded;

  /// Sends `player.position` to the Pi (a no-op while it is unreachable).
  final void Function(PlayerSnapshot snapshot)? reportPosition;

  final Duration positionInterval;
  final Duration statsInterval;

  /// How long a failing item is shown before the Pi is asked to move on.
  final Duration errorRetry;

  String? _itemId;
  String? _url;
  Map<String, String> _headers = const {};
  bool _playing = false;
  bool _muted = false;
  bool _viewReady = false;
  bool _disposed = false;
  bool _failed = false;
  bool _durationSent = false;
  int _positionMs = 0;
  int? _durationMs;
  int _loadSeq = 0;
  Timer? _statsTimer;
  Timer? _positionTimer;
  Timer? _errorTimer;

  String? get itemId => _itemId;
  bool get hasItem => _itemId != null;
  bool get playing => _playing && _itemId != null;
  bool get muted => _muted;

  /// The last position read from the player.
  int get positionMs => _positionMs;

  PlayerSnapshot get snapshot => PlayerSnapshot(
    itemId: _itemId,
    playing: _playing,
    positionMs: _positionMs,
    durationMs: _durationMs,
    muted: _muted,
  );

  /// Reads the player's position now (falls back to the last known one).
  Future<PlayerSnapshot> freshSnapshot() async {
    await _readStats();
    return snapshot;
  }

  /// `display.load`: play [itemId] from [startAtMs].
  Future<void> load({
    required String itemId,
    required String url,
    required Map<String, String> headers,
    int startAtMs = 0,
    bool? muted,
  }) async {
    _itemId = itemId;
    _url = url;
    _headers = Map.unmodifiable(headers);
    _playing = true;
    if (muted != null) _muted = muted;
    _positionMs = startAtMs;
    _durationMs = null;
    await _open(startAtMs);
  }

  /// `display.control`.
  Future<void> control(String action, {int? positionMs, bool? muted}) async {
    switch (action) {
      case 'pause':
        _playing = false;
        if (_itemId != null) await native.pause();
      case 'resume':
        _playing = true;
        if (_itemId != null) await native.resume();
      case 'seek':
        if (positionMs == null || _itemId == null) return;
        _positionMs = positionMs;
        await native.seek(positionMs);
      case 'mute':
        if (muted == null) return;
        _muted = muted;
        await native.setMuted(muted);
      default:
        return;
    }
    _sendPosition();
  }

  /// The SurfaceView exists: show the current item (again, after a menu).
  Future<void> viewCreated() async {
    _viewReady = true;
    if (_itemId != null && _url != null && !_disposed) {
      await _open(_positionMs);
    }
  }

  /// The SurfaceView is gone (a menu screen covers it): stop the decoder but
  /// remember where the item was.
  Future<void> viewDisposed() async {
    _viewReady = false;
    await _readStats();
    _stopTimers();
    await native.release();
  }

  Future<void> _open(int startMs) async {
    if (_disposed || _url == null || !_viewReady) return;
    _loadSeq++;
    _failed = false;
    _durationSent = false;
    _errorTimer?.cancel();
    await native.open(
      url: _url!,
      headers: _headers,
      startMs: startMs,
      muted: _muted,
      playing: _playing,
    );
    if (_disposed) return;
    _statsTimer ??= Timer.periodic(statsInterval, (_) => _readStats());
    _positionTimer ??= Timer.periodic(positionInterval, (_) => _sendPosition());
  }

  Future<void> _readStats() async {
    final seq = _loadSeq;
    final s = await native.stats();
    if (_disposed || s == null || seq != _loadSeq || _itemId == null) return;
    _positionMs = s.position.inMilliseconds;
    final dur = s.duration;
    if (dur != null && dur > Duration.zero) {
      _durationMs = dur.inMilliseconds;
      if (!_durationSent) {
        _durationSent = true;
        _sendPosition(); // The Pi needs the duration to clamp seeks.
      }
    }
    if (s.error != null && !_failed) {
      _failed = true;
      final id = _itemId!;
      _errorTimer?.cancel();
      // Show the failure for a moment, then ask the Pi to move on.
      _errorTimer = Timer(errorRetry, () => unawaited(_finished(id)));
    }
  }

  void _sendPosition() {
    if (_itemId == null || _disposed) return;
    reportPosition?.call(snapshot);
  }

  void _onNativeEnded() {
    final id = _itemId;
    if (id == null || _disposed) return;
    unawaited(_finished(id));
  }

  /// The item is over (or cannot be played): the Pi moves on, or, without
  /// the Pi, it starts again here.
  Future<void> _finished(String id) async {
    final seq = _loadSeq;
    var handled = false;
    try {
      handled = await (reportEnded?.call(id) ?? Future.value(false));
    } catch (_) {
      handled = false;
    }
    if (handled || _disposed || seq != _loadSeq || _itemId != id) return;
    if (_failed) {
      await _open(0);
    } else {
      await native.seek(0);
      await native.resume();
    }
  }

  void _stopTimers() {
    _statsTimer?.cancel();
    _statsTimer = null;
    _positionTimer?.cancel();
    _positionTimer = null;
    _errorTimer?.cancel();
    _errorTimer = null;
  }

  Future<void> dispose() async {
    _disposed = true;
    _stopTimers();
    native.onEnded = null;
    await native.release();
  }
}
