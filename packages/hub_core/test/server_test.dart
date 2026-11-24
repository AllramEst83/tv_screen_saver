import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:hub_core/hub_core.dart';
import 'package:test/test.dart';

import 'support/fake_phone_harness.dart';

void main() {
  late Directory tmp;
  late PiServer server;
  late HttpClient client;
  late List<int> data;
  const token = 'secret-token';

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('hubcore');
    data = List.generate(1000, (i) => i % 251);
    File('${tmp.path}/clip').writeAsBytesSync(data);
    File('${tmp.path}/pic.png').writeAsBytesSync([1, 2, 3]);
    File('${tmp.path}/empty').writeAsBytesSync([]);
    Directory('${tmp.path}/adir').createSync();
    server = PiServer(
      ServerConfig(
        mediaDir: tmp.path,
        tokenFile: '${tmp.path}/token',
        port: 0,
        serverId: 'test',
      ),
      token,
    );
    await server.start(address: '127.0.0.1');
    client = HttpClient();
  });

  tearDown(() async {
    client.close(force: true);
    await server.stop();
    tmp.deleteSync(recursive: true);
  });

  Future<(HttpClientResponse, List<int>)> send(
    String method,
    String path, {
    Map<String, String> headers = const {},
    bool auth = true,
  }) async {
    final req = await client.openUrl(
      method,
      Uri.parse('http://127.0.0.1:${server.port}$path'),
    );
    if (auth) req.headers.set('Authorization', 'Bearer $token');
    headers.forEach(req.headers.set);
    final res = await req.close();
    final body = await res.fold<List<int>>([], (a, b) => a..addAll(b));
    return (res, body);
  }

  Future<String> raw(String requestLine) async {
    final s = await Socket.connect('127.0.0.1', server.port);
    s.write(
      '$requestLine HTTP/1.1\r\nHost: x\r\n'
      'Authorization: Bearer $token\r\nConnection: close\r\n\r\n',
    );
    final out = await utf8.decoder.bind(s).join();
    return out.split('\r\n').first;
  }

  test('health needs no auth', () async {
    final (res, body) = await send('GET', '/health', auth: false);
    expect(res.statusCode, 200);
    final j = jsonDecode(utf8.decode(body)) as Map;
    expect(j, {'ok': true, 'id': 'test', 'v': 1, 'clients': 0});

    final (headRes, headBody) = await send('HEAD', '/health', auth: false);
    expect(headRes.statusCode, 200);
    expect(headRes.contentLength, body.length);
    expect(headBody, isEmpty);
  });

  test('405 for unsupported methods on health and media', () async {
    expect((await send('POST', '/health', auth: false)).$1.statusCode, 405);
    expect((await send('PUT', '/health', auth: false)).$1.statusCode, 405);
    expect((await send('POST', '/media/clip/full')).$1.statusCode, 405);
    expect((await send('PUT', '/media/clip/full')).$1.statusCode, 405);
    expect((await send('DELETE', '/media/clip/full')).$1.statusCode, 405);
  });

  test(
    'no or wrong token gives 401; Bearer scheme is case-insensitive',
    () async {
      expect(
        (await send('GET', '/media/clip/full', auth: false)).$1.statusCode,
        401,
      );
      expect(
        (await send(
          'GET',
          '/media/clip/full',
          headers: {'Authorization': 'Bearer nope'},
        )).$1.statusCode,
        401,
      );
      expect((await send('GET', '/other', auth: false)).$1.statusCode, 401);
      expect(
        (await send(
          'GET',
          '/media/clip/full',
          auth: false,
          headers: {'Authorization': 'bearer $token'},
        )).$1.statusCode,
        200,
      );
      expect(
        (await send(
          'GET',
          '/media/clip/full',
          auth: false,
          headers: {'Authorization': 'BEARER $token'},
        )).$1.statusCode,
        200,
      );
    },
  );

  test('full file', () async {
    final (res, body) = await send('GET', '/media/clip/full');
    expect(res.statusCode, 200);
    expect(res.contentLength, 1000);
    expect(res.headers.value('accept-ranges'), 'bytes');
    expect(body, data);
  });

  test(
    'range middle, single byte, case-insensitive unit, open-ended, suffix, clamped end',
    () async {
      var (res, body) = await send(
        'GET',
        '/media/clip/full',
        headers: {'Range': 'bytes=100-199'},
      );
      expect(res.statusCode, 206);
      expect(res.headers.value('content-range'), 'bytes 100-199/1000');
      expect(body, data.sublist(100, 200));

      (res, body) = await send(
        'GET',
        '/media/clip/full',
        headers: {'Range': 'bytes=0-0'},
      );
      expect(res.statusCode, 206);
      expect(res.headers.value('content-range'), 'bytes 0-0/1000');
      expect(body, data.sublist(0, 1));

      (res, body) = await send(
        'GET',
        '/media/clip/full',
        headers: {'Range': 'Bytes=10-19'},
      );
      expect(res.statusCode, 206);
      expect(res.headers.value('content-range'), 'bytes 10-19/1000');
      expect(body, data.sublist(10, 20));

      (res, body) = await send(
        'GET',
        '/media/clip/full',
        headers: {'Range': 'bytes=500-'},
      );
      expect(res.statusCode, 206);
      expect(res.headers.value('content-range'), 'bytes 500-999/1000');
      expect(body, data.sublist(500));

      (res, body) = await send(
        'GET',
        '/media/clip/full',
        headers: {'Range': 'bytes=-100'},
      );
      expect(res.statusCode, 206);
      expect(res.headers.value('content-range'), 'bytes 900-999/1000');
      expect(body, data.sublist(900));

      (res, body) = await send(
        'GET',
        '/media/clip/full',
        headers: {'Range': 'bytes=-5000'},
      );
      expect(res.statusCode, 206);
      expect(res.headers.value('content-range'), 'bytes 0-999/1000');
      expect(body, data);

      (res, body) = await send(
        'GET',
        '/media/clip/full',
        headers: {'Range': 'bytes=-99999999999999999999'},
      );
      expect(res.statusCode, 206);
      expect(res.headers.value('content-range'), 'bytes 0-999/1000');
      expect(body, data);

      (res, body) = await send(
        'GET',
        '/media/clip/full',
        headers: {'Range': 'bytes=990-5000'},
      );
      expect(res.statusCode, 206);
      expect(res.headers.value('content-range'), 'bytes 990-999/1000');
      expect(body, data.sublist(990));

      (res, body) = await send(
        'GET',
        '/media/clip/full',
        headers: {'Range': 'bytes=990-99999999999999999999'},
      );
      expect(res.statusCode, 206);
      expect(res.headers.value('content-range'), 'bytes 990-999/1000');
      expect(body, data.sublist(990));
    },
  );

  test('unsatisfiable gives 416', () async {
    for (final r in ['bytes=1000-', 'bytes=2000-3000', 'bytes=-0']) {
      final (res, _) = await send(
        'GET',
        '/media/clip/full',
        headers: {'Range': r},
      );
      expect(res.statusCode, 416, reason: r);
      expect(res.headers.value('content-range'), 'bytes */1000');
    }
  });

  test('multi-range is ignored: full 200', () async {
    final (res, body) = await send(
      'GET',
      '/media/clip/full',
      headers: {'Range': 'bytes=0-1,5-6'},
    );
    expect(res.statusCode, 200);
    expect(body, data);
  });

  test('HEAD matches GET headers without a body', () async {
    var (res, body) = await send('HEAD', '/media/clip/full');
    expect(res.statusCode, 200);
    expect(res.contentLength, 1000);
    expect(body, isEmpty);
    (res, body) = await send(
      'HEAD',
      '/media/clip/full',
      headers: {'Range': 'bytes=10-19'},
    );
    expect(res.statusCode, 206);
    expect(res.contentLength, 10);
    expect(res.headers.value('content-range'), 'bytes 10-19/1000');
    expect(body, isEmpty);
  });

  test('content type from extension', () async {
    final (res, _) = await send('GET', '/media/pic.png/full');
    expect(res.headers.contentType?.mimeType, 'image/png');
    final (res2, _) = await send('GET', '/media/clip/full');
    expect(res2.headers.contentType?.mimeType, 'application/octet-stream');
  });

  test('missing, directory, symlink, other variant', () async {
    expect((await send('GET', '/media/nope/full')).$1.statusCode, 404);
    expect((await send('GET', '/media/adir/full')).$1.statusCode, 404);
    expect((await send('GET', '/media/clip/thumb')).$1.statusCode, 404);

    final outside = File('${tmp.path}/outside_secret.txt')
      ..writeAsStringSync('secret');
    final link = Link('${tmp.path}/escape.txt');
    var created = false;
    try {
      link.createSync(outside.path);
      created = true;
    } on FileSystemException {
      // Unprivileged Windows without Developer Mode cannot create symlinks.
    }
    if (created) {
      expect((await send('GET', '/media/escape.txt/full')).$1.statusCode, 404);
    }
  });

  test('bad ids and traversal are rejected', () async {
    expect(
      await raw('GET /media/../x/full'),
      anyOf(contains(' 400'), contains(' 404')),
    ); // dart normalizes dot segments
    expect(
      await raw('GET /media/%2e%2e/full'),
      anyOf(contains(' 400'), contains(' 404')),
    );
    expect(await raw('GET /media/a%2Fb/full'), contains(' 400'));
    expect(await raw('GET /media/a%5Cb/full'), contains(' 400'));
    expect(await raw('GET /media/a/b/full'), contains(' 404'));
    expect(await raw('GET /media/a%20b/full'), contains(' 400'));
  });

  test('empty file', () async {
    final (res, body) = await send('GET', '/media/empty/full');
    expect(res.statusCode, 200);
    expect(body, isEmpty);
    final (res2, _) = await send(
      'GET',
      '/media/empty/full',
      headers: {'Range': 'bytes=0-'},
    );
    expect(res2.statusCode, 416);
  });

  test('client abort mid-stream keeps the server running', () async {
    final big = File('${tmp.path}/big')
      ..writeAsBytesSync(List.filled(20 << 20, 7));
    expect(big.existsSync(), isTrue);
    final s = await Socket.connect('127.0.0.1', server.port);
    s.write(
      'GET /media/big/full HTTP/1.1\r\nHost: x\r\n'
      'Authorization: Bearer $token\r\n\r\n',
    );
    await s.first;
    s.destroy();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final (res, _) = await send('GET', '/health', auth: false);
    expect(res.statusCode, 200);
  });

  group('parseRange', () {
    test('invalid syntax is ignored', () {
      expect(parseRange('bytes=abc', 10), isA<FullRange>());
      expect(parseRange('items=0-1', 10), isA<FullRange>());
      expect(parseRange('bytes=5-2', 10), isA<FullRange>());
      expect(parseRange(null, 10), isA<FullRange>());
    });

    test('huge suffix returns whole file and huge start is unsatisfiable', () {
      final suffix = parseRange('bytes=-99999999999999999999999', 10);
      expect(suffix, isA<SingleRange>());
      expect((suffix as SingleRange).start, 0);
      expect(suffix.end, 9);

      expect(
        parseRange('bytes=99999999999999999999999-', 10),
        isA<UnsatisfiableRange>(),
      );
      expect(
        parseRange('bytes=-00000000000000000000', 10),
        isA<UnsatisfiableRange>(),
      );
    });
  });

  group('contentTypeFor', () {
    test('maps video, image and fallback extensions', () {
      expect(contentTypeFor('a.mp4'), 'video/mp4');
      expect(contentTypeFor('a.M4V'), 'video/mp4');
      expect(contentTypeFor('a.mkv'), 'video/x-matroska');
      expect(contentTypeFor('a.mov'), 'video/quicktime');
      expect(contentTypeFor('a.webm'), 'video/webm');
      expect(contentTypeFor('a.jpg'), 'image/jpeg');
      expect(contentTypeFor('a.JPEG'), 'image/jpeg');
      expect(contentTypeFor('a.png'), 'image/png');
      expect(contentTypeFor('a.webp'), 'image/webp');
      expect(contentTypeFor('a.gif'), 'image/gif');
      expect(contentTypeFor('a.avif'), 'image/avif');
      expect(contentTypeFor('a.heic'), 'image/heic');
      expect(contentTypeFor('a.heif'), 'image/heif');
      expect(contentTypeFor('noext'), 'application/octet-stream');
      expect(contentTypeFor('a.bin'), 'application/octet-stream');
    });
  });

  group('ServerConfig.fromEnvironment', () {
    test('uses HOME defaults and respects overrides', () {
      final def = ServerConfig.fromEnvironment({'HOME': '/home/pi'});
      expect(def.mediaDir, '/home/pi/tvsaver/media');
      expect(def.tokenFile, '/home/pi/.config/tvsaver/token');
      expect(def.port, 8772);
      expect(def.dbFile, '/home/pi/tvsaver/hub.db');
      expect(
        ServerConfig.fromEnvironment({
          'HOME': '/h',
          'TVSAVER_DB_FILE': '',
        }).dbFile,
        '/h/tvsaver/hub.db',
      );
      expect(def.serverId, Platform.localHostname);

      final custom = ServerConfig.fromEnvironment({
        'HOME': '/home/pi',
        'TVSAVER_MEDIA_DIR': '/srv/media',
        'TVSAVER_TOKEN_FILE': '/etc/tvsaver/tok',
        'TVSAVER_PORT': '9000',
        'TVSAVER_ID': 'hub-1',
        'TVSAVER_DB_FILE': '/var/db/hub.db',
      });
      expect(custom.dbFile, '/var/db/hub.db');
      expect(custom.mediaDir, '/srv/media');
      expect(custom.tokenFile, '/etc/tvsaver/tok');
      expect(custom.port, 9000);
      expect(custom.serverId, 'hub-1');
    });
  });

  group('token file', () {
    test('created once with 64 hex chars and reused', () {
      final p = '${tmp.path}/sub/token';
      final t = loadOrCreateToken(p);
      expect(t, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(loadOrCreateToken(p), t);
      if (!Platform.isWindows) {
        expect(File(p).statSync().mode & 0x1ff, 384); // 0600
      }
    });
  });

  test('HubServer transport and media share one port', () async {
    final db = server.db;
    await db.insertDevice(id: 'd1', name: 'Phone', role: 'owner', nowMs: 1);
    await db.insertPairing(
      rawToken: 'raw-tok',
      deviceId: 'd1',
      clientName: 'p',
      nowMs: 1,
    );
    final ws = await WebSocket.connect('ws://127.0.0.1:${server.port}/ws');
    addTearDown(() => ws.close());
    final frames = StreamIterator(
      ws.map((d) => jsonDecode(d as String) as Map<String, dynamic>),
    );
    ws.add(
      encodeFrame(HubMsg.hello, {
        'v': kProtocolVersion,
        'client': 'T',
        'token': 'raw-tok',
      }),
    );
    var ready = false;
    while (!ready &&
        await frames.moveNext().timeout(const Duration(seconds: 3))) {
      ready = frames.current['t'] == HubMsg.ready;
    }
    expect(ready, isTrue);

    final (res, body) = await send('GET', '/media/clip/full');
    expect(res.statusCode, 200);
    expect(body, data);
    final (_, hbody) = await send('GET', '/health', auth: false);
    expect(jsonDecode(utf8.decode(hbody))['clients'], greaterThan(0));
  });

  test('PiServer on a busy port throws SocketException', () async {
    final second = PiServer(
      ServerConfig(
        mediaDir: tmp.path,
        tokenFile: '${tmp.path}/token',
        port: server.port,
        serverId: 'x',
      ),
      token,
    );
    await expectLater(
      second.start(address: '127.0.0.1'),
      throwsA(isA<SocketException>()),
    );
    expect(second.port, 0);
    await second.stop(); // safe after a failed start
    expect(PiServer(second.config, token).port, 0);
  });

  test('HubDatabase.open persists across reopen and creates parents', () async {
    final path = '${tmp.path}/sub/hub.db';
    var db = HubDatabase.open(path);
    await db.insertDevice(id: 'd1', name: 'P', role: 'owner', nowMs: 1);
    await db.insertPairing(
      rawToken: 'r',
      deviceId: 'd1',
      clientName: 'c',
      nowMs: 1,
    );
    await db.close();
    db = HubDatabase.open(path);
    expect((await db.allDevices()).map((d) => d.id), ['d1']);
    expect((await db.allPairings()).length, 1);
    await db.close();
    if (!Platform.isWindows) {
      expect(File(path).statSync().mode & 0x1ff, 384);
    }
  });

  test('constantTimeEquals', () {
    expect(constantTimeEquals('abc', 'abc'), isTrue);
    expect(constantTimeEquals('abc', 'abd'), isFalse);
    expect(constantTimeEquals('abc', 'abcd'), isFalse);
    expect(constantTimeEquals('', ''), isTrue);
  });

  test(
    'PiServer: play all reaches the display with a file of the media dir',
    () async {
      // `tmp` holds clip, pic.png and friends; add the video the playlist uses.
      File('${tmp.path}/movie.mp4').writeAsBytesSync([1, 2, 3]);
      // The `all` playlist is the library now; files are imported at startup.
      await server.library.importLooseFiles();
      final tv = await TestPhone.connect(server.port);
      final phone = await TestPhone.connect(server.port);
      addTearDown(() async {
        await tv.close();
        await phone.close();
      });
      await tv.helloAsDisplay();
      server.hub.openPairingSession();
      await phone.pairWithQr(server.hub.currentQrUri('127.0.0.1')!);
      server.hub.closePairingSession();

      final reply = await phone.request('player.play', {'playlistId': 'all'});
      expect(reply['t'], HubMsg.ok, reason: '$reply');
      final load = await tv.waitFor((m) => m['t'] == 'display.load');
      expect(load['itemId'], 'movie.mp4');
      expect(File('${tmp.path}/${load['itemId']}').existsSync(), isTrue);
    },
  );
}
