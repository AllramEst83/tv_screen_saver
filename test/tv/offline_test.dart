import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hub_core/hub_core.dart';
import 'package:tv_saver/phone/phone_controller.dart';
import 'package:tv_saver/tv/cache/media_cache.dart';
import 'package:tv_saver/tv/display/offline_playlist.dart';

import '../phone/support.dart';
import 'support.dart';

void main() {
  late Rig rig;
  late Directory tmp;
  late MediaCache cache;
  late StaticPlaylistSource playlists;
  TvRig? tv;
  PhoneRig? phone;

  Future<Map<String, Object?>> extras(String playlist, String item) async => {
    'kind': 'image',
    'name': 'Photo $item',
    'imageMs': 250,
    'transition': 'crossfade',
    'kenBurns': false,
  };

  Future<Rig> startRig({String? dbFile, int port = 0}) => Rig.start(
    dbFile: dbFile,
    port: port,
    playlists: playlists,
    loadExtras: extras,
    cacheBytes: () => 1000000,
  );

  void cached(String id) {
    final dir = Directory('${tmp.path}/c')..createSync(recursive: true);
    File('${dir.path}/$id.full').writeAsBytesSync(List.filled(40, 1));
  }

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('offline');
    playlists = StaticPlaylistSource({
      'all': ['a.jpg', 'b.jpg', 'c.jpg', 'd.jpg'],
    });
    // b and d are not on the TV.
    cached('a.jpg');
    cached('c.jpg');
    cache = MediaCache(dir: Directory('${tmp.path}/c'));
    rig = await startRig(dbFile: '${tmp.path}/hub.db');
  });

  tearDown(() async {
    await phone?.dispose();
    tv?.dispose();
    await rig.dispose();
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows may still hold a file open.
    }
  });

  Future<void> startPlaying() async {
    tv = TvRig(rig, cache: cache);
    await tv!.start();
    await until(() => tv!.display.pairing != null);
    phone = PhoneRig();
    await phone!.controller.start();
    await phone!.controller.pairFromQr(tv!.display.pairing!.qr);
    await phone!.waitFor(PhoneScreen.home);
    await until(() => !tv!.display.needsPairing);
    await phone!.controller.play();
    await until(() => tv!.display.player.itemId == 'a.jpg');
    await until(() => tv!.display.player.image.value != null);
  }

  Future<void> piGoesAway() async {
    await rig.dispose();
    await until(() => !tv!.display.connected);
  }

  test('the OfflinePlaylist frame is read leniently', () {
    final p = OfflinePlaylist.tryParse({
      'playlistId': 'all',
      'items': [
        {'id': 'a.jpg', 'kind': 'image', 'name': 'A'},
        {'id': 'v.mp4', 'kind': 'video', 'cacheRequired': true},
        {'kind': 'image'}, // no id: skipped
        'junk',
      ],
      'imageMs': 9000,
      'transition': 'cut',
      'kenBurns': true,
    })!;
    expect(p.items.map((i) => i.id), ['a.jpg', 'v.mp4']);
    expect(p.items[1].cacheRequired, isTrue);
    expect(p.imageMs, 9000);
    expect(p.crossfade, isFalse);
    expect(p.kenBurns, isTrue);
    expect(p.indexOf('v.mp4'), 1);
    expect(OfflinePlaylist.tryParse({'items': []}), isNull);
  });

  test('without the Pi the cached photos loop; others are skipped', () async {
    await startPlaying();
    await until(() => tv!.display.player.info?.count == 4);
    await piGoesAway();
    // a ends (250 ms): b is not cached, so c comes next, then back to a.
    await until(() => tv!.display.player.itemId == 'c.jpg');
    expect(tv!.display.player.info!.index, 2);
    expect(tv!.display.player.info!.name, 'Photo c.jpg');
    await until(() => tv!.display.player.itemId == 'a.jpg');
  });

  test('the remote acts on the cached playlist: next, prev, pause, '
      'seek', () async {
    await startPlaying();
    await until(() => tv!.display.player.info?.count == 4);
    await piGoesAway();
    final d = tv!.display;
    await d.next();
    expect(d.player.itemId, 'c.jpg');
    await d.prev();
    expect(d.player.itemId, 'a.jpg');
    await d.prev(); // wraps backwards past d (not cached) and b: c
    expect(d.player.itemId, 'c.jpg');

    await d.togglePause();
    expect(d.player.playing, isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(d.player.itemId, 'c.jpg'); // paused: no advance
    await d.togglePause();
    expect(d.player.playing, isTrue);
    await d.seekBy(100);
    expect(d.player.snapshot.positionMs, greaterThanOrEqualTo(100));
  });

  test(
    'one cached item keeps looping; nothing cached changes nothing',
    () async {
      await startPlaying();
      await until(() => tv!.display.player.info?.count == 4);
      File('${tmp.path}/c/c.jpg.full').deleteSync();
      await piGoesAway();
      await tv!.display.next(); // c is gone: nothing else to move to
      expect(tv!.display.player.itemId, 'a.jpg');
      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(tv!.display.player.itemId, 'a.jpg');
      expect(tv!.display.player.image.value, isNotNull);
    },
  );

  test('on return the Pi adopts what the TV shows; the picture does not '
      'jump', () async {
    await startPlaying();
    await until(() => tv!.display.player.info?.count == 4);
    final port = rig.server.port;
    await piGoesAway();
    await until(() => tv!.display.player.itemId == 'c.jpg');
    final d = tv!.display;
    await d.togglePause(); // hold it on c
    final slot = d.player.image.value;

    rig = await startRig(dbFile: '${tmp.path}/hub.db', port: port);
    await until(() => d.connected);
    Future<Map<String, dynamic>> piPlayer() async {
      final snap = await rig.server.buildFullSnapshot(DeviceInfo.tv);
      return (snap['modules'] as Map)['player'] as Map<String, dynamic>;
    }

    await untilAsync(() async => (await piPlayer())['itemId'] == 'c.jpg');
    final p = await piPlayer();
    expect(p['playlistId'], 'all');
    expect(p['index'], 2);
    expect(p['state'], 'paused');
    // Same slide, not reloaded.
    expect(identical(d.player.image.value, slot), isTrue);
    expect(d.player.itemId, 'c.jpg');
  });
}
