import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hub_core/hub_core.dart';
import 'package:tv_saver/tv/display/display_client.dart';
import 'package:tv_saver/tv/display/display_screen.dart';
import 'package:tv_saver/tv/display/pairing_view.dart';
import 'package:tv_saver/tv/menu_screen.dart';

import 'support.dart';

/// A [DisplayClient] that never touches a socket and records the remote.
class RecordingDisplayClient extends DisplayClient {
  RecordingDisplayClient(FakeDisplayNative native)
    : super(
        client: HubClient(
          tokenStore: MemoryHubTokenStore(),
          clientName: 'TV',
          kind: 'display',
        ),
        store: MemoryHubTokenStore(),
        native: native,
      );

  final List<String> log = [];
  bool pairingWanted = false;
  PairingInfo? pairingInfo;

  @override
  Future<void> start() async {}

  @override
  bool get needsPairing => pairingWanted;

  @override
  PairingInfo? get pairing => pairingWanted ? pairingInfo : null;

  @override
  Future<void> togglePause() async => log.add('toggle');

  @override
  Future<void> next() async => log.add('next');

  @override
  Future<void> prev() async => log.add('prev');

  @override
  Future<void> seekBy(int deltaMs) async => log.add('seek:$deltaMs');

  @override
  Future<void> forgetAllPhones() async => log.add('forgetAll');

  @override
  void pairAnotherPhone() => log.add('pairAnother');

  @override
  void stopPairing() => log.add('stopPairing');

  void changed() => notifyListeners();
}

void main() {
  late FakeDisplayNative native;
  late RecordingDisplayClient client;

  setUp(() {
    native = FakeDisplayNative();
    client = RecordingDisplayClient(native);
  });

  Widget video(void Function(int) onCreated) {
    WidgetsBinding.instance.addPostFrameCallback((_) => onCreated(1));
    return const SizedBox(key: Key('fake-video'), width: 10, height: 10);
  }

  Future<void> pumpScreen(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: DisplayScreen(
          client: client,
          media3View: video,
          menuBuilder: (ctx, onPairPhone) => Scaffold(
            body: TvMenuScreen(version: '1', onPairPhone: onPairPhone),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('idle: says what to do and shows the picture surface', (
    tester,
  ) async {
    await pumpScreen(tester);
    expect(find.byKey(const Key('fake-video')), findsOneWidget);
    expect(find.byKey(const Key('display-status')), findsOneWidget);
    expect(find.byType(PairingView), findsNothing);
  });

  testWidgets('the remote: OK, Left, Right, fast-forward and rewind', (
    tester,
  ) async {
    await pumpScreen(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.mediaFastForward);
    await tester.sendKeyEvent(LogicalKeyboardKey.mediaRewind);
    expect(client.log, ['toggle', 'next', 'prev', 'seek:30000', 'seek:-30000']);
  });

  testWidgets('holding Back for 10 s sends forgetAll once; a tap does not', (
    tester,
  ) async {
    await pumpScreen(tester);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(seconds: 9));
    expect(client.log, isNot(contains('forgetAll')));
    await tester.pump(const Duration(seconds: 2));
    expect(client.log.where((e) => e == 'forgetAll'), hasLength(1));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.escape);
    // The release after a long hold is not also a "close pairing" tap.
    expect(client.log, ['forgetAll']);

    client.log.clear();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(seconds: 1));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(seconds: 15));
    expect(client.log, ['stopPairing']);
  });

  testWidgets('the pairing screen shows the QR and PIN and takes no remote', (
    tester,
  ) async {
    client
      ..pairingWanted = true
      ..pairingInfo = PairingInfo(
        qr: 'tvsaver://pair?v=2&h=192.168.1.5&p=8772&id=abc&c=xyz',
        pin: '4821',
        expiresAt: DateTime(2030),
      );
    await pumpScreen(tester);
    expect(find.byKey(const Key('pairing-qr')), findsOneWidget);
    expect(find.text('4821'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    expect(client.log, isEmpty);

    // Until the Pi sends a code, the screen says it is waiting.
    client.pairingInfo = null;
    client.changed();
    await tester.pump();
    expect(find.byKey(const Key('pairing-qr')), findsNothing);
    expect(find.byKey(const Key('pairing-status')), findsOneWidget);
  });

  testWidgets('Menu releases the picture, opens the menu and restores it', (
    tester,
  ) async {
    await pumpScreen(tester);
    expect(find.byKey(const Key('fake-video')), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
    await tester.pumpAndSettle();
    expect(find.byType(TvMenuScreen), findsOneWidget);
    expect(find.byKey(const Key('fake-video')), findsNothing);
    expect(native.calls, contains('release'));
    expect(find.text('OK: Pi stream   Right: video spike'), findsOneWidget);
    expect(find.textContaining('Left: pair another phone'), findsOneWidget);

    // Left asks for a pairing code for another phone and closes the menu.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(client.log, contains('pairAnother'));
    expect(find.byType(TvMenuScreen), findsNothing);
    expect(find.byKey(const Key('fake-video')), findsOneWidget);
  });

  testWidgets('Back leaves the menu for the picture', (tester) async {
    await pumpScreen(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
    await tester.pumpAndSettle();
    expect(find.byType(TvMenuScreen), findsOneWidget);
    final nav = tester.state<NavigatorState>(find.byType(Navigator));
    nav.pop();
    await tester.pumpAndSettle();
    expect(find.byType(TvMenuScreen), findsNothing);
    expect(find.byKey(const Key('fake-video')), findsOneWidget);
  });
}
