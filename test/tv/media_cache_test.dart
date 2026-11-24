import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tv_saver/tv/cache/media_cache.dart';

void main() {
  late Directory tmp;
  late HttpServer server;
  late MediaCache cache;
  late DateTime clock;
  final hits = <String>[];
  final bodies = <String, List<int>>{};
  Completer<void>? gate;

  Uri url(String name) => Uri.parse('http://127.0.0.1:${server.port}/$name');
  CacheRequest req(String name, {int? max}) => CacheRequest(
    key: name,
    url: url(name),
    headers: const {'Authorization': 'Bearer t'},
    maxBytes: max,
  );

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('cache');
    clock = DateTime.utc(2026, 11, 24, 12);
    hits.clear();
    bodies
      ..clear()
      ..['a.jpg'] = List.filled(400, 1)
      ..['b.jpg'] = List.filled(400, 2)
      ..['c.jpg'] = List.filled(400, 3)
      ..['big.mp4'] = List.filled(5000, 4);
    server = await HttpServer.bind('127.0.0.1', 0);
    server.listen((r) async {
      final name = r.uri.path.substring(1);
      hits.add('$name ${r.headers.value('authorization')}');
      await gate?.future;
      final body = bodies[name];
      if (body == null) {
        r.response.statusCode = 404;
      } else {
        r.response.contentLength = body.length;
        r.response.add(body);
      }
      await r.response.close();
    });
    cache = MediaCache(
      dir: Directory('${tmp.path}/c'),
      capBytes: 1000,
      now: () => clock,
    );
  });

  tearDown(() async {
    await cache.dispose();
    await server.close(force: true);
    tmp.deleteSync(recursive: true);
  });

  test(
    'downloads once with the bearer header, then serves from disk',
    () async {
      final f = await cache.fetch(req('a.jpg'));
      expect(f.lengthSync(), 400);
      await cache.fetch(req('a.jpg'));
      expect(hits, ['a.jpg Bearer t']);
      expect(await cache.lookup('a.jpg'), isNotNull);
      expect(await cache.lookup('nope.jpg'), isNull);
    },
  );

  test('two requests for one file share one download', () async {
    gate = Completer<void>();
    final a = cache.fetch(req('a.jpg'));
    final b = cache.fetch(req('a.jpg'));
    gate!.complete();
    await Future.wait([a, b]);
    gate = null;
    expect(hits, hasLength(1));
  });

  test('the least recently used file goes first when the cap is hit', () async {
    await cache.fetch(req('a.jpg'));
    clock = clock.add(const Duration(minutes: 1));
    await cache.fetch(req('b.jpg'));
    clock = clock.add(const Duration(minutes: 1));
    await cache.lookup('a.jpg'); // a was used last
    clock = clock.add(const Duration(minutes: 1));
    await cache.fetch(req('c.jpg')); // 1200 > 1000: b goes
    expect(await cache.lookup('b.jpg'), isNull);
    expect(await cache.lookup('a.jpg'), isNotNull);
    expect(await cache.lookup('c.jpg'), isNotNull);
    expect(await cache.usedBytes(), 800);
  });

  test('a file in use is never evicted', () async {
    await cache.fetch(req('a.jpg'));
    cache.pin('a.jpg');
    clock = clock.add(const Duration(minutes: 1));
    await cache.fetch(req('b.jpg'));
    clock = clock.add(const Duration(minutes: 1));
    await cache.fetch(req('c.jpg')); // wants a's room, but a is pinned
    expect(await cache.lookup('a.jpg'), isNotNull);
    cache.unpin('a.jpg');
  });

  test(
    'a file above the allowed size is refused before it downloads',
    () async {
      await expectLater(
        cache.fetch(req('big.mp4', max: 250)),
        throwsA(isA<CacheTooLarge>()),
      );
      await expectLater(
        cache.fetch(req('big.mp4')), // 5000 > the 1000 cap
        throwsA(isA<CacheTooLarge>()),
      );
      expect(await cache.usedBytes(), 0);
      expect(cache.maxStreamedItemBytes, 250);
    },
  );

  test('an error leaves no file behind', () async {
    await expectLater(
      cache.fetch(req('missing.jpg')),
      throwsA(isA<CacheHttpError>().having((e) => e.status, 'status', 404)),
    );
    final left = Directory('${tmp.path}/c').listSync();
    expect(left, isEmpty);
  });

  test('prefetch fetches in order and a newer list replaces the old', () async {
    gate = Completer<void>();
    cache.prefetch([req('a.jpg'), req('b.jpg')]);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    cache.prefetch([req('c.jpg')]); // replaces: b is never started
    gate!.complete();
    gate = null;
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(await cache.lookup('a.jpg'), isNotNull); // already running
    expect(await cache.lookup('c.jpg'), isNotNull);
    expect(await cache.lookup('b.jpg'), isNull);
  });

  test('leftover .part files are cleaned', () async {
    Directory('${tmp.path}/c').createSync();
    File('${tmp.path}/c/x.jpg.part').writeAsBytesSync([1]);
    await cache.cleanPartial();
    expect(File('${tmp.path}/c/x.jpg.part').existsSync(), isFalse);
  });
}
