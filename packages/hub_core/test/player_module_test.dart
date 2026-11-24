import 'dart:async';
import 'dart:io';

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

bool isChanged(Map<String, dynamic> m) =>
    m['t'] == HubMsg.event && m['kind'] == 'player.changed';

Map<String, dynamic> dataOf(Map<String, dynamic> m) =>
    m['data'] as Map<String, dynamic>;

Future<Map<String, dynamic>> expectErr(
  Future<Map<String, dynamic>> reply,
  String code,
) async {
  final r = await reply;
  expect(r['t'], HubMsg.err, reason: '$r');
  expect(r['code'], code);
  return r;
}

Future<void> expectOk(Future<Map<String, dynamic>> reply) async {
  final r = await reply;
  expect(r['t'], HubMsg.ok, reason: '$r');
}

/// Frames of [type] a client has received so far (consumed or not).
List<Map<String, dynamic>> framesOf(TestPhone p, String type) => [
  for (final m in p.receivedHistory)
    if (m['t'] == type) m,
];

/// Asks for a fresh snapshot (the one sent on connect stays in the inbox).
Future<Map<String, dynamic>> snapshotOf(TestPhone p) async {
  final n = framesOf(p, HubMsg.snapshot).length;
  p.send(HubMsg.sync);
  await until(() => framesOf(p, HubMsg.snapshot).length > n);
  return framesOf(p, HubMsg.snapshot).last;
}

Map<String, dynamic> playerOf(Map<String, dynamic> snap) =>
    (snap['modules'] as Map)['player'] as Map<String, dynamic>;

void main() {
  late TestHubRig rig;
  late StaticPlaylistSource source;
  late TestPhone tv;
  late TestPhone phone;

  setUp(() async {
    source = StaticPlaylistSource({
      'all': ['a.mp4', 'b.mp4', 'c.mp4'],
      'empty': <String>[],
    });
    rig = await TestHubRig.start(playlists: source);
    tv = await rig.onboardDisplay();
    phone = await rig.onboardPhone('Owner');
  });
  tearDown(() => rig.dispose());

  /// The TV drops and returns with its token.
  Future<TestPhone> reconnectTv() async {
    final token = tv.token;
    await tv.close();
    await until(() => rig.displayModule!.onlineDisplayId == null);
    final again = await rig.connectDisplay();
    again.sendDisplayHello(withToken: token);
    await again.expectType(HubMsg.ready);
    again
      ..token = token
      ..deviceId = tv.deviceId;
    await until(() => rig.displayModule!.onlineDisplayId != null);
    return again;
  }

  group('player commands', () {
    test('play from a phone: changed to all, display.load to the TV', () async {
      final second = await rig.onboardPhone('Second');
      await expectOk(phone.request('player.play', {'playlistId': 'all'}));

      for (final p in [phone, second, tv]) {
        final d = dataOf(await p.waitFor(isChanged));
        expect(d['playlistId'], 'all');
        expect(d['index'], 0);
        expect(d['itemId'], 'a.mp4');
        expect(d['state'], 'playing');
        expect(d['positionMs'], 0);
        expect(d['startedAt'], rig.clock.now().millisecondsSinceEpoch);
        expect(d['muted'], false);
      }
      final load = await tv.waitFor((m) => m['t'] == 'display.load');
      expect(load['itemId'], 'a.mp4');
      expect(load['variant'], 'full');
      expect(load['startAt'], 0);
      // Only the display gets the targeted frame.
      expect(framesOf(phone, 'display.load'), isEmpty);
      expect(framesOf(second, 'display.load'), isEmpty);
    });

    test('play with an index, and bad arguments', () async {
      await expectOk(
        phone.request('player.play', {'playlistId': 'all', 'index': 2}),
      );
      expect(
        (await tv.waitFor((m) => m['t'] == 'display.load'))['itemId'],
        'c.mp4',
      );

      await expectErr(
        phone.request('player.play', {'playlistId': 'nope'}),
        HubErrorCode.notFound,
      );
      await expectErr(
        phone.request('player.play', {'playlistId': 'empty'}),
        HubErrorCode.notFound,
      );
      await expectErr(
        phone.request('player.play', {'playlistId': 'all', 'index': 3}),
        HubErrorCode.invalid,
      );
      await expectErr(
        phone.request('player.play', {'playlistId': 'all', 'index': 'x'}),
        HubErrorCode.invalid,
      );
      await expectErr(phone.request('player.play'), HubErrorCode.invalid);
    });

    test('remote next acts like a phone: phones and TV follow', () async {
      await expectOk(phone.request('player.play', {'playlistId': 'all'}));
      await phone.waitFor(isChanged);
      await tv.waitFor((m) => m['t'] == 'display.load');

      await expectOk(tv.request('player.next'));
      final d = dataOf(await phone.waitFor(isChanged));
      expect(d['index'], 1);
      expect(d['itemId'], 'b.mp4');
      final load = await tv.waitFor((m) => m['t'] == 'display.load');
      expect(load['itemId'], 'b.mp4');
    });

    test('next and prev wrap around the playlist', () async {
      await expectOk(phone.request('player.play', {'playlistId': 'all'}));
      await expectOk(phone.request('player.prev'));
      await phone.waitFor(isChanged); // play
      expect(dataOf(await phone.waitFor(isChanged))['itemId'], 'c.mp4');
      await expectOk(phone.request('player.next'));
      expect(dataOf(await phone.waitFor(isChanged))['itemId'], 'a.mp4');
    });

    test('next with nothing playing is not_found', () async {
      await expectErr(phone.request('player.next'), HubErrorCode.notFound);
      await expectErr(phone.request('player.pause'), HubErrorCode.notFound);
      await expectErr(phone.request('player.resume'), HubErrorCode.notFound);
      await expectErr(
        phone.request('player.seek', {'positionMs': 5}),
        HubErrorCode.notFound,
      );
    });

    test(
      'pause, resume, seek and mute update state and control the TV',
      () async {
        final second = await rig.onboardPhone('Second');
        await expectOk(phone.request('player.play', {'playlistId': 'all'}));
        await tv.waitFor((m) => m['t'] == 'display.load');

        // The position shield ends, then 12 s of playback pass.
        rig.clock.advance(const Duration(seconds: 12));
        await expectOk(phone.request('player.pause'));
        var d = dataOf(
          await second.waitFor(
            (m) => isChanged(m) && dataOf(m)['state'] == 'paused',
          ),
        );
        expect(d['positionMs'], 12000);
        expect(d['startedAt'], isNull);
        var control = await tv.waitFor((m) => m['t'] == 'display.control');
        expect(control['action'], 'pause');
        expect(control['positionMs'], 12000);

        // Time passes while paused: the position does not move.
        rig.clock.advance(const Duration(seconds: 30));
        await expectOk(phone.request('player.seek', {'positionMs': 45000}));
        d = dataOf(
          await second.waitFor(
            (m) => isChanged(m) && dataOf(m)['positionMs'] == 45000,
          ),
        );
        expect(d['state'], 'paused');
        control = await tv.waitFor((m) => m['t'] == 'display.control');
        expect(control['action'], 'seek');
        expect(control['positionMs'], 45000);

        await expectOk(second.request('player.resume'));
        d = dataOf(
          await phone.waitFor(
            (m) =>
                isChanged(m) &&
                dataOf(m)['state'] == 'playing' &&
                dataOf(m)['positionMs'] == 45000,
          ),
        );
        expect(d['startedAt'], rig.clock.now().millisecondsSinceEpoch - 45000);
        control = await tv.waitFor((m) => m['t'] == 'display.control');
        expect(control['action'], 'resume');

        await expectOk(phone.request('player.setMuted', {'muted': true}));
        d = dataOf(
          await second.waitFor(
            (m) => isChanged(m) && dataOf(m)['muted'] == true,
          ),
        );
        expect(d['state'], 'playing');
        control = await tv.waitFor((m) => m['t'] == 'display.control');
        expect(control['action'], 'mute');
        expect(control['muted'], true);
        await expectErr(
          phone.request('player.setMuted', {'muted': 'yes'}),
          HubErrorCode.invalid,
        );

        // A phone that joins late sees the same position in its snapshot.
        rig.clock.advance(const Duration(seconds: 5));
        final player = playerOf(await snapshotOf(second));
        expect(player['state'], 'playing');
        expect(player['positionMs'], 50000);
        expect(player['muted'], true);
      },
    );

    test('muted lasts until the next play', () async {
      await expectOk(phone.request('player.play', {'playlistId': 'all'}));
      await expectOk(phone.request('player.setMuted', {'muted': true}));
      await expectOk(phone.request('player.next'));
      var load = await tv.waitFor(
        (m) => m['t'] == 'display.load' && m['itemId'] == 'b.mp4',
      );
      expect(load['muted'], true);
      await expectOk(phone.request('player.play', {'playlistId': 'all'}));
      load = await tv.waitFor(
        (m) =>
            m['t'] == 'display.load' &&
            m['itemId'] == 'a.mp4' &&
            m['muted'] == false,
      );
      expect(load['muted'], false);
    });

    test('seek past the end clamps to the known duration', () async {
      await expectOk(phone.request('player.play', {'playlistId': 'all'}));
      await tv.waitFor((m) => m['t'] == 'display.load');
      rig.clock.advance(const Duration(seconds: 3));
      await expectOk(
        tv.request('player.position', {
          'itemId': 'a.mp4',
          'positionMs': 3000,
          'durationMs': 60000,
        }),
      );
      await expectOk(phone.request('player.seek', {'positionMs': 999999999}));
      final d = dataOf(
        await phone.waitFor(
          (m) => isChanged(m) && dataOf(m)['positionMs'] == 60000,
        ),
      );
      expect(d['positionMs'], 60000);
      final control = await tv.waitFor((m) => m['t'] == 'display.control');
      expect(control['positionMs'], 60000);

      // A negative position clamps to the start.
      await expectOk(phone.request('player.seek', {'positionMs': -5}));
      expect(
        dataOf(
          await phone.waitFor(
            (m) => isChanged(m) && dataOf(m)['positionMs'] == 0,
          ),
        )['positionMs'],
        0,
      );
      await expectErr(
        phone.request('player.seek', {'positionMs': 'soon'}),
        HubErrorCode.invalid,
      );
    });

    test('with no display connected phones get unavailable', () async {
      await tv.close();
      await until(() => rig.displayModule!.onlineDisplayId == null);
      for (final type in [
        'player.next',
        'player.prev',
        'player.pause',
        'player.resume',
      ]) {
        await expectErr(phone.request(type), HubErrorCode.unavailable);
      }
      await expectErr(
        phone.request('player.play', {'playlistId': 'all'}),
        HubErrorCode.unavailable,
      );
      await expectErr(
        phone.request('player.seek', {'positionMs': 0}),
        HubErrorCode.unavailable,
      );
      await expectErr(
        phone.request('player.setMuted', {'muted': true}),
        HubErrorCode.unavailable,
      );
    });
  });

  group('item end', () {
    test('ended moves on and wraps from the last item to index 0', () async {
      await expectOk(
        phone.request('player.play', {'playlistId': 'all', 'index': 2}),
      );
      await tv.waitFor((m) => m['t'] == 'display.load');
      await phone.waitFor(isChanged);

      final moved = await tv.request('player.ended', {'itemId': 'c.mp4'});
      expect((moved['result'] as Map)['moved'], true);
      final d = dataOf(await phone.waitFor(isChanged));
      expect(d['index'], 0);
      expect(d['itemId'], 'a.mp4');
      expect(d['state'], 'playing');
      final load = await tv.waitFor(
        (m) => m['t'] == 'display.load' && m['itemId'] == 'a.mp4',
      );
      expect(load['startAt'], 0);
    });

    test('a duplicate or stale ended does not skip an item', () async {
      await expectOk(phone.request('player.play', {'playlistId': 'all'}));
      await tv.waitFor((m) => m['t'] == 'display.load');
      final first = await tv.request('player.ended', {'itemId': 'a.mp4'});
      expect((first['result'] as Map)['moved'], true);
      for (final id in ['a.mp4', 'zzz.mp4']) {
        final r = await tv.request('player.ended', {'itemId': id});
        expect((r['result'] as Map)['moved'], false);
      }
      await until(() => framesOf(tv, 'display.load').length >= 2);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(framesOf(tv, 'display.load').map((m) => m['itemId']).toList(), [
        'a.mp4',
        'b.mp4',
      ]);
    });

    test('an emptied playlist: next is not_found, ended goes idle', () async {
      await expectOk(phone.request('player.play', {'playlistId': 'all'}));
      await tv.waitFor((m) => m['t'] == 'display.load');
      source.playlists['all'] = [];
      await expectErr(phone.request('player.next'), HubErrorCode.notFound);

      final r = await tv.request('player.ended', {'itemId': 'a.mp4'});
      expect((r['result'] as Map)['moved'], false);
      final d = dataOf(
        await phone.waitFor(
          (m) => isChanged(m) && dataOf(m)['state'] == 'idle',
        ),
      );
      expect(d['itemId'], isNull);
      final stop = await tv.waitFor(
        (m) => m['t'] == 'display.control' && m['action'] == 'stop',
      );
      expect(stop['action'], 'stop');
    });

    test('next after the current item was removed takes its place', () async {
      await expectOk(
        phone.request('player.play', {'playlistId': 'all', 'index': 1}),
      );
      await tv.waitFor((m) => m['t'] == 'display.load');
      source.playlists['all'] = ['a.mp4', 'c.mp4'];
      await expectOk(phone.request('player.next'));
      final load = await tv.waitFor(
        (m) => m['t'] == 'display.load' && m['itemId'] == 'c.mp4',
      );
      expect(load['itemId'], 'c.mp4');
    });
  });

  group('display reports', () {
    test('player.position updates the snapshot without a rev bump', () async {
      await expectOk(phone.request('player.play', {'playlistId': 'all'}));
      await tv.waitFor((m) => m['t'] == 'display.load');
      await phone.waitFor(isChanged);
      final rev = rig.server.rev;
      final changedBefore = framesOf(
        phone,
        HubMsg.event,
      ).where(isChanged).length;

      rig.clock.advance(const Duration(seconds: 10));
      await expectOk(
        tv.request('player.position', {
          'itemId': 'a.mp4',
          'positionMs': 9000,
          'at': 1,
        }),
      );
      expect(rig.server.rev, rev);
      expect(
        framesOf(phone, HubMsg.event).where(isChanged).length,
        changedBefore,
      );

      final player = playerOf(await snapshotOf(phone));
      expect(player['positionMs'], 9000);
      expect(player['itemId'], 'a.mp4');

      // A report for another item (it just changed) is ignored.
      await expectOk(
        tv.request('player.position', {'itemId': 'b.mp4', 'positionMs': 1}),
      );
      expect(playerOf(await snapshotOf(phone))['positionMs'], 9000);
    });

    test('a stale position cannot undo a seek that is on its way', () async {
      await expectOk(phone.request('player.play', {'playlistId': 'all'}));
      await tv.waitFor((m) => m['t'] == 'display.load');
      rig.clock.advance(const Duration(seconds: 20));
      await expectOk(phone.request('player.seek', {'positionMs': 30000}));
      await expectOk(
        tv.request('player.position', {'itemId': 'a.mp4', 'positionMs': 19000}),
      );
      expect(playerOf(await snapshotOf(phone))['positionMs'], 30000);
    });

    test('a report after a Pi restart is adopted without restarting', () async {
      // Fresh rig: the Pi knows nothing, the TV is mid-clip.
      await rig.dispose();
      rig = await TestHubRig.start(playlists: source);
      tv = await rig.onboardDisplay();
      phone = await rig.onboardPhone('Owner');

      await expectOk(
        tv.request('player.report', {
          'playlistId': 'all',
          'index': 1,
          'itemId': 'b.mp4',
          'state': 'playing',
          'positionMs': 42000,
          'durationMs': 90000,
          'at': 5,
        }),
      );
      final d = dataOf(await phone.waitFor(isChanged));
      expect(d['playlistId'], 'all');
      expect(d['index'], 1);
      expect(d['itemId'], 'b.mp4');
      expect(d['state'], 'playing');
      expect(d['positionMs'], 42000);
      expect(d['startedAt'], rig.clock.now().millisecondsSinceEpoch - 42000);
      // Playback is not restarted.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(framesOf(tv, 'display.load'), isEmpty);
      expect(framesOf(tv, 'display.control'), isEmpty);

      expect(playerOf(await snapshotOf(phone))['itemId'], 'b.mp4');
    });

    test(
      'a report for a removed item is ignored; idle resets the player',
      () async {
        await expectOk(phone.request('player.play', {'playlistId': 'all'}));
        await phone.waitFor(isChanged);
        // The TV drops and returns: no command since, so its report counts.
        tv = await reconnectTv();
        final before = framesOf(phone, HubMsg.event).where(isChanged).length;

        final stale = await tv.request('player.report', {
          'playlistId': 'all',
          'index': 0,
          'itemId': 'gone.mp4',
          'state': 'playing',
          'positionMs': 1,
        });
        expect(stale['t'], HubMsg.ok);
        expect((stale['result'] as Map)['adopted'], false);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(framesOf(phone, HubMsg.event).where(isChanged).length, before);

        await expectOk(
          tv.request('player.report', {
            'playlistId': null,
            'itemId': null,
            'state': 'idle',
            'positionMs': 0,
          }),
        );
        final d = dataOf(
          await phone.waitFor(
            (m) => isChanged(m) && dataOf(m)['state'] == 'idle',
          ),
        );
        expect(d['itemId'], isNull);

        await expectErr(
          tv.request('player.report', {
            'playlistId': 'all',
            'itemId': 'a.mp4',
            'state': 'dancing',
            'positionMs': 0,
          }),
          HubErrorCode.invalid,
        );
      },
    );

    test('while the TV is away the player pauses at its position', () async {
      await expectOk(phone.request('player.play', {'playlistId': 'all'}));
      await phone.waitFor(isChanged);
      rig.clock.advance(const Duration(seconds: 8));
      await tv.close();
      final d = dataOf(
        await phone.waitFor(
          (m) => isChanged(m) && dataOf(m)['state'] == 'paused',
        ),
      );
      expect(d['positionMs'], 8000);
      expect(d['startedAt'], isNull);
      // The clock no longer runs.
      rig.clock.advance(const Duration(minutes: 5));
      expect(playerOf(await snapshotOf(phone))['positionMs'], 8000);
    });

    test('a report that is older than a command is not adopted', () async {
      await expectOk(phone.request('player.play', {'playlistId': 'all'}));
      await tv.waitFor((m) => m['t'] == 'display.load');
      await phone.waitFor(isChanged);
      await expectOk(phone.request('player.pause'));
      await phone.waitFor(
        (m) => isChanged(m) && dataOf(m)['state'] == 'paused',
      );

      final r = await tv.request('player.report', {
        'playlistId': 'all',
        'index': 2,
        'itemId': 'c.mp4',
        'state': 'playing',
        'positionMs': 5000,
      });
      expect((r['result'] as Map)['adopted'], false);
      // The TV is told to show what the Pi has: a.mp4, paused.
      final load = await tv.waitFor(
        (m) =>
            m['t'] == 'display.load' &&
            m['itemId'] == 'a.mp4' &&
            framesOf(tv, 'display.load').length >= 2,
      );
      expect(load['t'], 'display.load');
      final pause = await tv.waitFor(
        (m) => m['t'] == 'display.control' && m['action'] == 'pause',
      );
      expect(pause['action'], 'pause');
      expect(playerOf(await snapshotOf(phone))['itemId'], 'a.mp4');
    });

    test('the position shield ends exactly 2.5 s after the command', () async {
      await expectOk(phone.request('player.play', {'playlistId': 'all'}));
      await tv.waitFor((m) => m['t'] == 'display.load');

      rig.clock.advance(const Duration(milliseconds: 2499));
      await expectOk(
        tv.request('player.position', {'itemId': 'a.mp4', 'positionMs': 100}),
      );
      // Dropped: the Pi still counts from the play command.
      expect(playerOf(await snapshotOf(phone))['positionMs'], 2499);

      rig.clock.advance(const Duration(milliseconds: 1));
      await expectOk(
        tv.request('player.position', {'itemId': 'a.mp4', 'positionMs': 100}),
      );
      expect(playerOf(await snapshotOf(phone))['positionMs'], 100);
    });

    test('phones cannot send display-only messages', () async {
      for (final type in [
        'player.position',
        'player.report',
        'player.ended',
        'display.capabilities',
      ]) {
        await expectErr(
          phone.request(type, {
            'itemId': 'a.mp4',
            'positionMs': 0,
            'state': 'idle',
            'decoders': <String>[],
            'hdr': <String>[],
          }),
          HubErrorCode.forbidden,
        );
      }
    });

    test('the player module keeps one player per display id', () async {
      await expectOk(phone.request('player.play', {'playlistId': 'all'}));
      await phone.waitFor(isChanged);
      final id = tv.deviceId!;
      expect(rig.displayModule!.onlineDisplayId, id);
      // The TV goes away and comes back with its token: same player.
      await tv.close();
      await until(() => rig.displayModule!.onlineDisplayId == null);
      final again = await rig.connectDisplay();
      again.sendDisplayHello(withToken: tv.token);
      await again.expectType(HubMsg.ready);
      await until(() => rig.displayModule!.onlineDisplayId == id);
      expect(playerOf(await snapshotOf(phone))['itemId'], 'a.mp4');
    });
  });

  group('display module', () {
    test('capabilities are stored per display id', () async {
      expect(rig.displayModule!.capabilitiesFor(tv.deviceId!), isNull);
      await expectOk(
        tv.request('display.capabilities', {
          'decoders': ['hevc'],
          'hdr': ['HDR10', 'HLG'],
          'render': '3840x2160',
          'panel': {'width': 3840, 'height': 2160},
        }),
      );
      final caps = rig.displayModule!.capabilitiesFor(tv.deviceId!)!;
      expect(caps['decoders'], ['hevc']);
      expect(caps['hdr'], ['HDR10', 'HLG']);
      expect(caps['render'], '3840x2160');
      expect(caps['panel'], {'width': 3840, 'height': 2160});

      await expectErr(
        tv.request('display.capabilities', {'decoders': 'hevc', 'hdr': []}),
        HubErrorCode.invalid,
      );
      // A bad update leaves the stored value alone.
      expect(rig.displayModule!.capabilitiesFor(tv.deviceId!)!['decoders'], [
        'hevc',
      ]);
    });

    test(
      'display.changed tells phones when the TV leaves and returns',
      () async {
        expect(rig.displayModule!.onlineDisplayId, tv.deviceId);
        await tv.close();
        final off = await phone.expectEvent('display.changed');
        expect(dataOf(off)['online'], false);

        final again = await rig.connectDisplay();
        again.sendDisplayHello(withToken: tv.token);
        await again.expectType(HubMsg.ready);
        final on = await phone.expectEvent('display.changed');
        expect(dataOf(on)['online'], true);
      },
    );
  });

  group('MediaDirPlaylistSource', () {
    test('all is the video files sorted by name, ignoring case', () async {
      final dir = Directory.systemTemp.createTempSync('playlist_src');
      addTearDown(() => dir.deleteSync(recursive: true));
      for (final n in [
        'b.mp4',
        'a.MKV',
        'C.mov',
        '.hidden.mp4',
        'throughput-1g.bin',
        'notes.txt',
        'noext',
        'd.webm',
        'e.ts',
        'f.m4v',
        'has space.mp4',
      ]) {
        File('${dir.path}/$n').writeAsStringSync('x');
      }
      Directory('${dir.path}/sub.mp4').createSync();

      final src = MediaDirPlaylistSource(dir.path);
      expect(await src.itemIds('all'), [
        'a.MKV',
        'b.mp4',
        'C.mov',
        'd.webm',
        'e.ts',
        'f.m4v',
      ]);
      expect(await src.itemIds('other'), isNull);
      expect(
        await MediaDirPlaylistSource('${dir.path}/missing').itemIds('all'),
        isEmpty,
      );
    });

    test('a listing error returns the last result, or throws first', () async {
      final dir = Directory.systemTemp.createTempSync('playlist_err');
      addTearDown(() => dir.deleteSync(recursive: true));
      File('${dir.path}/a.mp4').writeAsStringSync('x');
      var fail = false;
      final src = MediaDirPlaylistSource(
        dir.path,
        list: (d) => fail
            ? Stream.error(const FileSystemException('boom'))
            : d.list(followLinks: false),
      );
      expect(await src.itemIds('all'), ['a.mp4']);
      fail = true;
      expect(await src.itemIds('all'), ['a.mp4']);

      final fresh = MediaDirPlaylistSource(
        dir.path,
        list: (_) => Stream.error(const FileSystemException('boom')),
      );
      await expectLater(
        fresh.itemIds('all'),
        throwsA(isA<FileSystemException>()),
      );
    });
  });
}
