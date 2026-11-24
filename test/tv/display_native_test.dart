import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tv_saver/tv/display/display_native.dart';
import 'package:tv_saver/tv/display/display_player.dart';
import 'package:tv_saver/tv/video_spike/spike_native.dart';

import 'support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ChannelDisplayNative', () {
    const channel = MethodChannel('tvsaver/test-video');
    late List<MethodCall> calls;
    late ChannelDisplayNative native;

    setUp(() {
      calls = [];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return null;
          });
      native = ChannelDisplayNative(channel);
    });
    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      channel.setMethodCallHandler(null);
    });

    test('sends the method names and argument maps Kotlin reads', () async {
      await native.open(
        url: 'http://pi/media/a.mp4/full',
        headers: {'Authorization': 'Bearer t'},
        startMs: 1500,
        muted: true,
        playing: false,
      );
      await native.pause();
      await native.resume();
      await native.seek(42000);
      await native.setMuted(true);
      await native.release();

      expect(
        [for (final c in calls) c.method],
        [
          'm3OpenItem',
          'm3Control',
          'm3Control',
          'm3Control',
          'm3Control',
          'm3Control',
        ],
      );
      expect(calls[0].arguments, {
        'url': 'http://pi/media/a.mp4/full',
        'headers': {'Authorization': 'Bearer t'},
        'startMs': 1500,
        'muted': true,
        'playing': false,
      });
      expect(calls[1].arguments, {'action': 'pause'});
      expect(calls[2].arguments, {'action': 'resume'});
      expect(calls[3].arguments, {'action': 'seek', 'positionMs': 42000});
      expect(calls[4].arguments, {'action': 'mute', 'muted': true});
      expect(calls[5].arguments, {'action': 'release'});
    });

    test('an inbound m3Ended fires onEnded', () async {
      var ended = 0;
      native.onEnded = () => ended++;
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            channel.name,
            const StandardMethodCodec().encodeMethodCall(
              const MethodCall('m3Ended'),
            ),
            (_) {},
          );
      expect(ended, 1);
    });
  });

  group('DisplayPlayer', () {
    test(
      'one more position goes out after a load, past the Pi shield',
      () async {
        final native = FakeDisplayNative();
        final sent = <PlayerSnapshot>[];
        final player = DisplayPlayer(
          native: native,
          reportPosition: sent.add,
          positionInterval: const Duration(minutes: 5),
          statsInterval: const Duration(minutes: 5),
          anchorDelay: const Duration(milliseconds: 80),
        );
        addTearDown(player.dispose);
        await player.viewCreated();
        native.statsValue = const Media3Stats(position: Duration(seconds: 3));
        await player.load(
          itemId: 'a.mp4',
          url: 'http://pi/a',
          headers: const {},
        );
        expect(sent, isEmpty);
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(sent, hasLength(1));
        expect(sent.single.positionMs, 3000);

        // A seek anchors again.
        await player.control('seek', positionMs: 9000);
        final afterSeek = sent.length; // control sends one at once
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(sent.length, afterSeek + 1);
      },
    );

    test('stop clears the item and releases the picture', () async {
      final native = FakeDisplayNative();
      final player = DisplayPlayer(
        native: native,
        statsInterval: const Duration(minutes: 5),
        positionInterval: const Duration(minutes: 5),
      );
      addTearDown(player.dispose);
      await player.viewCreated();
      await player.load(itemId: 'a.mp4', url: 'http://pi/a', headers: const {});
      expect(player.hasItem, isTrue);
      await player.control('stop');
      expect(player.hasItem, isFalse);
      expect(player.snapshot.state, 'idle');
      expect(native.calls, contains('release'));
    });
  });
}
