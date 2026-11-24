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

  group('free space on the TV', () {
    // The TV has `free` bytes left; deleting a cached file gives its bytes
    // back, which is what the volume does too.
    late int otherAppsFree; // free space if the cache were empty
    late MediaCache tight;

    setUp(() {
      otherAppsFree = 1200; // cache plus free space together
      tight = MediaCache(
        dir: Directory('${tmp.path}/c'),
        capBytes: 100000, // the Pi allows far more than the TV has
        reserveBytes: 500,
        now: () => clock,
        freeBytes: () async {
          var used = 0;
          final d = Directory('${tmp.path}/c');
          if (d.existsSync()) {
            for (final f in d.listSync().whereType<File>()) {
              used += f.lengthSync();
            }
          }
          return otherAppsFree - used;
        },
      );
    });

    tearDown(() => tight.dispose());

    test(
      'the cache never eats into the TV reserve; the oldest goes first',
      () async {
        // budget = 1200 - 500 = 700 bytes: one 400 byte file fits, two do not.
        await tight.fetch(req('a.jpg'));
        clock = clock.add(const Duration(minutes: 1));
        await tight.fetch(req('b.jpg'));
        expect(await tight.lookup('a.jpg'), isNull);
        expect(await tight.lookup('b.jpg'), isNotNull);
        expect(await tight.usedBytes(), 400);
      },
    );

    test('a file that cannot fit even in an empty cache is streamed', () async {
      otherAppsFree = 800; // budget 300 bytes
      await expectLater(
        tight.fetch(req('a.jpg')),
        throwsA(isA<CacheTooLarge>()),
      );
      expect(await tight.usedBytes(), 0);
    });

    test(
      'trim at start gives the space back when the TV is already short',
      () async {
        // Filled while the TV had room, now the TV has less.
        otherAppsFree = 5000;
        await tight.fetch(req('a.jpg'));
        clock = clock.add(const Duration(minutes: 1));
        await tight.fetch(req('b.jpg'));
        expect(await tight.usedBytes(), 800);
        otherAppsFree = 1000; // budget 500: only one of the two stays
        await tight.trim();
        expect(await tight.lookup('a.jpg'), isNull);
        expect(await tight.usedBytes(), 400);
        otherAppsFree = 400; // below the reserve: nothing stays
        await tight.trim();
        expect(await tight.usedBytes(), 0);
      },
    );

    test('a file in use survives a trim', () async {
      otherAppsFree = 5000;
      await tight.fetch(req('a.jpg'));
      tight.pin('a.jpg');
      otherAppsFree = 100;
      await tight.trim();
      expect(await tight.lookup('a.jpg'), isNotNull);
      tight.unpin('a.jpg');
    });

    test(
      'without a free-space reading only the cap limits the cache',
      () async {
        final blind = MediaCache(
          dir: Directory('${tmp.path}/c'),
          capBytes: 1000,
          now: () => clock,
        );
        await blind.fetch(req('a.jpg'));
        await blind.fetch(req('b.jpg'));
        expect(await blind.usedBytes(), 800);
        await blind.dispose();
      },
    );
  });
}
