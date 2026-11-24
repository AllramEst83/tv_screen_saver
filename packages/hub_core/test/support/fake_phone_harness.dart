import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:hub_core/hub_core.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';

/// Controllable clock for the server's pairing expiry.
class FakeClock {
  FakeClock([DateTime? initial])
    : _now = initial ?? DateTime.utc(2026, 11, 20, 18, 0);

  DateTime _now;

  DateTime now() => _now;

  void advance(Duration delta) => _now = _now.add(delta);
}

/// Counts every write statement that reaches the database.
class CountingInterceptor extends QueryInterceptor {
  int writes = 0;

  @override
  Future<int> runInsert(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    writes++;
    return executor.runInsert(statement, args);
  }

  @override
  Future<int> runUpdate(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    writes++;
    return executor.runUpdate(statement, args);
  }

  @override
  Future<int> runDelete(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    writes++;
    return executor.runDelete(statement, args);
  }

  @override
  Future<void> runCustom(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    writes++;
    return executor.runCustom(statement, args);
  }

  @override
  Future<void> runBatched(
    QueryExecutor executor,
    BatchedStatements statements,
  ) {
    writes++;
    return executor.runBatched(statements);
  }
}

/// Test-only module with a `hot` handler that relays to every other phone
/// without any database work (stand-in for `view.live`).
class HotRelayModule implements HubModule {
  final _events = StreamController<HubOutboundEvent>.broadcast();

  /// How many times the `count.op` handler really ran.
  int opRuns = 0;

  @override
  String get id => 'test';

  @override
  Stream<HubOutboundEvent> get events => _events.stream;

  @override
  Map<String, HubHandlerSpec> get handlers => {
    'hot.relay': HubHandlerSpec(
      hot: true,
      handler: (call) async {
        _events.add(
          HubOutboundEvent.unrevisioned(
            module: id,
            rawFrameType: 'hot.relay',
            data: {'n': call.args['n'], 'by': call.device.id},
            excludeConnectionId: call.connectionId,
          ),
        );
        return null;
      },
    ),
    'count.op': HubHandlerSpec(handler: (call) async => {'n': ++opRuns}),
    'owner.only': HubHandlerSpec(
      requireOwner: true,
      handler: (call) async => {'ok': true},
    ),
  };

  @override
  Future<Map<String, Object?>> snapshotFor(DeviceInfo device) async => {};

  @override
  Future<void> onPresenceChanged(Set<String> onlineDeviceIds) async {}

  @override
  Future<void> dispose() async => _events.close();
}

/// Real WebSocket test client simulating a phone connected to [HubServer].
class TestPhone {
  TestPhone(this.socket) {
    socket.listen(
      (data) {
        final decoded = jsonDecode(data as String) as Map<String, dynamic>;
        receivedHistory.add(decoded);
        _inbox.add(decoded);
        _signal();
      },
      onDone: () {
        closed = true;
        _signal();
      },
      onError: (_) {
        closed = true;
        _signal();
      },
    );
  }

  final WebSocket socket;
  final List<Map<String, dynamic>> _inbox = [];
  final List<Map<String, dynamic>> receivedHistory = [];
  Completer<void>? _waiter;
  bool closed = false;
  int _ridSeq = 0;

  String? token;
  String? deviceId;
  String? role;

  void _signal() {
    final w = _waiter;
    if (w != null && !w.isCompleted) {
      _waiter = null;
      w.complete();
    }
  }

  static Future<TestPhone> connect(int port) async =>
      TestPhone(await WebSocket.connect('ws://127.0.0.1:$port$kWsPath'));

  static Future<TestPhone> connectHost(String host, int port) async =>
      TestPhone(await WebSocket.connect('ws://$host:$port$kWsPath'));

  void send(String type, [Map<String, Object?> fields = const {}]) {
    socket.add(encodeFrame(type, fields));
  }

  Future<Map<String, dynamic>> next({
    Duration timeout = const Duration(seconds: 3),
  }) => waitFor((_) => true, timeout: timeout);

  Future<Map<String, dynamic>> expectType(String type) async {
    final m = await next();
    if (m['t'] != type) {
      throw StateError('Expected frame type "$type", got: $m');
    }
    return m;
  }

  /// First buffered or incoming frame matching [predicate]; earlier
  /// unrelated frames stay buffered.
  Future<Map<String, dynamic>> waitFor(
    bool Function(Map<String, dynamic> msg) predicate, {
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      for (var i = 0; i < _inbox.length; i++) {
        if (predicate(_inbox[i])) return _inbox.removeAt(i);
      }
      if (closed) {
        throw StateError('WebSocket closed while waiting for a matching frame');
      }
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) {
        throw TimeoutException('Timed out waiting for a matching frame');
      }
      _waiter ??= Completer<void>();
      await _waiter!.future.timeout(remaining);
    }
  }

  Future<Map<String, dynamic>> expectEvent(String kind) =>
      waitFor((m) => m['t'] == HubMsg.event && m['kind'] == kind);

  Future<Map<String, dynamic>> _consumeReady() async {
    final ready = await expectType(HubMsg.ready);
    final device = ready['device'] as Map<String, dynamic>;
    deviceId = device['id'] as String;
    role = device['role'] as String;
    return ready;
  }

  /// QR pairing: `hello{pairCode}` -> `paired` -> `ready`. Returns `ready`.
  Future<Map<String, dynamic>> pairWithQr(
    String qrUri, {
    String client = 'TestPhone',
  }) async {
    final parsed = PairQrData.tryParse(qrUri)!;
    send(HubMsg.hello, {
      'v': kProtocolVersion,
      'client': client,
      'pairCode': parsed.pairCode,
    });
    final paired = await expectType(HubMsg.paired);
    token = paired['token'] as String;
    return _consumeReady();
  }

  /// PIN pairing: `hello` -> `pair_required` -> `pair{pin}` -> `paired` ->
  /// `ready`. Returns `ready`.
  Future<Map<String, dynamic>> pairWithPin(
    String pin, {
    String client = 'TestPhone',
  }) async {
    send(HubMsg.hello, {'v': kProtocolVersion, 'client': client});
    await expectType(HubMsg.pairRequired);
    send(HubMsg.pair, {'pin': pin});
    final paired = await expectType(HubMsg.paired);
    token = paired['token'] as String;
    return _consumeReady();
  }

  /// Reconnects with a saved token. Returns `ready`.
  Future<Map<String, dynamic>> helloWithToken(
    String savedToken, {
    String client = 'TestPhone',
  }) async {
    send(HubMsg.hello, {
      'v': kProtocolVersion,
      'client': client,
      'token': savedToken,
    });
    token = savedToken;
    return _consumeReady();
  }

  /// Correlated request; waits for its `ok` or `err`.
  Future<Map<String, dynamic>> request(
    String type, [
    Map<String, Object?> args = const {},
  ]) async {
    final rid = ++_ridSeq;
    send(type, {'rid': rid, ...args});
    return waitFor(
      (m) => (m['t'] == HubMsg.ok || m['t'] == HubMsg.err) && m['rid'] == rid,
    );
  }

  Future<void> close() async {
    try {
      await socket.close();
    } catch (_) {}
  }
}

/// In-process TV test rig: a real loopback server, an in-memory database
/// whose writes are counted, a fake clock and scripted phones.
class TestHubRig {
  TestHubRig._({
    required this.clock,
    required this.db,
    required this.store,
    required this.server,
    required this.counter,
    required this.hot,
    this.displayModule,
    this.player,
  });

  final FakeClock clock;
  final HubDatabase db;
  final MemoryTvStore store;
  final HubServer server;
  final CountingInterceptor counter;
  final HotRelayModule hot;

  /// Set when the rig was started with `playlists`.
  final DisplayModule? displayModule;
  final PlayerModule? player;

  final List<TestPhone> phones = [];

  static Future<TestHubRig> start({
    int randomSeed = 42,
    int? port,
    HubDatabase? db,
    MemoryTvStore? store,
    int maxClients = 8,
    Duration idleTimeout = const Duration(seconds: 20),
    Duration pairingTimeout = const Duration(seconds: 120),
    Duration pairCodeTtl = const Duration(seconds: 120),
    PlaylistSource? playlists,
    Future<String?> Function(String itemId)? unplayableReason,
    Future<void> Function()? onCapabilitiesChanged,
    Future<Map<String, Object?>> Function(String, String)? loadExtras,
    Future<bool> Function(String)? muteFor,
    int Function()? cacheBytes,
    int prefetchCount = 2,
  }) async {
    final clock = FakeClock();
    final counter = CountingInterceptor();
    final database =
        db ?? HubDatabase(NativeDatabase.memory().interceptWith(counter));
    final tvStore = store ?? MemoryTvStore('hub-test-42');
    final server = HubServer(
      db: database,
      store: tvStore,
      name: 'Test TV',
      preferredPort: port ?? 0,
      now: clock.now,
      random: Random(randomSeed),
      maxClients: maxClients,
      idleTimeout: idleTimeout,
      pairingTimeout: pairingTimeout,
      pairCodeTtl: pairCodeTtl,
    );
    final devices = DevicesModule(
      db: database,
      onForgetDevice: server.forgetDevice,
      onStartPairing: server.startPairingFor,
      onCancelPairing: server.cancelPairingFor,
      onApproveDisplay: server.approveDisplay,
      onForgetAllPhones: server.forgetAllPhones,
    );
    final hot = HotRelayModule();
    server.registerModule(devices);
    server.registerModule(hot);
    DisplayModule? displayModule;
    PlayerModule? player;
    if (playlists != null) {
      displayModule = DisplayModule(
        db: database,
        onCapabilitiesChanged: onCapabilitiesChanged,
      );
      player = PlayerModule(
        db: database,
        display: displayModule,
        playlists: playlists,
        unplayableReason: unplayableReason,
        loadExtras: loadExtras,
        muteFor: muteFor,
        cacheBytes: cacheBytes,
        prefetchCount: prefetchCount,
        now: clock.now,
      );
      server.registerModule(displayModule);
      server.registerModule(player);
    }
    await server.start();
    return TestHubRig._(
      clock: clock,
      db: database,
      store: tvStore,
      server: server,
      counter: counter,
      hot: hot,
      displayModule: displayModule,
      player: player,
    );
  }

  Future<TestPhone> connectPhone() async {
    final p = await TestPhone.connect(server.port);
    phones.add(p);
    return p;
  }

  /// Connects a phone and pairs it by QR code.
  Future<TestPhone> onboardPhone([String name = 'Phone']) async {
    final p = await connectPhone();
    server.openPairingSession();
    final qr = server.currentQrUri('127.0.0.1')!;
    await p.pairWithQr(qr, client: name);
    server.closePairingSession();
    return p;
  }

  /// Connects a fake TV (no pairing yet).
  Future<TestPhone> connectDisplay() async => connectPhone();

  /// Connects a fake TV and pairs it as the first display.
  Future<TestPhone> onboardDisplay([String name = 'TV']) async {
    final d = await connectDisplay();
    await d.helloAsDisplay(client: name);
    return d;
  }

  Future<void> dispose({bool closeDb = true}) async {
    for (final p in phones) {
      await p.close();
    }
    phones.clear();
    await server.stop();
    if (closeDb) await db.close();
  }
}

extension TestDisplay on TestPhone {
  /// `hello {kind: display}` without a token. Expects `paired` and `ready`.
  Future<Map<String, dynamic>> helloAsDisplay({String client = 'TV'}) async {
    sendDisplayHello(client: client);
    final paired = await expectType(HubMsg.paired);
    token = paired['token'] as String;
    return _consumeReadyPublic();
  }

  void sendDisplayHello({String client = 'TV', String? withToken}) {
    send(HubMsg.hello, {
      'v': kProtocolVersion,
      'client': client,
      'kind': 'display',
      'token': ?withToken,
    });
  }

  Future<Map<String, dynamic>> _consumeReadyPublic() async {
    final ready = await expectType(HubMsg.ready);
    final device = ready['device'] as Map<String, dynamic>;
    deviceId = device['id'] as String;
    role = device['role'] as String;
    return ready;
  }

  /// Display side: `devices.startPairing`, then the first `display.pairing`.
  Future<Map<String, dynamic>> startPairing() async {
    final r = await request('devices.startPairing');
    if (r['t'] != HubMsg.ok) throw StateError('startPairing failed: $r');
    return waitFor((m) => m['t'] == 'display.pairing');
  }
}

extension TestPhonePin on TestPhone {
  /// After `pair_required`: types the TV's current PIN, expects `paired`
  /// and `ready`.
  Future<Map<String, dynamic>> pinPair(HubServer server) async {
    send(HubMsg.pair, {'pin': server.pairingCredentials.value!.pin});
    final paired = await expectType(HubMsg.paired);
    token = paired['token'] as String;
    final ready = await expectType(HubMsg.ready);
    final device = ready['device'] as Map<String, dynamic>;
    deviceId = device['id'] as String;
    role = device['role'] as String;
    return ready;
  }
}
