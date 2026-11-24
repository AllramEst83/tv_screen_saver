import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:hub_core/hub_core.dart';
import 'package:test/test.dart';

import 'support/fake_phone_harness.dart';

/// Scanner that finds nothing (no multicast in tests).
class EmptyScanner extends HubScanner {
  EmptyScanner() : super(timeout: const Duration(milliseconds: 50));

  @override
  Stream<HubEndpoint> scan() => const Stream.empty();
}

HubClient newClient(
  HubTokenStore store, {
  String name = 'Test Phone',
  Duration direct = const Duration(milliseconds: 800),
  HubScanner? scanner,
  Duration pingInterval = const Duration(seconds: 5),
  Duration deadAfter = const Duration(seconds: 15),
}) => HubClient(
  tokenStore: store,
  clientName: name,
  scanner: scanner ?? EmptyScanner(),
  pingInterval: pingInterval,
  deadAfter: deadAfter,
  directTimeout: direct,
  mdnsTimeout: const Duration(milliseconds: 100),
  reconnectBackoff: const [
    Duration(milliseconds: 50),
    Duration(milliseconds: 100),
  ],
);

Future<void> until(
  bool Function() cond, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!cond()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Condition not met in $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  group('Pairing and roles (server)', () {
    late TestHubRig rig;

    setUp(() async => rig = await TestHubRig.start());
    tearDown(() => rig.dispose());

    test('QR pairing: paired then ready, code becomes invalid', () async {
      final creds = rig.server.openPairingSession();
      final qr = rig.server.currentQrUri('127.0.0.1')!;
      final p1 = await rig.connectPhone();
      final ready = await p1.pairWithQr(qr);
      expect(p1.token, hasLength(64));
      expect(ready['id'], rig.server.hubId);
      expect(p1.role, 'owner');

      // The same code again is refused with pair_required.
      final p2 = await rig.connectPhone();
      p2.send(HubMsg.hello, {
        'v': 1,
        'client': 'Reuse',
        'pairCode': creds.pairCode,
      });
      await p2.expectType(HubMsg.pairRequired);
    });

    test(
      'PIN pairing: first device is owner, later ones controllers',
      () async {
        rig.server.openPairingSession();
        final p1 = await rig.connectPhone();
        p1.send(HubMsg.hello, {'v': 1, 'client': 'One'});
        await p1.expectType(HubMsg.pairRequired);
        await p1.pinPair(rig.server);
        expect(p1.role, 'owner');

        final p2 = await rig.connectPhone();
        p2.send(HubMsg.hello, {'v': 1, 'client': 'Two'});
        await p2.expectType(HubMsg.pairRequired);
        await p2.pinPair(rig.server);
        expect(p2.role, 'controller');

        // The token is stored only as a SHA-256 hash.
        final stored = await rig.db.allPairings();
        expect(stored, hasLength(2));
        expect(stored.map((r) => r.tokenHash), isNot(contains(p1.token)));
      },
    );

    test('3 wrong PINs lock for 60 s and rotate the credentials', () async {
      rig.server.openPairingSession();
      final p = await rig.connectPhone();
      p.send(HubMsg.hello, {'v': 1, 'client': 'Bad'});
      await p.expectType(HubMsg.pairRequired);
      final before = rig.server.pairingCredentials.value!;
      final wrong = before.pin == '0000' ? '1111' : '0000';

      p.send(HubMsg.pair, {'pin': wrong});
      expect((await p.expectType(HubMsg.pairFailed))['retryInMs'], isNull);
      p.send(HubMsg.pair, {'pin': wrong});
      expect((await p.expectType(HubMsg.pairFailed))['retryInMs'], isNull);
      p.send(HubMsg.pair, {'pin': wrong});
      expect((await p.expectType(HubMsg.pairFailed))['retryInMs'], 60000);

      final after = rig.server.pairingCredentials.value!;
      expect(after.pin, isNot(before.pin));
      expect(after.pairCode, isNot(before.pairCode));

      // The correct PIN still fails during the lock.
      p.send(HubMsg.pair, {'pin': after.pin});
      final locked = await p.expectType(HubMsg.pairFailed);
      expect(locked['retryInMs'], greaterThan(0));

      // After the lock (and credential expiry) a fresh PIN works.
      rig.clock.advance(const Duration(seconds: 61));
      final fresh = rig.server.rotatePairingCredentials();
      p.send(HubMsg.pair, {'pin': fresh.pin});
      await p.expectType(HubMsg.paired);
    });

    test('PIN expires after 120 s', () async {
      rig.server.openPairingSession();
      final p = await rig.connectPhone();
      p.send(HubMsg.hello, {'v': 1, 'client': 'Slow'});
      await p.expectType(HubMsg.pairRequired);
      final creds = rig.server.pairingCredentials.value!;
      rig.clock.advance(const Duration(seconds: 121));
      p.send(HubMsg.pair, {'pin': creds.pin});
      await p.expectType(HubMsg.pairFailed);
    });

    test(
      'token reconnect goes straight to ready; bad token needs pairing',
      () async {
        final p1 = await rig.onboardPhone('Mine');
        await p1.close();

        final p2 = await rig.connectPhone();
        final ready = await p2.helloWithToken(p1.token!);
        expect(ready['device'], isA<Map>());
        expect(p2.deviceId, p1.deviceId);
        expect(
          p2.receivedHistory.map((m) => m['t']),
          isNot(contains(HubMsg.paired)),
        );

        rig.server.openPairingSession();
        final p3 = await rig.connectPhone();
        p3.send(HubMsg.hello, {'v': 1, 'client': 'X', 'token': 'f' * 64});
        await p3.expectType(HubMsg.pairRequired);
      },
    );

    test(
      '8th phone gets conflict and is closed (1 display + 7 phones)',
      () async {
        for (var i = 0; i < 7; i++) {
          await rig.onboardPhone('Phone $i');
        }
        expect(rig.server.readyClientCount, 7);

        final devicesBefore = (await rig.db.allDevices()).length;
        final pairingsBefore = (await rig.db.allPairings()).length;
        final ninth = await rig.connectPhone();
        rig.server.openPairingSession();
        final qr = rig.server.currentQrUri('127.0.0.1')!;
        final parsed = PairQrData.tryParse(qr)!;
        ninth.send(HubMsg.hello, {
          'v': 1,
          'client': 'Ninth',
          'pairCode': parsed.pairCode,
        });
        final err = await ninth.expectType(HubMsg.err);
        expect(
          ninth.receivedHistory.map((m) => m['t']),
          isNot(contains('paired')),
        );
        expect(err['code'], HubErrorCode.conflict);
        await until(() => ninth.closed);
        expect(rig.server.readyClientCount, 7);
        expect((await rig.db.allDevices()).length, devicesBefore);
        expect((await rig.db.allPairings()).length, pairingsBefore);
      },
    );

    test('same token replaces the older socket', () async {
      final p1 = await rig.onboardPhone('Mine');
      final p1b = await rig.connectPhone();
      await p1b.helloWithToken(p1.token!);
      await p1.waitFor((m) => m['t'] == HubMsg.replaced);
      expect(rig.server.readyClientCount, 1);
    });

    test(
      'controller gets forbidden on owner actions; owner can forget',
      () async {
        final owner = await rig.onboardPhone('Owner');
        final ctl = await rig.onboardPhone('Controller');
        expect(owner.role, 'owner');
        expect(ctl.role, 'controller');

        final denied = await ctl.request('device.forget', {
          'deviceId': owner.deviceId,
        });
        expect(denied['t'], HubMsg.err);
        expect(denied['code'], HubErrorCode.forbidden);
        final denied2 = await ctl.request('owner.only');
        expect(denied2['code'], HubErrorCode.forbidden);
        expect((await owner.request('owner.only'))['t'], HubMsg.ok);

        final okReply = await owner.request('device.forget', {
          'deviceId': ctl.deviceId,
        });
        expect(okReply['t'], HubMsg.ok);
        await until(() => ctl.closed);

        // The forgotten phone's token no longer works.
        rig.server.openPairingSession();
        final again = await rig.connectPhone();
        again.send(HubMsg.hello, {'v': 1, 'client': 'C', 'token': ctl.token});
        await again.expectType(HubMsg.pairRequired);
      },
    );

    test('hello with a newer protocol version gets upgrade_tv', () async {
      final p = await rig.connectPhone();
      p.send(HubMsg.hello, {'v': kProtocolVersion + 1, 'client': 'Future'});
      final err = await p.expectType(HubMsg.err);
      expect(err['code'], HubErrorCode.upgradeTv);
      await until(() => p.closed);
    });

    test('1,000 hot frames relay in order with zero DB writes', () async {
      final a = await rig.onboardPhone('A');
      final b = await rig.onboardPhone('B');
      // Let presence writes and the snapshots settle.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final writesBefore = rig.counter.writes;

      for (var i = 0; i < 1000; i++) {
        a.send('hot.relay', {'n': i});
      }
      final received = <int>[];
      while (received.length < 1000) {
        final m = await b.waitFor((m) => m['t'] == 'hot.relay');
        received.add(m['n'] as int);
      }
      expect(received, List<int>.generate(1000, (i) => i));
      expect(rig.counter.writes, writesBefore);
      // The sender does not get its own frames back.
      expect(a.receivedHistory.where((m) => m['t'] == 'hot.relay'), isEmpty);
    });

    test('malformed, oversized and unknown frames are ignored', () async {
      final p = await rig.onboardPhone('A');
      p.socket.add('{{{ not json');
      p.socket.add(encodeFrame('x', {'pad': 'x' * (kMaxFrameBytes + 10)}));
      p.send('totally.unknown', {'rid': 1});
      p.send(HubMsg.ping, {'ts': 123});
      final pong = await p.waitFor((m) => m['t'] == HubMsg.pong);
      expect(pong['ts'], 123);
      expect(pong['now'], isA<int>());
    });

    test(
      'frames other than hello, pair and ping close an unpaired socket',
      () async {
        final p = await rig.connectPhone();
        p.send('device.rename', {'name': 'x'});
        await until(() => p.closed);
      },
    );
  });

  group('Devices module', () {
    late TestHubRig rig;

    setUp(() async => rig = await TestHubRig.start());
    tearDown(() => rig.dispose());

    test('snapshot lists devices; rename is self only', () async {
      final a = await rig.onboardPhone('Alpha');
      final b = await rig.onboardPhone('Beta');
      final snapshot = a.receivedHistory.firstWhere(
        (m) => m['t'] == HubMsg.snapshot,
      );
      final devices =
          (snapshot['modules'] as Map)['devices']['devices'] as List;
      expect(devices.single['name'], 'Alpha');
      expect(devices.single['role'], 'owner');

      final r = await b.request('device.rename', {'name': 'Beta 2'});
      expect(r['t'], HubMsg.ok);
      final changed = await a.waitFor(
        (m) =>
            m['t'] == HubMsg.event &&
            m['kind'] == 'devices.changed' &&
            (m['data']['devices'] as List).any((d) => d['name'] == 'Beta 2'),
      );
      expect((changed['data']['devices'] as List), hasLength(2));
      expect(
        (await b.request('device.rename', {'name': ''}))['code'],
        'invalid',
      );
    });

    test('devices.changed fires on connect and disconnect', () async {
      final a = await rig.onboardPhone('Alpha');
      final b = await rig.onboardPhone('Beta');
      await a.waitFor(
        (m) =>
            m['t'] == HubMsg.event &&
            m['kind'] == 'devices.changed' &&
            (m['data']['devices'] as List)
                    .where((d) => d['online'] == true)
                    .length ==
                2,
      );
      await b.close();
      await a.waitFor(
        (m) =>
            m['t'] == HubMsg.event &&
            m['kind'] == 'devices.changed' &&
            (m['data']['devices'] as List)
                    .where((d) => d['online'] == true)
                    .length ==
                1,
      );
    });

    test(
      'forgetPairings (TV remote) closes sockets and kills tokens',
      () async {
        final a = await rig.onboardPhone('Alpha');
        final b = await rig.onboardPhone('Beta');
        await rig.server.forgetPairings();
        await until(() => a.closed && b.closed);
        expect(await rig.db.allPairings(), isEmpty);
        expect(await rig.db.allDevices(), isEmpty);

        rig.server.openPairingSession();
        final again = await rig.connectPhone();
        again.send(HubMsg.hello, {'v': 1, 'client': 'A', 'token': a.token});
        await again.expectType(HubMsg.pairRequired);

        // With everything forgotten, the next device becomes owner again.
        final c = await rig.onboardPhone('Gamma');
        expect(c.role, 'owner');
      },
    );

    test('invokeLocal runs handlers as the TV owner', () async {
      final a = await rig.onboardPhone('Alpha');
      final b = await rig.onboardPhone('Beta');
      final res = await rig.server.invokeLocal('device.forget', {
        'deviceId': b.deviceId,
      });
      expect(res, isA<Map>());
      await until(() => b.closed);
      expect(a.closed, isFalse);
    });
  });

  group('HubClient', () {
    late TestHubRig rig;

    setUp(() async => rig = await TestHubRig.start());
    tearDown(() => rig.dispose());

    test('QR scan pairs with no further input and saves the token', () async {
      rig.server.openPairingSession();
      final store = MemoryHubTokenStore();
      final client = newClient(store);
      final ok = await client.connectFromQrUri(
        rig.server.currentQrUri('127.0.0.1')!,
      );
      expect(ok, isTrue);
      final st = client.state.value;
      expect(st.phase, HubConnectionPhase.connected);
      expect(st.hubName, 'Test TV');
      expect(st.device!.role.name, 'owner');
      await savedBy(store, rig.server.hubId);
      expect(await store.getPairing(rig.server.hubId), isNotNull);
      await client.dispose();
    });

    test('PIN pairing through an mDNS style endpoint', () async {
      rig.server.openPairingSession();
      final store = MemoryHubTokenStore();
      final client = newClient(store);
      await client.connectEndpoint(
        HubEndpoint(
          host: '127.0.0.1',
          port: rig.server.port,
          name: 'Test TV',
          id: rig.server.hubId,
        ),
      );
      expect(client.state.value.phase, HubConnectionPhase.awaitingPin);
      client.submitPin(rig.server.pairingCredentials.value!.pin);
      await until(
        () => client.state.value.phase == HubConnectionPhase.connected,
      );
      await client.dispose();
    });

    test('wrong hub id disconnects with a wrong-TV state', () async {
      rig.server.openPairingSession();
      final creds = rig.server.pairingCredentials.value!;
      final qr = PairQrData(
        version: 1,
        host: '127.0.0.1',
        port: rig.server.port,
        hubId: 'some-other-tv',
        pairCode: creds.pairCode,
      ).toUriString();
      final client = newClient(MemoryHubTokenStore());
      final ok = await client.connectFromQrUri(qr);
      expect(ok, isFalse);
      expect(client.state.value.phase, HubConnectionPhase.wrongTv);
      expect(client.state.value.lastError, HubMessages.wrongTv);
      await client.dispose();
    });

    test('replaced client does not reconnect', () async {
      rig.server.openPairingSession();
      final store = MemoryHubTokenStore();
      final c1 = newClient(store, name: 'One');
      await c1.connectFromQrUri(rig.server.currentQrUri('127.0.0.1')!);
      await savedBy(store, rig.server.hubId);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final c2 = newClient(store, name: 'Two');
      expect(await c2.reconnectSavedHub(), isTrue);
      await until(() => c1.state.value.phase == HubConnectionPhase.replaced);

      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(c1.state.value.phase, HubConnectionPhase.replaced);
      expect(rig.server.readyClientCount, 1);
      await c1.dispose();
      await c2.dispose();
    });

    test('request/ok/err and forbidden through the real client', () async {
      rig.server.openPairingSession();
      final owner = newClient(MemoryHubTokenStore(), name: 'Owner');
      await owner.connectFromQrUri(rig.server.currentQrUri('127.0.0.1')!);
      rig.server.openPairingSession();
      final ctl = newClient(MemoryHubTokenStore(), name: 'Ctl');
      await ctl.connectFromQrUri(rig.server.currentQrUri('127.0.0.1')!);
      expect(ctl.state.value.device!.role.name, 'controller');

      await expectLater(
        ctl.request('device.forget', {
          'deviceId': owner.state.value.device!.id,
        }),
        throwsA(
          isA<Object>().having(
            (e) => e.toString(),
            'toString',
            contains('forbidden'),
          ),
        ),
      );
      final res = await ctl.request('device.rename', {'name': 'Renamed'});
      expect(res['name'], 'Renamed');
      await owner.dispose();
      await ctl.dispose();
    });

    test('clock offset uses the pong round trip', () async {
      rig.server.openPairingSession();
      final client = newClient(MemoryHubTokenStore());
      await client.connectFromQrUri(rig.server.currentQrUri('127.0.0.1')!);
      // The fake clock is a fixed instant in 2026; the phone clock is real.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final expected =
          rig.clock.now().millisecondsSinceEpoch -
          DateTime.now().millisecondsSinceEpoch;
      expect((client.clockOffsetMs - expected).abs(), lessThan(1000));
      await client.dispose();
    });
  });

  group('App closed and reconnect', () {
    test(
      'TV refuses the connection: appNotOpen, then reconnects by itself',
      () async {
        // Reserve a port, then free it so nothing listens there.
        final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        final port = probe.port;
        await probe.close();

        final tvStore = MemoryTvStore('hub-test-42');
        final tvDb = HubDatabase.inMemory();
        var rig = await TestHubRig.start(port: port, store: tvStore, db: tvDb);
        expect(rig.server.port, port);
        rig.server.openPairingSession();
        final tokens = MemoryHubTokenStore();
        // Windows reports a refused loopback connect only after about 2 s.
        final client = newClient(tokens, direct: const Duration(seconds: 4));
        expect(
          await client.connectFromQrUri(rig.server.currentQrUri('127.0.0.1')!),
          isTrue,
        );
        await until(
          () => client.state.value.phase == HubConnectionPhase.connected,
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));

        // The TV app closes.
        await rig.dispose(closeDb: false);
        await until(
          () => client.state.value.phase == HubConnectionPhase.appNotOpen,
        );
        expect(client.state.value.lastError, HubMessages.appNotOpen);
        expect(
          client.state.value.lastError,
          "TV Saver isn't open on the TV. Open it with the remote.",
        );

        // The app reopens: the phone connects on its own, no input.
        rig = await TestHubRig.start(port: port, store: tvStore, db: tvDb);
        await until(
          () => client.state.value.phase == HubConnectionPhase.connected,
          timeout: const Duration(seconds: 20),
        );
        expect(client.state.value.device!.role.name, 'owner');
        await client.dispose();
        await rig.dispose();
      },
    );

    test('a refused TCP connect during pairing gives appNotOpen', () async {
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = probe.port;
      await probe.close();
      final client = newClient(MemoryHubTokenStore());
      final ok = await client.connectEndpoint(
        HubEndpoint(host: '127.0.0.1', port: port, name: 'Gone'),
      );
      expect(ok, isFalse);
      expect(client.state.value.phase, HubConnectionPhase.appNotOpen);
      await client.dispose();
    });

    test('a timeout gives "TV not found"', () async {
      final tokens = MemoryHubTokenStore();
      await tokens.savePairing(
        const SavedHubPairing(
          hubId: 'hub-x',
          token: 'tok',
          lastHost: '10.255.255.1',
          lastPort: 8772,
          hubName: 'Ghost TV',
        ),
      );
      final client = newClient(
        tokens,
        direct: const Duration(milliseconds: 300),
      );
      final ok = await client.reconnectSavedHub();
      expect(ok, isFalse);
      expect(client.state.value.phase, HubConnectionPhase.offline);
      expect(client.state.value.lastError, 'TV not found');
      await client.dispose();
    });

    test('upgrade_tv from the TV tells the phone to update the TV', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      unawaited(
        server.forEach((req) async {
          final ws = await WebSocketTransformer.upgrade(req);
          ws.listen((_) {
            ws.add(
              jsonEncode({
                't': HubMsg.err,
                'code': HubErrorCode.upgradeTv,
                'msg': 'old',
              }),
            );
          });
        }),
      );
      final client = newClient(MemoryHubTokenStore());
      await client.connectEndpoint(
        HubEndpoint(host: '127.0.0.1', port: server.port, name: 'Old TV'),
      );
      expect(client.state.value.phase, HubConnectionPhase.needsTvUpdate);
      expect(client.state.value.lastError, contains('Check for updates'));
      await client.dispose();
      await server.close(force: true);
    });
  });
}

/// Waits until the client has saved its pairing for [hubId].
Future<void> savedBy(MemoryHubTokenStore store, String hubId) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (await store.getPairing(hubId) == null) {
    if (DateTime.now().isAfter(deadline)) throw TimeoutException('not saved');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
