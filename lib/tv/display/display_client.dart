import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:hub_core/hub_core.dart';

import '../../shared/multicast_lock.dart';
import '../display_report.dart';
import 'display_native.dart';
import 'display_player.dart';

/// The pairing code the Pi relays to the TV (`display.pairing`).
class PairingInfo {
  const PairingInfo({
    required this.qr,
    required this.pin,
    required this.expiresAt,
  });

  final String qr;
  final String pin;
  final DateTime expiresAt;
}

/// How far the remote's fast-forward and rewind keys seek.
const remoteSeekMs = 30000;

/// The TV's capabilities for `display.capabilities`: decoders, HDR types, the
/// size the app renders at and the panel's native size. Read-only.
Future<Map<String, Object?>> readCapabilities(DisplayVideoNative native) async {
  final decoders = await native.decoders();
  final info = await native.displayInfo();
  final hdr = [
    for (final t in info?.hdrTypes ?? const <int>[])
      switch (t) {
        1 => 'DolbyVision',
        2 => 'HDR10',
        3 => 'HLG',
        4 => 'HDR10+',
        _ => 'type$t',
      },
  ];
  final panel = await DisplayReport.fetchPanelSize();
  final report = DisplayReport.read(panel: panel);
  String? size(int? w, int? h) => (w == null || h == null) ? null : '${w}x$h';
  return {
    'decoders': decoders,
    'hdr': hdr,
    'render': size(report?.renderWidth, report?.renderHeight),
    'panel': size(
      panel?.width ?? report?.displayWidth ?? info?.width,
      panel?.height ?? report?.displayHeight ?? info?.height,
    ),
  };
}

/// The TV as the paired display of the Pi.
///
/// Connects to the Pi with `hello {kind: "display"}` (last address, then
/// mDNS, then retries), keeps the token in secure storage, shows the pairing
/// code while no phone is paired, plays what `display.load` and
/// `display.control` say, and sends the remote's keys as `player.*` requests
/// over its own socket. With the Pi gone the current item keeps looping.
class DisplayClient extends ChangeNotifier {
  DisplayClient({
    required this.client,
    required this.store,
    required DisplayVideoNative native,
    HubScanner? scanner,
    MulticastLock? lock,
    Future<Map<String, Object?>> Function()? capabilities,
    Duration positionInterval = const Duration(seconds: 10),
    Duration statsInterval = const Duration(seconds: 1),
    Duration errorRetry = const Duration(seconds: 3),
    this.retryDelay = const Duration(seconds: 3),
  }) : _scanner = scanner ?? HubScanner(timeout: const Duration(seconds: 6)),
       _lock = lock ?? MulticastLock(),
       _capabilities = capabilities ?? (() => readCapabilities(native)) {
    player = DisplayPlayer(
      native: native,
      positionInterval: positionInterval,
      statsInterval: statsInterval,
      errorRetry: errorRetry,
      reportEnded: _reportEnded,
      reportPosition: _reportPosition,
    );
  }

  final HubClient client;
  final HubTokenStore store;
  late final DisplayPlayer player;
  final HubScanner _scanner;
  final MulticastLock _lock;
  final Future<Map<String, Object?>> Function() _capabilities;

  /// Pause between connection attempts when nothing answers.
  final Duration retryDelay;

  late final List<StreamSubscription<Map<String, dynamic>>> _subs;
  Future<void> _chain = Future.value();
  bool _started = false;
  bool _disposed = false;
  bool _wasConnected = false;
  bool _discovering = false;
  bool _lockHeld = false;
  Timer? _retryTimer;

  /// null until the first snapshot says whether any phone is paired.
  bool? _hasPhone;
  int _phoneCount = 0;
  bool _manualPairing = false;
  bool _sessionOpen = false;
  PairingInfo? _pairing;
  String? _pairingError;
  Map<String, dynamic>? _lastChanged;

  HubClientState get hub => client.state.value;
  bool get connected => hub.phase == HubConnectionPhase.connected;

  /// The pairing screen is wanted: no phone is paired, or the user asked to
  /// pair another one.
  bool get needsPairing => _hasPhone == false || _manualPairing;
  PairingInfo? get pairing => needsPairing ? _pairing : null;
  String? get pairingError => needsPairing ? _pairingError : null;

  /// Whether the TV has stopped trying to reach the Pi on its own.
  bool get gaveUp =>
      hub.phase == HubConnectionPhase.replaced ||
      hub.phase == HubConnectionPhase.needsTvUpdate;

  String get statusText => switch (hub.phase) {
    HubConnectionPhase.connected => '',
    HubConnectionPhase.connecting ||
    HubConnectionPhase.reconnecting ||
    HubConnectionPhase.disconnected => 'Connecting to the Pi…',
    HubConnectionPhase.offline ||
    HubConnectionPhase.appNotOpen ||
    HubConnectionPhase.wrongTv => 'The Pi is not reachable. Trying again…',
    HubConnectionPhase.needsTvUpdate =>
      'The Pi server is older than this app. Update the Pi.',
    HubConnectionPhase.replaced => 'This TV was replaced by another one.',
    HubConnectionPhase.awaitingPin => 'Connecting to the Pi…',
  };

  /// Starts connecting. Safe to call once.
  Future<void> start() async {
    if (_started || _disposed) return;
    _started = true;
    client.state.addListener(_onHubState);
    _subs = [
      client.snapshots.listen(_onSnapshot),
      client.events.listen((m) => _chain = _chain.then((_) => _onFrame(m))),
    ];
    _syncLock();
    await _connect();
  }

  // ---- connecting ----

  Future<void> _connect() async {
    if (_disposed || connected) return;
    SavedHubPairing? saved;
    try {
      saved = await store.getLastPairing();
    } catch (_) {}
    if (_disposed || connected) return;
    if (saved != null) {
      unawaited(_guarded(() async => client.reconnectSavedHub()));
    } else {
      unawaited(_discover());
    }
  }

  Future<void> _guarded(Future<void> Function() body) async {
    try {
      await body();
    } catch (_) {
      _scheduleRetry();
    }
  }

  /// First start: find the Pi by mDNS and join it as the display.
  Future<void> _discover() async {
    if (_discovering) return;
    _discovering = true;
    _syncLock();
    try {
      while (!_disposed && !connected && !gaveUp) {
        try {
          await for (final ep in _scanner.scan().timeout(
            const Duration(seconds: 7),
          )) {
            if (_disposed) return;
            if (await client.connectEndpoint(ep)) return;
            if (gaveUp) return;
          }
        } catch (_) {
          // No multicast or nothing found: wait and look again.
        }
        if (_disposed || connected || gaveUp) return;
        await Future<void>.delayed(retryDelay);
      }
    } finally {
      _discovering = false;
      _syncLock();
    }
  }

  void _scheduleRetry() {
    if (_disposed || gaveUp) return;
    _retryTimer?.cancel();
    _retryTimer = Timer(retryDelay, () {
      if (!_disposed && !connected && !gaveUp) unawaited(_connect());
    });
  }

  void _onHubState() {
    final now = connected;
    if (now && !_wasConnected) {
      _wasConnected = true;
      _onConnected();
    } else if (!now && _wasConnected) {
      _wasConnected = false;
      _onDisconnected();
    }
    // The client stops its own retries on a final answer (for example
    // `conflict`); the TV keeps trying.
    if (hub.phase == HubConnectionPhase.disconnected && _started) {
      _scheduleRetry();
    }
    _syncLock();
    _notify();
  }

  void _onConnected() {
    _sessionOpen = false;
    _pairing = null;
    _pairingError = null;
    unawaited(_announce());
  }

  void _onDisconnected() {
    _sessionOpen = false;
    _pairing = null;
  }

  /// On every (re)connect: capabilities, then the report of what is on
  /// screen, before anything from the snapshot is applied.
  Future<void> _announce() async {
    try {
      await client.request('display.capabilities', await _capabilities());
    } catch (_) {}
    try {
      await client.request('player.report', await _report());
    } catch (_) {}
  }

  Future<Map<String, Object?>> _report() async {
    final s = await player.freshSnapshot();
    final id = s.itemId;
    final changed = _lastChanged;
    final sameItem = id != null && changed?['itemId'] == id;
    return {
      'playlistId': id == null
          ? null
          : (sameItem ? changed!['playlistId'] : kAllPlaylistId),
      'index': sameItem ? (changed!['index'] ?? 0) : 0,
      'itemId': id,
      'state': s.state,
      'positionMs': id == null ? 0 : s.positionMs,
      'durationMs': ?s.durationMs,
      'muted': s.muted,
      'at': client.tvNowMs(),
    };
  }

  // ---- frames from the Pi ----

  void _onSnapshot(Map<String, dynamic> snap) {
    final modules = snap['modules'];
    final devices = modules is Map ? modules['devices'] : null;
    _setDevices(devices is Map ? devices['devices'] : null);
  }

  Future<void> _onFrame(Map<String, dynamic> msg) async {
    if (_disposed) return;
    try {
      switch (msg['t']) {
        case 'display.pairing':
          final qr = msg['qr'];
          final pin = msg['pin'];
          final expires = msg['expiresAt'];
          if (qr is String && pin is String && expires is num) {
            _pairing = PairingInfo(
              qr: qr,
              pin: pin,
              expiresAt: DateTime.fromMillisecondsSinceEpoch(expires.toInt()),
            );
            _pairingError = null;
            _notify();
          }
        case 'display.load':
          await _onLoad(msg);
        case 'display.control':
          await player.control(
            '${msg['action']}',
            positionMs: (msg['positionMs'] as num?)?.toInt(),
            muted: msg['muted'] as bool?,
          );
        case HubMsg.event:
          final data = msg['data'];
          if (data is! Map<String, dynamic>) return;
          if (msg['kind'] == 'player.changed') {
            _lastChanged = data;
          } else if (msg['kind'] == 'devices.changed') {
            _setDevices(data['devices']);
          }
      }
    } catch (_) {
      // One bad frame never stops the TV.
    }
  }

  Future<void> _onLoad(Map<String, dynamic> msg) async {
    final itemId = msg['itemId'];
    if (itemId is! String || itemId.isEmpty) return;
    final st = hub;
    final host = st.host;
    final port = st.port;
    final hubId = st.hubId;
    if (host == null || port == null || hubId == null) return;
    final saved = await store.getPairing(hubId);
    final token = saved?.token;
    if (token == null || token.isEmpty) return;
    final url = Uri(
      scheme: 'http',
      host: host,
      port: port,
      pathSegments: ['media', itemId, msg['variant'] as String? ?? 'full'],
    );
    await player.load(
      itemId: itemId,
      url: url.toString(),
      headers: {'Authorization': 'Bearer $token'},
      startAtMs: (msg['startAt'] as num?)?.toInt() ?? 0,
      muted: msg['muted'] as bool?,
    );
    _notify();
  }

  void _setDevices(Object? list) {
    if (list is! List) return;
    var phones = 0;
    for (final d in list) {
      if (d is Map && d['role'] != 'display') phones++;
    }
    final grew = phones > _phoneCount;
    _phoneCount = phones;
    _hasPhone = phones > 0;
    if (grew) _manualPairing = false; // The phone the user was adding paired.
    _syncPairing();
    _notify();
  }

  /// Opens or closes the Pi's pairing session to match [needsPairing].
  void _syncPairing() {
    if (!connected) return;
    if (needsPairing && !_sessionOpen) {
      _sessionOpen = true;
      unawaited(() async {
        try {
          await client.request('devices.startPairing');
          _pairingError = null;
        } catch (e) {
          _sessionOpen = false;
          _pairingError = e is HubError
              ? (e.message ?? 'Pairing is not available')
              : 'Pairing is not available';
          _notify();
        }
      }());
    } else if (!needsPairing && _sessionOpen) {
      _sessionOpen = false;
      _pairing = null;
      unawaited(_quiet(() => client.request('devices.cancelPairing')));
    }
  }

  // ---- player reports ----

  Future<bool> _reportEnded(String itemId) async {
    if (!connected) return false;
    try {
      await client.request('player.ended', {'itemId': itemId});
      return true;
    } catch (_) {
      return false;
    }
  }

  void _reportPosition(PlayerSnapshot s) {
    final id = s.itemId;
    if (!connected || id == null) return;
    unawaited(
      _quiet(
        () => client.request('player.position', {
          'itemId': id,
          'positionMs': s.positionMs,
          'durationMs': ?s.durationMs,
          'at': client.tvNowMs(),
        }),
      ),
    );
  }

  Future<void> _quiet(Future<Object?> Function() body) async {
    try {
      await body();
    } catch (_) {}
  }

  // ---- the remote ----

  /// OK: pause when playing, resume when paused.
  Future<void> togglePause() async {
    if (!player.hasItem) return;
    await _quiet(
      () => client.request(player.playing ? 'player.pause' : 'player.resume'),
    );
  }

  Future<void> next() => _quiet(() => client.request('player.next'));
  Future<void> prev() => _quiet(() => client.request('player.prev'));

  /// Fast-forward / rewind: a seek of [deltaMs] from the picture's position.
  Future<void> seekBy(int deltaMs) async {
    if (!player.hasItem) return;
    final s = await player.freshSnapshot();
    var target = s.positionMs + deltaMs;
    final dur = s.durationMs;
    if (dur != null && target > dur) target = dur;
    if (target < 0) target = 0;
    await _quiet(() => client.request('player.seek', {'positionMs': target}));
  }

  /// Hold Back for 10 s: forget every phone.
  Future<void> forgetAllPhones() =>
      _quiet(() => client.request('devices.forgetAll'));

  /// Menu: show a pairing code to add another phone.
  void pairAnotherPhone() {
    _manualPairing = true;
    _syncPairing();
    _notify();
  }

  /// Back on the pairing screen the user asked for.
  void stopPairing() {
    if (!_manualPairing) return;
    _manualPairing = false;
    _syncPairing();
    _notify();
  }

  // ---- plumbing ----

  void _syncLock() {
    final want = _started && !_disposed && (!connected || _discovering);
    if (want == _lockHeld) return;
    _lockHeld = want;
    unawaited(want ? _lock.acquire() : _lock.release());
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _retryTimer?.cancel();
    if (_started) {
      client.state.removeListener(_onHubState);
      for (final s in _subs) {
        s.cancel();
      }
    }
    if (_lockHeld) {
      _lockHeld = false;
      unawaited(_lock.release());
    }
    unawaited(player.dispose());
    unawaited(client.dispose());
    super.dispose();
  }
}
