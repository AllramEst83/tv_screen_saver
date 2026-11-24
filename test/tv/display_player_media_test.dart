import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tv_saver/tv/cache/media_cache.dart';
import 'package:tv_saver/tv/display/display_player.dart';

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
}
