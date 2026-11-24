import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' show Value;
import 'package:hub_core/hub_core.dart';
import 'package:sqlite3/sqlite3.dart' as sql;
import 'package:test/test.dart';

import 'support/fake_phone_harness.dart';
import 'support/limits.dart';

const staticToken = 'secret-token';

List<int> bytesOf(int n, [int seed = 7]) =>
    List.generate(n, (i) => (i * 31 + seed) % 251);

String shaOf(List<int> data) => sha256.convert(data).toString();

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

void main() {
  late Directory tmp;
  late String mediaDir;
  late PiServer server;
  late HttpClient client;
  late DateTime clock;
  HubDatabase? fileDb;
  var started = false;

  Future<void> startServer({
    int cap = 1 << 40,
    Future<int?> Function(String)? freeBytes,
    HubDatabase? db,
  }) async {
    final config = ServerConfig(
      mediaDir: mediaDir,
      tokenFile: '${tmp.path}/token',
      port: 0,
      serverId: 'test',
      storageCapBytes: cap,
    );
    final database = db ?? HubDatabase.inMemory();
    server = PiServer(
      config,
      staticToken,
      db: database,
      settingsLimits: openLimits,
      library: LibraryStore(
        config: config,
        db: database,
        now: () => clock,
        freeBytes: freeBytes,
        looseFileGrace: Duration.zero,
        reconcileInterval: Duration.zero,
      ),
    );
    await server.start(address: '127.0.0.1');
    started = true;
  }

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('hublib');
    mediaDir = '${tmp.path}/media';
    Directory(mediaDir).createSync();
    clock = DateTime.utc(2026, 11, 24, 12);
    client = HttpClient();
    fileDb = null;
    started = false;
  });

  tearDown(() async {
    client.close(force: true);
    if (started) await server.stop();
    await fileDb?.close();
    tmp.deleteSync(recursive: true);
  });

  Future<(HttpClientResponse, List<int>)> send(
    String method,
    String path, {
    Map<String, String> headers = const {},
    List<int>? body,
    String? bearer = staticToken,
  }) async {
    final req = await client.openUrl(
      method,
      Uri.parse('http://127.0.0.1:${server.port}$path'),
    );
    if (bearer != null) req.headers.set('Authorization', 'Bearer $bearer');
    headers.forEach(req.headers.set);
    if (body != null) {
      req.contentLength = body.length;
      req.add(body);
    }
    final res = await req.close();
    final out = await res.fold<List<int>>([], (a, b) => a..addAll(b));
    return (res, out);
  }

  Map<String, dynamic> asJson(List<int> body) =>
      jsonDecode(utf8.decode(body)) as Map<String, dynamic>;

  Future<(HttpClientResponse, Map<String, dynamic>)> startUpload(
    List<int> data, {
    String name = 'pic.jpg',
    String mime = 'image/jpeg',
    String? sha,
    int? bytes,
    String? bearer = staticToken,
  }) async {
    final (res, body) = await send(
      'POST',
      '/media/uploads',
      bearer: bearer,
      body: utf8.encode(
        jsonEncode({
          'name': name,
          'bytes': bytes ?? data.length,
          'sha256': sha ?? shaOf(data),
          'mime': mime,
        }),
      ),
    );
    return (res, body.isEmpty ? <String, dynamic>{} : asJson(body));
  }

  Future<(HttpClientResponse, List<int>)> putChunk(
    String uploadId,
    List<int> data,
    int start,
    int total, {
    String? bearer = staticToken,
  }) => send(
    'PUT',
    '/media/uploads/$uploadId',
    bearer: bearer,
    headers: {
      'Content-Range': 'bytes $start-${start + data.length - 1}/$total',
    },
    body: data,
  );

  Future<String> uploadAll(List<int> data, {String mime = 'image/jpeg'}) async {
    final (r, j) = await startUpload(data, mime: mime);
    expect(r.statusCode, 200);
    final (p, _) = await putChunk(
      j['uploadId'] as String,
      data,
      0,
      data.length,
    );
    expect(p.statusCode, 201);
    return '${shaOf(data).substring(0, 16)}.${mime == 'image/jpeg' ? 'jpg' : 'mp4'}';
  }

  Future<TestPhone> pairPhone() async {
    final p = await TestPhone.connect(server.port);
    server.hub.openPairingSession();
    await p.pairWithQr(server.hub.currentQrUri('127.0.0.1')!);
    server.hub.closePairingSession();
    addTearDown(p.close);
    return p;
  }

  group('uploads', () {
    test('new upload: chunks, 201, row, file, library.added', () async {
      await startServer();
      final phone = await pairPhone();
      final data = bytesOf(10000);
      final (r, j) = await startUpload(data);
      expect(r.statusCode, 200);
      expect(j['received'], 0);
      final id = j['uploadId'] as String;

      final (p1, b1) = await putChunk(id, data.sublist(0, 4000), 0, 10000);
      expect(p1.statusCode, 200);
      expect(asJson(b1)['received'], 4000);
      final (p2, b2) = await putChunk(id, data.sublist(4000), 4000, 10000);
      expect(p2.statusCode, 201);
      // The running hash verified it: the file was not read again.
      expect(server.library.diskHashes, 0);
      final done = asJson(b2);
      final sha = shaOf(data);
      expect(done['id'], '${sha.substring(0, 16)}.jpg');
      expect(done['name'], 'pic.jpg');
      expect(done['kind'], 'image');
      expect(done['bytes'], 10000);
      expect(done['sha256'], sha);

      expect(File('$mediaDir/${done['id']}').readAsBytesSync(), data);
      expect(File('$mediaDir/.uploads/$id.part').existsSync(), isFalse);
      expect(await server.db.allUploads(), isEmpty);
      expect((await server.db.libraryItem(done['id'] as String))!.bytes, 10000);
      final ev = await phone.expectEvent('library.added');
      expect((ev['data'] as Map)['id'], done['id']);

      final (g, body) = await send('GET', '/media/${done['id']}/full');
      expect(g.statusCode, 200);
      expect(body, data);
    });

    test('duplicate sha256 gets 409 with the id before any transfer', () async {
      await startServer();
      final data = bytesOf(500);
      final id = await uploadAll(data);
      final (r, j) = await startUpload(data, name: 'again.jpg');
      expect(r.statusCode, 409);
      expect(j['id'], id);
    });

    test('resume: HEAD offset, wrong offset 416, finish', () async {
      await startServer();
      final data = bytesOf(9000);
      final (_, j) = await startUpload(data);
      final id = j['uploadId'] as String;
      await putChunk(id, data.sublist(0, 3000), 0, 9000);

      final (h, _) = await send('HEAD', '/media/uploads/$id');
      expect(h.statusCode, 200);
      expect(h.headers.value('Upload-Offset'), '3000');

      final (bad, _) = await putChunk(id, data.sublist(5000, 6000), 5000, 9000);
      expect(bad.statusCode, 416);
      expect(bad.headers.value('Content-Range'), 'bytes */3000');

      // The same sha256 starts nothing new: it returns the unfinished upload.
      final (again, aj) = await startUpload(data);
      expect(again.statusCode, 200);
      expect(aj['uploadId'], id);
      expect(aj['received'], 3000);

      final (fin, _) = await putChunk(id, data.sublist(3000), 3000, 9000);
      expect(fin.statusCode, 201);
    });

    test('resume across a server restart', () async {
      fileDb = HubDatabase.open('${tmp.path}/hub.db');
      await startServer(db: fileDb);
      final data = bytesOf(9000);
      final (_, j) = await startUpload(data);
      final id = j['uploadId'] as String;
      await putChunk(id, data.sublist(0, 4000), 0, 9000);
      await server.stop();
      await fileDb!.close();

      fileDb = HubDatabase.open('${tmp.path}/hub.db');
      await startServer(db: fileDb);
      final (h, _) = await send('HEAD', '/media/uploads/$id');
      expect(h.headers.value('Upload-Offset'), '4000');
      final (fin, body) = await putChunk(id, data.sublist(4000), 4000, 9000);
      expect(fin.statusCode, 201, reason: utf8.decode(body));
      expect(asJson(body)['sha256'], shaOf(data));
      // The running hash did not survive the restart: one disk rehash.
      expect(server.library.diskHashes, 1);
    });

    test('bad checksum: partial deleted, 422', () async {
      await startServer();
      final data = bytesOf(2000);
      final (_, j) = await startUpload(data, sha: shaOf(bytesOf(2000, 9)));
      final id = j['uploadId'] as String;
      final (r, _) = await putChunk(id, data, 0, 2000);
      expect(r.statusCode, 422);
      expect(File('$mediaDir/.uploads/$id.part').existsSync(), isFalse);
      expect(await server.db.allUploads(), isEmpty);
      expect(await server.db.allLibraryItems(), isEmpty);
    });

    test(
      'limits: 413 above 80 MB image / 50 GB video, 415 for other mimes',
      () async {
        await startServer();
        final sha = shaOf(bytesOf(10));
        final (img, _) = await startUpload(
          const [],
          bytes: 80 * 1024 * 1024 + 1,
          sha: sha,
        );
        expect(img.statusCode, 413);
        final (okImg, _) = await startUpload(
          const [],
          bytes: 80 * 1024 * 1024,
          sha: sha,
        );
        expect(okImg.statusCode, 200);
        final (vid, _) = await startUpload(
          const [],
          bytes: 50 * 1024 * 1024 * 1024 + 1,
          sha: shaOf(bytesOf(11)),
          mime: 'video/mp4',
          name: 'a.mp4',
        );
        expect(vid.statusCode, 413);
        final (txt, _) = await startUpload(
          bytesOf(10),
          mime: 'application/pdf',
          name: 'a.pdf',
        );
        expect(txt.statusCode, 415);
        final (bad, _) = await send(
          'POST',
          '/media/uploads',
          body: utf8.encode('{"name": 1}'),
        );
        expect(bad.statusCode, 400);
      },
    );

    test('a chunk above 64 MB gets 413', () async {
      await startServer();
      final (_, j) = await startUpload(
        const [],
        bytes: 70 * 1024 * 1024,
        sha: shaOf(bytesOf(12)),
        mime: 'video/mp4',
        name: 'a.mp4',
      );
      final (r, _) = await send(
        'PUT',
        '/media/uploads/${j['uploadId']}',
        headers: {
          'Content-Range': 'bytes 0-${64 * 1024 * 1024}/${70 * 1024 * 1024}',
        },
        body: const [],
      );
      expect(r.statusCode, 413);
    });

    test('storage cap and free disk space: 507 full', () async {
      await startServer(cap: 3000);
      final first = bytesOf(2000);
      await uploadAll(first);
      final data = bytesOf(1500, 3);
      final (r, _) = await send(
        'POST',
        '/media/uploads',
        body: utf8.encode(
          jsonEncode({
            'name': 'b.jpg',
            'bytes': 1500,
            'sha256': shaOf(data),
            'mime': 'image/jpeg',
          }),
        ),
      );
      expect(r.statusCode, 507);
      final (_, body) = await send(
        'POST',
        '/media/uploads',
        body: utf8.encode(
          jsonEncode({
            'name': 'b.jpg',
            'bytes': 1500,
            'sha256': shaOf(data),
            'mime': 'image/jpeg',
          }),
        ),
      );
      final j = asJson(body);
      expect(j['code'], 'full');
      expect(j['usedBytes'], 2000);
      expect(j['capBytes'], 3000);
      expect(
        File('$mediaDir/${shaOf(first).substring(0, 16)}.jpg').existsSync(),
        isTrue,
      );

      await server.stop();
      await startServer(freeBytes: (_) async => 100);
      final (low, _) = await startUpload(data);
      expect(low.statusCode, 507);
    });

    test(
      'uploads older than 24 h are removed (start and hourly path)',
      () async {
        await startServer();
        final data = bytesOf(900);
        final (_, j) = await startUpload(data);
        final id = j['uploadId'] as String;
        await putChunk(id, data.sublist(0, 100), 0, 900);
        expect(File('$mediaDir/.uploads/$id.part').existsSync(), isTrue);

        clock = clock.add(const Duration(hours: 23));
        expect(await server.library.expireStaleUploads(), 0);
        clock = clock.add(const Duration(hours: 2));
        expect(await server.library.expireStaleUploads(), 1);
        expect(File('$mediaDir/.uploads/$id.part').existsSync(), isFalse);
        expect(await server.db.allUploads(), isEmpty);
        final (h, _) = await send('HEAD', '/media/uploads/$id');
        expect(h.statusCode, 404);
      },
    );

    test('auth: 401 without a token, 403 for a display', () async {
      await startServer();
      final (a, _) = await startUpload(bytesOf(10), bearer: null);
      expect(a.statusCode, 401);

      final tv = await TestPhone.connect(server.port);
      addTearDown(tv.close);
      await tv.helloAsDisplay();
      final (b, _) = await startUpload(bytesOf(10), bearer: tv.token);
      expect(b.statusCode, 403);
    });

    test('device tokens may upload and resume', () async {
      await startServer();
      final phone = await pairPhone();
      final data = bytesOf(600);
      final (r, j) = await startUpload(data, bearer: phone.token);
      expect(r.statusCode, 200);
      final up = await server.db.uploadById(j['uploadId'] as String);
      expect(up!.deviceId, phone.deviceId);
    });
  });

  group('delete and serving', () {
    test(
      'owner and static token delete; controller 403; unknown 404',
      () async {
        await startServer();
        final owner = await pairPhone();
        final controller = await pairPhone();
        final data = bytesOf(700);
        final id = await uploadAll(data);

        final (c, _) = await send(
          'DELETE',
          '/media/$id',
          bearer: controller.token,
        );
        expect(c.statusCode, 403);
        expect(File('$mediaDir/$id').existsSync(), isTrue);

        // A variant goes with it.
        Directory('$mediaDir/.variants').createSync();
        File('$mediaDir/.variants/$id.thumb').writeAsBytesSync([1]);
        File('$mediaDir/.variants/other.thumb').writeAsBytesSync([1]);

        final (o, _) = await send('DELETE', '/media/$id', bearer: owner.token);
        expect(o.statusCode, 200);
        final ev = await owner.expectEvent('library.removed');
        expect((ev['data'] as Map)['id'], id);
        expect(File('$mediaDir/$id').existsSync(), isFalse);
        expect(File('$mediaDir/.variants/$id.thumb').existsSync(), isFalse);
        expect(File('$mediaDir/.variants/other.thumb').existsSync(), isTrue);
        expect(await server.db.libraryItem(id), isNull);

        final (u, _) = await send('DELETE', '/media/$id');
        expect(u.statusCode, 404);

        final id2 = await uploadAll(bytesOf(300, 5));
        final (s, _) = await send('DELETE', '/media/$id2');
        expect(s.statusCode, 200);
      },
    );

    test('variants: 404 until the file exists, then Range works', () async {
      await startServer();
      final id = await uploadAll(bytesOf(800));
      for (final v in ['thumb', 'poster', '1920']) {
        final (r, _) = await send('GET', '/media/$id/$v');
        expect(r.statusCode, 404, reason: v);
      }
      final (bogus, _) = await send('GET', '/media/$id/huge');
      expect(bogus.statusCode, 404);

      Directory('$mediaDir/.variants').createSync();
      final thumb = [0xFF, 0xD8, ...bytesOf(200)];
      File('$mediaDir/.variants/$id.thumb').writeAsBytesSync(thumb);
      final (r, body) = await send(
        'GET',
        '/media/$id/thumb',
        headers: {'Range': 'bytes=10-19'},
      );
      expect(r.statusCode, 206);
      expect(r.headers.value('Content-Range'), 'bytes 10-19/${thumb.length}');
      expect(r.headers.contentType?.mimeType, 'image/jpeg');
      expect(body, thumb.sublist(10, 20));
    });
  });

  group('startup import and playlist', () {
    test('loose files become items; all lists the videos by name', () async {
      File('$mediaDir/b.mp4').writeAsBytesSync(bytesOf(40));
      File('$mediaDir/A.MP4').writeAsBytesSync(bytesOf(41));
      File('$mediaDir/c.mkv').writeAsBytesSync(bytesOf(42));
      File('$mediaDir/photo.jpg').writeAsBytesSync(bytesOf(43));
      File('$mediaDir/notes.txt').writeAsBytesSync(bytesOf(44));
      File('$mediaDir/big.bin').writeAsBytesSync(bytesOf(45));
      File('$mediaDir/.hidden.mp4').writeAsBytesSync(bytesOf(46));
      await startServer();

      final items = {
        for (final r in await server.db.allLibraryItems()) r.id: r,
      };
      expect(items.keys.toSet(), {'b.mp4', 'A.MP4', 'c.mkv', 'photo.jpg'});
      expect(items['photo.jpg']!.kind, 'image');
      expect(items['c.mkv']!.kind, 'video');
      expect(items['b.mp4']!.name, 'b.mp4');
      expect(items['b.mp4']!.bytes, 40);

      expect(await server.playlists.itemIds('all'), [
        'A.MP4',
        'b.mp4',
        'c.mkv',
      ]);
      expect(await server.playlists.itemIds('nope'), isNull);

      await server.library.hashingDone;
      final b = await server.db.libraryItem('b.mp4');
      expect(b!.sha256, shaOf(bytesOf(40)));
      // A finished import is not repeated; the same bytes are a duplicate.
      final (r, j) = await startUpload(
        bytesOf(40),
        mime: 'video/mp4',
        name: 'x.mp4',
      );
      expect(r.statusCode, 409);
      expect(j['id'], 'b.mp4');
    });

    test('a restart keeps rows and adds nothing twice', () async {
      File('$mediaDir/one.mp4').writeAsBytesSync(bytesOf(10));
      fileDb = HubDatabase.open('${tmp.path}/hub.db');
      await startServer(db: fileDb);
      await server.library.hashingDone;
      await server.stop();
      await fileDb!.close();
      fileDb = HubDatabase.open('${tmp.path}/hub.db');
      await startServer(db: fileDb);
      expect((await fileDb!.allLibraryItems()).length, 1);
      expect(await server.library.importLooseFiles(), 0);
    });
  });

  group('library module', () {
    test('exists, rename, delete, snapshot and events', () async {
      await startServer();
      final owner = await pairPhone();
      final controller = await pairPhone();
      final data = bytesOf(1234);
      final id = await uploadAll(data);

      final yes = await owner.request('library.exists', {
        'sha256': shaOf(data),
      });
      final y = yes['result'] as Map;
      expect(y['exists'], isTrue);
      expect(y['id'], id);
      final no = await owner.request('library.exists', {
        'sha256': shaOf(bytesOf(5)),
      });
      final n = no['result'] as Map;
      expect(n['exists'], isFalse);
      expect(n.containsKey('id'), isFalse);
      expect(
        (await owner.request('library.exists', {'sha256': 'zz'}))['code'],
        'invalid',
      );

      final renamed = await controller.request('library.rename', {
        'id': id,
        'name': '  Holiday  ',
      });
      expect(renamed['t'], HubMsg.ok);
      final upd = await owner.expectEvent('library.updated');
      expect((upd['data'] as Map)['name'], 'Holiday');
      expect(
        (await owner.request('library.rename', {
          'id': 'nope.jpg',
          'name': 'x',
        }))['code'],
        'not_found',
      );
      expect(
        (await owner.request('library.rename', {
          'id': id,
          'name': ' ',
        }))['code'],
        'invalid',
      );

      final seen = owner.receivedHistory
          .where((m) => m['t'] == HubMsg.snapshot)
          .length;
      owner.send(HubMsg.sync);
      await until(
        () =>
            owner.receivedHistory
                .where((m) => m['t'] == HubMsg.snapshot)
                .length >
            seen,
      );
      final snap = owner.receivedHistory.lastWhere(
        (m) => m['t'] == HubMsg.snapshot,
      );
      final lib = (snap['modules'] as Map)['library'] as Map;
      expect((lib['items'] as List).single['name'], 'Holiday');
      expect(lib['storage'], {'usedBytes': 1234, 'capBytes': 1 << 40});

      expect(
        (await controller.request('library.delete', {'id': id}))['code'],
        'forbidden',
      );
      final del = await owner.request('library.delete', {'id': id});
      expect(del['t'], HubMsg.ok);
      final rem = await controller.expectEvent('library.removed');
      expect((rem['data'] as Map)['id'], id);
      expect(File('$mediaDir/$id').existsSync(), isFalse);
      expect(
        (await owner.request('library.delete', {'id': id}))['code'],
        'not_found',
      );
    });
  });

  group('crash recovery and concurrency', () {
    Future<String> craftUpload(
      List<int> data, {
      required List<int> partContent,
      required int received,
    }) async {
      final id = 'crafted${shaOf(data).substring(0, 6)}';
      Directory('$mediaDir/.uploads').createSync(recursive: true);
      File('$mediaDir/.uploads/$id.part').writeAsBytesSync(partContent);
      await server.db.insertUpload(
        UploadsCompanion.insert(
          id: id,
          name: 'crafted.jpg',
          bytes: data.length,
          sha256: shaOf(data),
          mime: 'image/jpeg',
          received: Value(received),
          createdAt: clock.millisecondsSinceEpoch,
        ),
      );
      return id;
    }

    test('row complete with a full part file: 409 {id}, file, added', () async {
      await startServer();
      final phone = await pairPhone();
      final data = bytesOf(3000);
      final id = await craftUpload(
        data,
        partContent: data,
        received: data.length,
      );
      final (r, j) = await startUpload(data);
      final itemId = '${shaOf(data).substring(0, 16)}.jpg';
      expect(r.statusCode, 409);
      expect(j['id'], itemId);
      expect(File('$mediaDir/$itemId').readAsBytesSync(), data);
      expect(File('$mediaDir/.uploads/$id.part').existsSync(), isFalse);
      expect(await server.db.uploadById(id), isNull);
      final ev = await phone.expectEvent('library.added');
      expect((ev['data'] as Map)['id'], itemId);
    });

    test(
      'row complete with wrong content: 422, part and row removed',
      () async {
        await startServer();
        final data = bytesOf(3000);
        final id = await craftUpload(
          data,
          partContent: bytesOf(3000, 99),
          received: data.length,
        );
        final (r, _) = await startUpload(data);
        expect(r.statusCode, 422);
        expect(File('$mediaDir/.uploads/$id.part').existsSync(), isFalse);
        expect(await server.db.uploadById(id), isNull);
        expect(await server.db.allLibraryItems(), isEmpty);
      },
    );

    test(
      'part file longer or shorter than received: HEAD corrects it',
      () async {
        await startServer();
        final data = bytesOf(3000);
        final id = await craftUpload(
          data,
          partContent: data.sublist(0, 2000),
          received: 1000,
        );
        var (h, _) = await send('HEAD', '/media/uploads/$id');
        expect(h.headers.value('Upload-Offset'), '1000');
        expect(File('$mediaDir/.uploads/$id.part').lengthSync(), 1000);

        File(
          '$mediaDir/.uploads/$id.part',
        ).writeAsBytesSync(data.sublist(0, 400));
        (h, _) = await send('HEAD', '/media/uploads/$id');
        expect(h.headers.value('Upload-Offset'), '400');
        expect((await server.db.uploadById(id))!.received, 400);
      },
    );

    test(
      'final file present but the part file gone is recovered at start',
      () async {
        fileDb = HubDatabase.open('${tmp.path}/hub.db');
        await startServer(db: fileDb);
        final data = bytesOf(2500);
        final id = await craftUpload(
          data,
          partContent: data,
          received: data.length,
        );
        await server.stop();
        started = false;
        final itemId = '${shaOf(data).substring(0, 16)}.jpg';
        File('$mediaDir/.uploads/$id.part').renameSync('$mediaDir/$itemId');
        await startServer(db: fileDb);
        expect((await fileDb!.libraryItem(itemId))!.sha256, shaOf(data));
        expect(await fileDb!.allUploads(), isEmpty);
      },
    );

    test('an id collision with a file without a row is refused', () async {
      await startServer();
      final data = bytesOf(800);
      File(
        '$mediaDir/${shaOf(data).substring(0, 16)}.jpg',
      ).writeAsBytesSync([1]);
      final (_, j) = await startUpload(data);
      final (r, body) = await putChunk(j['uploadId'] as String, data, 0, 800);
      expect(r.statusCode, 409);
      expect(asJson(body)['code'], 'collision');
      expect(await server.db.allUploads(), isEmpty);
    });

    test('parallel starts: one upload per sha, and the cap holds', () async {
      await startServer(cap: 1500);
      final data = bytesOf(1000);
      final both = await Future.wait([startUpload(data), startUpload(data)]);
      expect(both[0].$2['uploadId'], both[1].$2['uploadId']);
      expect(await server.db.allUploads(), hasLength(1));

      final other = bytesOf(1000, 4);
      final (r, _) = await startUpload(other);
      expect(r.statusCode, 507); // 1000 reserved by the first upload
    });

    test('part files without a row: kept for an hour, then removed', () async {
      await startServer();
      File('$mediaDir/.uploads/fresh.part').writeAsBytesSync([1]);
      File('$mediaDir/.uploads/old.part').writeAsBytesSync([1]);
      File(
        '$mediaDir/.uploads/old.part',
      ).setLastModifiedSync(DateTime.utc(2020));
      await server.library.expireStaleUploads();
      expect(File('$mediaDir/.uploads/fresh.part').existsSync(), isTrue);
      expect(File('$mediaDir/.uploads/old.part').existsSync(), isFalse);
    });

    test(
      'mime parameters are ignored; dot ids and big bodies are refused',
      () async {
        await startServer();
        final data = bytesOf(100);
        final (r, _) = await startUpload(data, mime: ' Image/JPEG; charset=x ');
        expect(r.statusCode, 200);
        final (d, _) = await send('GET', '/media/.hidden/full');
        expect(d.statusCode, 400);
        final (big, _) = await send(
          'POST',
          '/media/uploads',
          body: List.filled(70 * 1024, 32),
        );
        expect(big.statusCode, 413);
      },
    );
  });

  group('reconcile', () {
    test('files added or removed by hand show up in all', () async {
      File('$mediaDir/a.mp4').writeAsBytesSync(bytesOf(10));
      await startServer();
      final phone = await pairPhone();
      expect(await server.playlists.itemIds('all'), ['a.mp4']);
      File('$mediaDir/b.mp4').writeAsBytesSync(bytesOf(11));
      expect(await server.playlists.itemIds('all'), ['a.mp4', 'b.mp4']);
      File('$mediaDir/a.mp4').deleteSync();
      expect(await server.playlists.itemIds('all'), ['b.mp4']);
      expect(await server.db.libraryItem('a.mp4'), isNull);
      final ev = await phone.expectEvent('library.removed');
      expect((ev['data'] as Map)['id'], 'a.mp4');
    });

    test('a recent file waits for the grace period', () async {
      final config = ServerConfig(
        mediaDir: mediaDir,
        tokenFile: '${tmp.path}/token',
        port: 0,
      );
      final db = HubDatabase.inMemory();
      addTearDown(db.close);
      final store = LibraryStore(config: config, db: db);
      File('$mediaDir/new.mp4').writeAsBytesSync([1]);
      expect(await store.importLooseFiles(), 0);
      File('$mediaDir/new.mp4').setLastModifiedSync(
        DateTime.now().subtract(const Duration(minutes: 1)),
      );
      expect(await store.importLooseFiles(), 1);
      await store.stop();
    });

    test(
      'a duplicate loose file is marked once; an unreadable one does not stop the rest',
      () async {
        final data = bytesOf(60);
        File('$mediaDir/one.mp4').writeAsBytesSync(data);
        File('$mediaDir/two.mp4').writeAsBytesSync(data);
        File('$mediaDir/zlast.mp4').writeAsBytesSync(bytesOf(61));
        Directory('$mediaDir/bad.mp4').createSync();
        final db = HubDatabase.inMemory();
        addTearDown(db.close);
        await db.insertLibraryItem(
          LibraryItemsCompanion.insert(
            id: 'bad.mp4',
            kind: 'video',
            name: 'bad.mp4',
            sha256: 'pending:bad.mp4',
            bytes: 1,
            createdAt: 1,
          ),
        );
        await startServer(db: db);
        await server.library.hashingDone;
        final rows = {
          for (final r in await db.allLibraryItems()) r.id: r.sha256,
        };
        expect(rows['zlast.mp4'], shaOf(bytesOf(61)));
        expect(rows['bad.mp4'], 'pending:bad.mp4');
        final marked = rows.entries.where((e) => e.value.startsWith('dup:'));
        expect(marked, hasLength(1));
        expect(await db.pendingLibraryItems(), hasLength(1)); // only bad.mp4
      },
    );
  });

  group('delete and the player', () {
    test(
      'deleting the playing item moves on; the last one goes idle',
      () async {
        File('$mediaDir/a.mp4').writeAsBytesSync(bytesOf(10));
        File('$mediaDir/b.mp4').writeAsBytesSync(bytesOf(11));
        await startServer();
        final tv = await TestPhone.connect(server.port);
        addTearDown(tv.close);
        await tv.helloAsDisplay();
        final phone = await pairPhone();
        final play = await phone.request('player.play', {'playlistId': 'all'});
        expect(play['t'], HubMsg.ok, reason: '$play');
        final first = await tv.waitFor((m) => m['t'] == 'display.load');
        expect(first['itemId'], 'a.mp4');

        final (d, _) = await send('DELETE', '/media/a.mp4');
        expect(d.statusCode, 200);
        final next = await tv.waitFor(
          (m) => m['t'] == 'display.load' && m['itemId'] == 'b.mp4',
        );
        expect(next['startAt'], 0);

        final (d2, _) = await send('DELETE', '/media/b.mp4');
        expect(d2.statusCode, 200);
        final stop = await tv.waitFor(
          (m) => m['t'] == 'display.control' && m['action'] == 'stop',
        );
        expect(stop['action'], 'stop');
      },
    );

    test(
      'display is owner-equivalent for delete; a controller is not',
      () async {
        await startServer();
        final tv = await TestPhone.connect(server.port);
        addTearDown(tv.close);
        await tv.helloAsDisplay();
        await pairPhone();
        final controller = await pairPhone();
        final id1 = await uploadAll(bytesOf(300, 1));
        final id2 = await uploadAll(bytesOf(300, 2));
        final (c, _) = await send(
          'DELETE',
          '/media/$id1',
          bearer: controller.token,
        );
        expect(c.statusCode, 403);
        final (d, _) = await send('DELETE', '/media/$id1', bearer: tv.token);
        expect(d.statusCode, 200);
        final denied = await controller.request('library.delete', {'id': id2});
        expect(denied['code'], 'forbidden');
        final viaWs = await tv.request('library.delete', {'id': id2});
        expect(viaWs['t'], HubMsg.ok, reason: '$viaWs');
      },
    );
  });

  group('config', () {
    test('TVSAVER_STORAGE_CAP_BYTES: positive integers only', () {
      int cap(String? v) => ServerConfig.fromEnvironment({
        'HOME': '/h',
        'TVSAVER_STORAGE_CAP_BYTES': ?v,
      }).storageCapBytes;
      expect(cap(null), 90000000000);
      expect(cap('5000000000'), 5000000000);
      expect(cap('0'), 90000000000);
      expect(cap('-4'), 90000000000);
      expect(cap('lots'), 90000000000);
      expect(cap(''), 90000000000);
    });
  });

  group('database upgrade', () {
    test(
      'version 1 file keeps devices and pairings and gains the tables',
      () async {
        final path = '${tmp.path}/v1.db';
        final raw = sql.sqlite3.open(path);
        raw.execute('''
        CREATE TABLE devices (id TEXT NOT NULL, name TEXT NOT NULL,
          role TEXT NOT NULL, created_at INTEGER NOT NULL, PRIMARY KEY (id));
        CREATE TABLE pairings (token_hash TEXT NOT NULL,
          device_id TEXT NOT NULL REFERENCES devices (id) ON DELETE CASCADE,
          client_name TEXT NOT NULL, created_at INTEGER NOT NULL,
          last_seen_at INTEGER NOT NULL, PRIMARY KEY (token_hash));
        INSERT INTO devices VALUES ('d1', 'Kay phone', 'owner', 1);
        INSERT INTO devices VALUES ('tv', 'TV', 'display', 2);
        INSERT INTO pairings VALUES ('${hashToken('rawtoken')}', 'd1', 'Kay', 1, 1);
        PRAGMA user_version = 1;
      ''');
        raw.dispose();

        final db = HubDatabase.open(path);
        addTearDown(db.close);
        expect((await db.allDevices()).map((d) => d.id), ['d1', 'tv']);
        expect((await db.verifyRawToken('rawtoken'))!.deviceId, 'd1');
        expect(await db.allLibraryItems(), isEmpty);
        expect(await db.allUploads(), isEmpty);
        await db.insertLibraryItem(
          LibraryItemsCompanion.insert(
            id: 'a.mp4',
            kind: 'video',
            name: 'a.mp4',
            sha256: 'x',
            bytes: 1,
            createdAt: 1,
          ),
        );
        final v = await db.customSelect('PRAGMA user_version').getSingle();
        expect(v.read<int>('user_version'), 4);
      },
    );
  });
}
