import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hub_core/hub_core.dart';
import 'package:tv_saver/phone/phone_controller.dart';
import 'package:tv_saver/phone/secure_token_store.dart';

import 'support.dart';

void main() {
  late Rig rig;
  final rigs = <PhoneRig>[];

  setUp(() async => rig = await Rig.start());
  tearDown(() async {
    for (final p in rigs) {
      await p.dispose();
    }
    rigs.clear();
    await rig.dispose();
  });

  PhoneRig newPhone({
    HubTokenStore? store,
    HubScanner? scanner,
    FakeLock? lock,
  }) {
    final p = PhoneRig(store: store, scanner: scanner, lock: lock);
    rigs.add(p);
    return p;
  }

  group('pairing', () {
    test(
      'first launch with no pairing shows Connect with the scan prompt',
      () async {
        final p = newPhone();
        expect(p.controller.screen, PhoneScreen.loading);
        await p.controller.start();
        expect(p.controller.screen, PhoneScreen.connect);
        expect(p.controller.hasPairing, isFalse);
        expect(p.controller.canRetry, isFalse);
        expect(p.controller.statusText, contains('Scan the QR code'));
        expect(p.lock.held, 0);
      },
    );

    test(
      'valid QR pairs the first phone as owner, second as controller',
      () async {
        final a = newPhone();
        await a.controller.start();
        expect(await a.controller.pairFromQr(rig.openQr()), QrOutcome.started);
        await a.waitFor(PhoneScreen.home);
        expect(a.controller.me!.role, DeviceRole.owner);
        await until(() => a.controller.devices.isNotEmpty);
        expect(a.controller.devices.single.name, 'Test phone');
        expect(a.controller.devices.single.online, isTrue);
        expect((await a.store.getLastPairing())!.hubId, 'hub-phone-test');

        final b = newPhone();
        await b.controller.start();
        await b.controller.pairFromQr(rig.openQr());
        await b.waitFor(PhoneScreen.home);
        expect(b.controller.me!.role, DeviceRole.controller);
        await until(() => a.controller.devices.length == 2);
      },
    );

    test(
      'a QR that is not tvsaver://pair is rejected without connecting',
      () async {
        final p = newPhone();
        await p.controller.start();
        expect(
          await p.controller.pairFromQr('https://example.com/x'),
          QrOutcome.invalid,
        );
        expect(p.controller.screen, PhoneScreen.connect);
        expect(p.client.state.value.phase, HubConnectionPhase.disconnected);
        expect(rig.server.readyClientCount, 0);
      },
    );

    test(
      'a wrong or reused code falls back to PIN entry, 3 wrong tries lock out',
      () async {
        final qr = rig.openQr();
        final bad = qr.replaceFirst(RegExp(r'c=[^&]+'), 'c=wrongcode');
        final p = newPhone();
        await p.controller.start();
        await p.controller.pairFromQr(bad);
        await p.waitFor(PhoneScreen.pin);

        p.controller.submitPin('0000');
        await until(
          () => p.client.state.value.lastError == HubMessages.wrongPin,
        );
        expect(p.controller.screen, PhoneScreen.pin);
        p.controller.submitPin('0001');
        await until(() => p.client.state.value.pinRetryInMs != null);
        final st = p.client.state.value;
        expect(st.lastError, startsWith('Too many tries'));
        expect(st.pinRetryInMs, greaterThan(0));
        expect(p.controller.screen, PhoneScreen.pin);
      },
    );

    test('the right PIN pairs after a rejected code', () async {
      final qr = rig.openQr();
      final p = newPhone();
      await p.controller.start();
      await p.controller.pairFromQr(
        qr.replaceFirst(RegExp(r'c=[^&]+'), 'c=wrongcode'),
      );
      await p.waitFor(PhoneScreen.pin);
      p.controller.submitPin(rig.server.pairingCredentials.value!.pin);
      await p.waitFor(PhoneScreen.home);
      expect(p.controller.me!.role, DeviceRole.owner);
    });

    test(
      'no pairing session open: tells the user to start pairing on the TV',
      () async {
        final qr = rig.openQr();
        rig.server.closePairingSession();
        final p = newPhone();
        await p.controller.start();
        await p.controller.pairFromQr(qr);
        await until(
          () => p.client.state.value.lastError == HubMessages.pairingNotOpen,
        );
        expect(p.controller.screen, PhoneScreen.connect);
        expect(
          p.controller.statusText,
          'Start pairing on the TV, then scan again.',
        );
        expect(p.controller.hasPairing, isFalse);
      },
    );

    test('cancelling the PIN screen returns to Connect', () async {
      final qr = rig.openQr();
      final p = newPhone();
      await p.controller.start();
      await p.controller.pairFromQr(
        qr.replaceFirst(RegExp(r'c=[^&]+'), 'c=wrongcode'),
      );
      await p.waitFor(PhoneScreen.pin);
      await p.controller.cancelPin();
      expect(p.controller.screen, PhoneScreen.connect);
    });
  });

  group('reconnect', () {
    Future<MemoryHubTokenStore> pairedStore() async {
      final store = MemoryHubTokenStore();
      final p = newPhone(store: store);
      await p.controller.start();
      await p.controller.pairFromQr(rig.openQr());
      await p.waitFor(PhoneScreen.home);
      await untilAsync(() async => await store.getLastPairing() != null);
      await p.dispose();
      rigs.remove(p);
      rig.server.closePairingSession();
      return store;
    }

    test('relaunch with a saved pairing reconnects straight to Home', () async {
      final store = await pairedStore();
      await until(() => rig.server.readyClientCount == 0);
      final p = newPhone(store: store);
      await p.controller.start();
      expect(p.controller.hasPairing, isTrue);
      await p.waitFor(PhoneScreen.home);
      expect(p.controller.me!.role, DeviceRole.owner);
      expect(p.controller.hub.hubName, 'Test Pi');
    });

    test(
      'Pi down shows "TV not found" with Retry; a Pi restart needs no new scan',
      () async {
        await rig.dispose();
        final dir = Directory.systemTemp.createTempSync('tvsaver_phone_');
        addTearDown(() {
          try {
            dir.deleteSync(recursive: true);
          } on FileSystemException {
            // Windows keeps the file locked until the hub closes; harmless.
          }
        });
        final file = '${dir.path}/hub.db';
        rig = await Rig.start(dbFile: file);
        final store = MemoryHubTokenStore();
        final first = newPhone(store: store);
        await first.controller.start();
        await first.controller.pairFromQr(rig.openQr());
        await first.waitFor(PhoneScreen.home);
        await untilAsync(() async => await store.getLastPairing() != null);
        final port = rig.server.port;
        await first.dispose();
        rigs.remove(first);
        await rig.dispose();

        // Pi down: the saved pairing stays, the phone says so and offers Retry.
        final p = newPhone(store: store);
        await p.controller.start();
        await until(
          () =>
              p.controller.hub.phase == HubConnectionPhase.offline ||
              p.controller.hub.phase == HubConnectionPhase.appNotOpen,
        );
        expect(p.controller.screen, PhoneScreen.connect);
        expect(p.controller.canRetry, isTrue);
        expect(p.controller.hasPairing, isTrue);
        expect(
          p.controller.statusText,
          anyOf(HubMessages.tvNotFound, HubMessages.appNotOpen),
        );

        // The Pi restarts on the same port with the same database.
        rig = await Rig.start(dbFile: file, port: port);
        await p.controller.retry();
        await p.waitFor(PhoneScreen.home);
        expect(p.controller.me!.role, DeviceRole.owner);
      },
    );

    test(
      'saved host is stale: reconnects through mDNS and saves the new address',
      () async {
        final store = await pairedStore();
        final saved = (await store.getLastPairing())!;
        // Point the pairing at a dead port, as after a DHCP change.
        await store.savePairing(
          saved.copyWith(lastPort: 1, lastHost: '127.0.0.1'),
        );
        final scanner = FakeScanner([
          HubEndpoint(
            host: '127.0.0.1',
            port: rig.server.port,
            name: 'Test Pi',
            id: 'hub-phone-test',
          ),
        ]);
        final p = newPhone(store: store, scanner: scanner);
        await p.controller.start();
        await p.waitFor(PhoneScreen.home);
        expect(scanner.scans, 1);
        await untilAsync(
          () async =>
              (await store.getLastPairing())!.lastPort == rig.server.port,
        );
      },
    );

    test('nothing answers: TV not found with Retry', () async {
      final store = await pairedStore();
      final saved = (await store.getLastPairing())!;
      await store.savePairing(
        saved.copyWith(lastPort: 1, lastHost: '127.0.0.1'),
      );
      final p = newPhone(store: store);
      await p.controller.start();
      await until(
        () =>
            p.controller.hub.phase == HubConnectionPhase.offline ||
            p.controller.hub.phase == HubConnectionPhase.appNotOpen,
      );
      expect(p.controller.screen, PhoneScreen.connect);
      expect(p.controller.canRetry, isTrue);
      expect(p.controller.hasPairing, isTrue);
    });

    test(
      'a forgotten phone goes back to Connect with a message and no pairing',
      () async {
        final store = MemoryHubTokenStore();
        final p = newPhone(store: store);
        await p.controller.start();
        await p.controller.pairFromQr(rig.openQr());
        await p.waitFor(PhoneScreen.home);
        rig.server.closePairingSession();

        await rig.server.forgetAllPhones();
        await p.waitFor(PhoneScreen.connect);
        await until(
          () => p.client.state.value.lastError == HubMessages.revoked,
        );
        expect(p.controller.statusText, HubMessages.revoked);
        await until(() => !p.controller.hasPairing);
        expect(await store.getLastPairing(), isNull);
      },
    );

    test(
      'a phone forgotten while the app was closed hits the same path',
      () async {
        final store = await pairedStore();
        await rig.server.forgetAllPhones();
        final p = newPhone(store: store);
        await p.controller.start();
        await until(
          () => p.client.state.value.lastError == HubMessages.revoked,
        );
        expect(p.controller.screen, PhoneScreen.connect);
        await until(() => !p.controller.hasPairing);
      },
    );
  });

  group('forget and lock', () {
    test('Forget this Pi removes only the local pairing', () async {
      final p = newPhone();
      await p.controller.start();
      await p.controller.pairFromQr(rig.openQr());
      await p.waitFor(PhoneScreen.home);
      await p.controller.forgetThisPi();
      expect(p.controller.screen, PhoneScreen.connect);
      expect(p.controller.hasPairing, isFalse);
      expect(await p.store.getLastPairing(), isNull);
      expect((await rig.db.allDevices()), hasLength(1));
    });

    test(
      'the multicast lock is held while scanning or reconnecting only',
      () async {
        final lock = FakeLock();
        final p = newPhone(lock: lock);
        await p.controller.start();
        expect(lock.held, 0);
        p.controller.setScanning(true);
        expect(lock.held, 1);
        await p.controller.pairFromQr(rig.openQr());
        p.controller.setScanning(false);
        await p.waitFor(PhoneScreen.home);
        await until(() => lock.held == 0);
        expect(lock.acquired, lock.released);
      },
    );
  });

  group('controller robustness', () {
    test(
      'the multicast lock is released in the background and re-acquired',
      () async {
        final lock = FakeLock();
        final p = newPhone(lock: lock);
        await p.controller.start();
        p.controller.setScanning(true);
        expect(lock.held, 1);
        p.controller.setForeground(false);
        expect(lock.held, 0);
        p.controller.setForeground(true);
        expect(lock.held, 1);
        p.controller.setScanning(false);
        expect(lock.held, 0);
      },
    );

    test('start() twice reconnects once', () async {
      final store = await _pairedStore(rig, newPhone);
      final p = newPhone(store: store);
      await Future.wait([p.controller.start(), p.controller.start()]);
      await p.waitFor(PhoneScreen.home);
      expect(rig.server.readyClientCount, 1);
    });

    test(
      'forgetThisPi reports a store failure and still disconnects',
      () async {
        final inner = MemoryHubTokenStore();
        final p = newPhone(store: _FailingRemoveStore(inner));
        await p.controller.start();
        await p.controller.pairFromQr(rig.openQr());
        await p.waitFor(PhoneScreen.home);
        await untilAsync(() async => await inner.getLastPairing() != null);
        expect(await p.controller.forgetThisPi(), isFalse);
        expect(p.controller.screen, PhoneScreen.connect);
        expect(p.client.state.value.phase, HubConnectionPhase.disconnected);
      },
    );

    test(
      'forgetThisPi falls back to the last pairing when hubId is unknown',
      () async {
        final store = MemoryHubTokenStore();
        await store.savePairing(
          const SavedHubPairing(
            hubId: 'h',
            token: 't',
            lastHost: '',
            lastPort: 1,
            hubName: 'Pi',
          ),
        );
        final p = newPhone(store: store);
        expect(p.controller.hub.hubId, isNull);
        expect(await p.controller.forgetThisPi(), isTrue);
        expect(await store.getLastPairing(), isNull);
      },
    );

    test(
      'the device list is cleared when the phone is no longer connected',
      () async {
        final p = newPhone();
        await p.controller.start();
        await p.controller.pairFromQr(rig.openQr());
        await p.waitFor(PhoneScreen.home);
        await until(() => p.controller.devices.isNotEmpty);
        await p.client.disconnect();
        expect(p.controller.devices, isEmpty);
      },
    );

    test('a new QR scan drops an attempt still in flight', () async {
      final store = MemoryHubTokenStore();
      await store.savePairing(
        const SavedHubPairing(
          hubId: 'hub-phone-test',
          token: 'stale',
          lastHost: '127.0.0.1',
          lastPort: 1,
          hubName: 'Pi',
        ),
      );
      final p = newPhone(store: store);
      await p.controller.start(); // Reconnect loop against a dead port.
      await p.controller.pairFromQr(rig.openQr());
      await p.waitFor(PhoneScreen.home);
      expect(rig.server.readyClientCount, 1);
    });
  });

  group('SecureTokenStore', () {
    test('round-trips pairings and keeps the active one', () async {
      FlutterSecureStorage.setMockInitialValues({});
      final store = SecureTokenStore();
      expect(await store.getLastPairing(), isNull);
      const a = SavedHubPairing(
        hubId: 'a',
        token: 'ta',
        lastHost: '10.0.0.2',
        lastPort: 8772,
        hubName: 'Pi A',
      );
      await store.savePairing(a);
      await store.savePairing(
        a.copyWith(token: 'tb', lastHost: '10.0.0.3').copyWith(),
      );
      final again = SecureTokenStore();
      final last = (await again.getLastPairing())!;
      expect(last.hubId, 'a');
      expect(last.token, 'tb');
      expect(last.lastHost, '10.0.0.3');
      await again.setLabel('a', 'Living room');
      expect((await store.getPairing('a'))!.displayName, 'Living room');
      await again.removePairing('a');
      expect(await store.getLastPairing(), isNull);
      expect(await store.allPairings(), isEmpty);
    });

    test('an unreadable record means not paired', () async {
      FlutterSecureStorage.setMockInitialValues({
        SecureTokenStore.storageKey: '{not json',
      });
      expect(await SecureTokenStore().getLastPairing(), isNull);
      FlutterSecureStorage.setMockInitialValues({
        SecureTokenStore.storageKey: jsonEncode({
          'active': 'x',
          'pairings': {},
        }),
      });
      expect(await SecureTokenStore().getLastPairing(), isNull);
    });

    test(
      'a throwing read is treated as corrupt: key deleted, not paired',
      () async {
        final storage = _ThrowingStorage();
        final store = SecureTokenStore(storage: storage);
        expect(await store.getLastPairing(), isNull);
        expect(storage.deleted, [SecureTokenStore.storageKey]);
        expect(await store.allPairings(), isEmpty);
      },
    );

    test('an unreadable JSON record is deleted', () async {
      FlutterSecureStorage.setMockInitialValues({
        SecureTokenStore.storageKey: '{not json',
      });
      final store = SecureTokenStore();
      expect(await store.getLastPairing(), isNull);
      expect(
        await const FlutterSecureStorage().read(
          key: SecureTokenStore.storageKey,
        ),
        isNull,
      );
    });

    test(
      'two pairings: removePairing and setActive fall back correctly',
      () async {
        FlutterSecureStorage.setMockInitialValues({});
        final store = SecureTokenStore();
        SavedHubPairing p(String id) => SavedHubPairing(
          hubId: id,
          token: 't$id',
          lastHost: '10.0.0.1',
          lastPort: 8772,
          hubName: 'Pi $id',
        );
        await store.savePairing(p('a'));
        await store.savePairing(p('b'));
        expect((await store.getLastPairing())!.hubId, 'b');
        await store.setActive('a');
        expect((await store.getLastPairing())!.hubId, 'a');
        await store.setActive('missing');
        expect((await store.getLastPairing())!.hubId, 'a');
        await store.removePairing('a');
        expect((await store.getLastPairing())!.hubId, 'b');
        await store.removePairing('zzz');
        expect((await store.allPairings()).map((e) => e.hubId), ['b']);
        await store.removePairing('b');
        expect(await store.getLastPairing(), isNull);
      },
    );
  });
}

class _ThrowingStorage extends FlutterSecureStorage {
  final deleted = <String>[];

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => throw PlatformException(code: 'keystore');

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => deleted.add(key);
}

Future<MemoryHubTokenStore> _pairedStore(
  Rig rig,
  PhoneRig Function({HubTokenStore? store, HubScanner? scanner, FakeLock? lock})
  make,
) async {
  final store = MemoryHubTokenStore();
  final p = make(store: store);
  await p.controller.start();
  await p.controller.pairFromQr(rig.openQr());
  await p.waitFor(PhoneScreen.home);
  await untilAsync(() async => await store.getLastPairing() != null);
  await p.dispose();
  rig.server.closePairingSession();
  await until(() => rig.server.readyClientCount == 0);
  return store;
}

class _FailingRemoveStore extends MemoryHubTokenStore {
  _FailingRemoveStore(this.inner);

  final MemoryHubTokenStore inner;

  @override
  Future<SavedHubPairing?> getLastPairing() => inner.getLastPairing();

  @override
  Future<SavedHubPairing?> getPairing(String hubId) => inner.getPairing(hubId);

  @override
  Future<void> savePairing(SavedHubPairing pairing) =>
      inner.savePairing(pairing);

  @override
  Future<void> removePairing(String hubId) async =>
      throw StateError('keystore');
}
