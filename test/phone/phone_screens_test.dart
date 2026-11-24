import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hub_core/hub_core.dart';
import 'package:tv_saver/main_phone.dart';
import 'package:tv_saver/phone/phone_controller.dart';
import 'package:tv_saver/phone/screens/home_screen.dart';
import 'package:tv_saver/phone/screens/pin_screen.dart';
import 'package:tv_saver/phone/screens/scan_screen.dart';

import 'support.dart';

void main() {
  late PhoneRig phone;

  setUp(() => phone = PhoneRig());
  tearDown(() => phone.dispose());

  Future<void> pumpApp(
    WidgetTester tester, {
    QrScannerBuilder? scanner,
  }) async {
    await tester.pumpWidget(
      PhoneApp(controller: phone.controller, scannerBuilder: scanner),
    );
    await tester.pump();
    await tester.pump();
  }

  void setHub(WidgetTester tester, HubClientState s) {
    phone.client.state.value = s;
  }

  testWidgets('first launch: Connect with Scan QR and no Retry', (tester) async {
    await pumpApp(tester);
    expect(find.byKey(const Key('scan-qr')), findsOneWidget);
    expect(find.byKey(const Key('retry')), findsNothing);
    expect(find.textContaining('Scan the QR code'), findsOneWidget);
  });

  testWidgets('Connect shows a status line per phase', (tester) async {
    await pumpApp(tester);
    final cases = <HubConnectionPhase, String>{
      HubConnectionPhase.connecting: 'Connecting',
      HubConnectionPhase.reconnecting: 'Looking for',
      HubConnectionPhase.offline: 'TV not found',
      HubConnectionPhase.appNotOpen: "isn't open on the TV",
      HubConnectionPhase.wrongTv: 'different TV',
      HubConnectionPhase.needsTvUpdate: 'older than this app',
      HubConnectionPhase.replaced: 'connected from somewhere else',
    };
    for (final e in cases.entries) {
      setHub(tester, HubClientState(phase: e.key, hubName: 'Test Pi'));
      await tester.pump();
      expect(
        tester.widget<Text>(find.byKey(const Key('connect-status'))).data,
        contains(e.value),
        reason: '${e.key}',
      );
    }
  });

  testWidgets('offline with a saved pairing shows Retry', (tester) async {
    await phone.store.savePairing(
      const SavedHubPairing(
        hubId: 'h',
        token: 't',
        lastHost: '',
        lastPort: 1,
        hubName: 'Test Pi',
      ),
    );
    await tester.pumpWidget(PhoneApp(controller: phone.controller));
    await tester.pump();
    setHub(
      tester,
      const HubClientState(
        phase: HubConnectionPhase.offline,
        lastError: HubMessages.tvNotFound,
      ),
    );
    await tester.pump();
    expect(find.text('TV not found'), findsOneWidget);
    expect(find.byKey(const Key('retry')), findsOneWidget);
    // Stop the client's retry timer before the test ends.
    await tester.pumpWidget(const SizedBox());
    await phone.dispose();
  });

  testWidgets('scanning a non-TV-Saver QR keeps the scanner and says so', (
    tester,
  ) async {
    late ValueChanged<String> onCode;
    await pumpApp(
      tester,
      scanner: (context, code, problem) {
        onCode = code;
        return const ColoredBox(color: Colors.black);
      },
    );
    await tester.tap(find.byKey(const Key('scan-qr')));
    await tester.pumpAndSettle();
    expect(find.byType(ScanScreen), findsOneWidget);
    expect(phone.lock.held, 1, reason: 'multicast lock while scanning');

    onCode('https://example.com');
    await tester.pump();
    await tester.pump();
    expect(find.text("That isn't a TV Saver QR code."), findsOneWidget);
    expect(find.byType(ScanScreen), findsOneWidget);
    await tester.pump(const Duration(seconds: 3)); // Debounce timer.

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(phone.lock.held, 0);
  });

  testWidgets('camera permission denied: message and Open settings', (
    tester,
  ) async {
    await pumpApp(
      tester,
      scanner: (context, code, problem) {
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => problem(CameraProblem.denied),
        );
        return const ColoredBox(color: Colors.black);
      },
    );
    await tester.tap(find.byKey(const Key('scan-qr')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('camera-problem')), findsOneWidget);
    expect(find.textContaining('camera'), findsWidgets);
    expect(find.byKey(const Key('open-settings')), findsOneWidget);
  });

  testWidgets('PIN screen: wrong PIN message, then lockout countdown', (
    tester,
  ) async {
    await pumpApp(tester);
    setHub(
      tester,
      const HubClientState(phase: HubConnectionPhase.awaitingPin),
    );
    await tester.pump();
    expect(find.byType(PinScreen), findsOneWidget);

    setHub(
      tester,
      const HubClientState(
        phase: HubConnectionPhase.awaitingPin,
        lastError: HubMessages.wrongPin,
      ),
    );
    await tester.pump();
    expect(find.text(HubMessages.wrongPin), findsOneWidget);

    setHub(
      tester,
      HubClientState(
        phase: HubConnectionPhase.awaitingPin,
        pinRetryInMs: 3000,
        lastError: HubMessages.tooManyTries(3000),
      ),
    );
    await tester.pump();
    expect(find.text('Too many tries. Wait 3 s.'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byKey(const Key('pin-field'))).enabled,
      isFalse,
    );
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Too many tries. Wait 2 s.'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    expect(find.textContaining('Too many tries'), findsNothing);
    expect(
      tester.widget<TextField>(find.byKey(const Key('pin-field'))).enabled,
      isTrue,
    );
  });

  testWidgets('Home shows the Pi name and own role', (
    tester,
  ) async {
    await tester.pumpWidget(PhoneApp(controller: phone.controller));
    await tester.pump();
    setHub(
      tester,
      const HubClientState(
        phase: HubConnectionPhase.connected,
        hubName: 'Living room Pi',
        device: DeviceInfo(
          id: 'me',
          name: 'Kay phone',
          role: DeviceRole.owner,
          online: true,
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.text('Living room Pi'), findsOneWidget);
    expect(find.text('You: Owner'), findsOneWidget);
  });

  testWidgets('Home lists devices with online dots; Forget this Pi asks first', (
    tester,
  ) async {
    late Rig server;
    await tester.runAsync(() async {
      server = await Rig.start();
      await phone.controller.start();
      await phone.controller.pairFromQr(server.openQr());
      await phone.waitFor(PhoneScreen.home);
      await until(() => phone.controller.devices.isNotEmpty);
    });
    await tester.pumpWidget(PhoneApp(controller: phone.controller));
    await tester.pump();
    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.text('You: Owner'), findsOneWidget);
    expect(find.textContaining('(this phone)'), findsOneWidget);
    final me = phone.controller.me!;
    final dot = tester.widget<Icon>(find.byKey(Key('dot-${me.id}')));
    expect(dot.color, Colors.green);

    await tester.tap(find.byKey(const Key('forget-pi')));
    await tester.pumpAndSettle();
    expect(find.text('Forget this Pi?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('forget-confirm')));
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    // The socket's close handshake timer runs on the fake clock.
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('scan-qr')), findsOneWidget);
    await tester.runAsync(() async {
      expect(await phone.store.getLastPairing(), isNull);
      expect(await server.db.allDevices(), hasLength(1));
      await server.dispose();
    });
  });
}
