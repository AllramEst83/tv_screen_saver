import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:hub_core/hub_core.dart';

import '../../shared/multicast_lock.dart';
import '../cache/media_cache.dart';
import '../display_report.dart';
import 'display_native.dart';
import 'display_player.dart';
import 'offline_playlist.dart';

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

int _widthOf(Object? render) {
  final m = RegExp(r'^(\d+)x\d+').firstMatch('$render');
  return m == null ? 0 : int.parse(m.group(1)!);
}

/// Width over height from a `display.load` frame, or null.
double? _aspectOf(Object? width, Object? height) {
  if (width is! num || height is! num || width <= 0 || height <= 0) {
    return null;
  }
  return width / height;
}

bool _isPhoto(String id) {
  final dot = id.lastIndexOf('.');
  if (dot < 0) return false;
  return const {
    'jpg',
    'jpeg',
    'png',
    'webp',
    'gif',
    'avif',
    'heic',
    'heif',
  }.contains(id.substring(dot + 1).toLowerCase());
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
    Duration anchorDelay = const Duration(seconds: 3),
    MediaCache? cache,
    this.retryDelay = const Duration(seconds: 3),
    this.approvalHintDelay = const Duration(seconds: 3),
  }) : _scanner = scanner ?? HubScanner(timeout: const Duration(seconds: 6)),
       _lock = lock ?? MulticastLock(),
       _capabilities = capabilities ?? (() => readCapabilities(native)) {
    player = DisplayPlayer(
      native: native,
      positionInterval: positionInterval,
      statsInterval: statsInterval,
      errorRetry: errorRetry,
      anchorDelay: anchorDelay,
      reportEnded: _reportEnded,
      reportPosition: _reportPosition,
      cache: cache,
      imageVariant: () =>
          player.nativeImages || _renderWidth >= 3840 || _renderWidth == 0
          ? 'full'
          : '1920',
    );
  }

  final HubClient client;
  final HubTokenStore store;
  late final DisplayPlayer player;
  final HubScanner _scanner;
  final MulticastLock _lock;
  final Future<Map<String, Object?>> Function() _capabilities;

  /// Width in pixels the app renders at (from `display.capabilities`); 0
  /// until known. Below 3840 the 1920 px photo variant is enough.
  int _renderWidth = 0;

  /// Pause between connection attempts when nothing answers.
  final Duration retryDelay;

  /// A connection without a token that is still open after this long is
  /// probably waiting for a phone to approve the TV.
  final Duration approvalHintDelay;

  late final List<StreamSubscription<Map<String, dynamic>>> _subs;
  Future<void> _chain = Future.value();
  bool _started = false;
  bool _disposed = false;
  bool _wasConnected = false;
  bool _discovering = false;
  bool _lockHeld = false;
  Timer? _retryTimer;
  Timer? _pairingRetry;
  Timer? _loadRetry;
  Timer? _approvalTimer;
  bool _awaitingApproval = false;
  bool _approvalFailed = false;

  /// null until the first snapshot says whether any phone is paired.
  bool? _hasPhone;
  int _phoneCount = 0;
  bool _manualPairing = false;
  bool _sessionOpen = false;
  PairingInfo? _pairing;
  String? _pairingError;
  Map<String, dynamic>? _lastChanged;

  /// The current playlist, for looping the cached part of it when the Pi
  /// cannot be reached.
  OfflinePlaylist? _offline;

  /// Where the Pi last was and the token for it (offline loads use them to
  /// name cached files).
  ({String host, int port, String token})? _base;

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

  /// Whether the Pi seems to wait for a phone to approve this TV.
  bool get awaitingApproval => _awaitingApproval && !connected;

  String get statusText => awaitingApproval
      ? 'Approve this TV on your phone'
      : _approvalFailed && !connected
      ? 'No phone approved this TV. Open the phone app and try again.'
      : _phaseText;

  String get _phaseText => switch (hub.phase) {
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
    } catch (e) {
      _log('reading the saved pairing', e);
    }
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
    } catch (e) {
      _log('connecting', e);
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
            if (await _joinAsDisplay(ep)) return;
            if (gaveUp) return;
          }
        } catch (e) {
          // No multicast or nothing found: wait and look again.
          _log('looking for the Pi', e);
        }
        if (_disposed || connected || gaveUp) return;
        await Future<void>.delayed(retryDelay);
      }
    } finally {
      _discovering = false;
      _syncLock();
    }
  }

  /// Joins the Pi at [ep] without a token. If the Pi keeps the connection
  /// open it waits for a phone to approve this TV; the screen says so.
  Future<bool> _joinAsDisplay(HubEndpoint ep) async {
    _approvalTimer?.cancel();
    _approvalTimer = Timer(approvalHintDelay, () {
      _awaitingApproval = true;
      _notify();
    });
    final ok = await client.connectEndpoint(ep);
    _approvalTimer?.cancel();
    final waited = _awaitingApproval;
    _awaitingApproval = false;
    _approvalFailed = !ok && waited;
    _notify();
    return ok;
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
      final caps = await _capabilities().timeout(const Duration(seconds: 5));
      _renderWidth = _widthOf(caps['render']);
      // The Flutter plane is below the panel (1080p on the X90K): photos go
      // on the native 4K surface and the full-size file is used.
      final panelWidth = _widthOf(caps['panel']);
      player.nativeImages =
          panelWidth >= 3840 && _renderWidth > 0 && _renderWidth < 3840;
      await client.request('display.capabilities', caps);
    } catch (e) {
      _log('sending capabilities', e); // The report still goes out.
    }
    try {
      await client.request('player.report', await _report());
    } catch (e) {
      _log('sending the report', e);
    }
  }

  Future<Map<String, Object?>> _report() async {
    final s = await player.freshSnapshot();
    final id = s.itemId;
    final changed = _lastChanged;
    final sameItem = id != null && changed?['itemId'] == id;
    // After a trip through the cached playlist the TV is on an item the Pi
    // has not heard of: name it by the playlist the TV was given.
    final local = id == null || sameItem ? -1 : (_offline?.indexOf(id) ?? -1);
    return {
      'playlistId': id == null
          ? null
          : sameItem
          ? changed!['playlistId']
          : (local >= 0 ? _offline!.playlistId : kAllPlaylistId),
      'index': sameItem ? (changed!['index'] ?? 0) : (local >= 0 ? local : 0),
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
        case 'display.prefetch':
          await _onPrefetch(msg);
        case 'display.playlist':
          _offline = OfflinePlaylist.tryParse(msg) ?? _offline;
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
    } catch (e) {
      // One bad frame never stops the TV.
      _log('handling ${msg['t']}', e);
    }
  }

  Future<void> _onLoad(Map<String, dynamic> msg, [int attempt = 0]) async {
    final itemId = msg['itemId'];
    if (itemId is! String || itemId.isEmpty) return;
    final st = hub;
    final host = st.host;
    final port = st.port;
    final hubId = st.hubId;
    String? token;
    if (host != null && port != null && hubId != null) {
      token = (await store.getPairing(hubId))?.token;
    }
    if (token == null || token.isEmpty) {
      // No address or token yet (still connecting): try again shortly.
      debugPrint('TV Saver: display.load waits for the address and token');
      if (!connected) _scheduleRetry();
      if (attempt < 5 && !_disposed) {
        _loadRetry?.cancel();
        _loadRetry = Timer(retryDelay, () {
          _chain = _chain.then((_) => _onLoad(msg, attempt + 1));
        });
      }
      return;
    }
    _base = (host: host!, port: port!, token: token);
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
      isImage: msg['kind'] == 'image',
      imageMs: (msg['imageMs'] as num?)?.toInt() ?? 10000,
      crossfade: msg['transition'] != 'cut',
      kenBurns: msg['kenBurns'] == true,
      cacheRequired: msg['cacheRequired'] == true,
      loop: msg['loop'] == true,
      aspect: _aspectOf(msg['width'], msg['height']),
      info: ItemInfo(
        name: msg['name'] as String?,
        index: (msg['index'] as num?)?.toInt(),
        count: (msg['count'] as num?)?.toInt(),
        isImage: msg['kind'] == 'image',
      ),
    );
    _notify();
  }

  /// `display.prefetch`: cache the items that play next (photos in the
  /// variant this TV needs; videos only when they are small enough to keep).
  Future<void> _onPrefetch(Map<String, dynamic> msg) async {
    final cache = player.cache;
    final ids = msg['itemIds'];
    if (cache == null || ids is! List) return;
    final cap = (msg['cacheBytes'] as num?)?.toInt();
    if (cap != null && cap > 0) cache.capBytes = cap;
    final st = hub;
    final host = st.host;
    final port = st.port;
    final hubId = st.hubId;
    if (host == null || port == null || hubId == null) return;
    final token = (await store.getPairing(hubId))?.token;
    if (token == null || token.isEmpty) return;
    _base = (host: host, port: port, token: token);
    final headers = {'Authorization': 'Bearer $token'};
    Uri urlOf(String id, String variant) => Uri(
      scheme: 'http',
      host: host,
      port: port,
      pathSegments: ['media', id, variant],
    );
    final requests = <CacheRequest>[];
    for (final id in ids.whereType<String>()) {
      if (_isPhoto(id)) {
        final full = CacheRequest(
          key: '$id.full',
          url: urlOf(id, 'full'),
          headers: headers,
        );
        final variant = player.imageVariant();
        requests.add(
          variant == 'full'
              ? full
              : CacheRequest(
                  key: '$id.$variant',
                  url: urlOf(id, variant),
                  headers: headers,
                  fallback: full,
                ),
        );
      } else {
        requests.add(
          CacheRequest(
            key: '$id.full',
            url: urlOf(id, 'full'),
            headers: headers,
            maxBytes: cache.maxStreamedItemBytes,
          ),
        );
      }
    }
    cache.prefetch(requests);
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
          _log('starting pairing', e);
          _sessionOpen = false;
          _pairingError = e is HubError
              ? (e.message ?? 'Pairing is not available')
              : 'Pairing is not available';
          _notify();
          // Try again: the Pi may only have been busy.
          _pairingRetry?.cancel();
          _pairingRetry = Timer(retryDelay, _syncPairing);
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
    // Without the Pi the next cached item plays; with none, this one loops.
    if (!connected) return _advanceLocally(1);
    try {
      final r = await client.request('player.ended', {'itemId': itemId});
      // `moved: false`: the Pi has nothing next (stale item, emptied
      // playlist), so the item loops here (or the Pi stops it).
      if (r['moved'] == true) return true;
      // A `stop` for an emptied playlist follows the reply; give it a moment
      // so the item does not flash once more before it goes.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      return false;
    } catch (e) {
      _log('player.ended', e);
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

  /// Runs a request and says whether it worked; a failure is only logged
  /// (frame-level facts, never a token).
  Future<bool> _quiet(Future<Object?> Function() body) async {
    try {
      await body();
      return true;
    } catch (e) {
      _log('a request', e);
      return false;
    }
  }

  void _log(String what, Object e) {
    final why = e is HubError ? 'code ${e.code}' : '${e.runtimeType}';
    debugPrint('TV Saver: $what failed ($why)');
  }

  // ---- the remote ----

  /// OK: pause when playing, resume when paused.
  Future<void> togglePause() async {
    if (!player.hasItem) return;
    if (!connected) {
      await player.control(player.playing ? 'pause' : 'resume');
      _notify();
      return;
    }
    await _quiet(
      () => client.request(player.playing ? 'player.pause' : 'player.resume'),
    );
  }

  Future<void> next() async {
    if (!connected) {
      await _advanceLocally(1);
      return;
    }
    await _quiet(() => client.request('player.next'));
  }

  Future<void> prev() async {
    if (!connected) {
      await _advanceLocally(-1);
      return;
    }
    await _quiet(() => client.request('player.prev'));
  }

  /// Fast-forward / rewind: a seek of [deltaMs] from the picture's position.
  Future<void> seekBy(int deltaMs) async {
    if (!player.hasItem) return;
    final s = await player.freshSnapshot();
    var target = s.positionMs + deltaMs;
    final dur = s.durationMs;
    if (dur != null && target > dur) target = dur;
    if (target < 0) target = 0;
    if (!connected) {
      await player.control('seek', positionMs: target);
      return;
    }
    await _quiet(() => client.request('player.seek', {'positionMs': target}));
  }

  // ---- offline ----

  /// Whether the file the player would use for [item] is in the cache.
  Future<bool> _isCached(OfflineItem item) async {
    final cache = player.cache;
    if (cache == null) return false;
    if (!item.isImage) return await cache.lookup('${item.id}.full') != null;
    final variant = player.imageVariant();
    if (variant != 'full' &&
        await cache.lookup('${item.id}.$variant') != null) {
      return true;
    }
    return await cache.lookup('${item.id}.full') != null;
  }

  /// Plays the next (or previous) item of the playlist that is in the cache.
  /// False when there is none other than the current one.
  Future<bool> _advanceLocally(int delta) async {
    final list = _offline;
    final base = _base;
    if (list == null || base == null || list.items.isEmpty) return false;
    final n = list.items.length;
    final current = player.itemId;
    final at = current == null ? -1 : list.indexOf(current);
    final start = at >= 0 ? at : (delta > 0 ? -1 : 0);
    for (var k = 1; k <= n; k++) {
      final i = (((start + delta * k) % n) + n) % n;
      final item = list.items[i];
      if (item.id == current) continue;
      if (!await _isCached(item)) continue;
      await player.load(
        itemId: item.id,
        url: Uri(
          scheme: 'http',
          host: base.host,
          port: base.port,
          pathSegments: ['media', item.id, 'full'],
        ).toString(),
        headers: {'Authorization': 'Bearer ${base.token}'},
        muted: player.muted,
        isImage: item.isImage,
        imageMs: list.imageMs ?? 10000,
        crossfade: list.crossfade,
        kenBurns: list.kenBurns,
        info: ItemInfo(
          name: item.name,
          index: i,
          count: n,
          isImage: item.isImage,
        ),
      );
      _notify();
      return true;
    }
    return false;
  }

  /// Hold Back for 10 s: forget every phone. False when the Pi did not do it.
  Future<bool> forgetAllPhones() =>
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
    _pairingRetry?.cancel();
    _loadRetry?.cancel();
    _approvalTimer?.cancel();
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
