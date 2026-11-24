import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:hub_core/hub_core.dart';
import 'package:test/test.dart';

void main() {
  group('UpdateManifest', () {
    test('parses and resolves a relative apk', () {
      final m = UpdateManifest.tryParse(
        '{"versionCode": 4, "versionName": "0.2.0", '
        '"apk": "tv-saver-tv.apk", "sha256": "${'A' * 64}"}',
      )!;
      expect(m.sha256, 'a' * 64);
      expect(m.isNewerThan(3), isTrue);
      expect(m.isNewerThan(4), isFalse);
      expect(
        m.apkUri(Uri.parse('http://192.168.0.10:8099/update.json')).toString(),
        'http://192.168.0.10:8099/tv-saver-tv.apk',
      );
    });

    test('rejects bad bodies, other hosts and non-http apks', () {
      expect(UpdateManifest.tryParse('nope'), isNull);
      expect(UpdateManifest.tryParse('{"versionCode": "1"}'), isNull);
      final file = UpdateManifest.tryParse(
        '{"versionCode": 1, "versionName": "a", "apk": "file:///x.apk"}',
      )!;
      expect(file.apkUri(Uri.parse('http://h/update.json')), isNull);
      final other = UpdateManifest.tryParse(
        '{"versionCode": 1, "versionName": "a", "apk": "http://evil/x.apk"}',
      )!;
      expect(other.apkUri(Uri.parse('http://h:8099/update.json')), isNull);
    });

    test('a checksum that is not 64 hex digits is dropped', () {
      final m = UpdateManifest.tryParse(
        '{"versionCode": 1, "versionName": "a", "apk": "x.apk", "sha256": "12"}',
      )!;
      expect(m.sha256, isNull);
    });

    test('pubspec version and address validation', () {
      final v = parsePubspecVersion('name: x\nversion: 0.3.1+7\n')!;
      expect((v.name, v.code), ('0.3.1', 7));
      expect(isValidUpdateAddress('http://1.2.3.4:8099/update.json'), isTrue);
      expect(isValidUpdateAddress('ftp://x'), isFalse);
    });
  });

  group('UpdateServer', () {
    late Directory tmp;
    late File apk;
    late UpdateServer server;
    late HttpClient http;
    var pubspec = 'name: x\nversion: 0.2.0+5\n';

    setUp(() async {
      tmp = Directory.systemTemp.createTempSync('upd');
      apk = File('${tmp.path}/app.apk')..writeAsBytesSync(utf8.encode('apk-1'));
      pubspec = 'name: x\nversion: 0.2.0+5\n';
      server = UpdateServer(apk: apk, readPubspec: () => pubspec);
      await server.start(port: 0, address: '127.0.0.1');
      http = HttpClient();
    });

    tearDown(() async {
      http.close(force: true);
      await server.stop();
      tmp.deleteSync(recursive: true);
    });

    Future<(HttpClientResponse, List<int>)> get(
      String path, {
      String method = 'GET',
    }) async {
      final req = await http.openUrl(
        method,
        Uri.parse('http://127.0.0.1:${server.port}$path'),
      );
      final res = await req.close();
      final body = await res.fold<List<int>>([], (a, b) => a..addAll(b));
      return (res, body);
    }

    test('update.json names the version, the apk and its checksum', () async {
      final (res, body) = await get('/update.json');
      expect(res.statusCode, 200);
      final m = UpdateManifest.tryParse(utf8.decode(body))!;
      expect(m.versionCode, 5);
      expect(m.versionName, '0.2.0');
      expect(m.apk, kUpdateApkRoute);
      expect(m.sha256, sha256.convert(utf8.encode('apk-1')).toString());
    });

    test('the apk is served whole, and HEAD gives only the headers', () async {
      var (res, body) = await get('/$kUpdateApkRoute');
      expect(res.statusCode, 200);
      expect(utf8.decode(body), 'apk-1');
      expect(
        res.headers.contentType?.mimeType,
        'application/vnd.android.package-archive',
      );
      (res, body) = await get('/$kUpdateApkRoute', method: 'HEAD');
      expect(res.contentLength, 5);
      expect(body, isEmpty);
    });

    test('a rebuilt apk or a new version is served at once', () async {
      await get('/update.json');
      apk.writeAsBytesSync(utf8.encode('apk-2-longer'));
      pubspec = 'name: x\nversion: 0.3.0+6\n';
      final (_, body) = await get('/update.json');
      final m = UpdateManifest.tryParse(utf8.decode(body))!;
      expect(m.versionCode, 6);
      expect(m.sha256, sha256.convert(utf8.encode('apk-2-longer')).toString());
    });

    test('other paths and methods are refused', () async {
      expect((await get('/nope')).$1.statusCode, 404);
      expect((await get('/update.json', method: 'POST')).$1.statusCode, 405);
    });

    test('a missing apk is a 404; a pubspec without +build is a 500', () async {
      pubspec = 'name: x\nversion: 0.2.0\n';
      final (res, body) = await get('/update.json');
      expect(res.statusCode, 500);
      expect(utf8.decode(body), contains('+build'));
      apk.deleteSync();
      expect((await get('/update.json')).$1.statusCode, 404);
      expect((await get('/$kUpdateApkRoute')).$1.statusCode, 404);
    });
  });

  test('the address on the TV network is picked', () {
    expect(
      addressOnTvNetwork(['192.168.1.20', '10.0.0.4'], '192.168.1.55'),
      '192.168.1.20',
    );
    expect(addressOnTvNetwork(['10.0.0.4'], '192.168.1.55'), isNull);
  });
}
