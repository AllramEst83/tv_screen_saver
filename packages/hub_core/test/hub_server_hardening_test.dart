import 'dart:async';
import 'dart:io';

import 'package:hub_core/hub_core.dart';
import 'package:test/test.dart';

import 'pairing_and_roles_test.dart' show newClient;
import 'support/fake_phone_harness.dart';

void main() {
  late TestHubRig rig;
  setUp(() async => rig = await TestHubRig.start());
  tearDown(() => rig.dispose());

  test('stop twice is safe and start after stop throws', () async {
    await rig.server.stop();
    await rig.server.stop();
    expect(rig.server.start(), throwsStateError);
  });

  test('hello with a whole double version is accepted', () async {
    final phone = await rig.connectPhone();
    rig.server.openPairingSession();
    final code = PairQrData.tryParse(
      rig.server.currentQrUri('127.0.0.1')!,
    )!.pairCode!;
    phone.socket.add('{"t":"hello","v":2.0,"client":"P","pairCode":"$code"}');
    await phone.waitFor((m) => m['t'] == HubMsg.ready);
  });

  test('wrong pairCode counts toward the lockout', () async {
    rig.server.openPairingSession();
    Map<String, dynamic>? last;
    for (var i = 0; i < 3; i++) {
      final p = await rig.connectPhone();
      p.send(HubMsg.hello, {
        'v': kProtocolVersion,
        'client': 'X',
        'pairCode': 'wrong$i',
      });
      last = await p.waitFor(
        (m) => m['t'] == HubMsg.pairRequired || m['t'] == HubMsg.pairFailed,
      );
    }
    expect(last!['t'], HubMsg.pairFailed);
    expect(last['retryInMs'], greaterThan(0));
  });

  test('next phone becomes owner when no owner remains', () async {
    final a = await rig.onboardPhone('A');
    final c = await rig.onboardPhone('C');
    expect(c.role, 'controller');
    await rig.server.forgetDevice(a.deviceId!);
    final d = await rig.onboardPhone('D');
    expect(d.role, 'owner');
  });

  test('sockets beyond maxClients * 4 are refused with 4013 (try again later)', () async {
    await rig.dispose();
    rig = await TestHubRig.start(maxClients: 1);
    final open = <WebSocket>[];
    for (var i = 0; i < 4; i++) {
      open.add(await WebSocket.connect('ws://127.0.0.1:${rig.server.port}/ws'));
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final extra = await WebSocket.connect(
      'ws://127.0.0.1:${rig.server.port}/ws',
    );
    final done = Completer<void>();
    extra.listen((_) {}, onDone: done.complete);
    await done.future.timeout(const Duration(seconds: 3));
    expect(extra.closeCode, 4013);
    for (final w in open) {
      await w.close();
    }
  });

  test(
    'a handler that throws after headers does not crash the server',
    () async {
      rig.server.registerHttpHandler((req) async {
        if (req.uri.path != '/boom') return false;
        req.response.contentLength = 100;
        req.response.add([1, 2, 3]);
        await req.response.flush();
        throw StateError('boom');
      });
      final client = HttpClient();
      try {
        final req = await client.getUrl(
          Uri.parse('http://127.0.0.1:${rig.server.port}/boom'),
        );
        try {
          final res = await req.close();
          await res.drain<void>();
        } catch (_) {}
      final ok = await (await client.getUrl(
          Uri.parse('http://127.0.0.1:${rig.server.port}/health'),
        )).close();
        expect(ok.statusCode, 200);
        await ok.drain<void>();
      } finally {
        client.close(force: true);
      }
    },
  );

  test(
    'HubClient: IPv6/malformed host fails cleanly; dispose is final',
    () async {
      final client = newClient(MemoryHubTokenStore());
      final ok = await client.connectEndpoint(
        const HubEndpoint(host: 'bad host::%', port: 1, name: 'x', id: 'y'),
      );
      expect(ok, isFalse);
      await client.dispose();
      },
  );
}
