import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tv_saver/tv/cache/media_cache.dart';
import 'package:tv_saver/tv/display/display_player.dart';

import 'package:tv_saver/tv/video_spike/spike_native.dart';

import 'support.dart';

void main() {
  late Directory tmp;
  late HttpServer server;
  late MediaCache cache;
  late FakeDisplayNative native;
  late DisplayPlayer player;
  final ended = <String>[];
  final positions = <PlayerSnapshot>[];
  final served = <String>[];
  final missing = <String>{};
  Completer<void>? gate;
  var variant = 'full';

  String url(String id) => 'http://127.0.0.1:${server.port}/media/$id/full';
  const headers = {'Authorization': 'Bearer t'};

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('dpm');
    ended.clear();
    positions.clear();
    served.clear();
    missing.clear();
    gate = null;
    variant = 'full';
    server = await HttpServer.bind('127.0.0.1', 0);
    server.listen((r) async {
      served.add(r.uri.path);
      await gate?.future;
      if (missing.any(r.uri.path.contains)) {
        r.response.statusCode = 404;
      } else {
        r.response.contentLength = 300;
        r.response.add(List.filled(300, 7));
      }
      await r.response.close();
    });
    cache = MediaCache(dir: Directory('${tmp.path}/c'), capBytes: 100000);
    native = FakeDisplayNative();
    player = DisplayPlayer(
      native: native,
      cache: cache,
      imageVariant: () => variant,
      reportEnded: (id) async {
        ended.add(id);
        return false;
      },
      reportPosition: positions.add,
      positionInterval: const Duration(milliseconds: 100),
      statsInterval: const Duration(milliseconds: 50),
      errorRetry: const Duration(milliseconds: 100),
      anchorDelay: const Duration(milliseconds: 50),
    );
    await player.viewCreated();
  });

  tearDown(() async {
    await player.dispose();
    await cache.dispose();
    await server.close(force: true);
    tmp.deleteSync(recursive: true);
  });

  Future<void> wait(int ms) => Future<void>.delayed(Duration(milliseconds: ms));

  Future<void> photo(String id, {int ms = 5000, int startAt = 0}) =>
      player.load(
        itemId: id,
        url: url(id),
        headers: headers,
        isImage: true,
        imageMs: ms,
        startAtMs: startAt,
      );

  test('a photo is shown from the cache and ends after its time', () async {
    await photo('p.jpg', ms: 300);
    final slot = player.image.value!;
    expect(slot.file.path, endsWith('p.jpg.full'));
    expect(slot.crossfade, isTrue);
    expect(native.calls, contains('release')); // the video view gives way
    expect(native.opens, isEmpty);
    expect(player.snapshot.durationMs, 300);
    expect(player.snapshot.state, 'playing');
    await wait(150);
    expect(ended, isEmpty);
    await wait(250);
    expect(ended, ['p.jpg']);
    // Without the Pi the photo starts again here.
    await wait(400);
    expect(ended.length, greaterThanOrEqualTo(2));
  });

  test('pause holds the clock, resume finishes the rest', () async {
    await photo('p.jpg', ms: 400);
    await wait(150);
    await player.control('pause');
    final held = (await player.freshSnapshot()).positionMs;
    expect(held, inInclusiveRange(100, 260));
    expect(player.snapshot.state, 'paused');
    await wait(500);
    expect(ended, isEmpty);
    expect((await player.freshSnapshot()).positionMs, held);
    await player.control('resume');
    await wait(100);
    expect(ended, isEmpty);
    await wait(350);
    expect(ended, ['p.jpg']);
  });

  test('seek moves the photo clock', () async {
    await photo('p.jpg');
    await player.control('seek', positionMs: 4900);
    await wait(250);
    expect(ended, ['p.jpg']);
  });

  test('startAt resumes a photo part way', () async {
    await photo('p.jpg', ms: 400, startAt: 300);
    await wait(250);
    expect(ended, ['p.jpg']);
  });

  test('stop clears the photo', () async {
    await photo('p.jpg');
    await player.control('stop');
    expect(player.image.value, isNull);
    expect(player.hasItem, isFalse);
  });

  test('a photo sends its position and duration like a clip', () async {
    await photo('p.jpg', ms: 2000);
    await wait(260);
    expect(positions, isNotEmpty);
    expect(positions.last.itemId, 'p.jpg');
    expect(positions.last.durationMs, 2000);
  });

  test(
    'the 1920 variant is asked for; the full photo serves when the Pi has none',
    () async {
      variant = '1920';
      missing.add('/1920');
      await photo('p.jpg');
      expect(served, ['/media/p.jpg/1920', '/media/p.jpg/full']);
      expect(player.image.value!.file.path, endsWith('p.jpg.full'));
    },
  );

  test('a newer photo wins over one still downloading', () async {
    gate = Completer<void>();
    final first = photo('a.jpg');
    await wait(50);
    final second = photo('b.jpg');
    gate!.complete();
    await Future.wait([first, second]);
    expect(player.image.value!.file.path, endsWith('b.jpg.full'));
    expect(player.itemId, 'b.jpg');
  });

  test('a photo that cannot be fetched is skipped after a moment', () async {
    missing.add('/media/');
    await photo('gone.jpg');
    expect(player.image.value, isNull);
    await wait(250);
    expect(ended, contains('gone.jpg'));
  });

  test('a clip that must be cached first plays from the file', () async {
    await player.load(
      itemId: 'v.mp4',
      url: url('v.mp4'),
      headers: headers,
      cacheRequired: true,
    );
    final open = native.opens.single;
    expect(open.url, startsWith('file:'));
    expect(open.url, endsWith('v.mp4.full'));
    expect(open.headers, isEmpty);
    expect(player.image.value, isNull);
  });

  test('a clip streams unless it is already cached', () async {
    await player.load(itemId: 'v.mp4', url: url('v.mp4'), headers: headers);
    expect(native.opens.last.url, url('v.mp4'));
    expect(native.opens.last.headers, headers);
    expect(served, isEmpty);
    await cache.fetch(
      CacheRequest(
        key: 'v.mp4.full',
        url: Uri.parse(url('v.mp4')),
        headers: headers,
      ),
    );
    await player.load(itemId: 'v.mp4', url: url('v.mp4'), headers: headers);
    expect(native.opens.last.url, startsWith('file:'));
  });

  test('a clip after a photo brings the photo down', () async {
    await photo('p.jpg');
    await player.load(itemId: 'v.mp4', url: url('v.mp4'), headers: headers);
    expect(player.image.value, isNull);
    expect(native.opens, hasLength(1));
  });

  test('a playlist of one clip repeats inside the player', () async {
    await player.load(
      itemId: 'v.mp4',
      url: url('v.mp4'),
      headers: headers,
      loop: true,
    );
    expect(native.opens.single.loop, isTrue);
    await player.load(itemId: 'w.mp4', url: url('w.mp4'), headers: headers);
    expect(native.opens.last.loop, isFalse);
  });

  test(
    'a playlist of one photo restarts its clock without asking the Pi',
    () async {
      await player.load(
        itemId: 'p.jpg',
        url: url('p.jpg'),
        headers: headers,
        isImage: true,
        imageMs: 150,
        loop: true,
      );
      await wait(500);
      expect(ended, isEmpty);
      expect(player.image.value, isNotNull);
      expect(player.snapshot.state, 'playing');
    },
  );

  test('the item info and the playing flag follow the player', () async {
    final seen = <bool>[];
    player.active.addListener(() => seen.add(player.active.value));
    await player.load(
      itemId: 'p.jpg',
      url: url('p.jpg'),
      headers: headers,
      isImage: true,
      info: const ItemInfo(name: 'Beach', index: 0, count: 3, isImage: true),
    );
    expect(player.info!.name, 'Beach');
    expect(player.active.value, isTrue);
    await player.control('pause');
    expect(player.active.value, isFalse);
    await player.control('stop');
    expect(player.info, isNull);
    expect(seen, isNotEmpty);
  });

  test('the position of a photo moves while it is shown', () async {
    await photo('p.jpg', ms: 5000);
    await wait(300);
    expect(player.snapshot.positionMs, greaterThan(200));
  });

  group('native 4K photos', () {
    setUp(() => player.nativeImages = true);

    test(
      'a photo is drawn on the video surface, not as a Flutter slide',
      () async {
        await photo('p.jpg', ms: 5000);
        final shown = native.shows.single;
        expect(shown.path, endsWith('p.jpg.full'));
        expect(shown.crossfadeMs, 800);
        expect(shown.kenBurns, isFalse);
        expect(shown.durationMs, 5000);
        expect(player.image.value, isNull);
        expect(player.snapshot.state, 'playing');
        expect(player.fromCache, isTrue);
      },
    );

    test(
      'a photo after a photo fades over it: the surface is not released',
      () async {
        await photo('a.jpg');
        native.calls.clear();
        await photo('b.jpg');
        expect(native.calls, isNot(contains('release')));
        expect(native.shows, hasLength(2));
        // A photo after a clip releases the player first.
        await player.load(itemId: 'v.mp4', url: url('v.mp4'), headers: headers);
        native.calls.clear();
        await photo('c.jpg');
        expect(native.calls.first, 'release');
      },
    );

    test('a cut and Ken Burns reach the native side', () async {
      await player.load(
        itemId: 'p.jpg',
        url: url('p.jpg'),
        headers: headers,
        isImage: true,
        imageMs: 4000,
        crossfade: false,
        kenBurns: true,
      );
      expect(native.shows.single.crossfadeMs, 0);
      expect(native.shows.single.kenBurns, isTrue);
    });

    test(
      'a TV that cannot draw natively falls back to the Flutter widget',
      () async {
        native.imageSupported = false;
        await photo('p.jpg');
        expect(native.shows, hasLength(1));
        expect(player.image.value, isNotNull);
      },
    );

    test('the clock, pause and the end work as for a Flutter photo', () async {
      await photo('p.jpg', ms: 400);
      await wait(150);
      await player.control('pause');
      await wait(500);
      expect(ended, isEmpty);
      await player.control('resume');
      await wait(450);
      expect(ended, ['p.jpg']);
    });

    test('the photo surface is wanted only while a photo shows', () async {
      expect(player.nativeImageActive.value, isFalse);
      await photo('p.jpg');
      expect(player.nativeImageActive.value, isTrue);
      // A menu closing and opening the video view does not redraw from Dart:
      // the native side redraws its own surface when it is created again.
      native.shows.clear();
      await player.viewDisposed();
      await player.viewCreated();
      expect(native.shows, isEmpty);
      expect(player.nativeImageActive.value, isTrue);
      // A clip takes it away and frees the photo.
      native.calls.clear();
      await player.load(itemId: 'v.mp4', url: url('v.mp4'), headers: headers);
      expect(player.nativeImageActive.value, isFalse);
      expect(native.calls, contains('clearImage'));
    });

    test('a TV that cannot draw natively never asks for the surface', () async {
      native.imageSupported = false;
      await photo('p.jpg');
      expect(player.nativeImageActive.value, isFalse);
    });

    test('stop frees the photo and the surface', () async {
      await photo('p.jpg');
      native.calls.clear();
      await player.control('stop');
      expect(native.calls, containsAll(['clearImage', 'release']));
      expect(player.nativeImageActive.value, isFalse);
      expect(player.hasItem, isFalse);
    });
  });

  group('changing between kinds', () {
    test('the first picture and a photo over a photo do not dip', () async {
      await photo('a.jpg');
      expect(player.changing.value, isFalse);
      var dipped = false;
      player.changing.addListener(() => dipped |= player.changing.value);
      await photo('b.jpg');
      expect(dipped, isFalse);
    });

    test(
      'a clip over a photo dips until the clip shows its first frame',
      () async {
        await photo('a.jpg');
        native.statsValue = const Media3Stats(); // position 0: not showing yet
        await player.load(itemId: 'v.mp4', url: url('v.mp4'), headers: headers);
        expect(player.changing.value, isTrue);
        native.statsValue = const Media3Stats(
          position: Duration(milliseconds: 80),
        );
        await player.freshSnapshot();
        expect(player.changing.value, isFalse);
      },
    );

    test(
      'a photo over a clip dips only until the photo is on screen',
      () async {
        native.statsValue = const Media3Stats(position: Duration(seconds: 1));
        await player.load(itemId: 'v.mp4', url: url('v.mp4'), headers: headers);
        final seen = <bool>[];
        player.changing.addListener(() => seen.add(player.changing.value));
        await photo('a.jpg');
        expect(seen, [true, false]);
        expect(player.changing.value, isFalse);
      },
    );

    test('a clip that fails, and stop, never leave the screen dark', () async {
      await photo('a.jpg');
      native.statsValue = const Media3Stats();
      await player.load(itemId: 'v.mp4', url: url('v.mp4'), headers: headers);
      expect(player.changing.value, isTrue);
      native.statsValue = const Media3Stats(error: 'boom');
      await player.freshSnapshot();
      expect(player.changing.value, isFalse);
      await player.load(itemId: 'w.mp4', url: url('w.mp4'), headers: headers);
      await player.control('stop');
      expect(player.changing.value, isFalse);
    });
  });
}
