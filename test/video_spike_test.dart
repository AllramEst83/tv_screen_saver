import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tv_saver/main_tv.dart';
import 'package:tv_saver/tv/video_spike/spike_log.dart';
import 'package:tv_saver/tv/video_spike/spike_native.dart';
import 'package:tv_saver/tv/video_spike/spike_player.dart';
import 'package:tv_saver/tv/video_spike/spike_screen.dart';
import 'package:video_player/video_player.dart';

class _FakeNative implements SpikeNative {
  @override
  Future<String?> spikeDir() async => '/files/spike';
  @override
  Future<List<String>> decoders() async => [];
  @override
  Future<DisplayModeInfo?> displayInfo() async => null;
  @override
  Future<ClipProbe?> probe(String path) async => null;
  final opens = <String>[];
  @override
  Future<void> media3Open(String path, String loop) async => opens.add(loop);
  @override
  Future<Media3Stats?> media3Stats() async => null;
  @override
  Future<void> media3Release() async {}
}

Widget _screen(List<String> clips, [_FakeNative? native]) => MaterialApp(
  home: Scaffold(
    body: SpikeScreen(
      native: native ?? _FakeNative(),
      lister: (_) async => clips,
      log: (_) {},
    ),
  ),
);

const _mode60 = DisplayModeInfo(
  modeId: 1,
  width: 3840,
  height: 2160,
  refreshRate: 60,
);

void main() {
  _playerTests();
  _parserTests();
  testWidgets('no clips: says how to push them', (tester) async {
    await tester.pumpWidget(_screen([]));
    await tester.pump();

    expect(find.text('No clips on the TV yet.'), findsOneWidget);
    expect(find.text(pushHint), findsOneWidget);
    expect(find.text('into /files/spike'), findsOneWidget);
  });

  testWidgets('clips are listed under the two setting rows', (tester) async {
    await tester.pumpWidget(
      _screen(['/files/spike/1-sdr-lines.mp4', '/files/spike/4-pan.mp4']),
    );
    await tester.pump();

    expect(find.text('1-sdr-lines.mp4'), findsOneWidget);
    expect(find.text('4-pan.mp4'), findsOneWidget);
    expect(find.text('View: platform-view'), findsOneWidget);
    expect(find.text('Loop: repeat-one'), findsOneWidget);
    expect(find.textContaining('No clips'), findsNothing);
  });

  testWidgets('OK on the first row cycles the view, second the loop', (
    tester,
  ) async {
    await tester.pumpWidget(_screen(['/files/spike/1.mp4']));
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    expect(find.text('View: media3-surface'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    expect(find.text('View: texture'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    expect(find.text('View: platform-view'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    expect(find.text('Loop: two-item-playlist'), findsOneWidget);
    expect(
      find.textContaining('playlist loop uses media3-surface'),
      findsOneWidget,
    );
  });

  testWidgets('the TV app opens Pi stream with OK and spike with Right', (
    tester,
  ) async {
    await tester.pumpWidget(const TvSaverApp(version: '1'));
    expect(find.text('OK: Pi stream   Right: video spike'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();

    expect(find.text('Video spike'), findsOneWidget);
  });

  group('VideoSpike log line', () {
    test(
      'names clip, mode, decoder, HDR, display modes and dropped frames',
      () {
        final line = videoSpikeLogLine(
          clip: '2-hdr10-lines.mp4',
          view: SpikeView.media3,
          loop: SpikeLoop.repeatOne,
          phase: 'playing',
          decoder: 'OMX.MS.HEVC.Decoder',
          hdr: 'HDR10',
          displayBefore: _mode60,
          displayNow: _mode60,
          droppedFrames: 3,
        );
        expect(
          line,
          'VideoSpike: clip=2-hdr10-lines.mp4, mode=media3-surface, '
          'loop=repeat-one, phase=playing, decoder=OMX.MS.HEVC.Decoder, '
          'hdr=HDR10, display_before=3840x2160@60.000, '
          'display_now=3840x2160@60.000, dropped=3',
        );
      },
    );

    test('unknowns are spelled out; video_player has no dropped count', () {
      final line = videoSpikeLogLine(
        clip: 'a.mp4',
        view: SpikeView.texture,
        loop: SpikeLoop.repeatOne,
        phase: 'stopped',
      );
      expect(line, startsWith('VideoSpike: clip=a.mp4, mode=texture,'));
      expect(line, contains('decoder=unknown'));
      expect(line, contains('display_now=unknown'));
      expect(line, endsWith('dropped=n/a'));
    });

    test(
      '24p verdict: only for 24 fps clips, from the active refresh rate',
      () {
        const mode24 = DisplayModeInfo(
          modeId: 2,
          width: 3840,
          height: 2160,
          refreshRate: 23.976,
        );
        expect(refreshVerdict(23.976, _mode60), 'only 60 Hz mode');
        expect(refreshVerdict(23.976, mode24), '24p possible');
        expect(refreshVerdict(30, _mode60), isNull);
        expect(refreshVerdict(null, _mode60), isNull);
        expect(
          videoSpikeLogLine(
            clip: '4.mp4',
            view: SpikeView.media3,
            loop: SpikeLoop.repeatOne,
            phase: 'playing',
            displayNow: _mode60,
            clipFps: 23.976,
          ),
          endsWith('result=only 60 Hz mode'),
        );
      },
    );

    test('decoder lines are logged at startup, or "unavailable"', () async {
      final logs = <String>[];
      await logVideoDecoders(_WithDecoders(), logs.add);
      expect(logs, [
        'VideoSpike: decoder c2.test.hevc video/hevc hw=true '
            'profiles=[Main,Main10]',
      ]);
      logs.clear();
      await logVideoDecoders(_FakeNative(), logs.add);
      expect(logs, ['VideoSpike: decoders unavailable']);
    });
  });
}

class _WithDecoders extends _FakeNative {
  @override
  Future<List<String>> decoders() async => [
    'c2.test.hevc video/hevc hw=true profiles=[Main,Main10]',
  ];
}

/// A controller that never touches the platform: [initialize] hangs or throws.
class _FakeController extends VideoPlayerController {
  _FakeController(String path, VideoViewType viewType, this.failWith)
    : super.file(File(path), viewType: viewType);

  final Object? failWith;

  @override
  Future<void> initialize() {
    final e = failWith;
    return e == null ? Completer<void>().future : Future.error(e);
  }

  @override
  // ignore: must_call_super
  Future<void> dispose() async {}
}

typedef _Pumped = ({
  List<String> logs,
  List<VideoViewType> types,
  _FakeNative native,
});

void _playerTests() {
  Future<_Pumped> pumpPlayer(
    WidgetTester tester, {
    required SpikeView view,
    SpikeLoop loop = SpikeLoop.repeatOne,
    Object? failWith,
    VoidCallback? onExit,
  }) async {
    final logs = <String>[];
    final types = <VideoViewType>[];
    final native = _FakeNative();
    await tester.pumpWidget(
      MaterialApp(
        home: SpikePlayer(
          path: '/files/spike/1-sdr-lines.mp4',
          view: view,
          loop: loop,
          native: native,
          log: logs.add,
          onExit: onExit ?? () {},
          controllerFactory: (path, type) {
            types.add(type);
            return _FakeController(path, type, failWith);
          },
          media3View: (onCreated) {
            Future.microtask(() => onCreated(0));
            return const SizedBox();
          },
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    return (logs: logs, types: types, native: native);
  }

  // Unmount so the player's timers are cancelled.
  Future<void> unmount(WidgetTester tester) =>
      tester.pumpWidget(const SizedBox());

  testWidgets('platform-view row asks video_player for a platform view', (
    tester,
  ) async {
    final r = await pumpPlayer(tester, view: SpikeView.platformView);
    expect(r.types, [VideoViewType.platformView]);
    await unmount(tester);
  });

  testWidgets('texture row asks video_player for a texture', (tester) async {
    final r = await pumpPlayer(tester, view: SpikeView.texture);
    expect(r.types, [VideoViewType.textureView]);
    await unmount(tester);
  });

  testWidgets('media3 view opens repeat-one with the repeat-one argument', (
    tester,
  ) async {
    final r = await pumpPlayer(tester, view: SpikeView.media3);
    expect(r.types, isEmpty);
    expect(r.native.opens, ['repeatOne']);
    await unmount(tester);
  });

  testWidgets('media3 view with the playlist loop opens the playlist', (
    tester,
  ) async {
    final r = await pumpPlayer(
      tester,
      view: SpikeView.media3,
      loop: SpikeLoop.playlist,
    );
    expect(r.native.opens, ['playlist']);
    await unmount(tester);
  });

  testWidgets('playlist loop on the texture row builds no video_player', (
    tester,
  ) async {
    final types = <VideoViewType>[];
    final native = _FakeNative();
    await tester.pumpWidget(
      MaterialApp(
        home: SpikeScreen(
          native: native,
          lister: (_) async => ['/files/spike/5-loop-audio.mp4'],
          log: (_) {},
          controllerFactory: (path, type) {
            types.add(type);
            return _FakeController(path, type, null);
          },
          media3View: (onCreated) {
            Future.microtask(() => onCreated(0));
            return const SizedBox();
          },
        ),
      ),
    );
    await tester.pump();
    // View row: platform-view -> media3 -> texture; then loop -> playlist.
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    expect(find.textContaining('View: texture'), findsOneWidget);
    expect(find.text('Loop: two-item-playlist'), findsOneWidget);
    // Play the clip: the effective view is Media3, so no controller is made.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    expect(find.byType(SpikePlayer), findsOneWidget);
    expect(types, isEmpty);
    await tester.pump();
    expect(native.opens, ['playlist']);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('initialize throwing shows "cannot play" and logs failed', (
    tester,
  ) async {
    final r = await pumpPlayer(
      tester,
      view: SpikeView.platformView,
      failWith: Exception('no HEVC decoder'),
    );
    expect(find.text('cannot play: no HEVC decoder'), findsOneWidget);
    expect(r.logs, hasLength(1));
    expect(r.logs.single, contains('phase=failed'));
    expect(r.logs.single, contains('cannot play: no HEVC decoder'));
    await unmount(tester);
  });

  testWidgets('Back logs phase=stopped once, then calls onExit', (
    tester,
  ) async {
    var exits = 0;
    final r = await pumpPlayer(
      tester,
      view: SpikeView.platformView,
      onExit: () => exits++,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.pump();
    expect(r.logs.where((l) => l.contains('phase=stopped')), hasLength(1));
    expect(exits, 1);
    await unmount(tester);
  });
}

void _parserTests() {
  test('DisplayModeInfo.fromMap: valid, null and malformed', () {
    final m = DisplayModeInfo.fromMap({
      'modeId': 1,
      'width': 3840,
      'height': 2160,
      'refreshRate': 60.0,
      'supportedModes': ['1:3840x2160@60.000'],
      'hdrTypes': [1, 2, 3],
    })!;
    expect(m.label, '3840x2160@60.000');
    expect(m.hdrTypes, [1, 2, 3]);
    expect(m.supportedModes, hasLength(1));
    expect(DisplayModeInfo.fromMap(null), isNull);
    expect(DisplayModeInfo.fromMap({'error': 'no display'}), isNull);
  });

  test('ClipProbe.fromMap: valid, error and null', () {
    final p = ClipProbe.fromMap({
      'mime': 'video/hevc',
      'hdr': 'HDR10',
      'decoder': 'c2.x',
      'frameRate': 23.976,
      'audio': 'audio/mp4a-latm',
    })!;
    expect(p.hdr, 'HDR10');
    expect(p.frameRate, 23.976);
    expect(ClipProbe.fromMap({})!.hdr, 'SDR');
    expect(ClipProbe.fromMap({'error': 'no video track'}), isNull);
    expect(ClipProbe.fromMap(null), isNull);
  });

  test('Media3Stats.fromMap: valid and null', () {
    final s = Media3Stats.fromMap({
      'decoder': 'c2.x',
      'hdr': 'HLG',
      'droppedFrames': 2,
      'frameRate': 24,
      'positionMs': 1500,
      'item': 1,
      'error': null,
    })!;
    expect(s.droppedFrames, 2);
    expect(s.frameRate, 24.0);
    expect(s.position, const Duration(milliseconds: 1500));
    expect(s.error, isNull);
    expect(Media3Stats.fromMap(null), isNull);
    expect(Media3Stats.fromMap({})!.position, Duration.zero);
  });

  test('listClipFiles: only .mp4, sorted; missing dir is empty', () async {
    final dir = Directory.systemTemp.createTempSync('spike_test');
    addTearDown(() => dir.deleteSync(recursive: true));
    for (final n in ['b.mp4', 'a.MP4', 'notes.txt', 'c.mkv']) {
      File('${dir.path}/$n').writeAsStringSync('x');
    }
    Directory('${dir.path}/sub.mp4').createSync();
    final names = (await listClipFiles(dir.path))
        .map((p) => p.split(RegExp(r'[\\/]')).last)
        .toList();
    expect(names, ['a.MP4', 'b.mp4']);
    expect(await listClipFiles('${dir.path}/missing'), isEmpty);
  });
}
