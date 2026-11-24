import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hub_core/hub_core.dart';
import 'package:image/image.dart' as img;
import 'package:tv_saver/phone/images/image_prep.dart';
import 'package:tv_saver/phone/upload/uploader.dart';

const token = 'secret-token';

Uint8List _picture(int seed, {int w = 300, int h = 200}) {
  final image = img.Image(width: w, height: h);
  for (final p in image) {
    p
      ..r = (p.x * seed) % 256
      ..g = (p.y + seed) % 256
      ..b = (p.x ^ p.y) % 256;
  }
  return Uint8List.fromList(img.encodeJpg(image, quality: 92));
}

void main() {
  late Directory tmp;
  late PiServer server;
  late HttpClient http;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('upl');
    final media = Directory('${tmp.path}/media')..createSync();
    server = PiServer(
      ServerConfig(
        mediaDir: media.path,
        tokenFile: '${tmp.path}/token',
        port: 0,
        serverId: 'test',
        storageCapBytes: 1 << 40,
      ),
      token,
    );
    await server.start(address: '127.0.0.1');
    http = HttpClient();
  });

  tearDown(() async {
    http.close(force: true);
    await server.stop();
    tmp.deleteSync(recursive: true);
  });

  Future<HttpClientRequest> open(
    String method,
    String path, {
    Map<String, String> headers = const {},
  }) async {
    final req = await http.openUrl(
      method,
      Uri.parse('http://127.0.0.1:${server.port}$path'),
    );
    req.headers.set('Authorization', 'Bearer $token');
    headers.forEach(req.headers.set);
    return req;
  }

  ImageUploader make({int chunk = 1000, OpenAuthorized? opener}) =>
      ImageUploader(
        request: (type, args) async {
          final sha = args['sha256'] as String;
          final item = await server.library.itemBySha(sha);
          return {'exists': item != null, 'id': ?item?.id};
        },
        open: opener ?? open,
        chunkBytes: chunk,
        prepare: (b) async => prepareImageSync(b)!,
      );

  test('uploads in chunks; the stored file is the prepared bytes', () async {
    final up = make();
    final src = _picture(3);
    final prepared = prepareImageSync(src)!;
    final item = up.add([BytesUploadSource('a.jpg', src)]).single;
    await up.whenIdle();
    expect(item.status, UploadStatus.done, reason: '${item.error}');
    expect(item.progress, 1);
    expect(prepared.bytes.length, greaterThan(2000)); // several chunks
    final stored = await server.library.itemBySha(prepared.sha256);
    expect(stored, isNotNull);
    expect(item.libraryId, stored!.id);
    final file = File('${server.config.mediaDir}/${stored.id}');
    expect(sha256.convert(file.readAsBytesSync()).toString(), prepared.sha256);
  });

  test('the same picture again says it is already there', () async {
    final up = make();
    up.add([BytesUploadSource('a.jpg', _picture(3))]);
    await up.whenIdle();
    final second = up.add([BytesUploadSource('copy.jpg', _picture(3))]).single;
    await up.whenIdle();
    expect(second.status, UploadStatus.done);
    expect(second.alreadyThere, isTrue);
  });

  test(
    'a dropped link fails, and Retry sends only the missing bytes',
    () async {
      final src = _picture(5);
      final prepared = prepareImageSync(src)!;
      var puts = 0;
      var failNext = false;
      final sentFrom = <int>[];
      Future<HttpClientRequest> flaky(
        String method,
        String path, {
        Map<String, String> headers = const {},
      }) async {
        if (method == 'PUT') {
          puts++;
          if (puts == 3 && failNext) {
            throw const SocketException('link lost');
          }
          sentFrom.add(
            int.parse(
              RegExp(r'bytes (\d+)-')
                  .firstMatch(
                    headers['content-range'] ?? headers['Content-Range']!,
                  )!
                  .group(1)!,
            ),
          );
        }
        return open(method, path, headers: headers);
      }

      failNext = true;
      final up = make(chunk: 700, opener: flaky);
      final item = up.add([BytesUploadSource('b.jpg', src)]).single;
      await up.whenIdle();
      expect(item.status, UploadStatus.failed);
      expect(item.error, ImageUploader.failedMessage);
      failNext = false;
      sentFrom.clear();
      up.retry(item);
      await up.whenIdle();
      expect(item.status, UploadStatus.done, reason: '${item.error}');
      // Resumed at the Pi's offset, not from zero.
      expect(sentFrom.first, 1400);
      final stored = (await server.library.itemBySha(prepared.sha256))!;
      expect(
        sha256
            .convert(
              File('${server.config.mediaDir}/${stored.id}').readAsBytesSync(),
            )
            .toString(),
        prepared.sha256,
      );
    },
  );

  test('a file that is not a picture fails with a plain message', () async {
    final up = ImageUploader(
      request: (_, _) async => {'exists': false},
      open: open,
    );
    final item = up.add([
      BytesUploadSource('x.txt', Uint8List.fromList([1, 2, 3])),
    ]).single;
    await up.whenIdle();
    expect(item.status, UploadStatus.failed);
    expect(item.error, "That file isn't a picture");
  });

  test('a wrong token says the phone is no longer paired', () async {
    final up = ImageUploader(
      request: (_, _) async => {'exists': false},
      open: (m, p, {headers = const {}}) async {
        final req = await open(m, p, headers: headers);
        req.headers.set('Authorization', 'Bearer nope');
        return req;
      },
      prepare: (b) async => prepareImageSync(b)!,
    );
    final item = up.add([BytesUploadSource('a.jpg', _picture(1))]).single;
    await up.whenIdle();
    expect(item.error, 'This phone is no longer paired');
  });
}
