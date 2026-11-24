import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' show Value;
import 'package:hub_core/hub_core.dart';
import 'package:test/test.dart';

import 'support/fake_phone_harness.dart';
import 'support/fake_tools.dart';
import 'support/limits.dart';

const token = 'secret-token';

void main() {
  late Directory tmp;
  late PiServer server;
  late HttpClient client;
  late String dbPath;
  var started = false;

  Future<void> startServer({
    int cap = 90000000000,
    int ceiling = 80,
    int cache = 2500000000,
    Map<String, SettingLimit>? limits = openLimits,
  }) async {
    final config = ServerConfig(
      mediaDir: '${tmp.path}/media',
      tokenFile: '${tmp.path}/token',
      port: 0,
      serverId: 'test',
      storageCapBytes: cap,
      streamCeilingMbps: ceiling,
      tvCacheBytes: cache,
    );
    final db = HubDatabase.open(dbPath);
    server = PiServer(
      config,
      token,
      db: db,
      settingsLimits: limits,
      library: LibraryStore(
        config: config,
        db: db,
        toolRunner: FakeRunner(),
        looseFileGrace: Duration.zero,
        reconcileInterval: Duration.zero,
      ),
    );
    await server.start(address: '127.0.0.1');
    started = true;
  }

  Future<void> stopServer() async {
    await server.stop();
    await server.db.close();
    started = false;
  }

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('settings');
    Directory('${tmp.path}/media').createSync();
    dbPath = '${tmp.path}/hub.db';
    client = HttpClient();
    started = false;
  });

  tearDown(() async {
    client.close(force: true);
    if (started) await stopServer();
    tmp.deleteSync(recursive: true);
  });

  Future<TestPhone> pair([String client = 'TestPhone']) async {
    final p = await TestPhone.connect(server.port);
    server.hub.openPairingSession();
    await p.pairWithQr(server.hub.currentQrUri('127.0.0.1')!, client: client);
    server.hub.closePairingSession();
    addTearDown(p.close);
    return p;
  }

  Map<String, dynamic> settingsSnap(Map<String, dynamic> snap) =>
      (snap['modules'] as Map)['settings'] as Map<String, dynamic>;

  Future<Map<String, dynamic>> snapshotOf(TestPhone p) async {
    p.send(HubMsg.sync);
    final s = await p.waitFor((m) => m['t'] == HubMsg.snapshot);
    return settingsSnap(s);
  }

  Future<int> startUpload(int bytes) async {
    final data = List.filled(bytes, 7);
    final req = await client.postUrl(
      Uri.parse('http://127.0.0.1:${server.port}/media/uploads'),
    );
    req.headers.set('Authorization', 'Bearer $token');
    final body = utf8.encode(
      jsonEncode({
        'name': 'x',
        'bytes': bytes,
        'sha256': sha256.convert(data).toString(),
        'mime': 'image/png',
      }),
    );
    req.contentLength = body.length;
    req.add(body);
    final res = await req.close();
    await res.drain<void>();
    return res.statusCode;
  }

  test('first values come from the environment config and defaults', () async {
    await startServer(cap: 5000000000, ceiling: 42, cache: 1000000000);
    final p = await pair();
    final s = await snapshotOf(p);
    expect(s['values'], {
      'imageSeconds': 10,
      'transition': 'crossfade',
      'kenBurns': false,
      'playWithSound': true,
      'storageCapBytes': 5000000000,
      'streamingCeilingMbps': 42,
      'tvCacheBytes': 1000000000,
    });
    final limits = s['limits'] as Map;
    expect(limits['imageSeconds'], {'min': 3, 'max': 120});
    expect(limits.containsKey('streamingCeilingMbps'), isTrue);
  });

  test('the owner updates partially; others get the event; it survives a '
      'restart and beats the environment', () async {
    await startServer();
    final owner = await pair();
    final other = await pair();
    expect(other.role, 'controller');
    final r = await owner.request('settings.update', {
      'streamingCeilingMbps': 60,
      'kenBurns': true,
    });
    expect(r['t'], HubMsg.ok, reason: '$r');
    final ev = await other.expectEvent('settings.changed');
    final values = (ev['data'] as Map)['values'] as Map;
    expect(values['streamingCeilingMbps'], 60);
    expect(values['kenBurns'], true);
    expect(values['imageSeconds'], 10, reason: 'partial update');
    // Live consumer.
    expect(server.config.streamCeilingMbps, 60);

    await stopServer();
    await startServer(ceiling: 80);
    expect(server.settings.values['streamingCeilingMbps'], 60);
    expect(server.config.streamCeilingMbps, 60);
    expect(server.settings.values['kenBurns'], true);
  });

  test('a controller is forbidden; invalid values name the field and change '
      'nothing', () async {
    await startServer(limits: null);
    final owner = await pair();
    final ctrl = await pair();
    final f = await ctrl.request('settings.update', {'imageSeconds': 20});
    expect(f['code'], HubErrorCode.forbidden);

    for (final bad in <Map<String, Object?>>[
      {'imageSeconds': 2},
      {'imageSeconds': 121},
      {'imageSeconds': 5.5},
      {'imageSeconds': '9'},
      {'transition': 'wipe'},
      {'kenBurns': 'yes'},
      {'streamingCeilingMbps': 0},
      {'tvCacheBytes': 1},
      {'storageCapBytes': -1},
      {'nope': 1},
    ]) {
      final r = await owner.request('settings.update', bad);
      expect(r['code'], HubErrorCode.invalid, reason: '$bad');
      expect(r['field'], bad.keys.first, reason: '$bad');
      expect(r['msg'], isNotEmpty);
    }
    // One bad entry rejects the whole patch.
    final mixed = await owner.request('settings.update', {
      'kenBurns': true,
      'imageSeconds': 1,
    });
    expect(mixed['code'], HubErrorCode.invalid);
    final empty = await owner.request('settings.update');
    expect(empty['code'], HubErrorCode.invalid);
    expect(
      (await snapshotOf(owner))['values'],
      containsPair('kenBurns', false),
    );
    expect(await server.db.allSettings(), isEmpty);
  });

  test('the TV (display) may update like the owner', () async {
    await startServer();
    final tv = await TestPhone.connect(server.port);
    addTearDown(tv.close);
    await tv.helloAsDisplay();
    final r = await tv.request('settings.update', {'transition': 'cut'});
    expect(r['t'], HubMsg.ok, reason: '$r');
    expect(server.settings.transition, 'cut');
  });

  test('lowering the storage cap below usage keeps files and refuses new '
      'uploads with 507', () async {
    await startServer(cap: 5000000);
    final owner = await pair();
    expect(await startUpload(2000), 200);
    final ok = await owner.request('settings.update', {
      'storageCapBytes': 1000,
    });
    expect(ok['t'], HubMsg.ok);
    expect(await startUpload(5000), 507);
    expect(await server.library.usedBytes(), 2000, reason: 'nothing deleted');
    final snap = await server.library.snapshot();
    expect(snap['storage'], {'usedBytes': 2000, 'capBytes': 1000});
  });

  test('the storage cap and TV cache are read live', () async {
    await startServer(cap: 1000);
    expect(await startUpload(2000), 507);
    final owner = await pair();
    await owner.request('settings.update', {'storageCapBytes': 1000000000});
    expect(await startUpload(2000), 200);
    expect(server.library.worker.config.tvCacheBytes, 2500000000);
    await owner.request('settings.update', {'tvCacheBytes': 600000000});
    expect(server.library.worker.config.tvCacheBytes, 600000000);
  });

  test('a damaged stored value falls back to the default', () async {
    await startServer();
    await server.db.writeSettings({
      'imageSeconds': '"banana"',
      'transition': '"cut"',
      'kenBurns': 'not json',
    });
    await stopServer();
    await startServer();
    expect(server.settings.values['imageSeconds'], 10);
    expect(server.settings.transition, 'cut');
    expect(server.settings.values['kenBurns'], false);
  });

  group('schema 4 migration', () {
    test('a real version 3 file keeps its data and gains Settings', () async {
      // Build a database, then turn it into a version 3 file.
      final db = HubDatabase.open(dbPath);
      await db.insertDevice(
        id: 'd1',
        name: 'Old phone',
        role: 'owner',
        nowMs: 1,
      );
      await db.insertPairing(
        rawToken: 'tok',
        deviceId: 'd1',
        clientName: 'Old phone',
        nowMs: 1,
      );
      await db.customStatement('DROP TABLE settings');
      await db.customStatement('PRAGMA user_version = 3');
      await db.close();

      final upgraded = HubDatabase.open(dbPath);
      addTearDown(upgraded.close);
      expect((await upgraded.allDevices()).single.name, 'Old phone');
      expect(await upgraded.verifyRawToken('tok'), isNotNull);
      expect(await upgraded.allSettings(), isEmpty);
      await upgraded.writeSettings({'imageSeconds': '15'});
      expect(await upgraded.allSettings(), {'imageSeconds': '15'});
      final v = await upgraded.customSelect('PRAGMA user_version').getSingle();
      expect(v.read<int>('user_version'), 5);
    });
  });

  test('environment and stored values are validated like updates', () async {
    // 3000 bytes is below the default minimum cap: the default is used.
    await startServer(cap: 3000, ceiling: 100000, cache: 1, limits: null);
    expect(server.settings.values['storageCapBytes'], kDefaultStorageCapBytes);
    expect(
      server.settings.values['streamingCeilingMbps'],
      kDefaultStreamCeilingMbps,
    );
    expect(server.settings.values['tvCacheBytes'], kDefaultTvCacheBytes);
    expect(server.config.storageCapBytes, kDefaultStorageCapBytes);
    await server.db.writeSettings({'imageSeconds': '9999'});
    await stopServer();
    await startServer(limits: null);
    expect(server.settings.values['imageSeconds'], 10);
  });

  test(
    'non-finite numbers are refused; a failed write is unavailable',
    () async {
      await startServer();
      for (final bad in [
        double.nan,
        double.infinity,
        double.negativeInfinity,
      ]) {
        await expectLater(
          server.settings.update({'imageSeconds': bad}),
          throwsA(
            isA<SettingsRejected>().having(
              (e) => e.extra['field'],
              'field',
              'imageSeconds',
            ),
          ),
        );
      }
      final db = HubDatabase.inMemory();
      final store = SettingsStore(
        db: db,
        config: ServerConfig(mediaDir: 'x', tokenFile: 'x'),
      );
      await store.load();
      await db.close();
      await expectLater(
        store.update({'kenBurns': true}),
        throwsA(
          isA<HubError>()
              .having((e) => e.code, 'code', 'unavailable')
              .having(
                (e) => e.message,
                'message',
                'Could not save the setting',
              ),
        ),
      );
      expect(store.values['kenBurns'], false, reason: 'nothing changed');
    },
  );

  test('library events carry the true storage figure; a new cap and a new '
      'ceiling are announced; cacheRequired follows the ceiling', () async {
    await startServer();
    final owner = await pair();
    // A video of 70 Mbit/s: below 80, above 60.
    final now = DateTime.now().millisecondsSinceEpoch;
    await server.db.insertLibraryItem(
      LibraryItemsCompanion.insert(
        id: 'v.mp4',
        kind: 'video',
        name: 'v',
        sha256: 'a' * 64,
        bytes: 5000,
        createdAt: now,
        bitrate: const Value(70000000),
      ),
    );
    final snap = await snapshotOf(owner);
    expect(snap, isNotNull);
    expect(await server.db.libraryItem('v.mp4'), isNotNull);
    await owner.request('settings.update', {'streamingCeilingMbps': 60});
    final upd = await owner.expectEvent('library.updated');
    final data = upd['data'] as Map;
    expect(data['id'], 'v.mp4');
    expect(data['cacheRequired'], true);
    expect(data['storage'], {'usedBytes': 5000, 'capBytes': 90000000000});
    expect((await server.db.libraryItem('v.mp4'))!.cacheRequired, isTrue);

    await owner.request('settings.update', {'streamingCeilingMbps': 100});
    final back = await owner.expectEvent('library.updated');
    expect((back['data'] as Map)['cacheRequired'], false);

    await owner.request('settings.update', {'storageCapBytes': 5000000000});
    final st = await owner.waitFor(
      (m) =>
          m['kind'] == 'library.storage' &&
          ((m['data'] as Map)['storage'] as Map)['capBytes'] == 5000000000,
    );
    expect((st['data'] as Map)['storage'], {
      'usedBytes': 5000,
      'capBytes': 5000000000,
    });
    // The snapshot has the figure too.
    expect((await server.library.snapshot())['storage'], {
      'usedBytes': 5000,
      'capBytes': 5000000000,
    });
  });

  test('a long or padded client name is stored trimmed, cut at 40 characters '
      'on a character boundary', () async {
    await startServer();
    final long = await pair('x' * 60);
    final padded = await pair('   Pixel 9   ');
    final emoji = await pair('${'a' * 39}😀😀');
    final rows = await server.db.allDevices();
    final names = {for (final r in rows) r.id: r.name};
    expect(names[long.deviceId], 'x' * 40);
    expect(names[padded.deviceId], 'Pixel 9');
    expect(names[emoji.deviceId], '${'a' * 39}😀');
  });
}
