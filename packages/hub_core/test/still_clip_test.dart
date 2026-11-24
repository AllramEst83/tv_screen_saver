import 'dart:async';
import 'dart:io';

import 'package:hub_core/hub_core.dart';
import 'package:test/test.dart';

/// Story 7-1: a clip made from a still by `tool/video/still_to_clip.sh` is a
/// normal video for the Pi: the inbox imports it with the real ffprobe and it
/// is a 3840x2160 HEVC item. Skipped when bash, ffmpeg or ffprobe is missing.
Future<bool> _has(String tool, [String flag = '-version']) async {
  try {
    final r = await Process.run(tool, [flag]);
    return r.exitCode == 0;
  } catch (_) {
    return false;
  }
}

/// A bash that works: on Windows the one on PATH may be the WSL stub, so Git's
/// is tried too.
Future<String?> _bash() async {
  for (final b in ['bash', 'C:/Program Files/Git/bin/bash.exe']) {
    if (await _has(b, '--version')) return b;
  }
  return null;
}

void main() {
  late Directory tmp;
  late bool tools;
  String? bash;

  setUpAll(() async {
    bash = await _bash();
    tools = await _has('ffmpeg') && await _has('ffprobe') && bash != null;
  });

  setUp(() => tmp = Directory.systemTemp.createTempSync('still'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('a still turned into a clip imports as a 4K HEVC video', () async {
    if (!tools) {
      markTestSkipped('ffmpeg, ffprobe or bash not available');
      return;
    }
    final script = File('../../tool/video/still_to_clip.sh').absolute.path;
    if (!File(script).existsSync()) {
      markTestSkipped('run from packages/hub_core');
      return;
    }
    final image = '${tmp.path}/pic.png';
    final made = await Process.run('ffmpeg', [
      '-hide_banner',
      '-loglevel',
      'error',
      '-y',
      '-f',
      'lavfi',
      '-i',
      'testsrc2=s=1600x900:d=1',
      '-frames:v',
      '1',
      image,
    ]);
    expect(made.exitCode, 0, reason: '${made.stderr}');
    final run = await Process.run(bash!, [
      script,
      image,
      '2',
      '${tmp.path}/out',
    ]);
    expect(run.exitCode, 0, reason: '${run.stdout}${run.stderr}');
    final clip = File('${tmp.path}/out/pic-4k.mp4');
    expect(clip.existsSync(), isTrue);

    final media = Directory('${tmp.path}/media')..createSync();
    final inbox = Directory('${tmp.path}/inbox')..createSync();
    clip.copySync('${inbox.path}/pic-4k.mp4');
    final config = ServerConfig(
      mediaDir: media.path,
      tokenFile: '${tmp.path}/token',
      inboxDir: inbox.path,
    );
    final db = HubDatabase.inMemory();
    final library = LibraryStore(
      config: config,
      db: db,
      looseFileGrace: Duration.zero,
      reconcileInterval: Duration.zero,
    );
    await library.start();
    var now = DateTime.utc(2026, 11, 24, 12);
    final watcher = InboxWatcher(
      dir: inbox.path,
      library: library,
      now: () => now,
      log: (_) {},
    );
    await watcher.pollNow();
    now = now.add(const Duration(seconds: 11));
    await watcher.pollNow();

    final item = (await library.items()).single;
    expect(item.kind, 'video');
    expect(item.name, 'pic-4k.mp4');
    expect(item.codec, 'hevc');
    expect(item.width, 3840);
    expect(item.height, 2160);
    expect(item.fps, closeTo(24, 0.1));
    expect(item.cacheRequired, isFalse);
    expect(File('${media.path}/${item.id}').existsSync(), isTrue);
    expect(File('${inbox.path}/pic-4k.mp4').existsSync(), isFalse);
    await watcher.stop();
    await library.stop();
    await db.close();
  }, timeout: const Timeout(Duration(minutes: 2)));
}
