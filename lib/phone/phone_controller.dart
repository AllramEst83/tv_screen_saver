import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:hub_core/hub_core.dart';

import '../shared/multicast_lock.dart';
import 'now_playing.dart';

/// Which top-level screen the phone shows.
enum PhoneScreen { loading, connect, pin, home }

/// Result of handing a scanned QR code to the controller.
enum QrOutcome {
  /// Not a TV Saver pairing code: stay on the scanner.
  invalid,

  /// A connection attempt started: leave the scanner and watch the state.
  started,
}

/// Phone-side state over [HubClient]: which screen to show, the paired device
/// list, the Wi-Fi multicast lock and the saved pairing.
class PhoneController extends ChangeNotifier {
  PhoneController({
    required this.client,
    required this.store,
    MulticastLock? lock,
  }) : _lock = lock ?? MulticastLock() {
    client.state.addListener(_onHubState);
    _subs = [
      client.snapshots.listen(_onSnapshot),
      client.events.listen(_onEvent),
    ];
  }

  final HubClient client;
  final HubTokenStore store;
  final MulticastLock _lock;
  late final List<StreamSubscription<Map<String, dynamic>>> _subs;

  bool _starting = false;
  bool _started = false;
  bool _foreground = true;
  bool _hasPairing = false;
  bool _scanning = false;
  bool _lockHeld = false;
  bool _disposed = false;
  List<DeviceInfo> _devices = const [];
  NowPlaying _nowPlaying = const NowPlaying();
  bool? _displayOnline;
  bool _tvNotConnected = false;
  String? _playerError;

  HubClientState get hub => client.state.value;

  /// A pairing is saved on this phone (the app will reconnect on its own).
  bool get hasPairing => _hasPairing;

  List<DeviceInfo> get devices => _devices;

  DeviceInfo? get me => hub.device;

  bool get lockHeld => _lockHeld;

  /// What the TV is playing (the `player` module).
  NowPlaying get nowPlaying => _nowPlaying;

  /// The Pi has no TV connected: the last command got `unavailable`, or the
  /// `display` module says so.
  bool get tvNotConnected => _tvNotConnected || _displayOnline == false;

  /// The message of the last player command that failed for another reason.
  String? get playerError => _playerError;

  /// The playing position now, from the Pi's clock.
  int get positionMs => _nowPlaying.positionAt(client.tvNowMs());

  PhoneScreen get screen {
    if (!_started) return PhoneScreen.loading;
    return switch (hub.phase) {
      HubConnectionPhase.connected => PhoneScreen.home,
      HubConnectionPhase.awaitingPin => PhoneScreen.pin,
      _ => PhoneScreen.connect,
    };
  }

  /// Status line for the Connect screen, per [HubConnectionPhase].
  String get statusText {
    final h = hub;
    final name = h.hubName ?? 'TV Saver';
    return switch (h.phase) {
      HubConnectionPhase.connecting => 'Connecting…',
      HubConnectionPhase.reconnecting => 'Looking for $name…',
      HubConnectionPhase.offline => h.lastError ?? HubMessages.tvNotFound,
      HubConnectionPhase.appNotOpen => HubMessages.appNotOpen,
      HubConnectionPhase.wrongTv => HubMessages.wrongTv,
      HubConnectionPhase.needsTvUpdate => HubMessages.upgradeTv,
      HubConnectionPhase.replaced => HubMessages.replaced,
      HubConnectionPhase.disconnected =>
        h.lastError ??
            (_hasPairing
                ? HubMessages.notConnected
                : 'Scan the QR code on the TV to pair this phone.'),
      _ => '',
    };
  }

  /// Whether the Connect screen is busy trying (spinner, no Retry).
  bool get busy =>
      hub.phase == HubConnectionPhase.connecting ||
      hub.phase == HubConnectionPhase.reconnecting;

  /// Whether the Connect screen offers Retry.
  bool get canRetry =>
      _hasPairing &&
      switch (hub.phase) {
        HubConnectionPhase.offline ||
        HubConnectionPhase.appNotOpen ||
        HubConnectionPhase.disconnected ||
        HubConnectionPhase.wrongTv => true,
        _ => false,
      };

  /// Loads the saved pairing and, when there is one, reconnects.
  Future<void> start() async {
    if (_starting) return;
    _starting = true;
    SavedHubPairing? saved;
    try {
      saved = await store.getLastPairing();
    } catch (_) {}
    if (_disposed) return;
    _hasPairing = saved != null;
    _started = true;
    notifyListeners();
    if (saved != null) {
      unawaited(_guarded(() async => client.reconnectSavedHub()));
    }
  }

  /// Runs a client call; an unexpected error becomes a visible state instead
  /// of escaping.
  Future<void> _guarded(Future<void> Function() body) async {
    try {
      await body();
    } catch (_) {
      if (_disposed) return;
      client.state.value = hub.copyWith(
        phase: HubConnectionPhase.disconnected,
        lastError: HubMessages.connectionLost,
      );
    }
  }

  /// The app went to the background or came back: the multicast lock must
  /// not be held while paused.
  void setForeground(bool value) {
    _foreground = value;
    _syncLock();
  }

  /// Called by the scanner while it is on screen: mDNS may be needed.
  void setScanning(bool value) {
    _scanning = value;
    _syncLock();
  }

  /// Hands a scanned code to the client. Codes that are not TV Saver QR codes
  /// are rejected without touching the connection.
  Future<QrOutcome> pairFromQr(String raw) async {
    if (PairQrData.tryParse(raw) == null) return QrOutcome.invalid;
    unawaited(_connectQr(raw));
    return QrOutcome.started;
  }

  Future<void> _connectQr(String raw) async {
    await _guarded(() async {
      // Drop any attempt still in flight (a retry loop, an earlier scan).
      await client.disconnect();
      await client.connectFromQrUri(raw);
    });
    await _refreshPairing();
  }

  void submitPin(String pin) => client.submitPin(pin);

  // ---- player ----

  /// Starts the one playlist there is until story 4-4: `all`.
  Future<void> play() => _player('player.play', {'playlistId': 'all'});
  Future<void> next() => _player('player.next');
  Future<void> prev() => _player('player.prev');

  /// Pause when playing, resume otherwise.
  Future<void> togglePause() =>
      _player(_nowPlaying.isPlaying ? 'player.pause' : 'player.resume');

  /// Seeks [deltaMs] from the position on screen now.
  Future<void> seekBy(int deltaMs) {
    final target = positionMs + deltaMs;
    return _player('player.seek', {'positionMs': target < 0 ? 0 : target});
  }

  Future<void> toggleMute() =>
      _player('player.setMuted', {'muted': !_nowPlaying.muted});

  Future<void> _player(
    String type, [
    Map<String, Object?> args = const {},
  ]) async {
    try {
      await client.request(type, args);
      _tvNotConnected = false;
      _playerError = null;
    } on HubError catch (e) {
      if (e.code == HubErrorCode.unavailable) {
        _tvNotConnected = true;
        _playerError = null;
      } else {
        _playerError = e.message ?? e.code;
      }
    } catch (_) {
      _playerError = HubMessages.connectionLost;
    }
    if (!_disposed) notifyListeners();
  }

  /// Leaves the PIN screen without pairing.
  Future<void> cancelPin() async {
    await client.disconnect();
    await _refreshPairing();
  }

  Future<void> retry() => _guarded(() async => client.retryNow());

  /// Removes only this phone's pairing: the Pi keeps the device record.
  /// Disconnects first so the client cannot save the token again. Returns
  /// false when the pairing could not be removed.
  Future<bool> forgetThisPi() async {
    var hubId = hub.hubId;
    if (hubId == null) {
      try {
        hubId = (await store.getLastPairing())?.hubId;
      } catch (_) {}
    }
    await _guarded(client.disconnect);
    var ok = true;
    try {
      if (hubId != null) await store.removePairing(hubId);
    } catch (_) {
      ok = false;
    }
    _devices = const [];
    await _refreshPairing();
    return ok;
  }

  Future<void> _refreshPairing() async {
    try {
      _hasPairing = await store.getLastPairing() != null;
    } catch (_) {}
    if (!_disposed) notifyListeners();
  }

  void _onHubState() {
    if (hub.phase == HubConnectionPhase.connected) {
      _hasPairing = true;
    } else {
      _devices = const [];
      if (!hub.knownPairing && hub.phase != HubConnectionPhase.connecting) {
        unawaited(_refreshPairing());
      }
    }
    _syncLock();
    if (!_disposed) notifyListeners();
  }

  void _syncLock() {
    final phase = hub.phase;
    final want =
        _foreground &&
        (_scanning ||
            phase == HubConnectionPhase.connecting ||
            phase == HubConnectionPhase.reconnecting ||
            phase == HubConnectionPhase.offline ||
            phase == HubConnectionPhase.appNotOpen);
    if (want == _lockHeld) return;
    _lockHeld = want;
    unawaited(want ? _lock.acquire() : _lock.release());
  }

  void _onSnapshot(Map<String, dynamic> snap) {
    final modules = snap['modules'];
    final devices = modules is Map ? modules['devices'] : null;
    _setDevices(devices is Map ? devices['devices'] : null);
    final player = NowPlaying.tryParse(
      modules is Map ? modules['player'] : null,
    );
    if (player != null) _nowPlaying = player;
    final display = modules is Map ? modules['display'] : null;
    if (display is Map && display['online'] is bool) {
      _setDisplayOnline(display['online'] as bool);
    }
    if (!_disposed) notifyListeners();
  }

  void _onEvent(Map<String, dynamic> ev) {
    final data = ev['data'];
    switch (ev['kind']) {
      case 'devices.changed':
        _setDevices(data is Map ? data['devices'] : null);
      case 'player.changed':
        final player = NowPlaying.tryParse(data);
        if (player == null) return;
        _nowPlaying = player;
        if (!_disposed) notifyListeners();
      case 'display.changed':
        if (data is Map && data['online'] is bool) {
          _setDisplayOnline(data['online'] as bool);
          if (!_disposed) notifyListeners();
        }
    }
  }

  void _setDisplayOnline(bool online) {
    _displayOnline = online;
    if (online) _tvNotConnected = false;
  }

  void _setDevices(Object? list) {
    if (list is! List) return;
    final parsed = <DeviceInfo>[];
    for (final d in list) {
      try {
        if (d is Map<String, dynamic>) parsed.add(DeviceInfo.fromJson(d));
      } catch (_) {
        // Skip a malformed entry, keep the rest.
      }
    }
    _devices = parsed;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    client.state.removeListener(_onHubState);
    for (final s in _subs) {
      s.cancel();
    }
    if (_lockHeld) {
      _lockHeld = false;
      unawaited(_lock.release());
    }
    super.dispose();
  }
}
