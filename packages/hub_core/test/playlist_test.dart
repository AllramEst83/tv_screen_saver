import 'package:drift/drift.dart' show Value;
import 'package:hub_core/hub_core.dart';
import 'package:test/test.dart';

DeviceInfo _device(DeviceRole role) =>
    DeviceInfo(id: 'd-${role.name}', name: role.name, role: role);

HubCall _call(
  String type,
  DeviceRole role, [
  Map<String, dynamic> args = const {},
]) => HubCall(type: type, device: _device(role), args: args, connectionId: 'c');

void main() {
  serverExtrasTests();
  late HubDatabase db;
  late PlaylistStore store;
  late PlaylistModule module;

  Future<void> addItem(String id) => db.insertLibraryItem(
    LibraryItemsCompanion.insert(
      id: id,
      kind: id.endsWith('.mp4') ? 'video' : 'image',
      name: id,
      sha256: id.padRight(64, '0'),
      bytes: 10,
      createdAt: 1,
    ),
  );

  setUp(() async {
    db = HubDatabase.inMemory();
    store = PlaylistStore(
      db: db,
      knownItemIds: () async => {
        for (final r in await db.allLibraryItems()) r.id,
      },
    );
    module = PlaylistModule(store);
    for (final id in ['a.jpg', 'b.jpg', 'c.mp4', 'd.jpg']) {
      await addItem(id);
    }
  });

  tearDown(() async {
    await module.dispose();
    await db.close();
  });

  Future<Map<String, Object?>> create(Map<String, dynamic> args) async {
    final r = await module.handlers['playlist.create']!.handler(
      _call('playlist.create', DeviceRole.controller, args),
    );
    return (r! as Map)['playlist'] as Map<String, Object?>;
  }

  test('create keeps order, drops duplicates, has defaults', () async {
    final p = await create({
      'name': '  Holiday ',
      'items': ['b.jpg', 'a.jpg', 'b.jpg', 'c.mp4'],
    });
    expect(p['name'], 'Holiday');
    expect(p['items'], ['b.jpg', 'a.jpg', 'c.mp4']);
    expect(p['shuffle'], false);
    expect(p['muted'], false);
    expect(p['kenBurns'], false);
    expect(p['imageSeconds'], isNull);
    expect(p['transition'], isNull);
    expect((await store.list()).single['id'], p['id']);
  });

  test('a partial update changes only the given fields', () async {
    final p = await create({
      'name': 'One',
      'items': ['a.jpg'],
      'imageSeconds': 20,
    });
    final r = await module.handlers['playlist.update']!.handler(
      _call('playlist.update', DeviceRole.controller, {
        'id': p['id'],
        'shuffle': true,
        'imageSeconds': null,
      }),
    );
    final u = (r! as Map)['playlist'] as Map;
    expect(u['name'], 'One');
    expect(u['items'], ['a.jpg']);
    expect(u['shuffle'], true);
    expect(u['imageSeconds'], isNull);
  });

  test('bad input is refused with the field and nothing is stored', () async {
    for (final bad in <Map<String, dynamic>>[
      {'name': ''},
      {'name': 'x' * 61},
      {
        'name': 'ok',
        'items': ['nope.jpg'],
      },
      {'name': 'ok', 'items': 'a.jpg'},
      {'name': 'ok', 'imageSeconds': 2},
      {'name': 'ok', 'imageSeconds': 121},
      {'name': 'ok', 'transition': 'wipe'},
      {'name': 'ok', 'shuffle': 'yes'},
    ]) {
      await expectLater(
        create(bad),
        throwsA(
          isA<HubError>().having((e) => e.code, 'code', HubErrorCode.invalid),
        ),
        reason: '$bad',
      );
    }
    expect(await store.list(), isEmpty);
  });

  test('unknown playlist: not_found; delete is owner only', () async {
    await expectLater(
      module.handlers['playlist.update']!.handler(
        _call('playlist.update', DeviceRole.owner, {'id': 'nope', 'name': 'x'}),
      ),
      throwsA(
        isA<HubError>().having((e) => e.code, 'code', HubErrorCode.notFound),
      ),
    );
    expect(module.handlers['playlist.delete']!.requireOwner, isTrue);
    final p = await create({'name': 'Gone'});
    await module.handlers['playlist.delete']!.handler(
      _call('playlist.delete', DeviceRole.owner, {'id': p['id']}),
    );
    expect(await store.list(), isEmpty);
  });

  test('events go out for change and removal', () async {
    final seen = <String>[];
    final sub = store.events.listen((e) => seen.add(e.kind));
    final p = await create({'name': 'E'});
    await store.delete(p['id']! as String);
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();
    expect(seen, ['playlist.changed', 'playlist.removed']);
  });

  test(
    'play order: stored order, shuffle is stable, gone items skipped',
    () async {
      final p = await create({
        'name': 'Order',
        'items': ['d.jpg', 'a.jpg', 'c.mp4', 'b.jpg'],
      });
      final id = p['id']! as String;
      final source = StoredPlaylistSource(
        base: StaticPlaylistSource({
          'all': ['c.mp4'],
        }),
        orderedIds: store.orderedIds,
      );
      expect(await source.itemIds(id), ['d.jpg', 'a.jpg', 'c.mp4', 'b.jpg']);
      expect(await source.itemIds('all'), ['c.mp4']);
      expect(await source.itemIds('missing'), isNull);

      await store.update(id, {'shuffle': true});
      final first = await source.itemIds(id);
      expect(first, unorderedEquals(['d.jpg', 'a.jpg', 'c.mp4', 'b.jpg']));
      expect(await source.itemIds(id), first); // the same every time

      await db.deleteLibraryItem('a.jpg');
      expect(await source.itemIds(id), isNot(contains('a.jpg')));
    },
  );

  test('deleting a library item takes it out of its playlists', () async {
    final p = await create({
      'name': 'F',
      'items': ['a.jpg', 'b.jpg'],
    });
    await store.forgetItem('a.jpg');
    expect((await store.list()).single['items'], ['b.jpg']);
    expect(p['id'], isNotNull);
  });

  test('the snapshot lists the playlists', () async {
    await create({'name': 'S'});
    final snap = await module.snapshotFor(_device(DeviceRole.controller));
    expect((snap['playlists']! as List).length, 1);
  });
}

void serverExtrasTests() {
  group('what the TV is told about an item', () {
    late HubDatabase db;
    late PiServer server;

    setUp(() async {
      db = HubDatabase.inMemory();
      server = PiServer(
        ServerConfig(mediaDir: '.', tokenFile: 'x'),
        't',
        db: db,
      );
      await server.settings.load();
      for (final (id, kind, cache) in [
        ('a.jpg', 'image', false),
        ('b.mp4', 'video', true),
      ]) {
        await db.insertLibraryItem(
          LibraryItemsCompanion.insert(
            id: id,
            kind: kind,
            name: id,
            sha256: id.padRight(64, '0'),
            bytes: 500,
            createdAt: 1,
            cacheRequired: Value(cache),
          ),
        );
      }
    });

    tearDown(() => db.close());

    test('a photo follows the Settings, a playlist overrides them', () async {
      var extras = await server.loadExtras('all', 'a.jpg');
      expect(extras['kind'], 'image');
      expect(extras['imageMs'], server.settings.imageSeconds * 1000);
      expect(extras['transition'], server.settings.values['transition']);
      expect(extras['kenBurns'], false);

      final p = await server.playlistStore.create({
        'name': 'Mine',
        'items': ['a.jpg'],
        'imageSeconds': 30,
        'transition': 'cut',
        'kenBurns': true,
        'muted': true,
      });
      extras = await server.loadExtras('${p['id']}', 'a.jpg');
      expect(extras['imageMs'], 30000);
      expect(extras['transition'], 'cut');
      expect(extras['kenBurns'], true);
      expect(await server.muteFor('${p['id']}'), true);
      expect(await server.muteFor('all'), false);
    });

    test('a video says whether it must be cached first', () async {
      final extras = await server.loadExtras('all', 'b.mp4');
      expect(extras, {'kind': 'video', 'cacheRequired': true, 'bytes': 500});
    });

    test('an unknown item adds nothing', () async {
      expect(await server.loadExtras('all', 'nope.jpg'), isEmpty);
    });
  });
}
