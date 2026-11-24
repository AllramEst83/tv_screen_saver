import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' show Value;

import '../config.dart';
import '../db/hub_database.dart';

/// Largest image (after phone prep) and video the Pi accepts.
const kMaxImageBytes = 80 * 1024 * 1024;
const kMaxVideoBytes = 50 * 1024 * 1024 * 1024;

/// Largest single `PUT` chunk.
const kMaxChunkBytes = 64 * 1024 * 1024;

/// Unfinished uploads older than this are deleted.
const kUploadTtl = Duration(hours: 24);

const _pendingPrefix = 'pending:';

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
  'sha256': r.sha256.startsWith(_pendingPrefix) ? null : r.sha256,
  'bytes': r.bytes,
  'width': r.width,
  'height': r.height,
  'durationMs': r.durationMs,
  'codec': r.codec,
  'hdr': r.hdr,
  'fps': r.fps,
  'bitrate': r.bitrate,
  'createdAt': r.createdAt,
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

/// The library: items in [HubDatabase], files in `mediaDir`, unfinished
/// uploads in `mediaDir/.uploads`, image and video variants in
/// `mediaDir/.variants`.
class LibraryStore {
  LibraryStore({
    required this.config,
    required this.db,
    DateTime Function()? now,
    Future<int?> Function(String dir)? freeBytes,
  }) : _now = now ?? DateTime.now,
       _freeBytes = freeBytes ?? _dfFreeBytes;

  final ServerConfig config;
  final HubDatabase db;
  final DateTime Function() _now;
  final Future<int?> Function(String dir) _freeBytes;

  final _events = StreamController<LibraryEvent>.broadcast();
  final Set<String> _busyUploads = {};
  Timer? _expiryTimer;
  bool _stopped = false;
  Future<void> _hashing = Future.value();

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

  // ---- lifecycle ----

  /// Prepares the directories, drops stale uploads, imports loose files and
  /// starts the hourly expiry. Hashing of imported files continues in the
  /// background (see [hashingDone]).
  Future<void> start() async {
    _stopped = false;
    await Directory(_uploadsDir).create(recursive: true);
    await expireStaleUploads();
    await importLooseFiles();
    _hashing = _hashPending();
    _expiryTimer?.cancel();
    _expiryTimer = Timer.periodic(const Duration(hours: 1), (_) {
      expireStaleUploads().then<void>((_) {}, onError: (Object _) {});
    });
  }

  /// Completes when the background hashing of imported files has finished.
  Future<void> get hashingDone => _hashing;

  Future<void> stop() async {
    _stopped = true;
    _expiryTimer?.cancel();
    _expiryTimer = null;
    await _hashing.catchError((Object _) {});
  }

  // ---- reading ----

  Future<List<LibraryItemRow>> items() => db.allLibraryItems();

  Future<int> usedBytes() async =>
      await db.libraryBytes() + await db.uploadsBytes();

  Future<Map<String, Object?>> snapshot() async => {
    'items': [for (final r in await items()) libraryItemJson(r)],
    'storage': {
      'usedBytes': await usedBytes(),
      'capBytes': config.storageCapBytes,
    },
  };

  /// Ids of the video items sorted by name (ignoring case).
  Future<List<String>> videoIds() async {
    final rows = [
      for (final r in await items())
        if (r.kind == 'video') r,
    ];
    rows.sort((a, b) {
      final c = a.name.toLowerCase().compareTo(b.name.toLowerCase());
      if (c != 0) return c;
      final d = a.name.compareTo(b.name);
      return d != 0 ? d : a.id.compareTo(b.id);
    });
    return [for (final r in rows) r.id];
  }

  Future<LibraryItemRow?> itemBySha(String sha) => db.libraryItemBySha(sha);

  // ---- changing ----

  /// Renames an item. Null when it does not exist.
  Future<LibraryItemRow?> rename(String id, String name) async {
    if (await db.renameLibraryItem(id, name) == 0) return null;
    final row = await db.libraryItem(id);
    if (row != null) _emit('library.updated', libraryItemJson(row));
    return row;
  }

  /// Removes the row, the file and its variants. False when unknown.
  Future<bool> deleteItem(String id) async {
    if (!_idPattern.hasMatch(id)) return false;
    final row = await db.libraryItem(id);
    if (row == null) return false;
    await db.deleteLibraryItem(id);
    await _deleteFile(pathOf(id));
    final dir = Directory(_variantsDir);
    if (await dir.exists()) {
      await for (final e in dir.list(followLinks: false)) {
        final name = e.uri.pathSegments.where((s) => s.isNotEmpty).last;
        if (name.startsWith('$id.')) await _deleteFile(e.path);
      }
    }
    _emit('library.removed', {'id': id});
    return true;
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

  /// Starts (or resumes) an upload. Throws [UploadRefused].
  Future<({String uploadId, int received})> startUpload({
    required String name,
    required int bytes,
    required String sha256,
    required String mime,
    required String deviceId,
  }) async {
    final kind = kindForMime(mime);
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
    final unfinished = await db.uploadBySha(sha256);
    if (unfinished != null) {
      final received = await _syncReceived(unfinished);
      if (received >= unfinished.bytes &&
          !_busyUploads.contains(unfinished.id)) {
        // The server stopped after the last chunk but before verifying it.
        final item = await _finish(unfinished); // throws 422 / 409 on failure
        throw UploadRefused(HttpStatus.conflict, {'id': item.id});
      }
      return (uploadId: unfinished.id, received: received);
    }
    final used = await usedBytes();
    final free = await _freeBytes(config.mediaDir);
    if (used + bytes > config.storageCapBytes ||
        (free != null && bytes > free)) {
      throw UploadRefused(HttpStatus.insufficientStorage, {
        'code': 'full',
        'usedBytes': used,
        'capBytes': config.storageCapBytes,
      });
    }
    final id = _newUploadId();
    await Directory(_uploadsDir).create(recursive: true);
    await File(_partPath(id)).create();
    await db.insertUpload(
      UploadsCompanion.insert(
        id: id,
        name: name,
        bytes: bytes,
        sha256: sha256,
        mime: mime.toLowerCase(),
        deviceId: Value(deviceId),
        createdAt: _nowMs,
      ),
    );
    return (uploadId: id, received: 0);
  }

  /// The bytes the Pi really holds for [row]; the row is corrected when the
  /// file is shorter (a crash lost data) and the file is cut back when longer.
  Future<int> _syncReceived(UploadRow row) async {
    final file = File(_partPath(row.id));
    var length = await file.exists() ? await file.length() : 0;
    if (!await file.exists()) await file.create(recursive: true);
    if (length > row.received) {
      final raf = await file.open(mode: FileMode.append);
      try {
        await raf.truncate(row.received);
      } finally {
        await raf.close();
      }
      length = row.received;
    }
    if (length < row.received) await db.setUploadReceived(row.id, length);
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
    final row = await db.uploadById(uploadId);
    if (row == null) throw const UploadRefused(HttpStatus.notFound);
    if (!_busyUploads.add(uploadId)) {
      throw const UploadRefused(HttpStatus.conflict);
    }
    try {
      final received = await _syncReceived(row);
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
      final raf = await File(_partPath(uploadId)).open(mode: FileMode.append);
      var written = 0;
      try {
        await raf.truncate(received);
        await for (final chunk in body) {
          written += chunk.length;
          if (written > length) break;
          await raf.writeFrom(chunk);
        }
        if (written != length) {
          await raf.truncate(received);
          throw const UploadRefused(HttpStatus.badRequest);
        }
        await raf.flush();
      } catch (_) {
        try {
          await raf.truncate(received);
        } catch (_) {}
        rethrow;
      } finally {
        await raf.close();
      }
      final now = received + length;
      await db.setUploadReceived(uploadId, now);
      if (now < row.bytes) return UploadResult.progress(now);
      return UploadResult.done(await _finish(row));
    } finally {
      _busyUploads.remove(uploadId);
    }
  }

  Future<LibraryItemRow> _finish(UploadRow row) async {
    final part = File(_partPath(row.id));
    final actual = await _hashFile(part);
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
    await part.rename(pathOf(id));
    final item = LibraryItemsCompanion.insert(
      id: id,
      kind: kindForMime(row.mime)!,
      name: row.name,
      sha256: row.sha256,
      bytes: row.bytes,
      createdAt: _nowMs,
    );
    await db.transaction(() async {
      await db.insertLibraryItem(item);
      await db.deleteUpload(row.id);
    });
    final saved = (await db.libraryItem(id))!;
    _emit('library.added', libraryItemJson(saved));
    return saved;
  }

  /// Deletes unfinished uploads older than 24 h (file and row).
  Future<int> expireStaleUploads() async {
    final cutoff = _nowMs - kUploadTtl.inMilliseconds;
    var n = 0;
    for (final u in await db.allUploads()) {
      if (u.createdAt >= cutoff || _busyUploads.contains(u.id)) continue;
      await _deleteFile(_partPath(u.id));
      await db.deleteUpload(u.id);
      n++;
    }
    // Part files without a row (a crash between the two steps).
    final dir = Directory(_uploadsDir);
    if (await dir.exists()) {
      final known = {for (final u in await db.allUploads()) '${u.id}.part'};
      await for (final e in dir.list(followLinks: false)) {
        final name = e.uri.pathSegments.where((s) => s.isNotEmpty).last;
        if (e is File && !known.contains(name)) await _deleteFile(e.path);
      }
    }
    return n;
  }

  // ---- startup import ----

  /// Gives every loose servable file in `mediaDir` a row (sha256 pending).
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
      if (kind == null || known.contains(name)) continue;
      final int size;
      try {
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
      n++;
    }
    return n;
  }

  Future<void> _hashPending() async {
    try {
      for (final r in await db.pendingLibraryItems()) {
        if (_stopped) return;
        final sha = await _hashFile(File(pathOf(r.id)), abortWhenStopped: true);
        if (sha == null || _stopped) return;
        if (await db.libraryItemBySha(sha) != null) continue; // a duplicate
        await db.setLibraryItemSha(r.id, sha);
        final row = await db.libraryItem(r.id);
        if (row != null) _emit('library.updated', libraryItemJson(row));
      }
    } catch (err) {
      if (!_stopped) stderr.writeln('tvsaver hash error: $err');
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
