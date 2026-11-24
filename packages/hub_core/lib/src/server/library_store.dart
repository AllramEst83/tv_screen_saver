import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' show Value;

import '../config.dart';
import '../db/hub_database.dart';
import 'media_probe.dart';
import 'media_worker.dart';
import 'tool_runner.dart';

/// Largest image (after phone prep) and video the Pi accepts.
const kMaxImageBytes = 80 * 1024 * 1024;
const kMaxVideoBytes = 50 * 1024 * 1024 * 1024;

/// Largest single `PUT` chunk.
const kMaxChunkBytes = 64 * 1024 * 1024;

/// Unfinished uploads older than this are deleted.
const kUploadTtl = Duration(hours: 24);

const _pendingPrefix = 'pending:';
const _dupPrefix = 'dup:';

/// The variants a client may ask for besides `full`.
const kVariants = {'thumb', 'poster', '1920'};

const _imageMimes = {
  'image/jpeg': 'jpg',
  'image/png': 'png',
  'image/webp': 'webp',
  'image/gif': 'gif',
  'image/avif': 'avif',
  'image/heic': 'heic',
  'image/heif': 'heif',
};

const _videoMimes = {
  'video/mp4': 'mp4',
  'video/x-m4v': 'm4v',
  'video/quicktime': 'mov',
  'video/x-matroska': 'mkv',
  'video/webm': 'webm',
  'video/mp2t': 'ts',
};

const _imageExtensions = {
  'jpg',
  'jpeg',
  'png',
  'webp',
  'gif',
  'avif',
  'heic',
  'heif',
};
const _videoExtensions = {'mp4', 'm4v', 'mov', 'mkv', 'webm', 'ts'};

final _idPattern = RegExp(r'^[A-Za-z0-9._-]+$');
final _shaPattern = RegExp(r'^[0-9a-f]{64}$');

/// `image` or `video` for a supported [mime], else null.
String? kindForMime(String mime) {
  final m = mime.toLowerCase();
  if (_imageMimes.containsKey(m)) return 'image';
  if (_videoMimes.containsKey(m)) return 'video';
  return null;
}

/// `image`, `video` or null (not a servable media file) for a file name.
String? kindForFileName(String name) {
  final dot = name.lastIndexOf('.');
  if (dot <= 0) return null;
  final ext = name.substring(dot + 1).toLowerCase();
  if (_imageExtensions.contains(ext)) return 'image';
  if (_videoExtensions.contains(ext)) return 'video';
  return null;
}

bool isValidSha256(Object? v) => v is String && _shaPattern.hasMatch(v);

/// The library item as clients see it.
Map<String, Object?> libraryItemJson(LibraryItemRow r) => {
  'id': r.id,
  'kind': r.kind,
  'name': r.name,
  'sha256':
      r.sha256.startsWith(_pendingPrefix) || r.sha256.startsWith(_dupPrefix)
      ? null
      : r.sha256,
  'bytes': r.bytes,
  'width': r.width,
  'height': r.height,
  'durationMs': r.durationMs,
  'codec': r.codec,
  'hdr': r.hdr,
  'fps': r.fps,
  'bitrate': r.bitrate,
  'createdAt': r.createdAt,
  'audioCodec': r.audioCodec,
  'profile': r.profile,
  'state': r.state,
  'stateReason': r.stateReason,
  'cacheRequired': r.cacheRequired,
  'variants': r.variants.isEmpty ? const <String>[] : r.variants.split(','),
};

/// Something that happened to the library: `added`, `updated` or `removed`.
class LibraryEvent {
  const LibraryEvent(this.kind, this.data);

  /// `library.added`, `library.updated` or `library.removed`.
  final String kind;
  final Map<String, Object?> data;
}

/// Why an upload could not start or continue. [status] is the HTTP status.
class UploadRefused implements Exception {
  const UploadRefused(
    this.status, [
    this.body = const {},
    this.headers = const {},
  ]);

  final int status;
  final Map<String, Object?> body;
  final Map<String, String> headers;

  @override
  String toString() => 'UploadRefused($status)';
}

/// Outcome of the last chunk.
class UploadResult {
  const UploadResult.progress(this.received) : item = null;
  const UploadResult.done(this.item) : received = 0;

  final int received;
  final LibraryItemRow? item;
}

class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

/// Running SHA-256 of an upload while its chunks arrive in order.
class _RunningHash {
  _RunningHash() {
    input = sha256.startChunkedConversion(_sink);
  }

  final _sink = _DigestSink();
  late final ByteConversionSink input;

  /// Bytes fed so far.
  int offset = 0;

  String finish() {
    input.close();
    return _sink.value.toString();
  }
}

/// Drops `;` parameters and normalizes case.
String normalizeMime(String mime) => mime.split(';').first.trim().toLowerCase();

/// The library: items in [HubDatabase], files in `mediaDir`, unfinished
/// uploads in `mediaDir/.uploads`, image and video variants in
/// `mediaDir/.variants`.
class LibraryStore {
  LibraryStore({
    required this.config,
    required this.db,
    DateTime Function()? now,
    Future<int?> Function(String dir)? freeBytes,
    this.looseFileGrace = const Duration(seconds: 10),
    this.reconcileInterval = const Duration(seconds: 5),
    ToolRunner? toolRunner,
  }) : _now = now ?? DateTime.now,
       _freeBytes = freeBytes ?? _dfFreeBytes {
    worker = MediaWorker(
      config: config,
      db: db,
      runner: toolRunner ?? ProcessToolRunner(),
      pathOf: pathOf,
      variantsDir: _variantsDir,
      onUpdated: (row) => _emit('library.updated', libraryItemJson(row)),
      capabilities: () => capabilities?.call(),
    );
  }

  final ServerConfig config;
  final HubDatabase db;
  final DateTime Function() _now;
  final Future<int?> Function(String dir) _freeBytes;

  /// Loose files modified more recently than this are still being copied and
  /// are not imported yet.
  final Duration looseFileGrace;

  /// The shortest time between two reconcile runs started by readers.
  final Duration reconcileInterval;

  /// Called after an item is removed (delete or file gone), so the player can
  /// move on. Errors are ignored.
  Future<void> Function(String id)? onItemRemoved;

  /// The background media worker (ffprobe, ffmpeg, libvips).
  late final MediaWorker worker;

  /// What the TV reported in `display.capabilities`, or null when no display
  /// has reported yet. Set by the server.
  Map<String, Object?>? Function()? capabilities;

  /// How many times a finished upload had to be re-read from disk to verify
  /// it (no running hash: the server restarted). For tests.
  int diskHashes = 0;

  final _events = StreamController<LibraryEvent>.broadcast();
  final Set<String> _busyUploads = {};
  final Map<String, _RunningHash> _hashers = {};
  final Set<String> _finishing = {};
  Timer? _hourlyTimer;
  bool _stopped = false;
  Future<void> _hashing = Future.value();
  Future<void> _startChain = Future.value();
  Future<void> _reconcileChain = Future.value();
  Stopwatch? _sinceReconcile;

  Stream<LibraryEvent> get events => _events.stream;

  String get _uploadsDir => '${config.mediaDir}/.uploads';
  String get _variantsDir => '${config.mediaDir}/.variants';
  String _partPath(String uploadId) => '$_uploadsDir/$uploadId.part';
  String pathOf(String id) => '${config.mediaDir}/$id';
  String variantPath(String id, String variant) => '$_variantsDir/$id.$variant';

  int get _nowMs => _now().millisecondsSinceEpoch;

  void _emit(String kind, Map<String, Object?> data) {
    if (!_events.isClosed) _events.add(LibraryEvent(kind, data));
  }

  void _removed(String id) {
    _emit('library.removed', {'id': id});
    final cb = onItemRemoved;
    if (cb != null) cb(id).then<void>((_) {}, onError: (Object _) {});
  }

  // ---- lifecycle ----

  /// Prepares the directories, drops stale uploads, finishes uploads a crash
  /// left half done, imports loose files and starts the hourly sweep. Hashing
  /// of imported files continues in the background (see [hashingDone]).
  Future<void> start() async {
    _stopped = false;
    await Directory(_uploadsDir).create(recursive: true);
    await expireStaleUploads();
    await _recoverUploads();
    await worker.start();
    await reconcile();
    _hashing = _hashing.then((_) => _hashPending()); // left from last run
    _hourlyTimer?.cancel();
    _hourlyTimer = Timer.periodic(const Duration(hours: 1), (_) {
      expireStaleUploads()
          .then<void>((_) => worker.refreshTools())
          .then<void>((_) => reconcile())
          .then<void>((_) {}, onError: (Object _) {});
    });
  }

  /// Completes when the background hashing of imported files has finished.
  Future<void> get hashingDone => _hashing;

  Future<void> stop() async {
    _stopped = true;
    _hourlyTimer?.cancel();
    _hourlyTimer = null;
    await worker.stop();
    await _hashing.catchError((Object _) {});
    await _reconcileChain.catchError((Object _) {});
  }

  // ---- reading ----

  Future<List<LibraryItemRow>> items() => db.allLibraryItems();

  /// Stored bytes plus the declared size of unfinished uploads.
  Future<int> usedBytes() async =>
      await db.libraryBytes() + await db.uploadsBytes();

  Future<Map<String, Object?>> snapshot() async => {
    'items': [for (final r in await items()) libraryItemJson(r)],
    'storage': {
      'usedBytes': await usedBytes(),
      'capBytes': config.storageCapBytes,
    },
  };

  /// Ids of the playable video items (not `unsupported`) sorted by name
  /// (ignoring case).
  Future<List<String>> videoIds() async {
    final rows = [
      for (final r in await items())
        if (r.kind == 'video' && r.state != 'unsupported') r,
    ];
    rows.sort((a, b) {
      final c = a.name.toLowerCase().compareTo(b.name.toLowerCase());
      if (c != 0) return c;
      final d = a.name.compareTo(b.name);
      return d != 0 ? d : a.id.compareTo(b.id);
    });
    return [for (final r in rows) r.id];
  }

  /// Why item [id] cannot be played (it is `unsupported`), else null.
  Future<String?> unplayableReason(String id) async {
    final r = await db.libraryItem(id);
    if (r == null || r.state != 'unsupported') return null;
    return r.stateReason ?? 'The TV cannot play this video';
  }

  /// The TV's capabilities changed: check the videos again.
  Future<void> capabilitiesChanged() => worker.recheck();

  Future<LibraryItemRow?> itemBySha(String sha) => db.libraryItemBySha(sha);

  // ---- changing ----

  /// Renames an item. Null when it does not exist.
  Future<LibraryItemRow?> rename(String id, String name) async {
    if (await db.renameLibraryItem(id, name) == 0) return null;
    final row = await db.libraryItem(id);
    if (row != null) _emit('library.updated', libraryItemJson(row));
    return row;
  }

  /// Removes the file, its variants and then the row. False when unknown.
  Future<bool> deleteItem(String id) async {
    if (!_idPattern.hasMatch(id) || id.startsWith('.')) return false;
    final row = await db.libraryItem(id);
    if (row == null) return false;
    worker.remove(id);
    await _removeFiles(id);
    await db.deleteLibraryItem(id);
    _removed(id);
    return true;
  }

  Future<void> _removeFiles(String id) async {
    await _deleteFile(pathOf(id));
    for (final v in kVariants) {
      await _deleteFile(variantPath(id, v));
      await _deleteFile('${variantPath(id, v)}.tmp.jpg');
    }
  }

  Future<void> _deleteFile(String path) async {
    try {
      await File(path).delete();
    } on FileSystemException {
      // Already gone.
    }
  }

  // ---- uploads ----

  static final _random = Random.secure();

  String _newUploadId() => List.generate(
    16,
    (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();

  Future<T> _serializedStart<T>(Future<T> Function() body) {
    final run = _startChain.then((_) => body());
    _startChain = run.then<void>((_) {}, onError: (Object _) {});
    return run;
  }

  /// Starts (or resumes) an upload. Throws [UploadRefused]. Calls run one at
  /// a time, so two clients cannot both pass the duplicate and cap checks.
  Future<({String uploadId, int received})> startUpload({
    required String name,
    required int bytes,
    required String sha256,
    required String mime,
    required String deviceId,
  }) => _serializedStart(() async {
    final type = normalizeMime(mime);
    final kind = kindForMime(type);
    if (kind == null) {
      throw const UploadRefused(HttpStatus.unsupportedMediaType);
    }
    final limit = kind == 'image' ? kMaxImageBytes : kMaxVideoBytes;
    if (bytes > limit) {
      throw const UploadRefused(HttpStatus.requestEntityTooLarge);
    }
    final existing = await db.libraryItemBySha(sha256);
    if (existing != null) {
      throw UploadRefused(HttpStatus.conflict, {'id': existing.id});
    }
    var unfinished = await db.uploadBySha(sha256);
    if (unfinished != null) {
      final busy = _busyUploads.contains(unfinished.id);
      if (!busy &&
          unfinished.received >= unfinished.bytes &&
          !await File(_partPath(unfinished.id)).exists()) {
        final item = await _recoverUpload(unfinished);
        if (item != null) {
          throw UploadRefused(HttpStatus.conflict, {'id': item.id});
        }
        unfinished = null;
      }
    }
    if (unfinished != null) {
      final busy = _busyUploads.contains(unfinished.id);
      final received = await _syncReceived(unfinished);
      if (received >= unfinished.bytes && !busy) {
        // The server stopped after the last chunk but before verifying it.
        final item = await _finish(unfinished); // throws 422 / 409 on failure
        throw UploadRefused(HttpStatus.conflict, {'id': item.id});
      }
      return (uploadId: unfinished.id, received: received);
    }
    final used = await usedBytes();
    final others = [
      for (final u in await db.allUploads()) u.bytes - u.received,
    ].fold<int>(0, (a, b) => a + b);
    final free = await _freeBytes(config.mediaDir);
    if (used + bytes > config.storageCapBytes ||
        (free != null && bytes + others > free)) {
      throw UploadRefused(HttpStatus.insufficientStorage, {
        'code': 'full',
        'usedBytes': used,
        'capBytes': config.storageCapBytes,
      });
    }
    final id = _newUploadId();
    await Directory(_uploadsDir).create(recursive: true);
    await File(_partPath(id)).create();
    try {
      await db.insertUpload(
        UploadsCompanion.insert(
          id: id,
          name: name,
          bytes: bytes,
          sha256: sha256,
          mime: type,
          deviceId: Value(deviceId),
          createdAt: _nowMs,
        ),
      );
    } catch (_) {
      await _deleteFile(_partPath(id));
      final again = await db.uploadBySha(sha256);
      if (again == null) rethrow;
      return (uploadId: again.id, received: again.received);
    }
    return (uploadId: id, received: 0);
  });

  /// The bytes the Pi really holds for [row]; the row is corrected when the
  /// file is shorter (a crash lost data) and the file is cut back when longer.
  /// While a chunk is in flight (and [held] is false) the row is returned
  /// as is.
  Future<int> _syncReceived(UploadRow row, {bool held = false}) async {
    if (!held && _busyUploads.contains(row.id)) return row.received;
    final file = File(_partPath(row.id));
    if (!await file.exists()) await file.create(recursive: true);
    var length = await file.length();
    if (length > row.received) {
      final raf = await file.open(mode: FileMode.append);
      try {
        await raf.truncate(row.received);
      } finally {
        await raf.close();
      }
      length = row.received;
    }
    if (length < row.received) {
      await db.setUploadReceived(row.id, length);
      _hashers.remove(row.id);
    }
    return length;
  }

  /// Bytes received so far, or null for an unknown upload.
  Future<int?> uploadOffset(String uploadId) async {
    final row = await db.uploadById(uploadId);
    return row == null ? null : _syncReceived(row);
  }

  /// Appends one chunk. [start]..[end] is the inclusive byte range and [total]
  /// the size announced at the start. Throws [UploadRefused].
  Future<UploadResult> putChunk(
    String uploadId, {
    required int start,
    required int end,
    required int total,
    required Stream<List<int>> body,
  }) async {
    if (!_busyUploads.add(uploadId)) {
      throw const UploadRefused(HttpStatus.conflict);
    }
    try {
      final row = await db.uploadById(uploadId);
      if (row == null) {
        _hashers.remove(uploadId);
        throw const UploadRefused(HttpStatus.notFound);
      }
      final received = await _syncReceived(row, held: true);
      if (start != received) {
        throw UploadRefused(HttpStatus.requestedRangeNotSatisfiable, const {}, {
          HttpHeaders.contentRangeHeader: 'bytes */$received',
        });
      }
      if (total != row.bytes || end < start || end >= row.bytes) {
        throw const UploadRefused(HttpStatus.badRequest);
      }
      final length = end - start + 1;
      if (length > kMaxChunkBytes) {
        throw const UploadRefused(HttpStatus.requestEntityTooLarge);
      }
      var hash = _hashers[uploadId];
      if (hash != null && hash.offset != received) {
        _hashers.remove(uploadId);
        hash = null;
      }
      if (hash == null && received == 0) {
        hash = _hashers[uploadId] = _RunningHash();
      }
      final raf = await File(_partPath(uploadId)).open(mode: FileMode.append);
      var written = 0;
      try {
        await raf.truncate(received);
        await for (final chunk in body) {
          written += chunk.length;
          if (written > length) break;
          await raf.writeFrom(chunk);
          hash?.input.add(chunk);
        }
        if (written != length) {
          throw const UploadRefused(HttpStatus.badRequest);
        }
        await raf.flush();
      } catch (_) {
        // Bytes may be in the hash that are not kept: start over at the end.
        _hashers.remove(uploadId);
        try {
          await raf.truncate(received);
        } catch (_) {}
        rethrow;
      } finally {
        await raf.close();
      }
      final now = received + length;
      hash?.offset = now;
      await db.setUploadReceived(uploadId, now);
      if (now < row.bytes) return UploadResult.progress(now);
      final running = _hashers.remove(uploadId);
      final digest = running != null && running.offset == row.bytes
          ? running.finish()
          : null;
      return UploadResult.done(await _finish(row, digest: digest));
    } finally {
      _busyUploads.remove(uploadId);
    }
  }

  /// Verifies the finished part file and moves it into the library. [digest]
  /// is the running hash; without it the file is read again.
  Future<LibraryItemRow> _finish(UploadRow row, {String? digest}) async {
    final part = File(_partPath(row.id));
    _hashers.remove(row.id);
    if (!await part.exists()) {
      await db.deleteUpload(row.id);
      throw const UploadRefused(HttpStatus.notFound);
    }
    var actual = digest;
    if (actual == null) {
      diskHashes++;
      actual = await _hashFile(part);
    }
    if (actual != row.sha256) {
      await _deleteFile(part.path);
      await db.deleteUpload(row.id);
      throw const UploadRefused(HttpStatus.unprocessableEntity);
    }
    final dup = await db.libraryItemBySha(row.sha256);
    if (dup != null) {
      await _deleteFile(part.path);
      await db.deleteUpload(row.id);
      throw UploadRefused(HttpStatus.conflict, {'id': dup.id});
    }
    final ext = (_imageMimes[row.mime] ?? _videoMimes[row.mime])!;
    final id = '${row.sha256.substring(0, 16)}.$ext';
    final taken =
        await db.libraryItem(id) != null ||
        await FileSystemEntity.type(pathOf(id), followLinks: false) !=
            FileSystemEntityType.notFound;
    if (taken) {
      await _deleteFile(part.path);
      await db.deleteUpload(row.id);
      throw UploadRefused(HttpStatus.conflict, {'id': id, 'code': 'collision'});
    }
    // One quick ffprobe: refuse a video the TV could neither stream nor cache.
    ProbeInfo? probe;
    if (kindForMime(row.mime) == 'video') {
      probe = await worker.quickProbe(part.path, fileBytes: row.bytes);
      final heavy = probe == null
          ? null
          : worker.tooHeavyReason(probe, row.bytes);
      if (heavy != null) {
        await _deleteFile(part.path);
        await db.deleteUpload(row.id);
        throw UploadRefused(HttpStatus.unprocessableEntity, {
          'code': 'too_heavy',
          'reason': heavy,
        });
      }
    }
    // File first, row second: a crash in between leaves a final file the next
    // reconcile imports and an upload row that `_recoverUpload` closes.
    _finishing.add(id);
    try {
      await part.rename(pathOf(id));
      try {
        await _insertFinished(row, id, probe);
      } catch (_) {
        try {
          await File(pathOf(id)).rename(part.path);
        } catch (_) {}
        rethrow;
      }
    } finally {
      _finishing.remove(id);
    }
    final saved = (await db.libraryItem(id))!;
    _emit('library.added', libraryItemJson(saved));
    worker.enqueue(id);
    return saved;
  }

  Future<void> _insertFinished(UploadRow row, String id, [ProbeInfo? probe]) =>
      db.transaction(() async {
        await db.insertLibraryItem(
          LibraryItemsCompanion.insert(
            id: id,
            kind: kindForMime(row.mime)!,
            name: row.name,
            sha256: row.sha256,
            bytes: row.bytes,
            createdAt: _nowMs,
            width: Value(probe?.width),
            height: Value(probe?.height),
            durationMs: Value(probe?.durationMs),
            codec: Value(probe?.codec),
            profile: Value(probe?.profile),
            hdr: Value(probe?.hdr),
            fps: Value(probe?.fps),
            bitrate: Value(probe?.bitrate),
            audioCodec: Value(probe?.audioCodec),
            cacheRequired: Value(worker.isAboveCeiling(probe?.bitrate)),
          ),
        );
        await db.deleteUpload(row.id);
      });

  /// An upload row whose part file is gone: if the verified final file is in
  /// the library directory, finish the bookkeeping; else drop the row.
  Future<LibraryItemRow?> _recoverUpload(UploadRow row) async {
    final ext = _imageMimes[row.mime] ?? _videoMimes[row.mime];
    final id = ext == null ? null : '${row.sha256.substring(0, 16)}.$ext';
    if (id != null &&
        await FileSystemEntity.type(pathOf(id), followLinks: false) ==
            FileSystemEntityType.file &&
        await db.libraryItem(id) == null &&
        await db.libraryItemBySha(row.sha256) == null) {
      _finishing.add(id);
      try {
        await _insertFinished(row, id);
      } finally {
        _finishing.remove(id);
      }
      final saved = (await db.libraryItem(id))!;
      _emit('library.added', libraryItemJson(saved));
      worker.enqueue(id);
      return saved;
    }
    await db.deleteUpload(row.id);
    return null;
  }

  Future<void> _recoverUploads() async {
    for (final u in await db.allUploads()) {
      if (u.received >= u.bytes && !await File(_partPath(u.id)).exists()) {
        await _recoverUpload(u);
      }
    }
  }

  /// Deletes unfinished uploads older than 24 h (file and row), and part
  /// files without a row that are older than an hour.
  Future<int> expireStaleUploads() async {
    final cutoff = _nowMs - kUploadTtl.inMilliseconds;
    var n = 0;
    for (final u in await db.allUploads()) {
      if (u.createdAt >= cutoff || _busyUploads.contains(u.id)) continue;
      _hashers.remove(u.id);
      await _deleteFile(_partPath(u.id));
      await db.deleteUpload(u.id);
      n++;
    }
    final dir = Directory(_uploadsDir);
    if (await dir.exists()) {
      final known = {for (final u in await db.allUploads()) '${u.id}.part'};
      await for (final e in dir.list(followLinks: false)) {
        final name = e.uri.pathSegments.where((s) => s.isNotEmpty).last;
        if (e is! File || known.contains(name)) continue;
        // A part file is created just before its row.
        final age = DateTime.now().difference(await e.lastModified());
        if (age > const Duration(hours: 1)) await _deleteFile(e.path);
      }
    }
    return n;
  }

  // ---- loose files ----

  /// Imports new loose files and drops rows whose file is gone. Runs one at a
  /// time.
  Future<void> reconcile() {
    _sinceReconcile = Stopwatch()..start();
    final run = _reconcileChain.then((_) async {
      await importLooseFiles();
      await _pruneMissing();
    });
    _reconcileChain = run.then<void>((_) {}, onError: (Object _) {});
    return run;
  }

  /// [reconcile], unless one ran less than [reconcileInterval] ago. Never
  /// throws.
  Future<void> reconcileIfStale() async {
    if (_stopped) return;
    final since = _sinceReconcile;
    if (since != null && since.elapsed < reconcileInterval) {
      return _reconcileChain;
    }
    try {
      await reconcile();
    } catch (_) {
      // The caller can still use what the database has.
    }
  }

  /// Gives every loose servable file in `mediaDir` a row (sha256 pending).
  /// Files modified within [looseFileGrace] are left for later.
  Future<int> importLooseFiles() async {
    final dir = Directory(config.mediaDir);
    if (!await dir.exists()) return 0;
    final known = {for (final r in await db.allLibraryItems()) r.id};
    var n = 0;
    await for (final e in dir.list(followLinks: false)) {
      if (e is! File) continue;
      final name = e.uri.pathSegments.where((s) => s.isNotEmpty).last;
      if (name.startsWith('.') || !_idPattern.hasMatch(name)) continue;
      if (name.toLowerCase().endsWith('.bin')) continue;
      final kind = kindForFileName(name);
      if (kind == null || known.contains(name) || _finishing.contains(name)) {
        continue;
      }
      final int size;
      try {
        if (DateTime.now().difference(await e.lastModified()) <
            looseFileGrace) {
          continue;
        }
        size = await e.length();
      } on FileSystemException {
        continue;
      }
      await db.insertLibraryItem(
        LibraryItemsCompanion.insert(
          id: name,
          kind: kind,
          name: name,
          sha256: '$_pendingPrefix$name',
          bytes: size,
          createdAt: _nowMs,
        ),
      );
      worker.enqueue(name);
      n++;
    }
    if (n > 0) _hashing = _hashing.then((_) => _hashPending());
    return n;
  }

  Future<void> _pruneMissing() async {
    if (!await Directory(config.mediaDir).exists()) return;
    for (final r in await db.allLibraryItems()) {
      if (_finishing.contains(r.id)) continue;
      final type = await FileSystemEntity.type(
        pathOf(r.id),
        followLinks: false,
      );
      if (type != FileSystemEntityType.notFound) continue;
      await _removeFiles(r.id);
      await db.deleteLibraryItem(r.id);
      _removed(r.id);
    }
  }

  Future<void> _hashPending() async {
    final List<LibraryItemRow> pending;
    try {
      pending = await db.pendingLibraryItems();
    } catch (err) {
      if (!_stopped) stderr.writeln('tvsaver hash error: $err');
      return;
    }
    for (final r in pending) {
      if (_stopped) return;
      try {
        final sha = await _hashFile(File(pathOf(r.id)), abortWhenStopped: true);
        if (sha == null || _stopped) return;
        final dup = await db.libraryItemBySha(sha);
        // The same bytes as another item: remember that, do not hash again.
        await db.setLibraryItemSha(
          r.id,
          dup == null ? sha : '$_dupPrefix${r.id}',
        );
        final row = await db.libraryItem(r.id);
        if (row != null) _emit('library.updated', libraryItemJson(row));
      } catch (err) {
        if (!_stopped) stderr.writeln('tvsaver hash error for ${r.id}: $err');
      }
    }
  }

  /// Streams [file] through SHA-256. With [abortWhenStopped] returns null once
  /// the store stops.
  Future<String?> _hashFile(File file, {bool abortWhenStopped = false}) async {
    final sink = _DigestSink();
    final input = sha256.startChunkedConversion(sink);
    await for (final chunk in file.openRead()) {
      if (abortWhenStopped && _stopped) return null;
      input.add(chunk);
    }
    input.close();
    return sink.value.toString();
  }
}

/// Free bytes on the volume of [dir] via `df`, or null when unknown.
Future<int?> _dfFreeBytes(String dir) async {
  if (Platform.isWindows) return null;
  try {
    final res = await Process.run('df', ['-Pk', dir]);
    if (res.exitCode != 0) return null;
    final lines = const LineSplitter().convert(res.stdout as String);
    if (lines.length < 2) return null;
    final cols = lines.last.trim().split(RegExp(r'\s+'));
    if (cols.length < 4) return null;
    final kb = int.tryParse(cols[3]);
    return kb == null ? null : kb * 1024;
  } catch (_) {
    return null;
  }
}
