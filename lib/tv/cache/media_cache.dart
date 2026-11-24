import 'dart:async';
import 'dart:io';

/// One item to bring into the cache: where to get it and how to name it.
class CacheRequest {
  const CacheRequest({
    required this.key,
    required this.url,
    required this.headers,
    this.maxBytes,
    this.fallback,
  });

  /// File name inside the cache (`<itemId>.<variant>`).
  final String key;
  final Uri url;
  final Map<String, String> headers;

  /// Refuse (without downloading) a file larger than this.
  final int? maxBytes;

  /// Asked for instead when the Pi has no such file (a `1920` image variant
  /// that was never made; the full image then serves).
  final CacheRequest? fallback;
}

/// The file is larger than the cache allows for it.
class CacheTooLarge implements Exception {
  const CacheTooLarge(this.bytes);

  final int bytes;

  @override
  String toString() => 'CacheTooLarge($bytes)';
}

/// Free space the TV keeps for itself and its other apps (about where Android
/// starts to warn that storage is running low).
const kStorageReserveBytes = 512 * 1000 * 1000;

/// The Pi answered with a status other than 200.
class CacheHttpError implements Exception {
  const CacheHttpError(this.status);

  final int status;

  @override
  String toString() => 'CacheHttpError($status)';
}

/// An LRU file cache on the TV (CAP-8): the next items of the playlist are
/// downloaded ahead, the least recently used files go first when the cap is
/// reached, and a file is never evicted while it is in use.
///
/// Files are written as `<key>.part` and renamed when complete, so a crash or
/// a power cut never leaves a half file that looks finished.
class MediaCache {
  MediaCache({
    required this.dir,
    this.capBytes = 2500 * 1000 * 1000,
    this.freeBytes,
    this.reserveBytes = kStorageReserveBytes,
    HttpClient Function()? httpClient,
    DateTime Function()? now,
  }) : _newClient = httpClient ?? HttpClient.new,
       _now = now ?? DateTime.now;

  final Directory dir;

  /// The most bytes the cache keeps (the Pi sends its setting with every
  /// `display.prefetch`).
  int capBytes;

  /// Free bytes on the volume the cache lives on; null when it cannot be
  /// read (then only [capBytes] limits the cache).
  final Future<int?> Function()? freeBytes;

  /// Free space that is never used for the cache.
  final int reserveBytes;
  final HttpClient Function() _newClient;
  final DateTime Function() _now;

  HttpClient? _http;
  final Map<String, Future<File>> _inFlight = {};
  final Map<String, int> _pins = {};
  int _prefetchRun = 0;
  bool _disposed = false;

  /// The most an item that is only streamed may weigh before it is left
  /// uncached: a quarter of the cap.
  int get maxStreamedItemBytes => capBytes ~/ 4;

  String _path(String key) => '${dir.path}/$key';

  /// The finished file for [key], or null. Counts as a use.
  Future<File?> lookup(String key) async {
    final f = File(_path(key));
    try {
      if (!await f.exists()) return null;
      await f.setLastModified(_now());
      return f;
    } on FileSystemException {
      return null;
    }
  }

  /// Bytes of finished files in the cache.
  Future<int> usedBytes() async {
    var total = 0;
    if (!await dir.exists()) return 0;
    await for (final e in dir.list(followLinks: false)) {
      if (e is File && !e.path.endsWith('.part')) {
        try {
          total += await e.length();
        } on FileSystemException {
          // Gone meanwhile.
        }
      }
    }
    return total;
  }

  /// Keeps [key] from being evicted until [unpin] (it is on screen or being
  /// played). Calls nest.
  void pin(String key) => _pins[key] = (_pins[key] ?? 0) + 1;

  void unpin(String key) {
    final n = (_pins[key] ?? 0) - 1;
    if (n <= 0) {
      _pins.remove(key);
    } else {
      _pins[key] = n;
    }
  }

  /// The file for [request]: from the cache, or downloaded now. Two calls for
  /// the same key share one download.
  Future<File> fetch(CacheRequest request) async {
    final fallback = request.fallback;
    // The full image already here serves as well as a variant that may not
    // exist.
    if (fallback != null && await lookup(request.key) == null) {
      final full = await lookup(fallback.key);
      if (full != null) return full;
    }
    try {
      return await _share(request);
    } on CacheHttpError catch (e) {
      if (e.status == HttpStatus.notFound && fallback != null) {
        return fetch(fallback);
      }
      rethrow;
    }
  }

  Future<File> _share(CacheRequest request) {
    final running = _inFlight[request.key];
    if (running != null) return running;
    final run = _fetch(request);
    _inFlight[request.key] = run;
    return run.whenComplete(() => _inFlight.remove(request.key));
  }

  Future<File> _fetch(CacheRequest request) async {
    final have = await lookup(request.key);
    if (have != null) return have;
    await dir.create(recursive: true);
    final http = _http ??= _newClient()
      ..connectionTimeout = const Duration(seconds: 10);
    final part = File('${_path(request.key)}.part');
    pin(request.key);
    try {
      final req = await http.getUrl(request.url);
      request.headers.forEach(req.headers.set);
      final res = await req.close().timeout(const Duration(seconds: 30));
      if (res.statusCode != HttpStatus.ok) {
        await res.drain<void>();
        throw CacheHttpError(res.statusCode);
      }
      final length = res.contentLength;
      final max = request.maxBytes;
      if (max != null && length > max) {
        await res.drain<void>().catchError((Object _) {});
        throw CacheTooLarge(length);
      }
      if (length > capBytes) {
        await res.drain<void>().catchError((Object _) {});
        throw CacheTooLarge(length);
      }
      if (!await _makeRoom(length > 0 ? length : 0)) {
        // Even with every unused file gone it would eat into the TV's own
        // free space: the item streams instead.
        await res.drain<void>().catchError((Object _) {});
        throw CacheTooLarge(length);
      }
      final sink = part.openWrite();
      var written = 0;
      try {
        await for (final chunk in res) {
          written += chunk.length;
          if (max != null && written > max) throw CacheTooLarge(written);
          sink.add(chunk);
        }
      } catch (_) {
        await sink.close().catchError((Object _) {});
        rethrow;
      }
      await sink.close();
      if (length >= 0 && written != length) {
        throw const FileSystemException('The download ended early');
      }
      final done = await part.rename(_path(request.key));
      await done.setLastModified(_now());
      return done;
    } catch (_) {
      try {
        if (await part.exists()) await part.delete();
      } on FileSystemException {
        // Nothing to clean.
      }
      rethrow;
    } finally {
      unpin(request.key);
    }
  }

  /// What the cache may hold: the Pi's cap, and never more than what leaves
  /// [reserveBytes] free on the volume (the cache and the free space together
  /// are what the TV has to give).
  int _budget(int used, int? free) {
    if (free == null) return capBytes;
    final room = used + free - reserveBytes;
    final b = room < capBytes ? room : capBytes;
    return b < 0 ? 0 : b;
  }

  /// Deletes least recently used finished files until [incoming] more bytes
  /// fit in the budget. Pinned files stay. False when they still do not fit.
  Future<bool> _makeRoom(int incoming) async {
    final files = <(File, int, DateTime)>[];
    var total = 0;
    if (!await dir.exists()) {
      return incoming <= _budget(0, await freeBytes?.call());
    }
    await for (final e in dir.list(followLinks: false)) {
      if (e is! File || e.path.endsWith('.part')) continue;
      try {
        final st = await e.stat();
        files.add((e, st.size, st.modified));
        total += st.size;
      } on FileSystemException {
        // Gone meanwhile.
      }
    }
    final budget = _budget(total, await freeBytes?.call());
    if (total + incoming <= budget) return true;
    files.sort((a, b) => a.$3.compareTo(b.$3));
    for (final (file, size, _) in files) {
      if (total + incoming <= budget) break;
      final name = file.uri.pathSegments.last;
      if (_pins.containsKey(name)) continue;
      try {
        await file.delete();
        total -= size;
      } on FileSystemException {
        // Keep going.
      }
    }
    return total + incoming <= budget;
  }

  /// Brings the cache inside its budget now: the oldest unused files go until
  /// the TV has its reserve of free space again. Run at start.
  Future<void> trim() async {
    await _makeRoom(0);
  }

  /// Downloads [requests] one after the other in the background, skipping
  /// what is cached. A newer call replaces the list; a download already
  /// running finishes. Failures are skipped: the item is fetched again when
  /// it plays.
  void prefetch(List<CacheRequest> requests) {
    final run = ++_prefetchRun;
    unawaited(() async {
      for (final r in requests) {
        if (_disposed || run != _prefetchRun) return;
        try {
          await fetch(r);
        } catch (_) {
          // Too large, offline or refused: not needed to keep going.
        }
      }
    }());
  }

  /// Deletes `.part` files a crash left behind.
  Future<void> cleanPartial() async {
    if (!await dir.exists()) return;
    await for (final e in dir.list(followLinks: false)) {
      if (e is File && e.path.endsWith('.part') && _inFlight.isEmpty) {
        try {
          await e.delete();
        } on FileSystemException {
          // Next time.
        }
      }
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    _http?.close(force: true);
    _http = null;
  }
}
