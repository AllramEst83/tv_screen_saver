import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tv_saver/phone/now_playing.dart';
import 'package:tv_saver/phone/phone_controller.dart';
import 'package:tv_saver/phone/screens/now_playing_card.dart';

import 'support.dart';

/// A controller whose player state is set by the test and whose commands are
/// recorded.
class PlayerController extends PhoneController {
  PlayerController(PhoneRig rig) : super(client: rig.client, store: rig.store);

  NowPlaying playing = const NowPlaying();
  bool notConnected = false;
  int position = 0;
  String? error;
  final List<String> log = [];

  void update() => notifyListeners();

  @override
  NowPlaying get nowPlaying => playing;

  @override
  bool get tvNotConnected => notConnected;

  @override
  int get positionMs => position;

  @override
  String? get playerError => error;

  @override
  Future<void> play() async => log.add('play');

  @override
  Future<void> next() async => log.add('next');

  @override
  Future<void> prev() async => log.add('prev');

  @override
  Future<void> togglePause() async => log.add('toggle');

  @override
  Future<void> seekBy(int deltaMs) async => log.add('seek:$deltaMs');

  @override
  Future<void> toggleMute() async => log.add('mute');
}

void main() {
  late PhoneRig rig;
  late PlayerController controller;

  setUp(() {
    rig = PhoneRig();
    controller = PlayerController(rig);
  });
  tearDown(() async {
    controller.dispose();
    await rig.dispose();
  });

  Future<void> pumpCard(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListenableBuilder(
            listenable: controller,
            builder: (_, _) => NowPlayingCard(controller: controller),
          ),
        ),
      ),
    );
  }

  testWidgets('idle: Play starts the playlist', (tester) async {
    await pumpCard(tester);
    expect(find.text('Nothing playing'), findsOneWidget);
    expect(find.byKey(const Key('player-toggle')), findsNothing);
    await tester.tap(find.byKey(const Key('player-play')));
    expect(controller.log, ['play']);
  });

  testWidgets('playing: shows the item and position, every control works', (
    tester,
  ) async {
    controller
      ..playing = const NowPlaying(
        playlistId: 'all',
        itemId: 'b.mp4',
        index: 1,
        state: 'playing',
        startedAt: 1,
      )
      ..position = 65000;
    await pumpCard(tester);
    expect(find.byKey(const Key('now-playing-title')), findsOneWidget);
    expect(find.text('b.mp4'), findsOneWidget);
    expect(find.textContaining('Playing · 1:05'), findsOneWidget);
    expect(find.byKey(const Key('player-play')), findsNothing);

    for (final key in [
      'player-back30',
      'player-prev',
      'player-toggle',
      'player-next',
      'player-fwd30',
      'player-mute',
    ]) {
      await tester.tap(find.byKey(Key(key)));
    }
    expect(controller.log, [
      'seek:-30000',
      'prev',
      'toggle',
      'next',
      'seek:30000',
      'mute',
    ]);
  });

  testWidgets('paused and muted are shown', (tester) async {
    controller
      ..playing = const NowPlaying(
        itemId: 'a.mp4',
        state: 'paused',
        positionMs: 3000,
        muted: true,
      )
      ..position = 3000;
    await pumpCard(tester);
    expect(find.textContaining('Paused · 0:03 · muted'), findsOneWidget);
    expect(find.byIcon(Icons.volume_off), findsOneWidget);
    expect(find.byTooltip('Resume'), findsOneWidget);
  });

  testWidgets('TV not connected and other errors are shown', (tester) async {
    controller
      ..notConnected = true
      ..error = 'Playlist is empty';
    await pumpCard(tester);
    expect(find.byKey(const Key('tv-not-connected')), findsOneWidget);
    expect(find.text('TV not connected'), findsOneWidget);
    expect(find.text('Playlist is empty'), findsOneWidget);

    controller
      ..notConnected = false
      ..error = null
      ..update();
    await tester.pump();
    expect(find.byKey(const Key('tv-not-connected')), findsNothing);
  });

  group('NowPlaying', () {
    test(
      'position runs from startedAt while playing and holds while paused',
      () {
        const playing = NowPlaying(
          itemId: 'a',
          state: 'playing',
          positionMs: 0,
          startedAt: 1000,
        );
        expect(playing.positionAt(6000), 5000);
        expect(playing.positionAt(500), 0); // never negative
        const paused = NowPlaying(
          itemId: 'a',
          state: 'paused',
          positionMs: 4000,
        );
        expect(paused.positionAt(99999), 4000);
        expect(const NowPlaying().isIdle, isTrue);
      },
    );

    test('parses the Pi payload and tolerates junk', () {
      final np = NowPlaying.tryParse({
        'playlistId': 'all',
        'index': 2,
        'itemId': 'c.mp4',
        'state': 'playing',
        'positionMs': 10,
        'startedAt': 99,
        'muted': true,
      })!;
      expect(np.itemId, 'c.mp4');
      expect(np.index, 2);
      expect(np.muted, isTrue);
      expect(NowPlaying.tryParse('nope'), isNull);
      expect(
        NowPlaying.tryParse(<String, Object?>{'state': 7})!.isIdle,
        isTrue,
      );
    });

    test('formatPosition', () {
      expect(formatPosition(0), '0:00');
      expect(formatPosition(65000), '1:05');
      expect(formatPosition(3723000), '1:02:03');
    });
  });
}
