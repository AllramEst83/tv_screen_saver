import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hub_core/hub_core.dart';
import 'package:tv_saver/tv/display/awake_guard.dart';
import 'package:tv_saver/tv/display/display_client.dart';
import 'package:tv_saver/tv/display/display_player.dart';
import 'package:tv_saver/tv/display/display_screen.dart';
import 'package:tv_saver/tv/display/idle_view.dart';
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
  bool forgetOk = true;
  bool online = false;
  PairingInfo? pairingInfo;

  @override
  Future<void> start() async {}

  @override
  bool get connected => online;

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
  Future<bool> forgetAllPhones() async {
    log.add('forgetAll');
    return forgetOk;
  }

  @override
  void pairAnotherPhone() => log.add('pairAnother');

  @override
  void stopPairing() => log.add('stopPairing');

  void changed() => notifyListeners();
}

/// Counts what the screen asks of the wake lock.
class FakeAwake implements AwakeGuard {
  final List<String> calls = [];
  bool held = false;

  @override
  Future<void> hold() async {
    held = true;
    calls.add('hold');
  }

  @override
  Future<void> release() async {
    held = false;
    calls.add('release');
  }
}

void main() {
  late FakeDisplayNative native;
  late FakeAwake awake;
  late RecordingDisplayClient client;

  setUp(() {
    native = FakeDisplayNative();
    client = RecordingDisplayClient(native);
    awake = FakeAwake();
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
          awake: awake,
          infoFor: const Duration(seconds: 4),
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

  testWidgets('paired and idle: the clock screen, gone the moment a clip '
      'starts; the Menu key still works', (tester) async {
    await pumpScreen(tester);
    expect(find.byType(IdleView), findsOneWidget);
    expect(find.byKey(const Key('display-status')), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
    await tester.pumpAndSettle();
    expect(find.byType(TvMenuScreen), findsOneWidget);
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pumpAndSettle();

    await tester.runAsync(
      () => client.player.load(
        itemId: 'a.mp4',
        url: 'http://pi/a.mp4',
        headers: const {},
      ),
    );
    client.changed();
    await tester.pump();
    expect(find.byType(IdleView), findsNothing);
  });

  testWidgets('no phone paired: the pairing view, not the idle screen', (
    tester,
  ) async {
    client
      ..pairingWanted = true
      ..pairingInfo = null;
    await pumpScreen(tester);
    expect(find.byType(IdleView), findsNothing);
    expect(find.byType(PairingView), findsOneWidget);
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
    expect(
      tester.widget<QrCodeView>(find.byKey(const Key('pairing-qr'))).data,
      client.pairingInfo!.qr,
    );
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

  testWidgets('a held Back shows a countdown from 3 s and the result', (
    tester,
  ) async {
    await pumpScreen(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(seconds: 2));
    expect(find.byKey(const Key('back-countdown')), findsNothing);
    await tester.pump(const Duration(seconds: 2));
    expect(find.byKey(const Key('back-countdown')), findsOneWidget);
    expect(find.textContaining('6 s'), findsOneWidget);

    await tester.pump(const Duration(seconds: 7));
    expect(client.log, ['forgetAll']);
    expect(find.byKey(const Key('back-countdown')), findsNothing);
    expect(find.byKey(const Key('display-notice')), findsOneWidget);
    expect(find.textContaining('forgotten'), findsOneWidget);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(seconds: 6)); // the notice goes
    expect(find.byKey(const Key('display-notice')), findsNothing);
  });

  testWidgets('a failed forgetAll says so', (tester) async {
    client.forgetOk = false;
    await pumpScreen(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(seconds: 11));
    expect(find.textContaining('Could not forget'), findsOneWidget);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(seconds: 6));
  });

  testWidgets('opening the menu drops a Back press in progress', (
    tester,
  ) async {
    await pumpScreen(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(seconds: 1));
    // Two Menu presses in a row open one menu.
    await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
    await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
    await tester.pumpAndSettle();
    expect(find.byType(TvMenuScreen), findsOneWidget);
    // The hold never completes behind the menu.
    await tester.pump(const Duration(seconds: 15));
    expect(client.log, isNot(contains('forgetAll')));
    expect(native.calls.where((c) => c == 'release'), hasLength(1));
  });

  Future<void> playClip(WidgetTester tester, {bool image = false}) async {
    await tester.runAsync(
      () => client.player.load(
        itemId: 'a.mp4',
        url: 'http://pi/a.mp4',
        headers: const {},
        info: ItemInfo(name: 'Fireplace', index: 1, count: 4, isImage: image),
      ),
    );
    client.changed();
    await tester.pump();
  }

  testWidgets('Info shows the overlay for a few seconds; Menu still opens '
      'the menu', (tester) async {
    await pumpScreen(tester);
    await playClip(tester);
    expect(find.byKey(const Key('info-overlay')), findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.info);
    await tester.pump();
    expect(find.byKey(const Key('info-overlay')), findsOneWidget);
    expect(find.text('Fireplace'), findsOneWidget);
    expect(find.text('2 of 4 · Video'), findsOneWidget);
    expect(find.byKey(const Key('info-time')), findsOneWidget);
    expect(find.byType(TvMenuScreen), findsNothing);

    await tester.pump(const Duration(seconds: 5));
    expect(find.byKey(const Key('info-overlay')), findsNothing);

    // Info again toggles it off by hand.
    await tester.sendKeyEvent(LogicalKeyboardKey.info);
    await tester.pump();
    expect(find.byKey(const Key('info-overlay')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.info);
    await tester.pump();
    expect(find.byKey(const Key('info-overlay')), findsNothing);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('the overlay is the only place that says the Pi is away', (
    tester,
  ) async {
    await pumpScreen(tester);
    await playClip(tester);
    expect(find.textContaining('not reachable'), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.info);
    await tester.pump();
    expect(find.byKey(const Key('info-offline')), findsOneWidget);
    client.online = true;
    client.changed();
    await tester.pump();
    expect(find.byKey(const Key('info-offline')), findsNothing);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('Info does nothing while nothing plays', (tester) async {
    await pumpScreen(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.info);
    await tester.pump();
    expect(find.byKey(const Key('info-overlay')), findsNothing);
  });

  testWidgets('the wake lock is held while playing and released otherwise', (
    tester,
  ) async {
    await pumpScreen(tester);
    expect(awake.held, isFalse);
    await playClip(tester);
    expect(awake.held, isTrue);
    await tester.runAsync(() => client.player.control('pause'));
    await tester.pump();
    expect(awake.held, isFalse);
    await tester.runAsync(() => client.player.control('resume'));
    await tester.pump();
    expect(awake.held, isTrue);
    await tester.runAsync(() => client.player.control('stop'));
    await tester.pump();
    expect(awake.held, isFalse);
    await tester.runAsync(() => client.player.control('resume'));
    await tester.pumpWidget(const SizedBox());
    expect(awake.held, isFalse); // leaving the screen lets go
  });

  testWidgets('coming back to the app re-applies full screen and the lock', (
    tester,
  ) async {
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
    await pumpScreen(tester);
    await playClip(tester);
    awake.calls.clear();
    calls.clear();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(calls, contains('SystemChrome.setEnabledSystemUIMode'));
    expect(awake.calls, contains('hold'));
  });
}
