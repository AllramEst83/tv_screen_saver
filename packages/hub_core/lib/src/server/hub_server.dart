import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../db/hub_database.dart';
import '../observable.dart';
import '../protocol.dart';
import '../tv_store.dart';
import 'hub_module.dart';
import 'devices_module.dart';

typedef HttpRouteHandler = Future<bool> Function(HttpRequest request);

/// Pairing credentials currently active on the TV (4-digit PIN and one-time
/// QR code).
class ActivePairingCredentials {
  const ActivePairingCredentials({
    required this.pin,
    required this.pairCode,
    required this.expiresAt,
  });

  final String pin;
  final String pairCode;
  final DateTime expiresAt;
}

/// Close code for "try again later". dart:io rejects the registered 1013, so
/// this uses the application range.
const _tryAgainLater = 4013;

/// Multi-client authoritative WebSocket and HTTP hub server.
///
/// Supports up to [maxClients] concurrent phones, SHA-256 hashed tokens in the
/// database, QR one-time code and 4-digit PIN pairing with a 3-attempt / 60 s
/// lockout, per-device identity with `owner` and `controller` roles, module
/// handler routing, targeted events and unrevisioned hot streams.

class HubServer {
  HubServer({
    required this.db,
    required this.store,
    required this.name,
    this.preferredPort = kDefaultHubPort,
    this.bindAddress,
    this.strictPort = false,
    this.maxClients = 8,
    this.idleTimeout = const Duration(seconds: 20),
    this.pairingTimeout = const Duration(seconds: 120),
    this.pairCodeTtl = const Duration(seconds: 120),
    Random? random,
    DateTime Function()? now,
  }) : _random = random ?? Random.secure(),
       _now = now ?? DateTime.now;

  final HubDatabase db;
  final TvStore store;

  /// Shown in `ready`; changed by the TV name setting.
  String name;
  final int preferredPort;

  /// Interface to listen on; null means all IPv4 interfaces.
  final InternetAddress? bindAddress;

  /// When true, [start] throws a [SocketException] if [preferredPort] is busy
  /// instead of falling back to an ephemeral port.
  final bool strictPort;
  final int maxClients;
  final Duration idleTimeout;
  final Duration pairingTimeout;

  /// Lifetime of one QR code and PIN before they rotate.
  final Duration pairCodeTtl;
  final Random _random;
  final DateTime Function() _now;

  static const maxPairAttempts = 3;
  static const pairLockout = Duration(seconds: 60);
  static const _maxOpCacheSize = 500;

  /// Current pairing credentials shown on the TV pairing dialog (or null).
  final Observable<ActivePairingCredentials?> pairingCredentials = Observable(
    null,
  );

  /// Emits whenever a phone reaches `pair_required` so the TV can open the
  /// pairing dialog.
  final _pairRequestedCtrl =
      StreamController<ActivePairingCredentials>.broadcast();
  Stream<ActivePairingCredentials> get onPairRequested =>
      _pairRequestedCtrl.stream;

  /// Emits when a phone finishes pairing (QR or PIN), so the TV can close the
  /// pairing dialog.
  final _devicePairedCtrl = StreamController<DeviceInfo>.broadcast();
  Stream<DeviceInfo> get onDevicePaired => _devicePairedCtrl.stream;

  /// Every outbound event, so the in-process TV UI stays synced without a
  /// socket.
  final _localEventsCtrl = StreamController<HubOutboundEvent>.broadcast();
  Stream<HubOutboundEvent> get localEvents => _localEventsCtrl.stream;

  final List<HubModule> _modules = [];
  final Map<String, HubHandlerSpec> _handlers = {};
  final List<StreamSubscription<HubOutboundEvent>> _moduleSubs = [];
  final List<HttpRouteHandler> _httpHandlers = [];

  final List<_HubConnection> _connections = [];

  /// token hash -> device, so image requests do not hit the database each
  /// time. Dropped when a device or all pairings are forgotten.
  final Map<String, DeviceInfo> _tokenCache = {};
  final LinkedHashMap<String, Object?> _opCache = LinkedHashMap();

  HttpServer? _http;
  bool _stopped = false;
  String _hubId = '';
  int _rev = 0;
  int _connSeq = 0;
  int _wrongAttempts = 0;
  DateTime? _firstFailureAt;
  DateTime? _lockedUntil;
  bool _pairingDialogOpen = false;
  Timer? _rotateTimer;

  /// Connection id of the display that opened the current pairing session;
  /// it receives `display.pairing` frames.
  String? _pairingDisplayConnId;

  /// Displays waiting for a phone to approve them, by request id.
  final Map<String, _WaitingDisplay> _waitingDisplays = {};

  /// Off: new phones are refused (`err forbidden`); paired phones still
  /// connect with their token.
  bool allowPairing = true;

  /// Phones that are connected and ready right now.
  final Observable<int> connectedPhones = Observable(0);
  Future<void> _issueLock = Future.value();

  int get port => _http?.port ?? 0;
  String get hubId => _hubId;
  int get rev => _rev;
  int get readyClientCount => _connections.where((c) => c.ready).length;
  DateTime get currentTime => _now();

  Set<String> get onlineDeviceIds => {
    for (final c in _connections)
      if (c.ready && c.device != null) c.device!.id,
  };

  /// Registers a domain [HubModule] before calling [start].
  void registerModule(HubModule module) {
    _modules.add(module);
    for (final entry in module.handlers.entries) {
      _handlers[entry.key] = entry.value;
    }
    _moduleSubs.add(module.events.listen(_dispatchModuleEvent));
  }

  /// Registers an extra HTTP route handler.
  void registerHttpHandler(HttpRouteHandler handler) {
    _httpHandlers.add(handler);
  }

  /// Opens the TV pairing dialog and rotates fresh QR code and PIN valid for
  /// 120 s.
  ActivePairingCredentials openPairingSession() {
    _pairingDialogOpen = true;
    return rotatePairingCredentials();
  }

  /// Closes the pairing session: no phone can pair until it is opened again.
  void closePairingSession() {
    _pairingDialogOpen = false;
    _pairingDisplayConnId = null;
    _rotateTimer?.cancel();
    _rotateTimer = null;
    pairingCredentials.value = null;
    // Phones waiting for a PIN must not hang.
    for (final c in [..._connections]) {
      if (c.pairing && !c.ready) {
        c.pairing = false;
        _send(c, HubMsg.err, {
          'code': HubErrorCode.unavailable,
          'msg': 'Pairing was closed on the TV.',
        });
        try {
          c.socket.close();
        } catch (_) {}
      }
    }
  }

  /// `devices.startPairing`: opens a session whose credentials are relayed to
  /// the display connection [connectionId].
  Future<void> startPairingFor(String connectionId) async {
    if (!allowPairing) {
      throw const HubError(HubErrorCode.forbidden, 'Pairing is turned off');
    }
    _pairingDisplayConnId = connectionId;
    openPairingSession();
  }

  /// `devices.cancelPairing` from display connection [connectionId].
  Future<void> cancelPairingFor(String connectionId) async {
    if (_pairingDisplayConnId == connectionId) closePairingSession();
  }

  void _relayPairing() {
    final id = _pairingDisplayConnId;
    final creds = pairingCredentials.value;
    if (id == null || creds == null) return;
    for (final c in _connections) {
      if (c.id != id || !c.ready) continue;
      final host = c.localHost;
      if (host == null) {
        _send(c, HubMsg.err, {
          'code': HubErrorCode.unavailable,
          'msg': 'The Pi has no LAN address to put in the QR code',
        });
        continue;
      }
      final qr = currentQrUri(host);
      if (qr == null) continue;
      _send(c, 'display.pairing', {
        'qr': qr,
        'pin': creds.pin,
        'expiresAt': creds.expiresAt.millisecondsSinceEpoch,
      });
    }
  }

  /// Rotates both the 4-digit PIN and the 128-bit base64url one-time QR
  /// `pairCode`.
  ActivePairingCredentials rotatePairingCredentials() {
    final creds = ActivePairingCredentials(
      pin: _newPin(),
      pairCode: _newPairCode(),
      expiresAt: _now().add(pairCodeTtl),
    );
    pairingCredentials.value = creds;
    _rotateTimer?.cancel();
    _rotateTimer = null;
    if (_pairingDialogOpen && !_stopped) {
      _rotateTimer = Timer(pairCodeTtl, () {
        if (_pairingDialogOpen && !_stopped) rotatePairingCredentials();
      });
    }
    _relayPairing();
    return creds;
  }

  /// Builds the current `tvsaver://pair?...` QR URI for [lanHost].
  String? currentQrUri(String lanHost) {
    final creds = pairingCredentials.value;
    if (creds == null || _hubId.isEmpty || port == 0) return null;
    return PairQrData(
      version: kProtocolVersion,
      host: lanHost,
      port: port,
      hubId: _hubId,
      pairCode: creds.pairCode,
    ).toUriString();
  }

  /// Starts listening on [preferredPort] (falling back to an ephemeral port
  /// if busy). The advertised port is the truth.
  Future<int> start() async {
    if (_stopped) throw StateError('HubServer was stopped; create a new one');
    _hubId = await store.hubId();
    final address = bindAddress ?? InternetAddress.anyIPv4;
    try {
      _http = await HttpServer.bind(address, preferredPort);
    } on SocketException {
      if (strictPort) rethrow;
      _http = await HttpServer.bind(address, 0);
    }
    _http!.listen(_onRequest, onError: (_) {});
    return port;
  }

  /// Stops the server, closes all sockets, and disposes registered modules.
  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    _rotateTimer?.cancel();
    _rotateTimer = null;
    for (final w in _waitingDisplays.values) {
      w.timer.cancel();
    }
    _waitingDisplays.clear();
    await _http?.close(force: true);
    _http = null;
    for (final c in [..._connections]) {
      c.idle?.cancel();
      try {
        await c.socket.close();
      } catch (_) {}
    }
    _connections.clear();
    pairingCredentials.value = null;
    pairingCredentials.dispose();
    connectedPhones.dispose();
    for (final sub in _moduleSubs) {
      await sub.cancel();
    }
    _moduleSubs.clear();
    for (final m in _modules) {
      await m.dispose();
    }
    await _pairRequestedCtrl.close();
    await _devicePairedCtrl.close();
    await _localEventsCtrl.close();
  }

  /// Forgets every paired device (phones and display) and drops all sockets.
  /// Their tokens stop working. Used by the admin reset.
  Future<void> resetAll() => _withLock(() async {
    closePairingSession();
    for (final w in _waitingDisplays.values) {
      w.timer.cancel();
    }
    _waitingDisplays.clear();
    _tokenCache.clear();
    await db.deleteAllDevices();
    _tokenCache.clear();
    for (final c in [..._connections]) {
      c.revoked = true;
      c.idle?.cancel();
      try {
        await c.socket.close(WebSocketStatus.policyViolation);
      } catch (_) {}
    }
    _connections.clear();
    await _notifyPresence();
  });

  /// Same as [resetAll].
  Future<void> forgetPairings() => resetAll();

  /// `devices.forgetAll`: deletes every phone pairing and closes phone
  /// sockets. The display stays connected. The caller's own socket (an owner
  /// phone) closes right after its reply went out.
  Future<void> forgetAllPhones([String? callerConnectionId]) =>
      _withLock(() async {
        _tokenCache.removeWhere((_, d) => !d.isDisplay);
        await db.deleteAllPhones();
        _tokenCache.removeWhere((_, d) => !d.isDisplay);
        _HubConnection? caller;
        for (final c in [..._connections]) {
          if (c.isDisplay || c.wantsDisplay) continue;
          // Phones still mid-pairing (no device yet) are closed too.
          c.revoked = true;
          _connections.remove(c);
          c.idle?.cancel();
          if (c.id == callerConnectionId) {
            caller = c;
            continue;
          }
          try {
            await c.socket.close(WebSocketStatus.policyViolation);
          } catch (_) {}
        }
        await _releaseWaitingDisplay();
        await _notifyPresence();
        if (caller != null) {
          // After this handler returns, so the reply still reaches the phone.
          Timer(Duration.zero, () {
            try {
              caller!.socket.close(WebSocketStatus.policyViolation);
            } catch (_) {}
          });
        }
      });

  /// With no phone left to approve, a waiting TV is admitted (physical
  /// presence is the only proof). Callers hold the issue lock.
  Future<void> _releaseWaitingDisplay() async {
    if (_waitingDisplays.isEmpty || await db.phoneCount() > 0) return;
    final id = _waitingDisplays.keys.first;
    final w = _endWaiting(id);
    if (w == null || w.conn.socket.readyState != WebSocket.open) return;
    _watchIdle(w.conn, pairingTimeout);
    await _issueDevice(w.conn, display: true);
  }

  /// Ends a waiting request: stops its timer and tells phones to drop it.
  _WaitingDisplay? _endWaiting(String requestId) {
    final w = _waitingDisplays.remove(requestId);
    if (w == null) return null;
    w.timer.cancel();
    w.conn.waitingApproval = false;
    for (final o in _connections) {
      if (o.ready && o.device != null && !o.device!.isDisplay) {
        _send(o, 'devices.approvalCancelled', {'requestId': requestId});
      }
    }
    return w;
  }

  /// Forgets one device: deletes its pairings and closes its sockets.
  Future<void> forgetDevice(String deviceId) async {
    _tokenCache.removeWhere((_, d) => d.id == deviceId);
    await db.deleteDevice(deviceId);
    _tokenCache.removeWhere((_, d) => d.id == deviceId);
    for (final c in [..._connections]) {
      if (c.device?.id == deviceId) {
        c.revoked = true;
        _connections.remove(c);
        c.idle?.cancel();
        try {
          await c.socket.close(WebSocketStatus.policyViolation);
        } catch (_) {}
      }
    }
    await _notifyPresence();
    await _withLock(_releaseWaitingDisplay);
  }

  /// Lets the in-process TV UI (D-pad) invoke any registered handler as the
  /// TV owner.
  Future<Object?> invokeLocal(
    String type, [
    Map<String, Object?> args = const {},
    DeviceInfo? asDevice,
  ]) async {
    final spec = _handlers[type];
    if (spec == null) {
      throw HubError(HubErrorCode.notFound, 'Unknown handler $type');
    }
    final caller = asDevice ?? DeviceInfo.tv;
    if (spec.requireOwner && !caller.isOwnerEquivalent) {
      throw const HubError(
        HubErrorCode.forbidden,
        'Only the owner can do this',
      );
    }
    return spec.handler(
      HubCall(
        type: type,
        device: caller,
        args: Map<String, dynamic>.from(args),
        connectionId: '__tv__',
      ),
    );
  }

  /// Builds a fresh snapshot for [device] across all modules.
  Future<Map<String, Object?>> buildFullSnapshot(DeviceInfo device) async {
    final modulesMap = <String, Object?>{};
    for (final m in _modules) {
      modulesMap[m.id] = await m.snapshotFor(device);
    }
    return {
      'rev': _rev,
      'now': _now().millisecondsSinceEpoch,
      'modules': modulesMap,
    };
  }

  /// Authenticates an HTTP request by `Authorization: Bearer <token>`.
  /// Returns the calling device, or null when the token is missing or unknown.
  /// The token hash is looked up in `pairings` once, then served from memory.
  Future<DeviceInfo?> authenticateHttp(HttpRequest request) async {
    final header = request.headers.value(HttpHeaders.authorizationHeader);
    if (header == null || header.length < 8) return null;
    if (header.substring(0, 7).toLowerCase() != 'bearer ') return null;
    final token = header.substring(7).trim();
    if (token.isEmpty) return null;
    final hash = hashToken(token);
    final cached = _tokenCache[hash];
    if (cached != null) return cached;
    final pairing = await db.pairingByHash(hash);
    if (pairing == null) return null;
    final row = await db.getDevice(pairing.deviceId);
    if (row == null) return null;
    final device = DeviceInfo.fromRow(row, online: true);
    _tokenCache[hash] = device;
    return device;
  }

  // ---- HTTP + WebSocket upgrade ----

  Future<void> _onRequest(HttpRequest request) async {
    if (request.uri.path == kWsPath &&
        WebSocketTransformer.isUpgradeRequest(request)) {
      final localHost = await _localHostFor(request);
      final WebSocket socket;
      try {
        socket = await WebSocketTransformer.upgrade(request);
      } catch (_) {
        return;
      }
      // Cap on open sockets, including ones that never finish pairing.
      if (_connections.length >= maxClients * 4) {
        try {
          await socket.close(_tryAgainLater);
        } catch (_) {}
        return;
      }
      _attachSocket(socket, localHost);
      return;
    }

    for (final handler in _httpHandlers) {
      try {
        if (await handler(request)) return;
      } catch (_) {
        try {
          request.response
            ..statusCode = HttpStatus.internalServerError
            ..write('Internal server error');
          await request.response.close();
        } catch (_) {
          // Headers already sent: closing short of the declared length makes
          // the HTTP layer drop the connection.
          try {
            await request.response.close();
          } catch (_) {}
        }
        return;
      }
    }

    // Built-in /health unless a registered handler already answered it.
    if (request.uri.path == '/health') {
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.json
        ..write(
          jsonEncode({
            'ok': true,
            'id': _hubId,
            'v': kProtocolVersion,
            'clients': readyClientCount,
          }),
        );
      await request.response.close();
      return;
    }

    request.response
      ..statusCode = HttpStatus.notFound
      ..write('Not found');
    await request.response.close();
  }

  /// IPv4 address to put in the QR code for this client: the Host header when
  /// it is an IPv4 literal, 127.0.0.1 for loopback clients, else the local
  /// address in the client's /24, else the first non-loopback IPv4 address.
  /// Null when the Pi has none.
  Future<String?> _localHostFor(HttpRequest request) async {
    try {
      final lit = InternetAddress.tryParse(request.requestedUri.host);
      if (lit != null &&
          lit.type == InternetAddressType.IPv4 &&
          !lit.isMulticast &&
          lit.address != '0.0.0.0') {
        return lit.address;
      }
      final remote = request.connectionInfo?.remoteAddress;
      if (remote != null && remote.isLoopback) {
        return InternetAddress.loopbackIPv4.address;
      }
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      );
      if (remote != null && remote.type == InternetAddressType.IPv4) {
        final r = remote.rawAddress;
        for (final i in interfaces) {
          for (final a in i.addresses) {
            final b = a.rawAddress;
            if (b[0] == r[0] && b[1] == r[1] && b[2] == r[2]) return a.address;
          }
        }
      }
      for (final i in interfaces) {
        for (final a in i.addresses) {
          if (!a.isLoopback) return a.address;
        }
      }
    } catch (_) {}
    return null;
  }

  void _attachSocket(WebSocket socket, String? localHost) {
    final conn = _HubConnection('conn_${++_connSeq}', socket)
      ..localHost = localHost;
    _connections.add(conn);
    _watchIdle(conn, pairingTimeout);
    socket.listen(
      (data) {
        if (!conn.waitingApproval) {
          _watchIdle(conn, conn.ready ? idleTimeout : pairingTimeout);
        }
        // Per-connection ordered queue: frames of one phone run one by one.
        conn.queue = conn.queue.then((_) => _onFrame(conn, data));
      },
      onDone: () => _drop(conn),
      onError: (_) => _drop(conn),
      cancelOnError: true,
    );
  }

  void _watchIdle(_HubConnection c, Duration limit) {
    c.idle?.cancel();
    c.idle = Timer(limit, () {
      try {
        c.socket.close(WebSocketStatus.goingAway);
      } catch (_) {}
    });
  }

  Future<void> _drop(_HubConnection c) async {
    c.idle?.cancel();
    final wasReady = c.ready;
    _connections.remove(c);
    for (final id in [
      for (final e in _waitingDisplays.entries)
        if (e.value.conn == c) e.key,
    ]) {
      _endWaiting(id);
    }
    if (_pairingDisplayConnId == c.id) closePairingSession();
    _updatePairingVisibility();
    if (wasReady) {
      await _notifyPresence();
    }
  }

  /// Sends a raw payload; a socket that is closing must never break fan-out.
  void _trySend(_HubConnection c, String payload) {
    try {
      c.socket.add(payload);
    } catch (_) {}
  }

  void _send(
    _HubConnection c,
    String type, [
    Map<String, Object?> fields = const {},
  ]) {
    if (c.socket.readyState == WebSocket.open) {
      _trySend(c, encodeFrame(type, fields));
    }
  }

  void _updatePairingVisibility() {
    if (!_pairingDialogOpen) {
      pairingCredentials.value = null;
    }
  }

  // ---- Frame processing ----

  Future<void> _onFrame(_HubConnection c, Object? raw) async {
    final msg = decodeFrame(raw);
    if (msg == null) return; // Malformed or over 64 KB: ignored.
    final type = msg['t'] as String;
    try {
      if (!c.ready) {
        await _beforeReady(c, type, msg);
      } else {
        await _onReadyFrame(c, type, msg);
      }
    } catch (_) {
      // Never let a frame error crash the server.
    }
  }

  Future<void> _beforeReady(
    _HubConnection c,
    String type,
    Map<String, dynamic> msg,
  ) async {
    if (c.waitingApproval && type != HubMsg.ping) return;
    if (type == HubMsg.hello) {
      final kind = msg['kind'];
      if (kind != null && kind != 'phone' && kind != 'display') {
        _send(c, HubMsg.err, {
          if (msg['rid'] != null) 'rid': msg['rid'],
          'code': HubErrorCode.invalid,
          'msg': 'Unknown device kind',
        });
        await c.socket.close();
        return;
      }
      final rawV = msg['v'];
      final clientVer = rawV == null
          ? 1
          : (rawV is int
                ? rawV
                : (rawV is double && rawV.isFinite && rawV == rawV.truncate()
                      ? rawV.toInt()
                      : 0));
      if (clientVer < 1) {
        _send(c, HubMsg.err, {
          if (msg['rid'] != null) 'rid': msg['rid'],
          'code': HubErrorCode.invalid,
          'msg': 'Invalid protocol version',
        });
        await c.socket.close();
        return;
      }
      if (clientVer > kProtocolVersion) {
        _send(c, HubMsg.err, {
          if (msg['rid'] != null) 'rid': msg['rid'],
          'code': HubErrorCode.upgradeTv,
          'msg': 'The TV app needs an update',
        });
        await c.socket.close();
        return;
      }
      if (c.waitingApproval) return; // A display is already waiting.
      c.helloDone = true;
      final isDisplayHello = kind == 'display';
      c.wantsDisplay = isDisplayHello;
      final rawName = msg['client'];
      final trimmed = rawName is String ? rawName.trim() : '';
      c.clientName = trimmed.isEmpty
          ? (isDisplayHello ? 'TV' : 'Phone')
          : (trimmed.length > DevicesModule.maxNameLength
                ? trimmed.substring(0, DevicesModule.maxNameLength).trimRight()
                : trimmed);

      // Path A: reconnect with a saved token.
      final token = msg['token'];
      if (token is String && token.isNotEmpty) {
        final pairing = await db.verifyRawToken(token);
        if (pairing != null) {
          final row = await db.getDevice(pairing.deviceId);
          // A phone token never opens a display session and vice versa.
          if (row != null && (row.role == 'display') == isDisplayHello) {
            c.tokenHash = pairing.tokenHash;
            await db.touchPairing(
              pairing.tokenHash,
              _now().millisecondsSinceEpoch,
            );
            c.authenticated = true;
            c.pairing = false;
            _updatePairingVisibility();
            await _becomeReady(c, DeviceInfo.fromRow(row, online: true));
            return;
          }
        }
      }

      // New phones are refused while pairing is turned off.
      if (!allowPairing) {
        await _refusePairing(c, msg['rid']);
        return;
      }

      // A TV without a valid token: first display, approval or replacement.
      if (isDisplayHello) {
        await _displayHello(c);
        return;
      }

      // Phones can only pair while the display has a pairing session open.
      if (!_pairingDialogOpen) {
        await _refuseUnavailable(c, msg['rid']);
        return;
      }

      // Path B: one-step QR pairCode. An invalid or reused code falls through
      // to the PIN flow (`pair_required`), unless the lockout is active.
      final pairCode = msg['pairCode'];
      if (pairCode is String && pairCode.isNotEmpty) {
        final now = _now();
        final locked = _lockedUntil;
        if (locked != null && now.isBefore(locked)) {
          _send(c, HubMsg.pairFailed, {
            'retryInMs': locked.difference(now).inMilliseconds,
          });
          return;
        }
        final creds = pairingCredentials.value;
        final valid =
            creds != null &&
            now.isBefore(creds.expiresAt) &&
            constantTimeEquals(creds.pairCode, pairCode);
        if (valid) {
          _wrongAttempts = 0;
          _lockedUntil = null;
          // Single use: rotate immediately so the code cannot be replayed.
          if (_pairingDialogOpen) {
            rotatePairingCredentials();
          } else {
            pairingCredentials.value = null;
          }
          await _issueTokenAndProceed(c);
          return;
        }
        // A wrong or reused code counts toward the lockout like a wrong PIN.
        if (_recordFailedPairAttempt(c, now, notify: false)) {
          _send(c, HubMsg.pairFailed, {
            'retryInMs': pairLockout.inMilliseconds,
          });
          return;
        }
      }

      // Path C: mDNS + 4-digit PIN pairing.
      c.pairing = true;
      final creds = _ensureFreshCredentials();
      if (!_pairRequestedCtrl.isClosed) _pairRequestedCtrl.add(creds);
      _send(c, HubMsg.pairRequired);
      return;
    }

    if (type == HubMsg.pair && c.helloDone && !c.authenticated) {
      if (!allowPairing) {
        await _refusePairing(c, msg['rid']);
        return;
      }
      if (!_pairingDialogOpen) {
        await _refuseUnavailable(c, msg['rid']);
        return;
      }
      await _verifyPin(c, msg['pin']);
      return;
    }

    if (type == HubMsg.ping) {
      _send(c, HubMsg.pong, {
        if (msg['ts'] != null) 'ts': msg['ts'],
        'now': _now().millisecondsSinceEpoch,
      });
      return;
    }

    await c.socket.close(WebSocketStatus.policyViolation);
  }

  Future<void> _refusePairing(_HubConnection c, Object? rid) async {
    _send(c, HubMsg.err, {
      'rid': ?rid,
      'code': HubErrorCode.forbidden,
      'msg': 'Pairing is turned off',
    });
    await c.socket.close();
  }

  Future<void> _refuseUnavailable(_HubConnection c, Object? rid) async {
    _send(c, HubMsg.err, {
      'rid': ?rid,
      'code': HubErrorCode.unavailable,
      'msg': 'Pairing is not open. Start pairing on the TV.',
    });
    await c.socket.close();
  }

  /// Hello of a TV that has no valid token.
  Future<void> _displayHello(_HubConnection c) => _withLock(() async {
    final existing = await db.displays();
    if (existing.isEmpty) {
      await _issueDevice(c, display: true);
      return;
    }
    final online = _connections.any(
      (o) =>
          o != c &&
          (o.device?.isDisplay ?? false) &&
          o.socket.readyState == WebSocket.open,
    );
    // Only one TV may wait for approval at a time.
    if (online || _waitingDisplays.isNotEmpty) {
      _send(c, HubMsg.err, {
        'code': HubErrorCode.conflict,
        'msg': 'A TV is already connected',
      });
      await c.socket.close();
      return;
    }
    if (await db.phoneCount() == 0) {
      // Nobody can approve: physical presence is the only proof left.
      await _issueDevice(c, display: true);
      return;
    }
    final requestId = 'r_${_randomHex(6)}';
    c.waitingApproval = true;
    c.idle?.cancel();
    final timer = Timer(pairingTimeout, () async {
      if (_endWaiting(requestId) == null) return;
      _send(c, HubMsg.err, {
        'code': HubErrorCode.timeout,
        'msg': 'No phone approved this TV in time',
      });
      try {
        await c.socket.close();
      } catch (_) {}
    });
    _waitingDisplays[requestId] = _WaitingDisplay(c, timer);
    for (final o in _connections) {
      if (o.ready && o.device != null && !o.device!.isDisplay) {
        _sendApprovalRequest(o, requestId, c.clientName);
      }
    }
  });

  void _sendApprovalRequest(_HubConnection phone, String id, String name) {
    _send(phone, 'devices.approvalRequested', {'requestId': id, 'name': name});
  }

  /// `devices.approveDisplay`: a paired phone lets the waiting TV in. Returns
  /// false when the request is unknown or expired.
  Future<bool> approveDisplay(String requestId) async {
    final w = _endWaiting(requestId);
    if (w == null) return false;
    final c = w.conn;
    if (c.socket.readyState != WebSocket.open) return false;
    _watchIdle(c, pairingTimeout);
    await _withLock(() => _issueDevice(c, display: true));
    if (!c.ready) {
      throw const HubError(
        HubErrorCode.conflict,
        'The TV could not be admitted',
      );
    }
    return true;
  }

  ActivePairingCredentials _ensureFreshCredentials() {
    final current = pairingCredentials.value;
    if (current != null && _now().isBefore(current.expiresAt)) {
      return current;
    }
    return rotatePairingCredentials();
  }

  Future<void> _verifyPin(_HubConnection c, Object? givenPin) async {
    final now = _now();
    final locked = _lockedUntil;
    if (locked != null && now.isBefore(locked)) {
      _send(c, HubMsg.pairFailed, {
        'retryInMs': locked.difference(now).inMilliseconds,
      });
      return;
    }
    final creds = pairingCredentials.value;
    final valid =
        creds != null &&
        now.isBefore(creds.expiresAt) &&
        givenPin is String &&
        constantTimeEquals(creds.pin, givenPin.trim());
    if (valid) {
      _wrongAttempts = 0;
      _lockedUntil = null;
      c.pairing = false;
      if (_pairingDialogOpen) {
        rotatePairingCredentials();
      } else {
        _updatePairingVisibility();
      }
      await _issueTokenAndProceed(c);
      return;
    }
    _recordFailedPairAttempt(c, now);
  }

  /// Counts a failed attempt. Returns true when this attempt started the
  /// lockout. With [notify] the `pair_failed` frame is sent here.
  bool _recordFailedPairAttempt(
    _HubConnection c,
    DateTime now, {
    bool notify = true,
  }) {
    final first = _firstFailureAt;
    if (first != null && now.difference(first) > pairLockout) {
      _wrongAttempts = 0; // Old failures decay: they do not count any more.
    }
    if (_wrongAttempts == 0) _firstFailureAt = now;
    _wrongAttempts++;
    if (_wrongAttempts >= maxPairAttempts) {
      _wrongAttempts = 0;
      _firstFailureAt = null;
      _lockedUntil = now.add(pairLockout);
      if (_pairingDialogOpen || _connections.any((o) => o.pairing)) {
        rotatePairingCredentials();
      }
      if (notify) {
        _send(c, HubMsg.pairFailed, {'retryInMs': pairLockout.inMilliseconds});
      }
      return true;
    }
    if (notify) _send(c, HubMsg.pairFailed);
    return false;
  }

  /// Creates the device (first one is `owner`) and token, then goes ready.
  /// Serialized so two simultaneous pairings cannot both become owner.
  Future<void> _issueTokenAndProceed(_HubConnection c) =>
      _withLock(() => _issueDevice(c));

  Future<void> _withLock(Future<void> Function() body) {
    final done = _issueLock.then((_) => body());
    _issueLock = done.catchError((Object _) {});
    return done;
  }

  int get _maxPhones => max(1, maxClients - 1);

  int get _readyPhones => _connections
      .where((c) => c.ready && !(c.device?.isDisplay ?? false))
      .length;

  /// Creates a phone (or, with [display], the display) device. Callers hold
  /// the issue lock.
  Future<void> _issueDevice(_HubConnection c, {bool display = false}) async {
    {
      // Capacity first: a refused device must not leave a device or token.
      if (display
          ? _connections.any(
              (o) => o != c && o.ready && (o.device?.isDisplay ?? false),
            )
          : _readyPhones >= _maxPhones) {
        _send(c, HubMsg.err, {
          'code': HubErrorCode.conflict,
          'msg': display
              ? 'A TV is already connected'
              : 'Too many phones are connected ($_maxPhones)',
        });
        await c.socket.close();
        return;
      }
      final rawToken = _newSessionToken();
      final nowMs = _now().millisecondsSinceEpoch;
      final deviceId = 'd_${_randomHex(6)}';
      final String role;
      try {
        role = await db.transaction(() async {
          if (display) {
            // A new TV replaces the old display row (and its token).
            for (final old in await db.displays()) {
              await db.deleteDevice(old.id);
            }
          }
          final role = display ? 'display' : await db.nextDeviceRole();
          await db.insertDevice(
            id: deviceId,
            name: c.clientName,
            role: role,
            nowMs: nowMs,
          );
          await db.insertPairing(
            rawToken: rawToken,
            deviceId: deviceId,
            clientName: c.clientName,
            nowMs: nowMs,
          );
          return role;
        });
      } catch (_) {
        _send(c, HubMsg.err, {
          'code': HubErrorCode.invalid,
          'msg': 'Pairing failed, try again',
        });
        try {
          await c.socket.close();
        } catch (_) {}
        return;
      }
      if (display) _tokenCache.removeWhere((_, d) => d.isDisplay);
      c.tokenHash = hashToken(rawToken);
      c.authenticated = true;
      c.pairing = false;
      _updatePairingVisibility();
      _send(c, HubMsg.paired, {'token': rawToken});
      final paired = DeviceInfo(
        id: deviceId,
        name: c.clientName,
        role: DeviceRole.parse(role),
        online: true,
      );
      await _becomeReady(c, paired);
      if (c.ready && !_devicePairedCtrl.isClosed) {
        _devicePairedCtrl.add(paired);
      }
    }
  }

  Future<void> _becomeReady(_HubConnection c, DeviceInfo device) async {
    // Same token again: the older socket is replaced and must not reconnect.
    final stale = _connections
        .where(
          (o) => o != c && o.tokenHash != null && o.tokenHash == c.tokenHash,
        )
        .toList();
    for (final s in stale) {
      _send(s, HubMsg.replaced);
      s.idle?.cancel();
      _connections.remove(s);
      try {
        await s.socket.close();
      } catch (_) {}
    }

    // Cap on simultaneously ready devices: one display and up to
    // maxClients - 1 phones.
    final tooMany = device.isDisplay
        ? _connections.any(
            (o) => o != c && o.ready && (o.device?.isDisplay ?? false),
          )
        : _readyPhones >= _maxPhones;
    if (tooMany) {
      _send(c, HubMsg.err, {
        'code': HubErrorCode.conflict,
        'msg': device.isDisplay
            ? 'A TV is already connected'
            : 'Too many phones are connected ($_maxPhones)',
      });
      await c.socket.close();
      return;
    }

    c.device = device;
    c.ready = true;
    _watchIdle(c, idleTimeout);

    _send(c, HubMsg.ready, {
      'v': kProtocolVersion,
      'id': _hubId,
      'name': name,
      'now': _now().millisecondsSinceEpoch,
      'device': {
        'id': device.id,
        'name': device.name,
        'role': device.role.name,
      },
    });

    await _notifyPresence();

    final snap = await buildFullSnapshot(device);
    _send(c, HubMsg.snapshot, snap);

    // A phone that connects while a TV waits for approval gets the request.
    if (!device.isDisplay) {
      for (final e in _waitingDisplays.entries) {
        _sendApprovalRequest(c, e.key, e.value.conn.clientName);
      }
    }
  }

  Future<void> _onReadyFrame(
    _HubConnection c,
    String type,
    Map<String, dynamic> msg,
  ) async {
    if (type == HubMsg.ping) {
      _send(c, HubMsg.pong, {
        if (msg['ts'] != null) 'ts': msg['ts'],
        'now': _now().millisecondsSinceEpoch,
      });
      return;
    }

    if (type == HubMsg.sync) {
      final DeviceInfo fresh;
      try {
        fresh = await _refreshDevice(c);
      } on HubError {
        await _closeUnauthorized(c);
        return;
      }
      final snap = await buildFullSnapshot(fresh);
      _send(c, HubMsg.snapshot, snap);
      return;
    }

    final spec = _handlers[type];
    if (spec == null) return; // Unknown types are ignored.

    final rid = (msg['rid'] as num?)?.toInt();
    final op = msg['op'] is String ? msg['op'] as String : null;

    if (c.revoked || c.device == null) {
      await _closeUnauthorized(c);
      return;
    }

    // Hot handlers use the cached device: no database work per frame.
    final DeviceInfo device;
    try {
      device = spec.hot ? c.device! : await _refreshDevice(c);
    } on HubError catch (e) {
      if (rid != null) {
        _send(c, HubMsg.err, {'rid': rid, 'code': e.code, 'msg': e.message});
      }
      await _closeUnauthorized(c);
      return;
    }
    final opKey = op == null ? null : '${device.id}|$type|$op';
    if (spec.requireOwner && !device.isOwnerEquivalent) {
      if (rid != null) {
        _send(c, HubMsg.err, {
          'rid': rid,
          'code': HubErrorCode.forbidden,
          'msg': 'Only the owner can do this',
        });
      }
      return;
    }

    if (opKey != null && _opCache.containsKey(opKey)) {
      if (rid != null) {
        _send(c, HubMsg.ok, {'rid': rid, 'result': _opCache[opKey]});
      }
      return;
    }

    try {
      final result = await spec.handler(
        HubCall(
          type: type,
          device: device,
          args: msg,
          connectionId: c.id,
          rid: rid,
        ),
      );
      if (opKey != null) {
        _opCache[opKey] = result;
        if (_opCache.length > _maxOpCacheSize) {
          _opCache.remove(_opCache.keys.first);
        }
      }
      if (rid != null) {
        _send(c, HubMsg.ok, {'rid': rid, 'result': ?result});
      }
    } on HubError catch (e) {
      if (rid != null) {
        _send(c, HubMsg.err, {
          'rid': rid,
          'code': e.code,
          if (e.message != null) 'msg': e.message,
          ...e.extra,
        });
      }
    } catch (e) {
      if (rid != null) {
        _send(c, HubMsg.err, {
          'rid': rid,
          'code': HubErrorCode.invalid,
          'msg': e.toString(),
        });
      }
    }
  }

  Future<void> _closeUnauthorized(_HubConnection c) async {
    c.revoked = true;
    c.idle?.cancel();
    _connections.remove(c);
    try {
      await c.socket.close(WebSocketStatus.policyViolation);
    } catch (_) {}
  }

  Future<DeviceInfo> _refreshDevice(_HubConnection c) async {
    final current = c.device!;
    final row = await db.getDevice(current.id);
    if (row == null) {
      c.revoked = true;
      throw const HubError(HubErrorCode.unauthorized, 'Device was forgotten');
    }
    final updated = DeviceInfo.fromRow(row, online: true);
    c.device = updated;
    return updated;
  }

  Future<void> _notifyPresence() async {
    final online = onlineDeviceIds;
    connectedPhones.value = _readyPhones;
    for (final m in _modules) {
      await m.onPresenceChanged(online);
    }
  }

  void _dispatchModuleEvent(HubOutboundEvent ev) {
    if (!_localEventsCtrl.isClosed) {
      _localEventsCtrl.add(ev);
    }
    switch (ev.target) {
      case EventTargetKind.broadcast:
        final nextRev = ++_rev;
        final payload = encodeFrame(HubMsg.event, {
          'rev': nextRev,
          'module': ev.module,
          'kind': ev.kind,
          'data': ev.data,
        });
        for (final c in _connections) {
          if (c.ready && c.socket.readyState == WebSocket.open) {
            _trySend(c, payload);
          }
        }
      case EventTargetKind.targetedDevice:
        final payload = encodeFrame(ev.rawFrameType ?? ev.kind, ev.data);
        for (final c in _connections) {
          if (c.ready &&
              c.device?.id == ev.targetDeviceId &&
              c.socket.readyState == WebSocket.open) {
            _trySend(c, payload);
          }
        }
      case EventTargetKind.unrevisionedBroadcast:
        final payload = encodeFrame(ev.rawFrameType ?? ev.kind, ev.data);
        for (final c in _connections) {
          if (c.ready &&
              c.id != ev.excludeConnectionId &&
              c.socket.readyState == WebSocket.open) {
            _trySend(c, payload);
          }
        }
    }
  }

  String _newPin() => _random
      .nextInt(pow(10, kPinLength).toInt())
      .toString()
      .padLeft(kPinLength, '0');

  String _newPairCode() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  String _newSessionToken() {
    final bytes = List<int>.generate(32, (_) => _random.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  String _randomHex(int byteLen) {
    final bytes = List<int>.generate(byteLen, (_) => _random.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}

class _WaitingDisplay {
  _WaitingDisplay(this.conn, this.timer);

  final _HubConnection conn;
  final Timer timer;
}

class _HubConnection {
  _HubConnection(this.id, this.socket);

  final String id;
  final WebSocket socket;
  Future<void> queue = Future.value();
  Timer? idle;
  String clientName = 'Phone';
  String? tokenHash;
  DeviceInfo? device;
  bool helloDone = false;
  bool pairing = false;
  bool authenticated = false;
  bool ready = false;
  bool revoked = false;

  bool get isDisplay => device?.isDisplay ?? false;

  /// A display that waits for a phone to approve it (no idle timeout).
  bool waitingApproval = false;

  /// The hello said `kind: display` (set before the device is known).
  bool wantsDisplay = false;

  /// Local address of the socket, used as the QR host for the display.
  String? localHost;
}
