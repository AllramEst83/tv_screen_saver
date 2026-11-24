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

/// Multi-client authoritative WebSocket and HTTP hub server running on the TV.
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
  final Random _random;
  final DateTime Function() _now;

  static const maxPairAttempts = 3;
  static const pairLockout = Duration(seconds: 60);
  static const pairCodeTtl = Duration(seconds: 120);
  static const _maxOpCacheSize = 500;

  /// Current pairing credentials shown on the TV pairing dialog (or null).
  final Observable<ActivePairingCredentials?> pairingCredentials =
      Observable(null);

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
  String _hubId = '';
  int _rev = 0;
  int _connSeq = 0;
  int _wrongAttempts = 0;
  DateTime? _firstFailureAt;
  DateTime? _lockedUntil;
  bool _pairingDialogOpen = false;

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

  /// Closes the TV pairing dialog. Credentials remain if a phone is mid-PIN.
  void closePairingSession() {
    _pairingDialogOpen = false;
    _updatePairingVisibility();
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
    return creds;
  }

  /// Builds the current `drawaid://pair?...` QR URI for [lanHost].
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

  /// Forgets every paired device (TV remote action "Forget all phones") and
  /// drops their sockets. Their tokens stop working.
  Future<void> forgetPairings() async {
    _tokenCache.clear();
    await db.deleteAllPairings();
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
    if (spec.requireOwner && !caller.isOwner) {
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
      final WebSocket socket;
      try {
        socket = await WebSocketTransformer.upgrade(request);
      } catch (_) {
        return;
      }
      _attachSocket(socket);
      return;
    }

    for (final handler in _httpHandlers) {
      try {
        if (await handler(request)) return;
      } catch (_) {
        request.response
          ..statusCode = HttpStatus.internalServerError
          ..write('Internal server error');
        await request.response.close();
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

  void _attachSocket(WebSocket socket) {
    final conn = _HubConnection('conn_${++_connSeq}', socket);
    _connections.add(conn);
    _watchIdle(conn, pairingTimeout);
    socket.listen(
      (data) {
        _watchIdle(conn, conn.ready ? idleTimeout : pairingTimeout);
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
    if (!_pairingDialogOpen && !_connections.any((c) => c.pairing)) {
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
    if (type == HubMsg.hello) {
      final rawV = msg['v'];
      final clientVer = rawV == null ? 1 : (rawV is int ? rawV : 0);
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
      c.helloDone = true;
      final rawName = msg['client'];
      c.clientName = (rawName is String && rawName.trim().isNotEmpty)
          ? rawName.trim()
          : 'Phone';

      // Path A: reconnect with a saved token.
      final token = msg['token'];
      if (token is String && token.isNotEmpty) {
        final pairing = await db.verifyRawToken(token);
        if (pairing != null) {
          final row = await db.getDevice(pairing.deviceId);
          if (row != null) {
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

  void _recordFailedPairAttempt(_HubConnection c, DateTime now) {
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
      _send(c, HubMsg.pairFailed, {'retryInMs': pairLockout.inMilliseconds});
    } else {
      _send(c, HubMsg.pairFailed);
    }
  }

  /// Creates the device (first one is `owner`) and token, then goes ready.
  /// Serialized so two simultaneous pairings cannot both become owner.
  Future<void> _issueTokenAndProceed(_HubConnection c) {
    final done = _issueLock.then((_) async {
      // Capacity first: a refused phone must not leave a device or token.
      if (readyClientCount >= maxClients) {
        _send(c, HubMsg.err, {
          'code': HubErrorCode.conflict,
          'msg': 'Too many phones are connected ($maxClients)',
        });
        await c.socket.close();
        return;
      }
      final rawToken = _newSessionToken();
      final nowMs = _now().millisecondsSinceEpoch;
      final role = await db.nextDeviceRole();
      final deviceId = 'd_${_randomHex(6)}';
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
    });
    _issueLock = done.catchError((Object _) {});
    return done;
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

    // Cap on simultaneously ready phones.
    if (readyClientCount >= maxClients) {
      _send(c, HubMsg.err, {
        'code': HubErrorCode.conflict,
        'msg': 'Too many phones are connected ($maxClients)',
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
    if (spec.requireOwner && !device.isOwner) {
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
    connectedPhones.value = online.length;
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

  String _newPin() => _random.nextInt(10000).toString().padLeft(4, '0');

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
}
