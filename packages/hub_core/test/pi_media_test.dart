import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:hub_core/hub_core.dart';
import 'package:test/test.dart';

import 'support/fake_phone_harness.dart';
import 'support/limits.dart';
import 'support/fake_tools.dart';

const token = 'secret-token';

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
  late PiServer server;
  late FakeRunner runner;
  late HttpClient client;
  var started = false;

  Future<void> startServer({int cacheBytes = 2500000000}) async {
    final config = ServerConfig(
      mediaDir: '${tmp.path}/media',
      tokenFile: '${tmp.path}/token',
      port: 0,
      serverId: 'test',
      tvCacheBytes: cacheBytes,
    );
    final db = HubDatabase.inMemory();
    server = PiServer(
      config,
      token,
      db: db,
      settingsLimits: openLimits,
      library: LibraryStore(
        config: config,
        db: db,
        toolRunner: runner,
        looseFileGrace: Duration.zero,
        reconcileInterval: Duration.zero,
      ),
    );
    await server.start(address: '127.0.0.1');
    started = true;
  }

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('pimedia');
    Directory('${tmp.path}/media').createSync();
    runner = FakeRunner();
    client = HttpClient();
    started = false;
  });

  tearDown(() async {
    client.close(force: true);
    if (started) {
      await server.stop();
      await server.db.close();
    }
    tmp.deleteSync(recursive: true);
  });

  Future<(HttpClientResponse, List<int>)> send(
    String method,
    String path, {
    Map<String, String> headers = const {},
    List<int>? body,
  }) async {
    final req = await client.openUrl(
      method,
      Uri.parse('http://127.0.0.1:${server.port}$path'),
    );
    req.headers.set('Authorization', 'Bearer $token');
    headers.forEach(req.headers.set);
    if (body != null) {
      req.contentLength = body.length;
      req.add(body);
    }
    final res = await req.close();
    final out = await res.fold<List<int>>([], (a, b) => a..addAll(b));
    return (res, out);
  }

  /// Uploads [data] in one chunk; returns the last PUT's response.
  Future<(HttpClientResponse, Map<String, dynamic>)> upload(
    List<int> data,
    String mime,
  ) async {
    final (r, b) = await send(
      'POST',
      '/media/uploads',
      body: utf8.encode(
        jsonEncode({
          'name': 'clip',
          'bytes': data.length,
          'sha256': sha256.convert(data).toString(),
          'mime': mime,
        }),
      ),
    );
    expect(r.statusCode, 200);
    final id = (jsonDecode(utf8.decode(b)) as Map)['uploadId'];
    final (p, pb) = await send(
      'PUT',
      '/media/uploads/$id',
      headers: {'Content-Range': 'bytes 0-${data.length - 1}/${data.length}'},
      body: data,
    );
    return (
      p,
      pb.isEmpty
          ? <String, dynamic>{}
          : jsonDecode(utf8.decode(pb)) as Map<String, dynamic>,
    );
  }

  List<int> bytes(int n, int seed) =>
      List.generate(n, (i) => (i * 13 + seed) % 251);

  Future<TestPhone> pairPhone() async {
    final p = await TestPhone.connect(server.port);
    server.hub.openPairingSession();
    await p.pairWithQr(server.hub.currentQrUri('127.0.0.1')!);
    server.hub.closePairingSession();
    addTearDown(p.close);
    return p;
  }

  Future<void> stateOf(String id, String state) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while ((await server.db.libraryItem(id))?.state != state) {
      if (DateTime.now().isAfter(deadline)) {
        fail('item $id is ${(await server.db.libraryItem(id))?.state}');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  test(
    'the last PUT of a too heavy video: 422 too_heavy with a reason',
    () async {
      runner.probeOutput = ffprobeJson(bitRate: 90000000);
      await startServer(cacheBytes: 3000);
      final (res, body) = await upload(bytes(2000, 1), 'video/mp4');
      expect(res.statusCode, 422);
      expect(body['code'], 'too_heavy');
      expect(body['reason'], contains('Lower its bitrate'));
      expect(await server.db.allLibraryItems(), isEmpty);
      expect(
        Directory('${tmp.path}/media').listSync().whereType<File>(),
        isEmpty,
      );
    },
  );

  test('variants are served with 200 and Range 206 once they exist', () async {
    await startServer();
    final (res, body) = await upload(bytes(1000, 2), 'video/mp4');
    expect(res.statusCode, 201);
    final id = body['id'] as String;
    await server.library.worker.idle;

    final (t, tb) = await send('GET', '/media/$id/thumb');
    expect(t.statusCode, 200);
    expect(tb, hasLength(10));
    expect(t.headers.value('accept-ranges'), 'bytes');
    final (r, rb) = await send(
      'GET',
      '/media/$id/thumb',
      headers: {'Range': 'bytes=2-5'},
    );
    expect(r.statusCode, 206);
    expect(r.headers.value('content-range'), 'bytes 2-5/10');
    expect(rb, hasLength(4));
    final (p, _) = await send('GET', '/media/$id/poster');
    expect(p.statusCode, 200);
    // Not made (an image-only variant on a video): 404.
    final (n, _) = await send('GET', '/media/$id/1920');
    expect(n.statusCode, 404);
  });

  test('an item turns unsupported when the TV reports; all skips it', () async {
    runner.probeOutput = ffprobeJson(transfer: 'smpte2084');
    await startServer();
    final tv = await TestPhone.connect(server.port);
    addTearDown(tv.close);
    await tv.helloAsDisplay();
    final phone = await pairPhone();

    final (res, body) = await upload(bytes(1000, 3), 'video/mp4');
    expect(res.statusCode, 201);
    final id = body['id'] as String;
    await server.library.worker.idle;
    expect((await server.db.libraryItem(id))!.state, 'new'); // no report yet

    final r = await tv.request('display.capabilities', {
      'decoders': ['x video/hevc profiles=[Main,Main10] max=3840x2160'],
      'hdr': <String>[],
      'render': '3840x2160',
      'panel': '3840x2160',
    });
    expect(r['t'], HubMsg.ok);
    await stateOf(id, 'unsupported');
    final row = (await server.db.libraryItem(id))!;
    expect(row.state, 'unsupported');
    expect(row.stateReason, contains('HDR10 is not supported'));
    expect(await server.library.videoIds(), isEmpty);
    final play = await phone.request('player.play', {'playlistId': 'all'});
    expect(play['t'], HubMsg.err);
    expect(play['code'], HubErrorCode.notFound);
    // The TV now supports HDR10: the video is ready and plays.
    await tv.request('display.capabilities', {
      'decoders': ['x video/hevc profiles=[Main,Main10] max=3840x2160'],
      'hdr': ['HDR10'],
      'render': '3840x2160',
      'panel': '3840x2160',
    });
    await stateOf(id, 'ready');
    final ok = await phone.request('player.play', {'playlistId': 'all'});
    expect(ok['t'], HubMsg.ok);
  });
}
