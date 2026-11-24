import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tv_saver/tv/update/update_source_store.dart';
import 'package:tv_saver/tv/update/updater.dart';

void main() {
  group('TvUpdater', () {
    late Directory dir;
    late MemoryUpdateSourceStore store;
    var installedCode = 1;
    final apkBytes = utf8.encode('apk-bytes');
    final apkSha = sha256.convert(apkBytes).toString();

    setUp(() async {
      installedCode = 1;
      dir = await Directory.systemTemp.createTemp('tvsaver_upd_');
      store = MemoryUpdateSourceStore();
      await store.setUpdateSource('http://10.0.0.5:8099/update.json');
    });
    tearDown(() => dir.delete(recursive: true));

    TvUpdater make({
      String? sha,
      bool noSha = false,
      InstallResult result = InstallResult.started,
      List<String>? installed,
      String? apkUrl,
      Future<int> Function()? installedVersion,
      Future<String> Function(Uri)? fetch,
      Future<void> Function(Uri, File, void Function(double))? download,
    }) {
      final useSha = noSha ? null : (sha ?? apkSha);
      final body =
          '{"versionCode": 2, "versionName": "0.2.0", '
          '"apk": "${apkUrl ?? 'tv-saver-tv.apk'}"'
          '${useSha == null ? '' : ', "sha256": "$useSha"'}}';
      return TvUpdater(
        store: store,
        installedVersionCode: installedVersion ?? () async => installedCode,
        fetch: fetch ?? (_) async => body,
        download:
            download ??
            (uri, file, onProgress) async {
              onProgress(0.5);
              await file.writeAsBytes(apkBytes);
            },
        installer: (path) async {
          installed?.add(path);
          return result;
        },
        tempDir: () async => dir,
      );
    }

    test('downloads, verifies sha256 and opens the installer', () async {
      final installed = <String>[];
      final u = make(sha: apkSha, installed: installed);
      await u.checkNow();
      expect(u.state.value.phase, UpdatePhase.available);
      await u.install();
      expect(u.state.value.phase, UpdatePhase.installing);
      expect(installed.single, startsWith(dir.path));
    });

    test('sha mismatch deletes the file and reports damage', () async {
      final installed = <String>[];
      final u = make(sha: 'f' * 64, installed: installed);
      await u.checkNow();
      await u.install();
      expect(u.state.value.phase, UpdatePhase.error);
      expect(u.state.value.message, 'Download damaged, try again');
      expect(installed, isEmpty);
      expect(dir.listSync(), isEmpty);
    });

    test('blocked installs report needsPermission', () async {
      final u = make(sha: apkSha, result: InstallResult.needsPermission);
      await u.checkNow();
      await u.install();
      expect(u.state.value.phase, UpdatePhase.needsPermission);
      expect(u.state.value.canInstall, isTrue);
    });

    test('download failure gives an error that can be retried', () async {
      final u = make(download: (_, _, _) async => throw Exception('x'));
      await u.checkNow();
      await u.install();
      expect(u.state.value.phase, UpdatePhase.error);
      expect(u.state.value.canInstall, isTrue);
    });

    test('no saved source asks for the address', () async {
      await store.setUpdateSource(null);
      final u = make();
      await u.checkNow();
      expect(u.state.value.message, 'Enter the update address');
    });

    test('quiet check stays silent when up to date', () async {
      final u = TvUpdater(
        store: store,
        installedVersionCode: () async => 5,
        fetch: (_) async =>
            '{"versionCode": 2, "versionName": "x", "apk": "a.apk"}',
      );
      await u.check();
      expect(u.state.value.phase, UpdatePhase.none);
    });

    test('missing sha256 is refused without download or install', () async {
      var downloads = 0;
      final installed = <String>[];
      final u = make(
        noSha: true,
        installed: installed,
        download: (_, _, _) async => downloads++,
      );
      await u.checkNow();
      await u.install();
      expect(u.state.value.phase, UpdatePhase.error);
      expect(
        u.state.value.message,
        'This update has no checksum, so it was not installed',
      );
      expect(downloads, 0);
      expect(installed, isEmpty);
    });

    test('apk on a different host makes the manifest invalid', () async {
      final u = make(apkUrl: 'http://evil.example/x.apk');
      await u.checkNow();
      expect(u.state.value.phase, UpdatePhase.checkFailed);
      final same = make(apkUrl: 'http://10.0.0.5:9999/x.apk');
      await same.checkNow();
      expect(same.state.value.phase, UpdatePhase.checkFailed);
    });

    test('a stalled download fails, deletes the partial file', () async {
      final u = make(
        download: (uri, file, onProgress) async {
          await file.writeAsBytes([1, 2]);
          throw TimeoutException('stalled');
        },
      );
      await u.checkNow();
      await u.install();
      expect(u.state.value.phase, UpdatePhase.error);
      expect(u.state.value.canInstall, isTrue);
      expect(dir.listSync(), isEmpty);
    });

    test(
      'cached apk: wrong file is replaced, correct file skips download',
      () async {
        final file = File('${dir.path}/tv-saver-update.apk');
        var downloads = 0;
        Future<void> dl(Uri uri, File f, void Function(double) p) async {
          downloads++;
          await f.writeAsBytes(apkBytes);
        }

        file.writeAsBytesSync([9, 9, 9]);
        final u = make(download: dl);
        await u.checkNow();
        await u.install();
        expect(downloads, 1);
        expect(u.state.value.phase, UpdatePhase.installing);
        expect(file.readAsBytesSync(), apkBytes);

        final again = make(download: dl);
        await again.checkNow();
        await again.install();
        expect(downloads, 1, reason: 'correct cached file is reused');
      },
    );

    group('installerClosed', () {
      Future<TvUpdater> installing({
        Future<int> Function()? installedVersion,
      }) async {
        final u = make(installedVersion: installedVersion);
        await u.checkNow();
        await u.install();
        expect(u.state.value.phase, UpdatePhase.installing);
        return u;
      }

      test(
        'installed version at or above the manifest clears the state',
        () async {
          final u = await installing();
          installedCode = 2;
          await u.installerClosed();
          expect(u.state.value.phase, UpdatePhase.none);
        },
      );

      test('still older offers Install again', () async {
        final u = await installing();
        await u.installerClosed();
        expect(u.state.value.phase, UpdatePhase.error);
        expect(u.state.value.canInstall, isTrue);
      });

      test('a throwing version lookup is handled', () async {
        var fail = false;
        final u = await installing(
          installedVersion: () async {
            if (fail) throw StateError('no package info');
            return 1;
          },
        );
        fail = true;
        await u.installerClosed();
        expect(u.state.value.phase, UpdatePhase.error);
        expect(u.state.value.canInstall, isTrue);
      });
    });

    test('a late quiet check does not overwrite installing', () async {
      final gate = Completer<String>();
      final u = make(fetch: (_) => gate.future);
      final check = u.check();
      await Future<void>.delayed(Duration.zero);
      u.state.value = const UpdateState(
        phase: UpdatePhase.installing,
        versionName: '0.2.0',
      );
      gate.complete(
        '{"versionCode": 2, "versionName": "0.2.0", '
        '"apk": "tv-saver-tv.apk", "sha256": "$apkSha"}',
      );
      await check;
      expect(u.state.value.phase, UpdatePhase.installing);
    });

    test('normalizeAddress accepts an uppercase scheme', () {
      expect(
        TvUpdater.normalizeAddress('HTTP://10.0.0.5:8099'),
        'http://10.0.0.5:8099/update.json',
      );
    });

    test('setSource rejects invalid addresses', () async {
      final u = make();
      await expectLater(u.setSource('   '), throwsFormatException);
    });
  });

  group('FileUpdateSourceStore', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('upsrc'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('remembers the address in a small file; null forgets it', () async {
      final store = FileUpdateSourceStore(File('${dir.path}/sub/source.txt'));
      expect(await store.updateSource(), isNull);
      await store.setUpdateSource('http://10.0.0.5:8099/update.json');
      expect(
        await FileUpdateSourceStore(File('${dir.path}/sub/source.txt'))
            .updateSource(),
        'http://10.0.0.5:8099/update.json',
      );
      await store.setUpdateSource(null);
      expect(await store.updateSource(), isNull);
    });
  });
}
