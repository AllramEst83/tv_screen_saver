import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hub_core/hub_core.dart';
import 'package:tv_saver/phone/phone_controller.dart';
import 'package:tv_saver/tv/cache/media_cache.dart';

import '../phone/support.dart';
import 'support.dart';

/// Records what the TV asks to have cached instead of downloading it.
class RecordingCache extends MediaCache {
  RecordingCache(Directory dir) : super(dir: dir);

  final List<List<CacheRequest>> prefetches = [];

  @override
  void prefetch(List<CacheRequest> requests) => prefetches.add(requests);
}

void main() {
  late Rig rig;
  late Directory tmp;
  late RecordingCache cache;
  TvRig? tv;
  PhoneRig? phone;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('pre');
    cache = RecordingCache(Directory('${tmp.path}/c'));
    rig = await Rig.start(
      playlists: StaticPlaylistSource({
        'all': ['a.jpg', 'b.jpg', 'c.mp4', 'd.jpg'],
      }),
      loadExtras: (playlist, item) async => {
        'kind': item.endsWith('.jpg') ? 'image' : 'video',
        if (item.endsWith('.jpg')) 'imageMs': 8000,
      },
      cacheBytes: () => 777000,
    );
  });

  tearDown(() async {
    await phone?.dispose();
    tv?.dispose();
    await rig.dispose();
    tmp.deleteSync(recursive: true);
  });

  Future<void> playAll({String render = '3840x2160'}) async {
    tv = TvRig(rig, cache: cache, render: render);
    await tv!.start();
    await until(() => tv!.display.pairing != null);
    phone = PhoneRig();
    await phone!.controller.start();
    await phone!.controller.pairFromQr(tv!.display.pairing!.qr);
    await phone!.waitFor(PhoneScreen.home);
    await until(() => !tv!.display.needsPairing);
    await phone!.controller.play();
  }

  test('the TV caches the next items: photos as full, videos capped at a '
      'quarter of the cache, with the Pi cache size', () async {
    await playAll();
    await until(() => cache.prefetches.isNotEmpty);
    final first = cache.prefetches.first;
    expect(first.map((r) => r.key), ['b.jpg.full', 'c.mp4.full']);
    expect(cache.capBytes, 777000);
    expect(first[0].maxBytes, isNull); // photos are small
    expect(first[1].maxBytes, 777000 ~/ 4);
    expect(first[0].url.path, '/media/b.jpg/full');
    expect(first[0].headers['Authorization'], startsWith('Bearer '));
  });

  test('display.load tells the player it is a photo', () async {
    await playAll();
    await until(() => tv!.display.player.itemId == 'a.jpg');
    // No cache download could succeed here (the rig has no media route), so
    // the photo is skipped; what matters is that it took the photo path and
    // never opened the video view.
    expect(tv!.native.opens, isEmpty);
  });

  test(
    'a 1080p Flutter plane on a 4K panel: photos go native, full size',
    () async {
      await playAll(render: '1920x1080');
      await until(() => cache.prefetches.isNotEmpty);
      expect(tv!.display.player.nativeImages, isTrue);
      expect(tv!.display.player.imageVariant(), 'full');
      expect(cache.prefetches.first.first.key, 'b.jpg.full');
      expect(cache.prefetches.first.first.fallback, isNull);
    },
  );

  test('a full 4K Flutter plane keeps the Flutter widget', () async {
    await playAll();
    await until(() => cache.prefetches.isNotEmpty);
    expect(tv!.display.player.nativeImages, isFalse);
    expect(tv!.display.player.imageVariant(), 'full');
  });
}
