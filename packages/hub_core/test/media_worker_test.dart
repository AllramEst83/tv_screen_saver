import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:hub_core/hub_core.dart';
import 'package:sqlite3/sqlite3.dart' as sql;
import 'package:test/test.dart';

String shaOf(List<int> data) => sha256.convert(data).toString();

String ffprobeJson({
  String codec = 'hevc',
  String profile = 'Main 10',
  String transfer = 'bt709',
  String tag = 'hvc1',
  String? audio = 'aac',
  int width = 3840,
  int height = 2160,
  String duration = '100.0',
  int? bitRate = 60000000,
  List<Map<String, Object?>> sideData = const [],
  Map<String, Object?> tags = const {},
}) => jsonEncode({
  'streams': [
    {
      'codec_type': 'video',
      'codec_name': codec,
      'profile': profile,
      'width': width,
      'height': height,
      'color_transfer': transfer,
      'codec_tag_string': tag,
      'avg_frame_rate': '24000/1001',
      'side_data_list': sideData,
      'tags': tags,
    },
    if (audio != null)
      {'codec_type': 'audio', 'codec_name': audio, 'profile': 'LC'},
  ],
  'format': {'duration': duration, 'bit_rate': ?bitRate?.toString()},
});

const tvCaps = {
  'decoders': [
    'OMX.x video/hevc hw=true profiles=[Main,Main10,Main10HDR10] max=3840x2160',
    'OMX.y audio/ac3 hw=true channels<=6',
    'OMX.y audio/eac3 hw=true channels<=8',
  ],
  'hdr': ['HDR10', 'HLG'],
  'render': '3840x2160',
  'panel': '3840x2160',
};

/// Answers tool calls from a script and records them.
class FakeRunner implements ToolRunner {
  FakeRunner({
    this.available = const {'ffprobe', 'ffmpeg', 'vips', 'vipsheader'},
  });

  Set<String> available;
  String probeOutput = ffprobeJson();
  bool probeFails = false;
  bool hang = false;
  String imageHeader = 'width: 4000\nheight: 3000\norientation: 6\n';
  bool rejectKeepIcc = false;
  final calls = <List<String>>[];
  Completer<void>? gate;

  @override
  Future<bool> isAvailable(String tool) async => available.contains(tool);

  @override
  void cancelAll() {}

  @override
  Future<ToolResult> run(
    String tool,
    List<String> args, {
    required Duration timeout,
  }) async {
    calls.add([tool, ...args]);
    final g = gate;
    if (g != null && tool == 'ffmpeg') await g.future;
    if (hang) return const ToolResult(-9, '', '', timedOut: true);
    switch (tool) {
      case 'ffprobe':
        return probeFails
            ? const ToolResult(1, '', 'Invalid data found\n')
            : ToolResult(0, probeOutput, '');
      case 'vipsheader':
        return imageHeader.isEmpty
            ? const ToolResult(1, '', 'not an image\n')
            : ToolResult(0, imageHeader, '');
      case 'ffmpeg':
        File(args.last).writeAsBytesSync(List.filled(10, 1));
        return const ToolResult(0, '', '');
      case 'vips':
        if (rejectKeepIcc && args[2].contains('keep=icc')) {
          return const ToolResult(1, '', 'unknown option keep\n');
        }
        final out = args[2].split('[').first;
        File(out).writeAsBytesSync(List.filled(10, 1));
        return const ToolResult(0, '', '');
    }
    return const ToolResult(127, '', 'unknown tool');
  }
}

void main() {
  group('parseFfprobe', () {
    test('SDR h264 with audio', () {
      final i = parseFfprobe(
        ffprobeJson(codec: 'h264', profile: 'High', audio: 'aac'),
      );
      expect(i.codec, 'h264');
      expect(i.hdr, 'SDR');
      expect(i.width, 3840);
      expect(i.durationMs, 100000);
      expect(i.fps, 23.976);
      expect(i.bitrate, 60000000);
      expect(i.audioCodec, 'aac');
    });

    test('HDR10, HLG and Dolby Vision', () {
      expect(parseFfprobe(ffprobeJson(transfer: 'smpte2084')).hdr, 'HDR10');
      expect(parseFfprobe(ffprobeJson(transfer: 'arib-std-b67')).hdr, 'HLG');
      expect(
        parseFfprobe(
          ffprobeJson(
            transfer: 'smpte2084',
            sideData: [
              {'side_data_type': 'DOVI configuration record'},
            ],
          ),
        ).hdr,
        'DolbyVision',
      );
    });

    test('10-bit HEVC profile and a file without audio', () {
      final i = parseFfprobe(ffprobeJson(audio: null));
      expect(i.profile, 'Main 10');
      expect(i.audioCodec, isNull);
    });

    test('rotation swaps the size; missing bit rate is computed', () {
      final i = parseFfprobe(
        ffprobeJson(
          width: 1920,
          height: 1080,
          bitRate: null,
          sideData: [
            {'rotation': -90},
          ],
        ),
        fileBytes: 125000000,
      );
      expect((i.width, i.height), (1080, 1920));
      expect(i.bitrate, 10000000);
    });

    test('no video track', () {
      expect(
        () => parseFfprobe('{"streams":[],"format":{}}'),
        throwsA(isA<ProbeException>()),
      );
    });
  });

  group('checkCapabilities', () {
    CapabilityVerdict check({
      String codec = 'hevc',
      String? profile = 'Main 10',
      String hdr = 'SDR',
      String? audio = 'aac',
      Map<String, Object?> caps = tvCaps,
    }) => checkCapabilities(
      codec: codec,
      profile: profile,
      hdr: hdr,
      audioCodec: audio,
      capabilities: caps,
    );

    test('supported', () {
      expect(check(hdr: 'HDR10', audio: 'eac3').supported, isTrue);
      expect(check(codec: 'h264', profile: 'High').supported, isTrue);
    });

    test('Main10 not listed', () {
      final v = check(
        caps: {
          ...tvCaps,
          'decoders': ['OMX.x video/hevc profiles=[Main]'],
        },
      );
      expect(v.supported, isFalse);
      expect(
        v.reason,
        'HEVC Main10 is not supported by this TV; convert it on the PC',
      );
    });

    test('codec, HDR and audio', () {
      expect(check(codec: 'av1').reason, contains('AV1'));
      expect(check(hdr: 'DolbyVision').reason, contains('Dolby Vision'));
      expect(check(audio: 'dts').reason, contains('DTS'));
      expect(
        check(caps: {...tvCaps, 'hdr': <String>[]}, hdr: 'HDR10').reason,
        contains('HDR10 is not supported'),
      );
    });
  });

  group('worker', () {
    late Directory tmp;
    late FakeRunner runner;
    late HubDatabase db;
    late LibraryStore store;
    late ServerConfig config;
    Map<String, Object?>? caps = tvCaps;
    final events = <LibraryEvent>[];
    final logs = <String>[];

    Future<void> startStore({
      int ceilingMbps = 80,
      int cacheBytes = 2500000000,
    }) async {
      config = ServerConfig(
        mediaDir: '${tmp.path}/media',
        tokenFile: '${tmp.path}/token',
        streamCeilingMbps: ceilingMbps,
        tvCacheBytes: cacheBytes,
      );
      store = LibraryStore(
        config: config,
        db: db,
        toolRunner: runner,
        looseFileGrace: Duration.zero,
        reconcileInterval: Duration.zero,
      );
      store.capabilities = () => caps;
      store.events.listen(events.add);
      await store.start();
    }

    Future<LibraryItemRow> upload(
      String name,
      String mime, {
      int size = 1000,
      int seed = 1,
    }) async {
      final data = List.generate(size, (i) => (i * 7 + seed) % 251);
      final start = await store.startUpload(
        name: name,
        bytes: size,
        sha256: shaOf(data),
        mime: mime,
        deviceId: '',
      );
      final r = await store.putChunk(
        start.uploadId,
        start: 0,
        end: size - 1,
        total: size,
        body: Stream.value(data),
      );
      return r.item!;
    }

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('mworker');
      Directory('${tmp.path}/media').createSync();
      runner = FakeRunner();
      db = HubDatabase.inMemory();
      caps = tvCaps;
      events.clear();
      logs.clear();
    });

    tearDown(() async {
      await store.stop();
      await db.close();
      tmp.deleteSync(recursive: true);
    });

    test(
      'HEVC upload: ready, metadata, variants and library.updated',
      () async {
        await startStore();
        runner.probeOutput = ffprobeJson(transfer: 'smpte2084');
        final item = await upload('a.mp4', 'video/mp4');
        expect(item.codec, 'hevc'); // from the quick probe
        await store.worker.idle;
        final row = (await db.libraryItem(item.id))!;
        expect(row.state, 'ready');
        expect(row.hdr, 'HDR10');
        expect(row.audioCodec, 'aac');
        expect(row.variants, 'poster,thumb');
        expect(row.cacheRequired, isFalse);
        expect(File(store.variantPath(item.id, 'poster')).existsSync(), isTrue);
        expect(File(store.variantPath(item.id, 'thumb')).existsSync(), isTrue);
        final updated = events.where((e) => e.kind == 'library.updated').last;
        expect(updated.data['id'], item.id);
        expect(updated.data['state'], 'ready');
        expect(updated.data['variants'], ['poster', 'thumb']);
        // The poster is taken at 10 % of the duration.
        final posterCall = runner.calls.firstWhere(
          (c) => c[0] == 'ffmpeg' && c.contains('-frames:v'),
        );
        expect(posterCall[posterCall.indexOf('-ss') + 1], '10.000');
      },
    );

    test('unsupported HDR: reason, not playable, skipped by all', () async {
      caps = {...tvCaps, 'hdr': <String>[]};
      await startStore();
      runner.probeOutput = ffprobeJson(transfer: 'smpte2084');
      final item = await upload('a.mp4', 'video/mp4');
      await store.worker.idle;
      final row = (await db.libraryItem(item.id))!;
      expect(row.state, 'unsupported');
      expect(row.stateReason, contains('convert it on the PC'));
      expect(File(store.pathOf(item.id)).existsSync(), isTrue);
      expect(await store.videoIds(), isEmpty);
      expect(await store.unplayableReason(item.id), row.stateReason);
    });

    test(
      'no display yet: stays new, checked when capabilities arrive',
      () async {
        caps = null;
        await startStore();
        runner.probeOutput = ffprobeJson(transfer: 'smpte2084');
        final item = await upload('a.mp4', 'video/mp4');
        await store.worker.idle;
        expect((await db.libraryItem(item.id))!.state, 'new');
        expect(await store.videoIds(), [item.id]);

        caps = {...tvCaps, 'hdr': <String>[]};
        await store.capabilitiesChanged();
        expect((await db.libraryItem(item.id))!.state, 'unsupported');

        caps = tvCaps;
        await store.capabilitiesChanged();
        final row = (await db.libraryItem(item.id))!;
        expect(row.state, 'ready');
        expect(row.stateReason, isNull);
        expect(events.last.kind, 'library.updated');
      },
    );

    test('above the ceiling and small: cacheRequired', () async {
      await startStore();
      runner.probeOutput = ffprobeJson(bitRate: 90000000);
      final item = await upload('a.mp4', 'video/mp4'); // 1000 B << cache / 4
      await store.worker.idle;
      expect((await db.libraryItem(item.id))!.cacheRequired, isTrue);
      expect((await db.libraryItem(item.id))!.state, 'ready');
    });

    test('above the ceiling and huge: 422 too_heavy, file deleted', () async {
      await startStore(cacheBytes: 3000); // 25 % = 750 bytes
      runner.probeOutput = ffprobeJson(bitRate: 90000000);
      await expectLater(
        upload('a.mp4', 'video/mp4'),
        throwsA(
          isA<UploadRefused>()
              .having((e) => e.status, 'status', 422)
              .having((e) => e.body['code'], 'code', 'too_heavy')
              .having((e) => e.body['reason'], 'reason', contains('PC')),
        ),
      );
      expect(await db.allLibraryItems(), isEmpty);
      expect(await db.allUploads(), isEmpty);
      expect(Directory('${config.mediaDir}/.uploads').listSync(), isEmpty);
    });

    test('image: 1920 and thumb, oriented size', () async {
      await startStore();
      final item = await upload('p.jpg', 'image/jpeg');
      await store.worker.idle;
      final row = (await db.libraryItem(item.id))!;
      expect(row.state, 'ready');
      expect((row.width, row.height), (3000, 4000)); // orientation 6
      expect(row.variants, '1920,thumb');
      final vipsCall = runner.calls.firstWhere((c) => c[0] == 'vips');
      expect(vipsCall, containsAll(['--size', 'down']));
      expect(vipsCall[3], contains('keep=icc'));
    });

    test('image: older libvips that rejects keep=icc is retried', () async {
      runner.rejectKeepIcc = true;
      await startStore();
      final item = await upload('p.jpg', 'image/jpeg');
      await store.worker.idle;
      expect((await db.libraryItem(item.id))!.variants, '1920,thumb');
    });

    test('small image: no variant is made', () async {
      runner.imageHeader = 'width: 300\nheight: 200\n';
      await startStore();
      final item = await upload('p.jpg', 'image/jpeg');
      await store.worker.idle;
      final row = (await db.libraryItem(item.id))!;
      expect(row.state, 'ready');
      expect(row.variants, '');
      expect(runner.calls.where((c) => c[0] == 'vips'), isEmpty);
    });

    test('corrupt image: error state', () async {
      runner.imageHeader = '';
      await startStore();
      final item = await upload('p.jpg', 'image/jpeg');
      await store.worker.idle;
      final row = (await db.libraryItem(item.id))!;
      expect(row.state, 'error');
      expect(row.stateReason, contains('could not be read'));
    });

    test('tools missing: items stay new, uploads work', () async {
      runner.available = {};
      await startStore();
      final v = await upload('a.mp4', 'video/mp4', seed: 1);
      final i = await upload('p.jpg', 'image/jpeg', seed: 2);
      await store.worker.idle;
      for (final id in [v.id, i.id]) {
        final row = (await db.libraryItem(id))!;
        expect(row.state, 'new');
        expect(row.variants, '');
      }
      expect(runner.calls, isEmpty);
      expect(store.worker.hasFfprobe, isFalse);
    });

    test('a tool that appears later queues the waiting items', () async {
      runner.available = {};
      await startStore();
      final v = await upload('a.mp4', 'video/mp4');
      await store.worker.idle;
      expect((await db.libraryItem(v.id))!.state, 'new');
      runner.available = {'ffprobe', 'ffmpeg', 'vips', 'vipsheader'};
      await store.worker.refreshTools();
      await store.worker.idle;
      expect((await db.libraryItem(v.id))!.state, 'ready');
    });

    test('hanging tool: item error, next job continues', () async {
      await startStore();
      runner.hang = true;
      runner.probeOutput = ffprobeJson();
      // Quick probe times out too, so the upload still succeeds.
      final a = await upload('a.mp4', 'video/mp4', seed: 1);
      await store.worker.idle;
      final row = (await db.libraryItem(a.id))!;
      expect(row.state, 'error');
      expect(row.stateReason, contains('timed out'));
      runner.hang = false;
      final b = await upload('b.mp4', 'video/mp4', seed: 2);
      await store.worker.idle;
      expect((await db.libraryItem(b.id))!.state, 'ready');
    });

    test('delete while queued: job dropped, no stray variants', () async {
      await startStore();
      final gate = runner.gate = Completer<void>();
      // The first job blocks inside ffmpeg; the second waits in the queue.
      final a = await upload('a.mp4', 'video/mp4', seed: 1);
      final b = await upload('b.mp4', 'video/mp4', seed: 2);
      await store.deleteItem(b.id);
      await store.deleteItem(a.id);
      gate.complete();
      await store.worker.idle;
      expect(await db.allLibraryItems(), isEmpty);
      final dir = Directory('${config.mediaDir}/.variants');
      expect(!dir.existsSync() || dir.listSync().isEmpty, isTrue);
    });

    test('items already in the library are queued at start', () async {
      await startStore();
      await upload('a.mp4', 'video/mp4');
      await store.worker.idle;
      await store.stop();
      // A loose clip and an old unprobed row.
      File('${config.mediaDir}/loose.mp4').writeAsBytesSync(List.filled(50, 3));
      runner.calls.clear();
      events.clear();
      await store.start();
      await store.hashingDone;
      await store.worker.idle;
      final loose = (await db.libraryItem('loose.mp4'))!;
      expect(loose.state, 'ready');
      expect(loose.codec, 'hevc');
    });

    test('item json carries the new fields', () async {
      await startStore();
      final item = await upload('a.mp4', 'video/mp4');
      await store.worker.idle;
      final json = libraryItemJson((await db.libraryItem(item.id))!);
      expect(
        json.keys,
        containsAll([
          'audioCodec',
          'profile',
          'state',
          'stateReason',
          'cacheRequired',
          'variants',
        ]),
      );
    });
  });

  test('schema 2 database is upgraded to 3 and keeps its items', () async {
    final tmp = Directory.systemTemp.createTempSync('mig');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final path = '${tmp.path}/v2.db';
    final raw = sql.sqlite3.open(path);
    raw.execute('''
      CREATE TABLE devices (id TEXT NOT NULL, name TEXT NOT NULL,
        role TEXT NOT NULL, created_at INTEGER NOT NULL, PRIMARY KEY (id));
      CREATE TABLE pairings (token_hash TEXT NOT NULL,
        device_id TEXT NOT NULL REFERENCES devices (id) ON DELETE CASCADE,
        client_name TEXT NOT NULL, created_at INTEGER NOT NULL,
        last_seen_at INTEGER NOT NULL, PRIMARY KEY (token_hash));
      CREATE TABLE library_items (id TEXT NOT NULL, kind TEXT NOT NULL,
        name TEXT NOT NULL, sha256 TEXT NOT NULL UNIQUE, bytes INTEGER NOT NULL,
        width INTEGER, height INTEGER, duration_ms INTEGER, codec TEXT,
        hdr TEXT, fps REAL, bitrate INTEGER, created_at INTEGER NOT NULL,
        PRIMARY KEY (id));
      CREATE TABLE uploads (id TEXT NOT NULL, name TEXT NOT NULL,
        bytes INTEGER NOT NULL, sha256 TEXT NOT NULL UNIQUE,
        mime TEXT NOT NULL, received INTEGER NOT NULL DEFAULT 0,
        device_id TEXT NOT NULL DEFAULT '', created_at INTEGER NOT NULL,
        PRIMARY KEY (id));
      INSERT INTO devices VALUES ('d1', 'Kay phone', 'owner', 1);
      INSERT INTO library_items (id, kind, name, sha256, bytes, codec, created_at)
        VALUES ('a.mp4', 'video', 'a.mp4', 'abc', 5, 'hevc', 1);
      PRAGMA user_version = 2;
    ''');
    raw.dispose();
    final db = HubDatabase.open(path);
    addTearDown(db.close);
    final item = (await db.libraryItem('a.mp4'))!;
    expect(item.codec, 'hevc');
    expect(item.state, 'new');
    expect(item.variants, '');
    expect(item.cacheRequired, isFalse);
    expect(item.audioCodec, isNull);
    expect((await db.allDevices()).single.id, 'd1');
    final v = await db.customSelect('PRAGMA user_version').getSingle();
    expect(v.read<int>('user_version'), 3);
  });

  group('real ffprobe and ffmpeg', () {
    late bool have;
    late Directory tmp;
    final runner = ProcessToolRunner();

    setUpAll(() async {
      have =
          await runner.isAvailable('ffmpeg') &&
          await runner.isAvailable('ffprobe');
    });
    setUp(() => tmp = Directory.systemTemp.createTempSync('realtools'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('probe and variants on a generated clip', () async {
      if (!have) {
        markTestSkipped('ffmpeg/ffprobe not installed');
        return;
      }
      final clip = '${tmp.path}/clip.mp4';
      final gen = await runner.run('ffmpeg', [
        '-v', 'error', '-y', '-f', 'lavfi', '-i',
        'testsrc=size=640x360:rate=10', '-f', 'lavfi', '-i',
        'sine=frequency=440:duration=3', '-t', '3', '-pix_fmt', 'yuv420p',
        '-c:v', 'libx264', '-c:a', 'aac', clip, //
      ], timeout: const Duration(seconds: 60));
      if (gen.exitCode != 0) {
        markTestSkipped('ffmpeg has no libx264');
        return;
      }
      final tools = MediaTools(runner);
      final info = await tools.probeVideo(clip, fileBytes: 1);
      expect(info.codec, 'h264');
      expect((info.width, info.height), (640, 360));
      expect(info.hdr, 'SDR');
      expect(info.audioCodec, 'aac');
      expect(info.durationMs, closeTo(3000, 200));
      final made = await tools.videoVariants(
        source: clip,
        info: info,
        outDir: '${tmp.path}/v',
        id: 'clip.mp4',
      );
      expect(made, ['poster', 'thumb']);
      final poster = File('${tmp.path}/v/clip.mp4.poster');
      final thumb = File('${tmp.path}/v/clip.mp4.thumb');
      expect(poster.lengthSync(), greaterThan(100));
      expect(thumb.lengthSync(), greaterThan(100));
      expect(poster.readAsBytesSync().take(2), [0xFF, 0xD8]); // JPEG
      expect(Directory('${tmp.path}/v').listSync().length, 2);
    });

    test('a file that is not a video gives a readable reason', () async {
      if (!have) {
        markTestSkipped('ffprobe not installed');
        return;
      }
      final f = File('${tmp.path}/junk.mp4')
        ..writeAsBytesSync(List.filled(500, 7));
      expect(
        MediaTools(runner).probeVideo(f.path),
        throwsA(isA<MediaToolException>()),
      );
    });

    test('a hanging process is killed at the timeout', () async {
      if (Platform.isWindows) {
        markTestSkipped('uses sleep');
        return;
      }
      final r = await runner.run('sleep', [
        '30',
      ], timeout: const Duration(milliseconds: 200));
      expect(r.timedOut, isTrue);
    });
  });
}
