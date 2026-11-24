import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:hub_core/hub_core.dart';
import 'package:test/test.dart';

import 'support/fake_tools.dart';

List<int> bytesOf(int n, [int seed = 7]) =>
    List.generate(n, (i) => (i * 31 + seed) % 251);

void main() {
  late Directory tmp;
  late String inbox;
  late String media;
  late HubDatabase db;
  late LibraryStore library;
  late InboxWatcher watcher;
  late FakeRunner runner;
  late DateTime clock;
  final events = <LibraryEvent>[];
  StreamSubscription<LibraryEvent>? sub;

  Future<void> build({int cap = 1 << 40, Set<String>? tools}) async {
    final config = ServerConfig(
      mediaDir: media,
      tokenFile: '${tmp.path}/token',
      storageCapBytes: cap,
    );
    runner = FakeRunner(
      available: tools ?? const {'ffprobe', 'ffmpeg', 'vips', 'vipsheader'},
    );
    db = HubDatabase.inMemory();
    library = LibraryStore(
      config: config,
      db: db,
      toolRunner: runner,
      looseFileGrace: Duration.zero,
      reconcileInterval: Duration.zero,
    );
    await library.start();
    sub = library.events.listen(events.add);
    watcher = InboxWatcher(
      dir: inbox,
      library: library,
      stableFor: const Duration(seconds: 10),
      now: () => clock,
      log: (_) {},
    );
    Directory(inbox).createSync(recursive: true);
  }

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('inbox');
    inbox = '${tmp.path}/inbox';
    media = '${tmp.path}/media';
    Directory(media).createSync();
    clock = DateTime.utc(2026, 11, 24, 12);
    events.clear();
  });

  tearDown(() async {
    await sub?.cancel();
    await watcher.stop();
    await library.stop();
    await db.close();
    tmp.deleteSync(recursive: true);
  });

  Future<void> settle() async {
    await watcher.pollNow(); // sees the file
    clock = clock.add(const Duration(seconds: 11));
    await watcher.pollNow(); // stable: imports
  }

  void drop(String name, List<int> bytes) =>
      File('$inbox/$name').writeAsBytesSync(bytes);

  String rejectedReason(String name) =>
      File('$inbox/rejected/$name.txt').readAsStringSync().trim();

  test('a stable photo is imported and leaves the inbox', () async {
    await build();
    final data = bytesOf(3000);
    drop('IMG 1.JPG', data);
    await settle();
    final items = await library.items();
    expect(items, hasLength(1));
    final item = items.single;
    final sha = sha256.convert(data).toString();
    expect(item.id, '${sha.substring(0, 16)}.jpg');
    expect(item.name, 'IMG 1.JPG');
    expect(item.sha256, sha);
    expect(File('$media/${item.id}').readAsBytesSync(), data);
    expect(File('$inbox/IMG 1.JPG').existsSync(), isFalse);
    await Future<void>.delayed(Duration.zero); // events are delivered async
    expect(events.map((e) => e.kind), contains('library.added'));
    expect(watcher.imported, 1);
  });

  test('a file that is still changing waits', () async {
    await build();
    drop('a.jpg', bytesOf(100));
    await watcher.pollNow();
    clock = clock.add(const Duration(seconds: 8));
    drop('a.jpg', bytesOf(200)); // still being copied
    await watcher.pollNow();
    clock = clock.add(const Duration(seconds: 8));
    await watcher.pollNow(); // only 8 s since the last change
    expect(await library.items(), isEmpty);
    clock = clock.add(const Duration(seconds: 5));
    await watcher.pollNow();
    expect(await library.items(), hasLength(1));
  });

  test('a duplicate goes to rejected with a reason; nothing is lost', () async {
    await build();
    drop('a.jpg', bytesOf(500));
    await settle();
    drop('copy.jpg', bytesOf(500));
    await settle();
    expect(await library.items(), hasLength(1));
    expect(File('$inbox/rejected/copy.jpg').existsSync(), isTrue);
    expect(rejectedReason('copy.jpg'), contains('Already in the library'));
    expect(watcher.rejected, 1);
  });

  test('an unsupported file is rejected; hidden files are ignored', () async {
    await build();
    drop('notes.docx', bytesOf(50));
    drop('.hidden.jpg', bytesOf(50));
    drop('~lock.jpg', bytesOf(50));
    await settle();
    expect(rejectedReason('notes.docx'), contains('Not a picture or video'));
    expect(File('$inbox/.hidden.jpg').existsSync(), isTrue);
    expect(File('$inbox/~lock.jpg').existsSync(), isTrue);
    expect(await library.items(), isEmpty);
  });

  test('a second rejected file with the same name gets a new name', () async {
    await build();
    drop('x.docx', bytesOf(10));
    await settle();
    drop('x.docx', bytesOf(11));
    await settle();
    expect(File('$inbox/rejected/x.docx').existsSync(), isTrue);
    expect(File('$inbox/rejected/x (2).docx').existsSync(), isTrue);
    expect(File('$inbox/rejected/x (2).docx.txt').existsSync(), isTrue);
  });

  test(
    'a photo above 4096 px is scaled down once; the original goes',
    () async {
      await build();
      runner.imageHeader = 'width: 6000\nheight: 4000\n';
      drop('big.png', bytesOf(5000));
      await settle();
      final item = (await library.items()).single;
      expect(item.id, endsWith('.jpg'));
      expect(item.name, 'big.png');
      expect(File('$inbox/big.png').existsSync(), isFalse);
      final vips = runner.calls.where((c) => c.first == 'vips').single;
      expect(vips, containsAll(['thumbnail', '4096', '--size', 'down']));
      expect(vips[3], contains('Q=95'));
      expect(vips[3], contains('keep=icc'));
    },
  );

  test('a photo that fits is kept byte for byte', () async {
    await build();
    runner.imageHeader = 'width: 3000\nheight: 2000\n';
    final data = bytesOf(900);
    drop('fit.jpg', data);
    await settle();
    final item = (await library.items()).single;
    expect(File('$media/${item.id}').readAsBytesSync(), data);
    expect(runner.calls.where((c) => c.first == 'vips'), isEmpty);
  });

  test('an image vips cannot read is rejected', () async {
    await build();
    runner.imageHeader = '';
    drop('broken.jpg', bytesOf(100));
    await settle();
    expect(rejectedReason('broken.jpg'), contains('could not be read'));
  });

  test('a full Pi rejects with a clear reason', () async {
    await build(cap: 1000);
    drop('a.jpg', bytesOf(2000));
    await settle();
    expect(rejectedReason('a.jpg'), contains('The Pi is full'));
    expect(await library.items(), isEmpty);
  });

  test(
    'a video above the ceiling and too large for the cache is rejected',
    () async {
      await build();
      // 200 Mbit/s and 1 GB: heavier than the ceiling and above 25 % of cache.
      runner.probeOutput = ffprobeJson(bitRate: 200000000);
      drop('huge.mp4', bytesOf(100));
      final file = File('$inbox/huge.mp4');
      // The probe sees the declared size through the rule; shrink the cache so
      // the small test file counts as large.
      library.config.tvCacheBytes = 100;
      expect(await file.length(), 100);
      await settle();
      expect(rejectedReason('huge.mp4'), isNotEmpty);
      expect(await library.items(), isEmpty);
    },
  );
}
