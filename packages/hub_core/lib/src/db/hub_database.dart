import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:sqlite3/open.dart';

part 'hub_database.g.dart';

/// Raspberry Pi OS ships only `libsqlite3.so.0` (the runtime package); the
/// unversioned `libsqlite3.so` comes with the `-dev` package. Load either.
void _configureSqliteLibrary() {
  open.overrideFor(OperatingSystem.linux, () {
    for (final name in const ['libsqlite3.so', 'libsqlite3.so.0']) {
      try {
        return DynamicLibrary.open(name);
      } catch (_) {}
    }
    return DynamicLibrary.open('libsqlite3.so.0'); // throws a clear error
  });
}

/// Computes a lowercase hex SHA-256 hash of a raw pairing token.
String hashToken(String rawToken) =>
    sha256.convert(utf8.encode(rawToken)).toString();

/// Constant-time comparison of two UTF-8 strings.
bool constantTimeEquals(String a, String b) {
  final ab = utf8.encode(a);
  final bb = utf8.encode(b);
  var diff = ab.length ^ bb.length;
  final n = ab.length > bb.length ? ab.length : bb.length;
  for (var i = 0; i < n; i++) {
    diff |= (i < ab.length ? ab[i] : 0) ^ (i < bb.length ? bb[i] : 0);
  }
  return diff == 0;
}

@DataClassName('DeviceRow')
class Devices extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get role => text()(); // 'owner' | 'controller' | 'display'
  IntColumn get createdAt => integer()();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('PairingRow')
class Pairings extends Table {
  TextColumn get tokenHash => text()();
  TextColumn get deviceId =>
      text().references(Devices, #id, onDelete: KeyAction.cascade)();
  TextColumn get clientName => text()();
  IntColumn get createdAt => integer()();
  IntColumn get lastSeenAt => integer()();

  @override
  Set<Column> get primaryKey => {tokenHash};
}

/// One stored photo or video. `id` is the file name in the media directory.
@DataClassName('LibraryItemRow')
class LibraryItems extends Table {
  TextColumn get id => text()();
  TextColumn get kind => text()(); // 'image' | 'video'
  TextColumn get name => text()();

  /// Lowercase hex SHA-256, or `pending:<id>` until the startup import has
  /// hashed a loose file.
  TextColumn get sha256 => text().unique()();
  IntColumn get bytes => integer()();
  IntColumn get width => integer().nullable()();
  IntColumn get height => integer().nullable()();
  IntColumn get durationMs => integer().nullable()();
  TextColumn get codec => text().nullable()();
  TextColumn get hdr => text().nullable()();
  RealColumn get fps => real().nullable()();
  IntColumn get bitrate => integer().nullable()();
  IntColumn get createdAt => integer()();

  // Schema 3: what the media worker found out.
  TextColumn get audioCodec => text().nullable()();
  TextColumn get profile => text().nullable()();

  /// `new` (not checked yet), `ready`, `unsupported` or `error`.
  TextColumn get state => text().withDefault(const Constant('new'))();
  TextColumn get stateReason => text().nullable()();

  /// The video is above the streaming ceiling: the TV plays it once cached.
  BoolColumn get cacheRequired =>
      boolean().withDefault(const Constant(false))();

  /// Comma list of the variants that exist (`poster,thumb` / `1920,thumb`).
  TextColumn get variants => text().withDefault(const Constant(''))();

  @override
  Set<Column> get primaryKey => {id};
}

/// An unfinished resumable upload.
@DataClassName('UploadRow')
class Uploads extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  IntColumn get bytes => integer()();
  TextColumn get sha256 => text().unique()();
  TextColumn get mime => text()();
  IntColumn get received => integer().withDefault(const Constant(0))();

  /// The paired device that started it; empty for the static token.
  TextColumn get deviceId => text().withDefault(const Constant(''))();
  IntColumn get createdAt => integer()();

  @override
  Set<Column> get primaryKey => {id};
}

/// One persisted setting: `key` is the setting name, `value` its JSON.
@DataClassName('SettingRow')
class Settings extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}

/// A stored playlist. `items` is a JSON list of library item ids;
/// `imageSeconds` and `transition` null mean "follow the Settings".
@DataClassName('PlaylistRow')
class Playlists extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get items => text().withDefault(const Constant('[]'))();
  BoolColumn get shuffle => boolean().withDefault(const Constant(false))();
  IntColumn get imageSeconds => integer().nullable()();
  TextColumn get transition => text().nullable()();
  BoolColumn get kenBurns => boolean().withDefault(const Constant(false))();
  BoolColumn get muted => boolean().withDefault(const Constant(false))();
  IntColumn get createdAt => integer()();
  IntColumn get updatedAt => integer()();

  @override
  Set<Column> get primaryKey => {id};
}

@DriftDatabase(
  tables: [Devices, Pairings, LibraryItems, Uploads, Settings, Playlists],
)
class HubDatabase extends _$HubDatabase {
  HubDatabase(super.e);

  /// File-backed database at [path]; creates parent directories.
  factory HubDatabase.open(String path) {
    _configureSqliteLibrary();
    final file = File(path);
    file.parent.createSync(recursive: true);
    final existed = file.existsSync();
    final db = HubDatabase(NativeDatabase(file));
    if (!existed && !Platform.isWindows) {
      // Create the file now so it can be restricted before any data lands.
      file.createSync();
      Process.runSync('chmod', ['600', path]);
    }
    return db;
  }

  factory HubDatabase.inMemory() => HubDatabase(NativeDatabase.memory());

  @override
  int get schemaVersion => 5;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) => m.createAll(),
    onUpgrade: (m, from, to) async {
      if (from < 2) {
        // Created with the current definition: it has the schema 3 columns.
        await m.createTable(libraryItems);
        await m.createTable(uploads);
      } else if (from < 3) {
        await m.addColumn(libraryItems, libraryItems.audioCodec);
        await m.addColumn(libraryItems, libraryItems.profile);
        await m.addColumn(libraryItems, libraryItems.state);
        await m.addColumn(libraryItems, libraryItems.stateReason);
        await m.addColumn(libraryItems, libraryItems.cacheRequired);
        await m.addColumn(libraryItems, libraryItems.variants);
      }
      if (from < 4) {
        await m.createTable(settings);
      }
      if (from < 5) {
        await m.createTable(playlists);
      }
    },
    beforeOpen: (details) async {
      await customStatement('PRAGMA foreign_keys = ON');
    },
  );

  // ---- Devices ----

  Future<List<DeviceRow>> allDevices() =>
      (select(devices)..orderBy([(t) => OrderingTerm.asc(t.createdAt)])).get();

  /// Latest pairing activity per device id (epoch ms).
  Future<Map<String, int>> lastSeenByDevice() async {
    final out = <String, int>{};
    for (final p in await select(pairings).get()) {
      final old = out[p.deviceId];
      if (old == null || p.lastSeenAt > old) out[p.deviceId] = p.lastSeenAt;
    }
    return out;
  }

  Future<DeviceRow?> getDevice(String id) =>
      (select(devices)..where((t) => t.id.equals(id))).getSingleOrNull();

  /// Role for the next paired phone: `owner` while no phone is owner, else
  /// `controller`. Displays do not take part in the election.
  Future<String> nextDeviceRole() async =>
      (await allDevices()).any((d) => d.role == 'owner')
      ? 'controller'
      : 'owner';

  /// Number of paired phones (every device that is not a display).
  Future<int> phoneCount() async =>
      (await allDevices()).where((d) => d.role != 'display').length;

  Future<List<DeviceRow>> displays() async =>
      (await allDevices()).where((d) => d.role == 'display').toList();

  Future<void> insertDevice({
    required String id,
    required String name,
    required String role,
    required int nowMs,
  }) => into(devices).insertOnConflictUpdate(
    DevicesCompanion.insert(id: id, name: name, role: role, createdAt: nowMs),
  );

  Future<void> renameDevice(String id, String name) => (update(
    devices,
  )..where((t) => t.id.equals(id))).write(DevicesCompanion(name: Value(name)));

  /// Deletes the device and (by cascade) its pairings.
  Future<void> deleteDevice(String id) async {
    await (delete(pairings)..where((t) => t.deviceId.equals(id))).go();
    await (delete(devices)..where((t) => t.id.equals(id))).go();
  }

  // ---- Pairings ----

  Future<List<PairingRow>> allPairings() => select(pairings).get();

  Future<PairingRow?> verifyRawToken(String rawToken) async {
    final candidateHash = hashToken(rawToken);
    final rows = await select(pairings).get();
    PairingRow? matched;
    for (final row in rows) {
      if (constantTimeEquals(row.tokenHash, candidateHash)) {
        matched = row;
      }
    }
    return matched;
  }

  /// The pairing whose stored hash equals [tokenHash], if any.
  Future<PairingRow?> pairingByHash(String tokenHash) => (select(
    pairings,
  )..where((t) => t.tokenHash.equals(tokenHash))).getSingleOrNull();

  Future<void> insertPairing({
    required String rawToken,
    required String deviceId,
    required String clientName,
    required int nowMs,
  }) => into(pairings).insertOnConflictUpdate(
    PairingsCompanion.insert(
      tokenHash: hashToken(rawToken),
      deviceId: deviceId,
      clientName: clientName,
      createdAt: nowMs,
      lastSeenAt: nowMs,
    ),
  );

  Future<void> touchPairing(String tokenHash, int nowMs) =>
      (update(pairings)..where((t) => t.tokenHash.equals(tokenHash))).write(
        PairingsCompanion(lastSeenAt: Value(nowMs)),
      );

  /// Deletes every device and pairing (phones and display).
  Future<void> deleteAllDevices() => transaction(() async {
    await delete(pairings).go();
    await delete(devices).go();
  });

  /// Deletes every phone (non-display) device and its pairings.
  Future<void> deleteAllPhones() => transaction(() async {
    final ids = [
      for (final d in await allDevices())
        if (d.role != 'display') d.id,
    ];
    await (delete(pairings)..where((t) => t.deviceId.isIn(ids))).go();
    await (delete(devices)..where((t) => t.id.isIn(ids))).go();
  });

  // ---- Library ----

  Future<List<LibraryItemRow>> allLibraryItems() => (select(
    libraryItems,
  )..orderBy([(t) => OrderingTerm.asc(t.createdAt)])).get();

  Future<LibraryItemRow?> libraryItem(String id) =>
      (select(libraryItems)..where((t) => t.id.equals(id))).getSingleOrNull();

  Future<LibraryItemRow?> libraryItemBySha(String sha) => (select(
    libraryItems,
  )..where((t) => t.sha256.equals(sha))).getSingleOrNull();

  Future<void> insertLibraryItem(LibraryItemsCompanion item) =>
      into(libraryItems).insert(item);

  Future<int> deleteLibraryItem(String id) =>
      (delete(libraryItems)..where((t) => t.id.equals(id))).go();

  Future<int> renameLibraryItem(String id, String name) =>
      (update(libraryItems)..where((t) => t.id.equals(id))).write(
        LibraryItemsCompanion(name: Value(name)),
      );

  /// Writes the media worker's findings. Does nothing when the row is gone.
  Future<int> updateLibraryItemMedia(String id, LibraryItemsCompanion c) =>
      (update(libraryItems)..where((t) => t.id.equals(id))).write(c);

  Future<int> setLibraryItemSha(String id, String sha) =>
      (update(libraryItems)..where((t) => t.id.equals(id))).write(
        LibraryItemsCompanion(sha256: Value(sha)),
      );

  /// Rows whose hash the startup import has not computed yet.
  Future<List<LibraryItemRow>> pendingLibraryItems() =>
      (select(libraryItems)..where((t) => t.sha256.like('pending:%'))).get();

  Future<int> libraryBytes() async {
    final sum = libraryItems.bytes.sum();
    final row = await (selectOnly(libraryItems)..addColumns([sum])).getSingle();
    return row.read(sum) ?? 0;
  }

  // ---- Settings ----

  /// Every stored setting as key to JSON text.
  Future<Map<String, String>> allSettings() async => {
    for (final r in await select(settings).get()) r.key: r.value,
  };

  /// Writes [values] (key to JSON text) in one transaction.
  Future<void> writeSettings(Map<String, String> values) =>
      transaction(() async {
        for (final e in values.entries) {
          await into(settings).insertOnConflictUpdate(
            SettingsCompanion.insert(key: e.key, value: e.value),
          );
        }
      });

  // ---- Playlists ----

  Future<List<PlaylistRow>> allPlaylists() => (select(
    playlists,
  )..orderBy([(t) => OrderingTerm.asc(t.createdAt)])).get();

  Future<PlaylistRow?> playlistById(String id) =>
      (select(playlists)..where((t) => t.id.equals(id))).getSingleOrNull();

  Future<void> writePlaylist(PlaylistsCompanion row) =>
      into(playlists).insertOnConflictUpdate(row);

  Future<int> deletePlaylistRow(String id) =>
      (delete(playlists)..where((t) => t.id.equals(id))).go();

  // ---- Uploads ----

  Future<List<UploadRow>> allUploads() => select(uploads).get();

  Future<UploadRow?> uploadById(String id) =>
      (select(uploads)..where((t) => t.id.equals(id))).getSingleOrNull();

  Future<UploadRow?> uploadBySha(String sha) =>
      (select(uploads)..where((t) => t.sha256.equals(sha))).getSingleOrNull();

  Future<void> insertUpload(UploadsCompanion row) => into(uploads).insert(row);

  Future<int> setUploadReceived(String id, int received) =>
      (update(uploads)..where((t) => t.id.equals(id))).write(
        UploadsCompanion(received: Value(received)),
      );

  Future<int> deleteUpload(String id) =>
      (delete(uploads)..where((t) => t.id.equals(id))).go();

  Future<int> uploadsBytes() async {
    final sum = uploads.bytes.sum();
    final row = await (selectOnly(uploads)..addColumns([sum])).getSingle();
    return row.read(sum) ?? 0;
  }
}
