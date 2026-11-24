import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../cache/media_cache.dart';
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

/// What the remote's info overlay says about the item on screen.
class ItemInfo {
  const ItemInfo({this.name, this.index, this.count, this.isImage = false});

  final String? name;

  /// Zero-based place in the playlist and its length, when the Pi said.
  final int? index;
  final int? count;
  final bool isImage;
}

/// A photo ready to show: the cached file and how to show it.
class ImageSlot {
  const ImageSlot({
    required this.file,
    required this.nonce,
    required this.crossfade,
    required this.kenBurns,
    required this.durationMs,
  });

  final File file;

  /// Changes with every photo, so the same file twice in a row still counts
  /// as a new slide.
  final int nonce;
  final bool crossfade;
  final bool kenBurns;
  final int durationMs;
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
    this.anchorDelay = const Duration(seconds: 3),
    this.cache,
    this.imageVariant = _fullVariant,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now {
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

  /// After a load or seek one more position goes to the Pi this much later:
  /// the Pi drops reports for 2.5 s after its own command, so the first one
  /// can be lost.
  final Duration anchorDelay;
  final DateTime Function() _now;

  /// The file cache; without it everything streams.
  final MediaCache? cache;

  /// The image variant to download: `full` on a 3840 px surface, else `1920`.
  final String Function() imageVariant;

  static String _fullVariant() => 'full';

  /// The item on screen plays from a file in the TV cache.
  bool get fromCache => _url?.startsWith('file:') ?? _photoShown;

  /// The photo on screen, or null while a clip (or nothing) plays.
  final ValueNotifier<ImageSlot?> image = ValueNotifier(null);

  /// True while something is playing (not paused, not idle): the screen
  /// stays awake only then.
  final ValueNotifier<bool> active = ValueNotifier(false);

  /// Width over height of the clip on screen, once the decoder knows it; the
  /// screen sizes the video surface by it so nothing is stretched.
  final ValueNotifier<double?> videoAspect = ValueNotifier(null);

  /// The native photo surface is wanted in the tree (a photo is on it).
  final ValueNotifier<bool> nativeImageActive = ValueNotifier(false);

  /// What the info overlay shows about the current item.
  ItemInfo? info;

  // A playlist of one: the clip repeats inside the player, a photo restarts
  // its clock, and the Pi is not asked for a "next".
  bool _loop = false;

  void _publish() {
    if (!_disposed) active.value = playing;
  }

  /// Show photos on the native 4K surface (when the Flutter plane is below
  /// the panel). The Flutter widget stays the fallback.
  bool nativeImages = false;

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
  Timer? _anchorTimer;

  // Photo state: the photo runs for [_imageMs]; `_imageBefore` is the time
  // already shown and `_imageSince` when the clock last started (null while
  // paused).
  bool _isImage = false;

  /// The cached file the native surface shows (null on the Flutter path).
  String? _nativeImagePath;
  int _imageMs = 0;
  int _imageBefore = 0;
  DateTime? _imageSince;
  Timer? _imageTimer;
  String? _pinned;

  /// When the picture was released for the menu (null while it is shown).
  DateTime? _releasedAt;

  String? get itemId => _itemId;
  bool get hasItem => _itemId != null;
  bool get playing => _playing && _itemId != null;
  bool get muted => _muted;

  /// The last position read from the player.
  int get positionMs => _positionMs;

  PlayerSnapshot get snapshot => PlayerSnapshot(
    itemId: _itemId,
    playing: _playing,
    positionMs: _isImage && _itemId != null ? _imageElapsed : _positionMs,
    durationMs: _durationMs,
    muted: _muted,
  );

  /// Reads the player's position now (falls back to the last known one).
  Future<PlayerSnapshot> freshSnapshot() async {
    await _readStats();
    return snapshot;
  }

  /// `display.load`: play [itemId] from [startAtMs]. A photo ([isImage]) is
  /// shown for [imageMs] from the cache; a video that must be cached first
  /// ([cacheRequired]) is downloaded before it starts.
  Future<void> load({
    required String itemId,
    required String url,
    required Map<String, String> headers,
    int startAtMs = 0,
    bool? muted,
    bool isImage = false,
    int imageMs = 10000,
    bool crossfade = true,
    bool kenBurns = false,
    bool cacheRequired = false,
    bool loop = false,
    ItemInfo? info,
  }) async {
    final seq = ++_loadSeq;
    _loop = loop;
    this.info = info;
    _itemId = itemId;
    _playing = true;
    if (muted != null) _muted = muted;
    _positionMs = startAtMs;
    _durationMs = null;
    _failed = false;
    _errorTimer?.cancel();
    _publish();
    if (isImage) {
      await _loadImage(
        seq,
        itemId,
        url,
        headers,
        startAtMs,
        imageMs,
        crossfade,
        kenBurns,
      );
      return;
    }
    _isImage = false;
    _stopImage();
    videoAspect.value = null;
    var playUrl = url;
    var playHeaders = Map<String, String>.of(headers);
    final c = cache;
    if (c != null) {
      final key = '$itemId.full';
      try {
        var file = await c.lookup(key);
        if (file == null && cacheRequired) {
          file = await c.fetch(
            CacheRequest(key: key, url: Uri.parse(url), headers: headers),
          );
        }
        if (file != null) {
          _pin(key);
          playUrl = file.uri.toString();
          playHeaders = const {};
        }
      } catch (_) {
        // Too big for the cache or the Pi is not answering: stream it.
      }
      if (seq != _loadSeq || _disposed) return;
    }
    _url = playUrl;
    _headers = Map.unmodifiable(playHeaders);
    await _open(startAtMs);
    _scheduleAnchor();
  }

  Future<void> _loadImage(
    int seq,
    String itemId,
    String url,
    Map<String, String> headers,
    int startAtMs,
    int imageMs,
    bool crossfade,
    bool kenBurns,
  ) async {
    final wasImage = _isImage;
    _isImage = true;
    _url = null;
    _stopTimers();
    _imageTimer?.cancel();
    _imageMs = imageMs;
    _durationMs = imageMs;
    final c = cache;
    File? file;
    if (c != null) {
      final base = Uri.parse(url);
      final variant = imageVariant();
      CacheRequest request(String v) => CacheRequest(
        key: '$itemId.$v',
        url: base.replace(
          pathSegments: [
            ...base.pathSegments.take(base.pathSegments.length - 1),
            v,
          ],
        ),
        headers: headers,
      );
      final full = request('full');
      try {
        file = await c.fetch(
          variant == 'full'
              ? full
              : CacheRequest(
                  key: '$itemId.$variant',
                  url: request(variant).url,
                  headers: headers,
                  fallback: full,
                ),
        );
      } catch (_) {
        file = null;
      }
    }
    if (seq != _loadSeq || _disposed) return;
    if (file == null) {
      // Not here and the Pi does not answer: show the failure for a moment,
      // then ask the Pi to move on.
      _failed = true;
      _errorTimer = Timer(errorRetry, () => unawaited(_finished(itemId)));
      return;
    }
    _pin(file.uri.pathSegments.last);
    // The clip, if one was playing, gives way (a photo after a photo does
    // not: it fades over it).
    if (!wasImage) await native.release();
    if (seq != _loadSeq || _disposed) return;
    var drawn = false;
    if (nativeImages) {
      nativeImageActive.value = true; // the surface is created now
      videoAspect.value = null;
      drawn = await native.showImage(
        path: file.path,
        crossfadeMs: crossfade ? 800 : 0,
        kenBurns: kenBurns,
        durationMs: imageMs,
      );
      if (seq != _loadSeq || _disposed) return;
      if (!drawn) nativeImageActive.value = false;
    }
    _nativeImagePath = drawn ? file.path : null;
    _imageBefore = startAtMs.clamp(0, imageMs);
    _imageSince = _playing ? _now() : null;
    image.value = drawn
        ? null
        : ImageSlot(
            file: file,
            nonce: seq,
            crossfade: crossfade,
            kenBurns: kenBurns,
            durationMs: imageMs,
          );
    _armImage(itemId);
    _positionTimer = Timer.periodic(positionInterval, (_) => _sendPosition());
    _scheduleAnchor();
  }

  /// A photo is on screen, natively or as a Flutter slide.
  bool get _photoShown => image.value != null || _nativeImagePath != null;

  int get _imageElapsed {
    final since = _imageSince;
    final run = since == null ? 0 : _now().difference(since).inMilliseconds;
    return (_imageBefore + run).clamp(0, _imageMs);
  }

  void _armImage(String itemId) {
    _imageTimer?.cancel();
    if (_imageSince == null) return;
    final left = _imageMs - _imageElapsed;
    _imageTimer = Timer(
      Duration(milliseconds: left < 0 ? 0 : left),
      () => unawaited(_finished(itemId)),
    );
  }

  void _stopImage() {
    _imageTimer?.cancel();
    _imageTimer = null;
    _imageSince = null;
    _imageBefore = 0;
    if (_nativeImagePath != null || nativeImageActive.value) {
      unawaited(native.clearImage());
    }
    _nativeImagePath = null;
    nativeImageActive.value = false;
    image.value = null;
  }

  void _pin(String key) {
    final old = _pinned;
    if (old == key) return;
    if (old != null) cache?.unpin(old);
    cache?.pin(key);
    _pinned = key;
  }

  void _unpin() {
    final old = _pinned;
    if (old != null) cache?.unpin(old);
    _pinned = null;
  }

  /// `display.control`.
  Future<void> control(String action, {int? positionMs, bool? muted}) async {
    switch (action) {
      case 'pause':
        _playing = false;
        if (_isImage) {
          _imageBefore = _imageElapsed;
          _imageSince = null;
          _imageTimer?.cancel();
          _positionMs = _imageBefore;
        } else if (_itemId != null) {
          await native.pause();
        }
      case 'resume':
        _playing = true;
        if (_isImage) {
          _imageSince ??= _now();
          if (_itemId != null && _photoShown) _armImage(_itemId!);
        } else if (_itemId != null) {
          await native.resume();
        }
      case 'seek':
        if (positionMs == null || _itemId == null) return;
        if (_isImage) {
          _imageBefore = positionMs.clamp(0, _imageMs);
          if (_imageSince != null) _imageSince = _now();
          _positionMs = _imageBefore;
          _armImage(_itemId!);
        } else {
          _positionMs = positionMs;
          await native.seek(positionMs);
        }
        _scheduleAnchor();
      case 'stop':
        // The Pi has nothing to play: show nothing.
        _itemId = null;
        _url = null;
        _playing = false;
        _positionMs = 0;
        _durationMs = null;
        _isImage = false;
        _loadSeq++;
        _stopTimers();
        _stopImage();
        _unpin();
        info = null;
        _loop = false;
        _publish();
        await native.release();
        return;
      case 'mute':
        if (muted == null) return;
        _muted = muted;
        if (!_isImage) await native.setMuted(muted);
      default:
        return;
    }
    _publish();
    _sendPosition();
  }

  /// The SurfaceView exists: show the current item (again, after a menu).
  Future<void> viewCreated() async {
    _viewReady = true;
    if (_isImage) {
      // A photo needs nothing here: a Flutter one is a widget, and the
      // native surface draws its photo again when it is created.
      return;
    }
    if (_itemId != null && _url != null && !_disposed) {
      var start = _positionMs;
      final released = _releasedAt;
      _releasedAt = null;
      if (_playing && released != null) {
        // The clip would have run on while the menu was open.
        start += _now().difference(released).inMilliseconds;
        final dur = _durationMs;
        if (dur != null && start > dur) start = dur;
      }
      _positionMs = start;
      await _open(start);
      _sendPosition();
    }
  }

  /// The SurfaceView is gone (a menu screen covers it): stop the decoder but
  /// remember where the item was.
  Future<void> viewDisposed() async {
    _viewReady = false;
    if (_isImage) return; // The photo keeps its clock under the menu.
    await _readStats();
    _releasedAt = _now();
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
      loop: _loop,
    );
    if (_disposed) return;
    _statsTimer ??= Timer.periodic(statsInterval, (_) => _readStats());
    _positionTimer ??= Timer.periodic(positionInterval, (_) => _sendPosition());
  }

  Future<void> _readStats() async {
    if (_isImage) {
      if (!_disposed && _itemId != null) _positionMs = _imageElapsed;
      return;
    }
    final seq = _loadSeq;
    final s = await native.stats();
    if (_disposed || s == null || seq != _loadSeq || _itemId == null) return;
    _positionMs = s.position.inMilliseconds;
    final aspect = s.aspect;
    if (aspect != null && aspect > 0 && videoAspect.value != aspect) {
      videoAspect.value = aspect;
    }
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

  void _scheduleAnchor() {
    _anchorTimer?.cancel();
    _anchorTimer = Timer(anchorDelay, () async {
      await _readStats();
      _sendPosition();
    });
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
    if (_loop && _isImage && _photoShown && !_failed) {
      // A playlist of one photo: show it again, no round trip.
      _imageBefore = 0;
      _imageSince = _playing ? _now() : null;
      _armImage(id);
      return;
    }
    final seq = _loadSeq;
    var handled = false;
    try {
      handled = await (reportEnded?.call(id) ?? Future.value(false));
    } catch (_) {
      handled = false;
    }
    if (handled || _disposed || seq != _loadSeq || _itemId != id) return;
    if (_isImage) {
      // Without the Pi the photo starts again here.
      _imageBefore = 0;
      _imageSince = _playing ? _now() : null;
      if (_photoShown) {
        _armImage(id);
      } else {
        _failed = false;
        _errorTimer = Timer(errorRetry, () => unawaited(_finished(id)));
      }
      return;
    }
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
    _anchorTimer?.cancel();
    _anchorTimer = null;
  }

  Future<void> dispose() async {
    _disposed = true;
    _stopTimers();
    _imageTimer?.cancel();
    _unpin();
    active.value = false;
    active.dispose();
    videoAspect.dispose();
    nativeImageActive.dispose();
    image.dispose();
    native.onEnded = null;
    await native.release();
  }
}
