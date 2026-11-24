import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:hub_core/hub_core.dart';
import 'package:test/test.dart';

import 'pairing_and_roles_test.dart' show EmptyScanner, newClient, until;
import 'support/fake_phone_harness.dart';

class _FixedScanner extends HubScanner {
  _FixedScanner(this.endpoint);
  final HubEndpoint endpoint;

  @override
  Stream<HubEndpoint> scan() => Stream.value(endpoint);
}

/// WebSocket server that answers `hello` with `ready` and a snapshot and then
/// behaves as [onFrame] says (silence by default).
class _FakeTv {
  _FakeTv(this.server, {this.onFrame});
  final HttpServer server;
  final void Function(WebSocket ws, Map<String, dynamic> msg)? onFrame;
  final List<WebSocket> sockets = [];
  int syncs = 0;

  static Future<_FakeTv> start({
    void Function(WebSocket ws, Map<String, dynamic> msg)? onFrame,
  }) async {
    final tv = _FakeTv(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
      onFrame: onFrame,
    );
    tv.server.forEach((req) async {
      final ws = await WebSocketTransformer.upgrade(req);
      tv.sockets.add(ws);
      ws.listen((raw) {
        final msg = jsonDecode(raw as String) as Map<String, dynamic>;
        if (msg['t'] == HubMsg.hello) {
          ws.add(
            encodeFrame(HubMsg.ready, {
              'v': 1,
              'id': 'fake',
              'name': 'Fake TV',
              'now': 0,
              'device': {'id': 'd', 'name': 'x', 'role': 'owner'},
            }),
          );
          ws.add(
            encodeFrame(HubMsg.snapshot, {'rev': 0, 'now': 0, 'modules': {}}),
          );
        }
        if (msg['t'] == HubMsg.sync) tv.syncs++;
        tv.onFrame?.call(ws, msg);
      });
    });
    return tv;
  }

  HubEndpoint get endpoint => HubEndpoint(
    host: '127.0.0.1',
    port: server.port,
    name: 'Fake TV',
    id: 'fake',
  );

  Future<void> close() async {
    for (final s in sockets) {
      s.close();
    }
    await server.close(force: true);
  }
}

void main() {
  group('server hardening', () {
    late TestHubRig rig;
    setUp(() async => rig = await TestHubRig.start());
    tearDown(() => rig.dispose());

    test('same op runs once; another device cannot reuse it', () async {
      final owner = await rig.onboardPhone('Owner');
      final ctl = await rig.onboardPhone('Ctl');

      final r1 = await owner.request('count.op', {'op': 'abc'});
      final r2 = await owner.request('count.op', {'op': 'abc'});
      expect(rig.hot.opRuns, 1);
      expect(r2['result'], r1['result']);

      // The same op on another device is not served from the owner's cache.
      final r3 = await ctl.request('count.op', {'op': 'abc'});
      expect(rig.hot.opRuns, 2);
      expect(r3['t'], HubMsg.ok);

      // A controller reusing an owner's op on an owner-only handler.
      expect((await owner.request('owner.only', {'op': 'o1'}))['t'], HubMsg.ok);
      final denied = await ctl.request('owner.only', {'op': 'o1'});
      expect(denied['code'], HubErrorCode.forbidden);
    });

    test('hot frames from a forgotten device stop', () async {
      final owner = await rig.onboardPhone('Owner');
      final ctl = await rig.onboardPhone('Ctl');
      final watcher = await rig.onboardPhone('Watcher');
      await owner.request('device.forget', {'deviceId': ctl.deviceId});
      await until(() => ctl.closed);
      expect(owner.closed, isFalse);
      expect(watcher.closed, isFalse);
      try {
        ctl.send('hot.relay', {'n': 1});
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(
        watcher.receivedHistory.where((m) => m['t'] == 'hot.relay'),
        isEmpty,
      );
    });

    test('forgetPairings closes every socket', () async {
      final a = await rig.onboardPhone('A');
      final b = await rig.onboardPhone('B');
      await rig.server.forgetPairings();
      await until(() => a.closed && b.closed);
    });

    test('a device row deleted behind the server closes the socket', () async {
      final a = await rig.onboardPhone('A');
      await rig.db.deleteDevice(a.deviceId!);
      final r = await a.request('device.rename', {'name': 'x'});
      expect(r['code'], HubErrorCode.unauthorized);
      await until(() => a.closed);
    });

    test(
      'wrong PINs decay: failures older than the lockout do not add up',
      () async {
        rig.server.openPairingSession();
        final p = await rig.connectPhone();
        p.send(HubMsg.hello, {'v': 1, 'client': 'Slow'});
        await p.expectType(HubMsg.pairRequired);
        for (var i = 0; i < 2; i++) {
          p.send(HubMsg.pair, {'pin': 'xxxx'});
          await p.expectType(HubMsg.pairFailed);
        }
        rig.clock.advance(const Duration(seconds: 61));
        p.send(HubMsg.pair, {'pin': 'xxxx'});
        final third = await p.expectType(HubMsg.pairFailed);
        expect(third['retryInMs'], isNull); // Not locked.
      },
    );

    test('invalid hello version gets err invalid and closes', () async {
      for (final v in <Object>['x', 0, 1.5]) {
        final p = await rig.connectPhone();
        p.send(HubMsg.hello, {'v': v, 'client': 'Bad'});
        final err = await p.expectType(HubMsg.err);
        expect(err['code'], HubErrorCode.invalid);
        await until(() => p.closed);
      }
    });

    test('an owner cannot forget itself or an owner', () async {
      final owner = await rig.onboardPhone('Owner');
      final r = await owner.request('device.forget', {
        'deviceId': owner.deviceId,
      });
      expect(r['code'], HubErrorCode.forbidden);
      expect(owner.closed, isFalse);
    });

    test('QR hello during a lockout gets pair_failed and no paired', () async {
      rig.server.openPairingSession();
      final p = await rig.connectPhone();
      p.send(HubMsg.hello, {'v': 1, 'client': 'Bad'});
      await p.expectType(HubMsg.pairRequired);
      for (var i = 0; i < 3; i++) {
        p.send(HubMsg.pair, {'pin': 'xxxx'});
        await p.expectType(HubMsg.pairFailed);
      }
      rig.server.openPairingSession();
      final code = rig.server.pairingCredentials.value!.pairCode;
      final q = await rig.connectPhone();
      q.send(HubMsg.hello, {'v': 1, 'client': 'Q', 'pairCode': code});
      final f = await q.expectType(HubMsg.pairFailed);
      expect(f['retryInMs'], greaterThan(0));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(q.receivedHistory.map((m) => m['t']), isNot(contains('paired')));
    });

    test('two phones pairing back to back yield exactly one owner', () async {
      rig.server.openPairingSession();
      final a = await rig.connectPhone();
      final b = await rig.connectPhone();
      a.send(HubMsg.hello, {'v': 1, 'client': 'A'});
      b.send(HubMsg.hello, {'v': 1, 'client': 'B'});
      await a.expectType(HubMsg.pairRequired);
      await b.expectType(HubMsg.pairRequired);
      // Codes are single use: the second PIN is the rotated one.
      a.send(HubMsg.pair, {'pin': rig.server.pairingCredentials.value!.pin});
      final ra = await a.waitFor((m) => m['t'] == HubMsg.ready);
      b.send(HubMsg.pair, {'pin': rig.server.pairingCredentials.value!.pin});
      final rb = await b.waitFor((m) => m['t'] == HubMsg.ready);
      final roles = [ra, rb].map((r) => (r['device'] as Map)['role']).toList();
      expect(roles.where((r) => r == 'owner'), hasLength(1));
    });
  });

  group('idle timeout', () {
    test('silent socket is closed; a pinging client stays connected', () async {
      final rig = await TestHubRig.start(
        idleTimeout: const Duration(milliseconds: 400),
      );
      addTearDown(rig.dispose);
      final silent = await rig.onboardPhone('Silent');

      rig.server.openPairingSession();
      final client = newClient(
        MemoryHubTokenStore(),
        pingInterval: const Duration(milliseconds: 100),
      );
      await client.connectFromQrUri(rig.server.currentQrUri('127.0.0.1')!);
      expect(client.state.value.phase, HubConnectionPhase.connected);

      await until(() => silent.closed);
      expect(client.state.value.phase, HubConnectionPhase.connected);
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(client.state.value.phase, HubConnectionPhase.connected);
      await client.dispose();
    });

    test(
      'PIN dialog state ends when the TV closes the pairing socket',
      () async {
        final rig = await TestHubRig.start(
          pairingTimeout: const Duration(milliseconds: 300),
        );
        addTearDown(rig.dispose);
        rig.server.openPairingSession();
        final client = newClient(MemoryHubTokenStore());
        await client.connectEndpoint(
          HubEndpoint(
            host: '127.0.0.1',
            port: rig.server.port,
            name: 'TV',
            id: rig.server.hubId,
          ),
        );
        expect(client.state.value.phase, HubConnectionPhase.awaitingPin);
        await until(
          () => client.state.value.phase == HubConnectionPhase.disconnected,
        );
        expect(client.state.value.lastError, HubMessages.connectionLost);
        await client.dispose();
      },
    );
  });

  group('client hardening', () {
    test('a missed rev triggers sync and a new snapshot', () async {
      final tv = await _FakeTv.start(
        onFrame: (ws, msg) {
          if (msg['t'] == HubMsg.hello) {
            ws.add(
              encodeFrame(HubMsg.event, {
                'rev': 5,
                'module': 'x',
                'kind': 'k',
                'data': {},
              }),
            );
          }
          if (msg['t'] == HubMsg.sync) {
            ws.add(
              encodeFrame(HubMsg.snapshot, {'rev': 5, 'now': 0, 'modules': {}}),
            );
          }
        },
      );
      final client = newClient(MemoryHubTokenStore());
      final snaps = <Map<String, dynamic>>[];
      client.snapshots.listen(snaps.add);
      await client.connectEndpoint(tv.endpoint);
      await until(() => tv.syncs == 1 && snaps.length == 2);
      expect(snaps.last['rev'], 5);
      expect(client.lastRev, 5);
      await client.dispose();
      await tv.close();
    });

    test(
      'a TV that goes silent is detected and the phone reconnects',
      () async {
        final tv = await _FakeTv.start();
        final client = newClient(
          MemoryHubTokenStore(),
          pingInterval: const Duration(milliseconds: 50),
          deadAfter: const Duration(milliseconds: 300),
        );
        // Save a pairing so the reconnect has somewhere to go.
        await client.tokenStore.savePairing(
          SavedHubPairing(
            hubId: 'fake',
            token: 't',
            lastHost: '127.0.0.1',
            lastPort: tv.server.port,
            hubName: 'Fake TV',
          ),
        );
        await client.connectEndpoint(tv.endpoint);
        expect(client.state.value.phase, HubConnectionPhase.connected);
        final phases = <HubConnectionPhase>[];
        client.state.addListener(() => phases.add(client.state.value.phase));
        await until(() => phases.contains(HubConnectionPhase.reconnecting));
        await client.dispose();
        await tv.close();
      },
    );

    test(
      'revoked token: ends in awaitingPin and the saved pairing is removed',
      () async {
        final rig = await TestHubRig.start();
        addTearDown(rig.dispose);
        rig.server.openPairingSession();
        final store = MemoryHubTokenStore();
        final client = newClient(store);
        await client.connectFromQrUri(rig.server.currentQrUri('127.0.0.1')!);
        await until(
          () => client.state.value.phase == HubConnectionPhase.connected,
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));

        await rig.server.forgetAllPhones();
        await until(
          () => client.state.value.phase == HubConnectionPhase.awaitingPin,
        );
        expect(client.state.value.lastError, HubMessages.revoked);
        expect(client.state.value.knownPairing, isFalse);
        await until(() => true);
        expect(await store.getPairing(rig.server.hubId), isNull);
        await client.dispose();
      },
    );

    test('reconnect keeps its phase: no flip to connecting', () async {
      final store = MemoryHubTokenStore();
      await store.savePairing(
        const SavedHubPairing(
          hubId: 'h',
          token: 't',
          lastHost: '10.255.255.1',
          lastPort: 8772,
          hubName: 'Ghost',
        ),
      );
      final client = newClient(
        store,
        direct: const Duration(milliseconds: 300),
      );
      final phases = <HubConnectionPhase>[];
      client.state.addListener(() => phases.add(client.state.value.phase));
      await client.reconnectSavedHub();
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(phases, isNotEmpty);
      expect(phases, isNot(contains(HubConnectionPhase.connecting)));
      await client.dispose();
    });

    test('unreachable last address, mDNS finds the TV: connected', () async {
      final rig = await TestHubRig.start();
      addTearDown(rig.dispose);
      final p = await rig.onboardPhone('Phone');
      final store = MemoryHubTokenStore();
      await store.savePairing(
        SavedHubPairing(
          hubId: rig.server.hubId,
          token: p.token!,
          lastHost: '10.255.255.1',
          lastPort: 8772,
          hubName: 'Test TV',
        ),
      );
      final client = newClient(
        store,
        direct: const Duration(milliseconds: 300),
        scanner: _FixedScanner(
          HubEndpoint(
            host: '127.0.0.1',
            port: rig.server.port,
            name: 'Test TV',
            id: rig.server.hubId,
          ),
        ),
      );
      expect(await client.reconnectSavedHub(), isTrue);
      expect(client.state.value.phase, HubConnectionPhase.connected);
      await client.dispose();
    });

    test('a failing token store does not break connecting', () async {
      final rig = await TestHubRig.start();
      addTearDown(rig.dispose);
      rig.server.openPairingSession();
      final client = newClient(_ThrowingStore());
      expect(
        await client.connectFromQrUri(rig.server.currentQrUri('127.0.0.1')!),
        isTrue,
      );
      expect(client.state.value.phase, HubConnectionPhase.connected);
      await client.dispose();
    });
  });

  test('EmptyScanner is empty', () async {
    expect(await EmptyScanner().scan().toList(), isEmpty);
  });
}

class _ThrowingStore implements HubTokenStore {
  @override
  Future<SavedHubPairing?> getPairing(String hubId) async =>
      throw StateError('boom');
  @override
  Future<SavedHubPairing?> getLastPairing() async => throw StateError('boom');
  @override
  Future<void> savePairing(SavedHubPairing pairing) async =>
      throw StateError('boom');
  @override
  Future<void> removePairing(String hubId) async => throw StateError('boom');
  @override
  Future<List<SavedHubPairing>> allPairings() async => throw StateError('boom');
  @override
  Future<void> setActive(String hubId) async => throw StateError('boom');
  @override
  Future<void> setLabel(String hubId, String? label) async =>
      throw StateError('boom');
}
