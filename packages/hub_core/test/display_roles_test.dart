import 'dart:async';

import 'package:hub_core/hub_core.dart';
import 'package:test/test.dart';

import 'support/fake_phone_harness.dart';

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

/// Pairs a phone with the QR from a `display.pairing` frame.
Future<TestPhone> pairViaDisplay(
  TestHubRig rig,
  TestPhone display, {
  String name = 'Phone',
  Map<String, dynamic>? pairing,
}) async {
  final frame =
      pairing ?? await display.waitFor((m) => m['t'] == 'display.pairing');
  final phone = await rig.connectPhone();
  await phone.pairWithQr(frame['qr'] as String, client: name);
  return phone;
}

void main() {
  group('Display role and pairing relay', () {
    late TestHubRig rig;

    setUp(() async => rig = await TestHubRig.start());
    tearDown(() => rig.dispose());

    test('first display is accepted without PIN and gets a token', () async {
      final tv = await rig.connectDisplay();
      final ready = await tv.helloAsDisplay();
      expect(tv.token, hasLength(64));
      expect(tv.role, 'display');
      expect((ready['device'] as Map)['role'], 'display');
      final rows = await rig.db.allDevices();
      expect(rows.single.role, 'display');

      // Token reconnect: straight to ready.
      await tv.close();
      await until(() => rig.server.readyClientCount == 0);
      final again = await rig.connectDisplay();
      again.sendDisplayHello(withToken: tv.token);
      await again.expectType(HubMsg.ready);
      expect(rig.server.readyClientCount, 1);
    });

    test('a phone token does not open a display session', () async {
      final phone = await rig.onboardPhone('Phone');
      final tv = await rig.connectDisplay();
      tv.sendDisplayHello(withToken: phone.token);
      // Treated as a new display (none paired yet) and accepted.
      await tv.expectType(HubMsg.paired);
      final ready = await tv.expectType(HubMsg.ready);
      expect((ready['device'] as Map)['role'], 'display');
      expect(tv.token, isNot(phone.token));
    });

    test('second display while the first is online gets conflict', () async {
      await rig.onboardDisplay();
      final second = await rig.connectDisplay();
      second.sendDisplayHello();
      final err = await second.expectType(HubMsg.err);
      expect(err['code'], HubErrorCode.conflict);
      await until(() => second.closed);
      expect(await rig.db.displays(), hasLength(1));
    });

    test('new display with a phone paired waits for approval', () async {
      final oldTv = await rig.onboardDisplay('Old TV');
      final phone = await rig.onboardPhone('Owner');
      await oldTv.close();
      await until(() => rig.server.readyClientCount == 1);

      final newTv = await rig.connectDisplay();
      newTv.sendDisplayHello(client: 'New TV');
      final req = await phone.waitFor(
        (m) => m['t'] == 'devices.approvalRequested',
      );
      expect(req['name'], 'New TV');
      expect(
        newTv.receivedHistory.map((m) => m['t']),
        isNot(contains('paired')),
      );

      final ok = await phone.request('devices.approveDisplay', {
        'requestId': req['requestId'],
      });
      expect(ok['t'], HubMsg.ok);
      await newTv.expectType(HubMsg.paired);
      final ready = await newTv.expectType(HubMsg.ready);
      expect((ready['device'] as Map)['role'], 'display');

      // The old display row is gone and its token no longer works.
      final displays = await rig.db.displays();
      expect(displays, hasLength(1));
      expect(displays.single.id, (ready['device'] as Map)['id']);
      final stale = await rig.connectDisplay();
      stale.sendDisplayHello(withToken: oldTv.token);
      // Unknown token: handled as a new display while one is online.
      final err = await stale.expectType(HubMsg.err);
      expect(err['code'], HubErrorCode.conflict);

      // The approval request cannot be replayed.
      final replay = await phone.request('devices.approveDisplay', {
        'requestId': req['requestId'],
      });
      expect(replay['code'], HubErrorCode.notFound);
    });

    test('a controller can approve too; a display cannot', () async {
      final oldTv = await rig.onboardDisplay();
      await rig.onboardPhone('Owner');
      final ctl = await rig.onboardPhone('Ctl');
      await oldTv.close();
      await until(() => rig.server.readyClientCount == 2);

      final newTv = await rig.connectDisplay();
      newTv.sendDisplayHello();
      final req = await ctl.waitFor(
        (m) => m['t'] == 'devices.approvalRequested',
      );
      final r = await ctl.request('devices.approveDisplay', {
        'requestId': req['requestId'],
      });
      expect(r['t'], HubMsg.ok);
      await newTv.expectType(HubMsg.paired);
      await newTv.expectType(HubMsg.ready);
      final denied = await newTv.request('devices.approveDisplay', {
        'requestId': 'x',
      });
      expect(denied['code'], HubErrorCode.forbidden);
    });

    test('approval times out with err timeout and closes', () async {
      await rig.dispose();
      rig = await TestHubRig.start(
        pairingTimeout: const Duration(milliseconds: 300),
      );
      final oldTv = await rig.onboardDisplay();
      await rig.onboardPhone('Owner');
      await oldTv.close();
      await until(() => rig.server.readyClientCount == 1);

      final newTv = await rig.connectDisplay();
      newTv.sendDisplayHello();
      final err = await newTv.expectType(HubMsg.err);
      expect(err['code'], HubErrorCode.timeout);
      await until(() => newTv.closed);
      final displays = await rig.db.displays();
      expect(displays.single.id, oldTv.deviceId);
    });

    test('new display with no phone paired replaces the old row', () async {
      final oldTv = await rig.onboardDisplay('Old');
      await oldTv.close();
      await until(() => rig.server.readyClientCount == 0);

      final newTv = await rig.connectDisplay();
      await newTv.helloAsDisplay(client: 'New');
      final displays = await rig.db.displays();
      expect(displays, hasLength(1));
      expect(displays.single.id, newTv.deviceId);
      expect(displays.single.id, isNot(oldTv.deviceId));
    });

    test('startPairing relays qr, pin and expiry to the display', () async {
      final tv = await rig.onboardDisplay();
      final first = await tv.startPairing();
      expect(first['pin'], matches(RegExp(r'^\d{4}$')));
      expect(first['expiresAt'], isA<int>());
      final qr = PairQrData.tryParse(first['qr'] as String)!;
      expect(qr.host, '127.0.0.1');
      expect(qr.port, rig.server.port);
      expect(qr.hubId, rig.server.hubId);

      // First phone is owner; the display gets fresh credentials after it.
      final owner = await pairViaDisplay(rig, tv, pairing: first);
      expect(owner.role, 'owner');
      final second = await tv.waitFor((m) => m['t'] == 'display.pairing');
      expect(second['qr'], isNot(first['qr']));
      expect(second['pin'], isNot(first['pin']));

      // PIN pairing works too and yields a controller.
      final p2 = await rig.connectPhone();
      p2.send(HubMsg.hello, {'v': kProtocolVersion, 'client': 'Two'});
      await p2.expectType(HubMsg.pairRequired);
      p2.send(HubMsg.pair, {'pin': second['pin']});
      await p2.expectType(HubMsg.paired);
      final ready = await p2.expectType(HubMsg.ready);
      expect((ready['device'] as Map)['role'], 'controller');

      // The used QR code cannot be replayed.
      final p3 = await rig.connectPhone();
      p3.send(HubMsg.hello, {
        'v': kProtocolVersion,
        'client': 'Replay',
        'pairCode': qr.pairCode,
      });
      await p3.expectType(HubMsg.pairRequired);
    });

    test('phones get unavailable while no session is open', () async {
      final tv = await rig.onboardDisplay();
      final p = await rig.connectPhone();
      p.send(HubMsg.hello, {'v': kProtocolVersion, 'client': 'Early'});
      final err = await p.expectType(HubMsg.err);
      expect(err['code'], HubErrorCode.unavailable);
      await until(() => p.closed);

      // After cancelPairing the same holds.
      await tv.startPairing();
      expect((await tv.request('devices.cancelPairing'))['t'], HubMsg.ok);
      final q = await rig.connectPhone();
      q.send(HubMsg.hello, {'v': kProtocolVersion, 'client': 'Late'});
      expect((await q.expectType(HubMsg.err))['code'], 'unavailable');
    });

    test('the pairing session ends when the display disconnects', () async {
      final tv = await rig.onboardDisplay();
      await tv.startPairing();
      expect(rig.server.pairingCredentials.value, isNotNull);
      await tv.close();
      await until(() => rig.server.pairingCredentials.value == null);
    });

    test('startPairing and cancelPairing are display only', () async {
      await rig.onboardDisplay();
      final phone = await rig.onboardPhone('Owner');
      expect(
        (await phone.request('devices.startPairing'))['code'],
        HubErrorCode.forbidden,
      );
      expect(
        (await phone.request('devices.cancelPairing'))['code'],
        HubErrorCode.forbidden,
      );
    });

    test('3 wrong PINs lock pairing and rotate the relayed codes', () async {
      final tv = await rig.onboardDisplay();
      final first = await tv.startPairing();
      final p = await rig.connectPhone();
      p.send(HubMsg.hello, {'v': kProtocolVersion, 'client': 'Bad'});
      await p.expectType(HubMsg.pairRequired);
      final wrong = first['pin'] == '0000' ? '1111' : '0000';
      for (var i = 0; i < 3; i++) {
        p.send(HubMsg.pair, {'pin': wrong});
        final f = await p.expectType(HubMsg.pairFailed);
        if (i == 2) expect(f['retryInMs'], 60000);
      }
      final rotated = await tv.waitFor(
        (m) => m['t'] == 'display.pairing' && m['pin'] != first['pin'],
      );
      expect(rotated['qr'], isNot(first['qr']));
    });
  });

  group('forgetAll and reset', () {
    late TestHubRig rig;

    setUp(() async => rig = await TestHubRig.start());
    tearDown(() => rig.dispose());

    test('display forgetAll removes phones, keeps the display', () async {
      final tv = await rig.onboardDisplay();
      final a = await rig.onboardPhone('A');
      final b = await rig.onboardPhone('B');
      expect(a.role, 'owner');
      expect(b.role, 'controller');

      final r = await tv.request('devices.forgetAll');
      expect(r['t'], HubMsg.ok);
      await until(() => a.closed && b.closed);
      expect(tv.closed, isFalse);
      final rows = await rig.db.allDevices();
      expect(rows.single.role, 'display');

      // The next phone to pair is owner.
      final pairing = await tv.startPairing();
      final c = await pairViaDisplay(rig, tv, pairing: pairing);
      expect(c.role, 'owner');
    });

    test('owner may forgetAll, a controller may not', () async {
      await rig.onboardDisplay();
      final owner = await rig.onboardPhone('Owner');
      final ctl = await rig.onboardPhone('Ctl');
      final denied = await ctl.request('devices.forgetAll');
      expect(denied['code'], HubErrorCode.forbidden);
      expect(ctl.closed, isFalse);
      expect((await owner.request('devices.forgetAll'))['t'], HubMsg.ok);
      await until(() => owner.closed && ctl.closed);
      expect(await rig.db.phoneCount(), 0);
      expect(await rig.db.displays(), hasLength(1));
    });

    test('device.forget works from the display (owner-equivalent)', () async {
      final tv = await rig.onboardDisplay();
      final owner = await rig.onboardPhone('Owner');
      final ctl = await rig.onboardPhone('Ctl');
      final r = await tv.request('device.forget', {'deviceId': ctl.deviceId});
      expect(r['t'], HubMsg.ok);
      await until(() => ctl.closed);
      expect(owner.closed, isFalse);
    });

    test('resetAll deletes every device and closes all sockets', () async {
      final tv = await rig.onboardDisplay();
      final phone = await rig.onboardPhone('Owner');
      await rig.server.resetAll();
      await until(() => tv.closed && phone.closed);
      expect(await rig.db.allDevices(), isEmpty);
      expect(await rig.db.allPairings(), isEmpty);

      // The display is the first display again and the phone the owner.
      final tv2 = await rig.connectDisplay();
      await tv2.helloAsDisplay();
      expect(tv2.role, 'display');
      final pairing = await tv2.startPairing();
      final p = await pairViaDisplay(rig, tv2, pairing: pairing);
      expect(p.role, 'owner');
    });

    test('phone election ignores the display row', () async {
      expect(await rig.db.nextDeviceRole(), 'owner');
      await rig.onboardDisplay();
      expect(await rig.db.nextDeviceRole(), 'owner');
    });
  });
}
