import 'dart:async';

import 'package:hub_core/hub_core.dart';
import 'package:test/test.dart';

import 'support/fake_phone_harness.dart';

List<Map<String, dynamic>> framesOf(TestPhone p, String type) => [
  for (final m in p.receivedHistory)
    if (m['t'] == type) m,
];

void main() {
  late TestHubRig rig;
  late TestPhone tv;
  late TestPhone phone;

  Future<void> start({
    Future<Map<String, Object?>> Function(String, String)? extras,
    Future<bool> Function(String)? muteFor,
    int prefetch = 2,
  }) async {
    rig = await TestHubRig.start(
      playlists: StaticPlaylistSource({
        'all': ['a.jpg', 'b.jpg', 'c.mp4', 'd.jpg'],
        'two': ['a.jpg', 'b.jpg'],
        'one': ['a.jpg'],
      }),
      loadExtras: extras,
      muteFor: muteFor,
      cacheBytes: () => 123456,
      prefetchCount: prefetch,
    );
    tv = await rig.onboardDisplay();
    phone = await rig.onboardPhone('Owner');
  }

  tearDown(() => rig.dispose());

  test('display.load carries the extras of the item', () async {
    await start(
      extras: (playlist, item) async => {
        'kind': item.endsWith('.jpg') ? 'image' : 'video',
        if (item.endsWith('.jpg')) 'imageMs': 15000,
        'playlist': playlist,
      },
    );
    await phone.request('player.play', {'playlistId': 'all'});
    final load = await tv.waitFor((m) => m['t'] == 'display.load');
    expect(load['itemId'], 'a.jpg');
    expect(load['kind'], 'image');
    expect(load['imageMs'], 15000);
    expect(load['playlist'], 'all');
    expect(load['variant'], 'full');
  });

  test(
    'display.load places the item in its playlist; one item loops',
    () async {
      await start();
      await phone.request('player.play', {'playlistId': 'all', 'index': 2});
      var load = await tv.waitFor((m) => m['t'] == 'display.load');
      expect(load['index'], 2);
      expect(load['count'], 4);
      expect(load.containsKey('loop'), isFalse);
      await phone.request('player.play', {'playlistId': 'one'});
      load = await tv.waitFor(
        (m) =>
            m['t'] == 'display.load' &&
            m['itemId'] == 'a.jpg' &&
            m['count'] == 1,
      );
      expect(load['index'], 0);
      expect(load['loop'], true);
    },
  );

  test('display.prefetch names the next items and the cache cap', () async {
    await start();
    await phone.request('player.play', {'playlistId': 'all'});
    final pre = await tv.waitFor((m) => m['t'] == 'display.prefetch');
    expect(pre['itemIds'], ['b.jpg', 'c.mp4']);
    expect(pre['cacheBytes'], 123456);
    await phone.request('player.next');
    await tv.waitFor(
      (m) => m['t'] == 'display.prefetch' && m['itemIds'][0] == 'c.mp4',
    );
    await phone.request('player.play', {'playlistId': 'all', 'index': 3});
    final wrap = await tv.waitFor(
      (m) => m['t'] == 'display.prefetch' && m['itemIds'][0] == 'a.jpg',
    );
    expect(wrap['itemIds'], ['a.jpg', 'b.jpg']); // wraps around
  });

  test('a one-item playlist has nothing to prefetch; 0 turns it off', () async {
    await start();
    await phone.request('player.play', {'playlistId': 'one'});
    await tv.waitFor((m) => m['t'] == 'display.load');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(framesOf(tv, 'display.prefetch'), isEmpty);
    await rig.dispose();
    await start(prefetch: 0);
    await phone.request('player.play', {'playlistId': 'all'});
    await tv.waitFor((m) => m['t'] == 'display.load');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(framesOf(tv, 'display.prefetch'), isEmpty);
  });

  test('a failing extras lookup still plays the item', () async {
    await start(extras: (_, _) async => throw StateError('db'));
    await phone.request('player.play', {'playlistId': 'two'});
    final load = await tv.waitFor((m) => m['t'] == 'display.load');
    expect(load['itemId'], 'a.jpg');
    expect(load.containsKey('kind'), isFalse);
  });

  test(
    'play starts muted when the playlist says so; setMuted overrides',
    () async {
      await start(muteFor: (playlist) async => playlist == 'two');
      await phone.request('player.play', {'playlistId': 'two'});
      var load = await tv.waitFor((m) => m['t'] == 'display.load');
      expect(load['muted'], true);
      await phone.request('player.setMuted', {'muted': false});
      await phone.request('player.play', {'playlistId': 'all'});
      load = await tv.waitFor(
        (m) =>
            m['t'] == 'display.load' &&
            m['itemId'] == 'a.jpg' &&
            m['muted'] == false,
      );
      expect(load['muted'], false);
    },
  );
}
