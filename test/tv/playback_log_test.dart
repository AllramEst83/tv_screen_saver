import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tv_saver/tv/display/display_screen.dart';
import 'package:tv_saver/tv/display/playback_log.dart';
import 'package:tv_saver/tv/menu_screen.dart';

import 'display_screen_test.dart' show FakeAwake, RecordingDisplayClient;
import 'support.dart';

class MemoryLog implements PlaybackLog {
  final List<String> lines = [];

  @override
  void event(String name, {String? item, String? state, String? detail}) =>
      lines.add([name, item ?? '', state ?? '', detail ?? ''].join('|'));
}

void main() {
  group('FilePlaybackLog', () {
    late Directory tmp;
    late File file;
    var clock = DateTime.utc(2026, 11, 24, 12);

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('plog');
      file = File('${tmp.path}/log/playback.csv');
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    test('writes one line per event, with the folder made on demand', () {
      final log = FilePlaybackLog(file, now: () => clock)
        ..event('item', item: 'a.jpg', state: 'playing')
        ..event('paused');
      final lines = file.readAsLinesSync();
      expect(lines, hasLength(2));
      expect(lines[0], '2026-11-24T12:00:00.000Z,item,a.jpg,playing,');
      expect(lines[1], '2026-11-24T12:00:00.000Z,paused,,,');
      expect(log, isNotNull);
    });

    test('commas and line breaks cannot break a line', () {
      FilePlaybackLog(file).event('x', detail: 'a,b\nc');
      expect(file.readAsLinesSync(), hasLength(1));
      expect(file.readAsStringSync().split(',').length, 5);
    });

    test('the file stays small: it rolls over to .1', () {
      final log = FilePlaybackLog(file, maxBytes: 200);
      for (var i = 0; i < 30; i++) {
        log.event('heartbeat', item: 'a.jpg', state: 'playing');
      }
      expect(File('${file.path}.1').existsSync(), isTrue);
      expect(file.lengthSync(), lessThan(400));
    });

    test('an unwritable place does not throw', () {
      final log = FilePlaybackLog(File('${tmp.path}/log'));
      File('${tmp.path}/log').createSync(); // a file where the folder belongs
      expect(() => log.event('x'), returnsNormally);
    });
  });

  group('on screen', () {
    late FakeDisplayNative native;
    late RecordingDisplayClient client;
    late MemoryLog log;

    setUp(() {
      native = FakeDisplayNative();
      client = RecordingDisplayClient(native);
      log = MemoryLog();
    });

    Future<void> pumpScreen(WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: DisplayScreen(
            client: client,
            media3View: (created) => const SizedBox(),
            awake: FakeAwake(),
            log: log,
            heartbeat: const Duration(minutes: 1),
            menuBuilder: (ctx, onPair) => Scaffold(
              body: TvMenuScreen(version: '1', onPairPhone: onPair),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('lifecycle, items and heartbeats are noted', (tester) async {
      await pumpScreen(tester);
      expect(log.lines.first, startsWith('start'));

      await tester.runAsync(
        () => client.player.load(
          itemId: 'a.mp4',
          url: 'http://pi/a.mp4',
          headers: const {},
        ),
      );
      client.changed();
      await tester.pump();
      expect(log.lines, contains('item|a.mp4|playing|'));

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(
        log.lines.where((l) => l.split('|').first != 'item').toList(),
        containsAllInOrder([
          startsWith('inactive|a.mp4'),
          startsWith('paused|a.mp4'),
          startsWith('resumed|a.mp4'),
        ]),
      );

      await tester.pump(const Duration(minutes: 2));
      expect(
        log.lines.where((l) => l.startsWith('heartbeat|a.mp4|playing|')),
        hasLength(2),
      );
      expect(log.lines.any((l) => l.contains('offline')), isTrue);

      await tester.pumpWidget(const SizedBox());
      expect(log.lines.last, startsWith('stop'));
    });
  });
}
