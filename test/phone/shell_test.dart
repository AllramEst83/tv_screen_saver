import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hub_core/hub_core.dart';
import 'package:tv_saver/main_phone.dart';
import 'package:tv_saver/phone/phone_controller.dart';

import 'support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('controller', () {
    late Rig rig;
    final phones = <PhoneRig>[];

    setUp(() async => rig = await Rig.start(withSettings: true));
    tearDown(() async {
      for (final p in phones) {
        await p.dispose();
      }
      phones.clear();
      await rig.dispose();
    });

    Future<PhoneRig> pair() async {
      final p = PhoneRig();
      phones.add(p);
      await p.controller.start();
      await p.controller.pairFromQr(rig.openQr());
      await p.waitFor(PhoneScreen.home);
      await until(() => p.controller.hasSettings);
      rig.server.closePairingSession();
      return p;
    }

    test('the owner changes the ceiling; the second phone follows and the '
        'controller cannot', () async {
      final owner = await pair();
      final other = await pair();
      expect(owner.controller.canChangeSettings, isTrue);
      expect(other.controller.canChangeSettings, isFalse);
      expect(other.controller.settingInt('streamingCeilingMbps'), 80);

      final r = await owner.controller.updateSettings({
        'streamingCeilingMbps': 60,
      });
      expect(r.ok, isTrue);
      await until(
        () => other.controller.settingInt('streamingCeilingMbps') == 60,
      );
      expect(rig.settings!.values['streamingCeilingMbps'], 60);

      final denied = await other.controller.updateSettings({
        'streamingCeilingMbps': 20,
      });
      expect(denied.ok, isFalse);
      expect(denied.message, 'Only the owner can change this');
      expect(other.controller.settingInt('streamingCeilingMbps'), 60);
    });

    test('a refused value names the field and the reason', () async {
      final owner = await pair();
      final r = await owner.controller.updateSettings({'imageSeconds': 500});
      expect(r.ok, isFalse);
      expect(r.field, 'imageSeconds');
      expect(r.message, contains('between 3 and 120'));
      expect(owner.controller.settingInt('imageSeconds'), 10);
      expect(owner.controller.limitFor('imageSeconds'), {'min': 3, 'max': 120});
    });

    test('rename: trimmed, saved, shown to others; empty and too long are '
        'refused before the Pi', () async {
      final a = await pair();
      final b = await pair();
      expect(
        (await a.controller.renameThisPhone('   ')).message,
        'Enter a name',
      );
      final long = await a.controller.renameThisPhone('x' * 41);
      expect(long.ok, isFalse);
      expect(long.message, contains('40'));
      final ok = await a.controller.renameThisPhone('  Kay Pixel  ');
      expect(ok.ok, isTrue);
      await until(() => b.controller.devices.any((d) => d.name == 'Kay Pixel'));
      await until(() => a.controller.me!.name == 'Kay Pixel');
    });

    test('the owner removes a controller phone; a controller cannot', () async {
      final owner = await pair();
      final other = await pair();
      final otherId = other.controller.me!.id;
      final denied = await other.controller.forgetDevice(
        owner.controller.me!.id,
      );
      expect(denied.ok, isFalse);
      final ok = await owner.controller.forgetDevice(otherId);
      expect(ok.ok, isTrue);
      await until(() => !owner.controller.devices.any((d) => d.id == otherId));
    });

    test(
      'a phone the owner removes ends on Connect with a plain message',
      () async {
        final owner = await pair();
        final other = await pair();
        final r = await owner.controller.forgetDevice(other.controller.me!.id);
        expect(r.ok, isTrue);
        await other.waitFor(PhoneScreen.connect);
        await until(() => !other.controller.hasPairing);
        expect(
          other.controller.statusText,
          'This phone was removed from the Pi',
        );
        expect(other.controller.hasSettings, isFalse);
        expect(other.controller.hasLibrary, isFalse);
        expect(owner.controller.screen, PhoneScreen.home);
      },
    );

    test(
      'Forget all phones sends every phone, the owner included, to Connect',
      () async {
        final owner = await pair();
        final other = await pair();
        final r = await owner.controller.forgetAllPhones();
        expect(r.ok, isTrue);
        for (final p in [owner, other]) {
          await p.waitFor(PhoneScreen.connect);
          await until(() => !p.controller.hasPairing);
          expect(p.controller.statusText, 'This phone was removed from the Pi');
        }
      },
    );

    test('Close app twice closes once; when the app returns it connects '
        'again and takes the lock', () async {
      var pops = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'SystemNavigator.pop') pops++;
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null),
      );
      final p = await pair();
      await Future.wait([p.controller.closeApp(), p.controller.closeApp()]);
      expect(pops, 1);
      expect(p.client.state.value.phase, isNot(HubConnectionPhase.connected));
      final before = p.lock.acquired;
      p.controller.setForeground(false);
      p.controller.setForeground(true);
      await until(
        () => p.client.state.value.phase == HubConnectionPhase.connected,
      );
      expect(p.lock.acquired, greaterThan(before));
      await until(() => p.lock.held == 0);
    });

    test(
      'Close app releases the lock, disconnects and leaves the app',
      () async {
        final calls = <String>[];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, (call) async {
              calls.add(call.method);
              return null;
            });
        addTearDown(
          () => TestDefaultBinaryMessengerBinding
              .instance
              .defaultBinaryMessenger
              .setMockMethodCallHandler(SystemChannels.platform, null),
        );
        final p = await pair();
        p.controller.setScanning(true);
        expect(p.lock.held, 1);
        await p.controller.closeApp();
        expect(p.lock.held, 0);
        expect(p.client.state.value.phase, isNot(HubConnectionPhase.connected));
        expect(calls, contains('SystemNavigator.pop'));
        // The pairing is kept: the next launch connects by itself.
        expect(await p.store.getLastPairing(), isNotNull);
      },
    );
  });

  group('screens', () {
    late Rig rig;
    late PhoneRig phone;
    PhoneRig? second;

    setUp(() => phone = PhoneRig());

    Future<void> pump(WidgetTester tester, {PhoneRig? who}) async {
      final target = who ?? phone;
      await tester.pumpWidget(
        PhoneApp(
          controller: target.controller,
          versionLoader: () async => '1.2.3 (4)',
        ),
      );
      await tester.pump();
    }

    Future<void> connect(WidgetTester tester, PhoneRig p) async {
      await tester.runAsync(() async {
        await p.controller.start();
        await p.controller.pairFromQr(rig.openQr());
        await p.waitFor(PhoneScreen.home);
        await until(() => p.controller.hasSettings);
        rig.server.closePairingSession();
      });
    }

    Future<void> open(WidgetTester tester, String nav) async {
      await tester.tap(find.byTooltip('Open navigation menu'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(Key(nav)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key(nav)));
      await tester.pumpAndSettle();
    }

    Future<void> finish(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        await phone.dispose();
        await second?.dispose();
        await rig.dispose();
      });
      second = null;
    }

    /// A tall screen: the whole Settings page is built at once.
    void tall(WidgetTester tester) {
      tester.view
        ..physicalSize = const Size(400, 3200)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
    }

    Future<void> setUpRig(WidgetTester tester) async {
      rig = (await tester.runAsync(() => Rig.start(withSettings: true)))!;
    }

    testWidgets('the drawer shows the Pi, its status, the role, the screens '
        'and Close app', (tester) async {
      await setUpRig(tester);
      await connect(tester, phone);
      await pump(tester);
      await tester.tap(find.byTooltip('Open navigation menu'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('drawer-pi-name')), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const Key('drawer-pi-name'))).data,
        'Test Pi',
      );
      expect(
        tester.widget<Text>(find.byKey(const Key('drawer-status'))).data,
        'Connected',
      );
      expect(find.text('This phone: Owner'), findsOneWidget);
      for (final label in ['Now playing', 'Devices', 'Settings', 'About']) {
        expect(find.text(label), findsWidgets);
      }
      expect(find.byKey(const Key('drawer-close')), findsOneWidget);
      expect(find.text('Close app'), findsOneWidget);
      await tester.tap(find.byKey(const Key('nav-about')));
      await tester.pumpAndSettle();
      expect(find.text('1.2.3 (4)'), findsOneWidget);
      expect(find.text('Test Pi'), findsWidgets);
      await finish(tester);
    });

    testWidgets('Close app in the drawer closes the app', (tester) async {
      final calls = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          calls.add(call.method);
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await setUpRig(tester);
      await connect(tester, phone);
      await pump(tester);
      await tester.tap(find.byTooltip('Open navigation menu'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('drawer-close')));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)),
      );
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();
      expect(calls, contains('SystemNavigator.pop'));
      expect(phone.lock.held, 0);
      await finish(tester);
    });

    testWidgets('Settings: panes with units, owner edits a number and it is '
        'saved on the Pi', (tester) async {
      tall(tester);
      await setUpRig(tester);
      await connect(tester, phone);
      await pump(tester);
      await open(tester, 'nav-settings');
      for (final title in [
        'Playback',
        'Library and storage',
        'Network and streaming',
      ]) {
        expect(find.text(title), findsOneWidget);
      }
      expect(find.byKey(const Key('owner-note')), findsNothing);
      expect(find.text('10 seconds'), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('setting-streamingCeilingMbps')),
        '60',
      );
      var saves = 0;
      final sub = rig.settings!.changes.listen((_) => saves++);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.runAsync(
        () => until(() => rig.settings!.values['streamingCeilingMbps'] == 60),
      );
      await tester.pumpAndSettle();
      // Done and the focus loss that follows save once.
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      unawaited(sub.cancel());
      expect(saves, 1);
      expect(find.text('Saved'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('a value out of range goes back with the reason beside the '
        'field', (tester) async {
      tall(tester);
      await setUpRig(tester);
      await connect(tester, phone);
      await pump(tester);
      await open(tester, 'nav-settings');
      await tester.enterText(
        find.byKey(const Key('setting-streamingCeilingMbps')),
        '9999',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(find.textContaining('Between 5 and 500 Mbps'), findsWidgets);
      expect(
        tester
            .widget<TextField>(
              find.descendant(
                of: find.byKey(const Key('setting-streamingCeilingMbps')),
                matching: find.byType(TextField),
              ),
            )
            .controller!
            .text,
        '80',
      );
      expect(rig.settings!.values['streamingCeilingMbps'], 80);
      await finish(tester);
    });

    testWidgets('a controller sees every value with the controls disabled '
        'and the owner note', (tester) async {
      tall(tester);
      await setUpRig(tester);
      final owner = PhoneRig();
      second = owner; // disposed in finish()
      await connect(tester, owner);
      await connect(tester, phone);
      expect(phone.controller.me!.role, DeviceRole.controller);
      await pump(tester);
      await open(tester, 'nav-settings');
      // One note at the top of each pane that has controls.
      expect(find.byKey(const Key('owner-note')), findsNWidgets(4));
      expect(find.text('Only the owner can change this'), findsNWidgets(4));
      expect(
        tester
            .widget<Slider>(find.byKey(const Key('imageSeconds-slider')))
            .onChanged,
        isNull,
      );
      expect(
        tester
            .widget<TextField>(
              find.descendant(
                of: find.byKey(const Key('setting-streamingCeilingMbps')),
                matching: find.byType(TextField),
              ),
            )
            .enabled,
        isFalse,
      );
      expect(
        tester
            .widget<OutlinedButton>(find.byKey(const Key('forget-all')))
            .onPressed,
        isNull,
      );
      await finish(tester);
    });

    testWidgets('rename from Settings: field error under the name, then '
        'saved', (tester) async {
      tall(tester);
      await setUpRig(tester);
      await connect(tester, phone);
      await pump(tester);
      await open(tester, 'nav-settings');
      await tester.tap(find.byKey(const Key('rename-this-phone')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('rename-field')), '   ');
      await tester.tap(find.byKey(const Key('rename-save')));
      await tester.pumpAndSettle();
      expect(find.text('Enter a name'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('rename-field')),
        'Kay Pixel',
      );
      await tester.tap(find.byKey(const Key('rename-save')));
      await tester.runAsync(
        () => until(
          () => phone.controller.devices.any((d) => d.name == 'Kay Pixel'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('rename-field')), findsNothing);
      expect(find.text('Kay Pixel'), findsWidgets);
      await finish(tester);
    });

    testWidgets('a dropped link keeps the app, with a Reconnecting banner '
        'and read-only settings', (tester) async {
      await setUpRig(tester);
      await connect(tester, phone);
      await pump(tester);
      expect(find.byKey(const Key('banner-reconnecting')), findsNothing);
      await open(tester, 'nav-settings');

      final state = phone.client.state.value;
      phone.client.state.value = state.copyWith(
        phase: HubConnectionPhase.reconnecting,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const Key('banner-reconnecting')), findsOneWidget);
      expect(find.text('Reconnecting…'), findsOneWidget);
      expect(phone.controller.screen, PhoneScreen.home);
      expect(find.byKey(const Key('owner-note')), findsOneWidget);
      expect(find.text('Read only for now'), findsOneWidget);
      // The last values are still there.
      expect(find.text('10 seconds'), findsOneWidget);

      phone.client.state.value = state.copyWith(
        phase: HubConnectionPhase.offline,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const Key('banner-offline')), findsOneWidget);
      expect(find.byKey(const Key('banner-retry')), findsOneWidget);

      phone.client.state.value = state.copyWith(
        phase: HubConnectionPhase.appNotOpen,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const Key('banner-server')), findsOneWidget);
      expect(
        find.text('The TV Saver server is not running on the Pi'),
        findsOneWidget,
      );

      phone.client.state.value = state;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const Key('banner-offline')), findsNothing);
      await finish(tester);
    });

    testWidgets('Storage pane follows the Pi: snapshot, events and a lowered '
        'cap', (tester) async {
      tall(tester);
      rig = (await tester.runAsync(
        () => Rig.start(withSettings: true, withLibrary: true),
      ))!;
      await tester.runAsync(() async {
        final now = DateTime.now().millisecondsSinceEpoch;
        for (final (id, bytes) in [('a.mp4', 5000), ('b.mp4', 3000)]) {
          await rig.db.insertLibraryItem(
            LibraryItemsCompanion.insert(
              id: id,
              kind: 'video',
              name: id,
              sha256: id.padRight(64, '0'),
              bytes: bytes,
              createdAt: now,
            ),
          );
        }
      });
      await connect(tester, phone);
      await tester.runAsync(() => until(() => phone.controller.hasLibrary));
      await pump(tester);
      await open(tester, 'nav-settings');
      String text() =>
          tester.widget<Text>(find.byKey(const Key('storage-text'))).data!;
      expect(text(), '8 KB of 10 KB used');
      expect(find.byKey(const Key('storage-over')), findsNothing);

      // An event carries the Pi's new figure (no bytes are added up here).
      await tester.runAsync(() async {
        await rig.library!.deleteItem('b.mp4');
        await until(() => phone.controller.storageUsedBytes == 5000);
      });
      await tester.pump();
      expect(text(), '5 KB of 10 KB used');

      // A lowered cap arrives as a storage event: over the limit.
      await tester.runAsync(() async {
        await phone.controller.updateSettings({'storageCapBytes': 4000});
        await until(() => phone.controller.storageCapBytes == 4000);
      });
      await tester.pump();
      expect(text(), '5 KB of 4 KB used');
      expect(find.byKey(const Key('storage-over')), findsOneWidget);
      expect(find.textContaining('Over the limit'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('Storage pane says Loading while the Pi has sent no figure', (
      tester,
    ) async {
      tall(tester);
      await setUpRig(tester); // no library module
      await connect(tester, phone);
      await pump(tester);
      await open(tester, 'nav-settings');
      expect(find.byKey(const Key('storage-text')), findsNothing);
      expect(find.text('Loading…'), findsOneWidget);
      expect(find.textContaining('0 KB'), findsNothing);
      await finish(tester);
    });

    testWidgets('Devices: large rows; the owner removes a phone after a '
        'confirm', (tester) async {
      await setUpRig(tester);
      final other = PhoneRig();
      second = other;
      await connect(tester, phone);
      await connect(tester, other);
      await tester.runAsync(
        () => until(() => phone.controller.devices.length == 2),
      );
      await pump(tester);
      await open(tester, 'nav-devices');
      final otherId = other.controller.me!.id;
      expect(find.byKey(Key('remove-$otherId')), findsOneWidget);
      await tester.tap(find.byKey(Key('remove-$otherId')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Remove '), findsWidgets);
      await tester.tap(find.byKey(const Key('forget-device-confirm')));
      await tester.runAsync(
        () => until(() => phone.controller.devices.length == 1),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(Key('remove-$otherId')), findsNothing);
      await finish(tester);
    });

    testWidgets('the layout holds at 360 dp and 200 % text', (tester) async {
      tester.view
        ..physicalSize = const Size(360 * 3, 740 * 3)
        ..devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await setUpRig(tester);
      await connect(tester, phone);
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(
            size: Size(360, 740),
            textScaler: TextScaler.linear(2),
          ),
          child: PhoneApp(
            controller: phone.controller,
            versionLoader: () async => '1.0.0 (1)',
          ),
        ),
      );
      await tester.pump();
      for (final nav in [
        'nav-now-playing',
        'nav-devices',
        'nav-settings',
        'nav-about',
      ]) {
        await open(tester, nav);
        expect(tester.takeException(), isNull, reason: nav);
      }
      await finish(tester);
    });
  });
}
