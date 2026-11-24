import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'config.dart';
import 'db/hub_database.dart';
import 'mime.dart';
import 'range.dart';
import 'server/devices_module.dart';
import 'server/display_module.dart';
import 'server/hub_module.dart';
import 'server/hub_server.dart';
import 'server/library_module.dart';
import 'server/library_store.dart';
import 'server/player_module.dart';
import 'server/playlist_module.dart';
import 'server/playlist_store.dart';
import 'server/playlist_source.dart';
import 'server/settings_module.dart';
import 'server/settings_store.dart';
import 'tv_store.dart';

const serverVersion = 1;

final _idPattern = RegExp(r'^[A-Za-z0-9._-]+$');

/// The 2-2 media routes (`/health`, bearer-token `/media/<id>/full` with
/// Range) as a handler mounted on [HubServer] via `registerHttpHandler`.
class _BodyTooLarge implements Exception {
  const _BodyTooLarge();
}

class PiServer {
  PiServer(
    ServerConfig config,
    String token, {
    HubDatabase? db,
    PlaylistSource? playlists,
    LibraryStore? library,
    Map<String, SettingLimit>? settingsLimits,
  }) : this._(
         config,
         token,
         db ?? HubDatabase.inMemory(),
         db == null,
         playlists,
         library,
         settingsLimits,
       );

  PiServer._(
    this.config,
    this.token,
    this.db,
    this._ownsDb,
    PlaylistSource? playlists,
    LibraryStore? library,
    Map<String, SettingLimit>? settingsLimits,
  ) : library = library ?? LibraryStore(config: config, db: db),
      settings = SettingsStore(db: db, config: config, limits: settingsLimits),
      _playlists = playlists;

  final ServerConfig config;
  final String token;
  final HubDatabase db;

  /// Items, uploads and the files behind them.
  final LibraryStore library;

  /// Persistent settings; the live storage cap, streaming ceiling and TV
  /// cache cap in [config] follow it.
  final SettingsStore settings;
  StreamSubscription<Map<String, Object?>>? _settingsSub;

  final PlaylistSource? _playlists;

  /// Until story 4-4 this is the `all` playlist: the library's videos.
  late final PlaylistSource playlists =
      _playlists ??
      StoredPlaylistSource(
        base: LibraryPlaylistSource(library),
        orderedIds: playlistStore.orderedIds,
      );

  /// Stored playlists (story 4-4).
  late final PlaylistStore playlistStore = PlaylistStore(
    db: db,
    knownItemIds: () async => {for (final r in await library.items()) r.id},
  );
  final bool _ownsDb;
  HubServer? _hub;
  HubServer get hub => _hub!;

  int get port => _hub?.port ?? 0;

  /// Starts one [HubServer] on [ServerConfig.port]. Throws a
  /// [SocketException] when the port is busy.
  Future<void> start({String address = '0.0.0.0'}) async {
    final hub = HubServer(
      db: db,
      store: MemoryTvStore(config.serverId),
      name: config.serverId,
      preferredPort: config.port,
      bindAddress: InternetAddress(address),
      strictPort: true,
    )..registerHttpHandler(handle);
    hub.registerModule(
      DevicesModule(
        db: db,
        onForgetDevice: hub.forgetDevice,
        onStartPairing: hub.startPairingFor,
        onCancelPairing: hub.cancelPairingFor,
        onApproveDisplay: hub.approveDisplay,
        onForgetAllPhones: hub.forgetAllPhones,
      ),
    );
    await settings.load();
    _settingsSub = settings.changes.listen((_) async {
      // The ceiling, the cache cap and the storage cap are live: bring the
      // stored videos' flags and the phones' storage figure up to date.
      try {
        await library.reevaluateCacheRequired();
      } catch (_) {}
      library.announceStorage();
    });
    hub.registerModule(SettingsModule(settings));
    hub.registerModule(LibraryModule(library));
    hub.registerModule(PlaylistModule(playlistStore));
    final displayModule = DisplayModule(
      db: db,
      onCapabilitiesChanged: library.capabilitiesChanged,
    );
    hub.registerModule(displayModule);
    library.capabilities = () => displayModule.currentCapabilities;
    final player = PlayerModule(
      db: db,
      display: displayModule,
      playlists: playlists,
      unplayableReason: library.unplayableReason,
    );
    hub.registerModule(player);
    library.onItemRemoved = (id) async {
      await playlistStore.forgetItem(id);
      await player.itemRemoved(id);
    };
    _hub = hub;
    await library.start();
    await hub.start();
  }

  Future<void> stop() async {
    library.onItemRemoved = null;
    await library.stop();
    library.capabilities = null;
    await _settingsSub?.cancel();
    await settings.dispose();
    await _hub?.stop();
    if (_ownsDb) await db.close();
  }

  /// Handles every request that is not a WebSocket upgrade. Always claims the
  /// request (returns true) so unknown paths keep the 2-2 401/404 behaviour.
  Future<bool> handle(HttpRequest req) async {
    try {
      await _handle(req);
    } catch (err) {
      // Never let one request take the server down; never log headers/tokens.
      stderr.writeln('tvsaver error ${req.method} ${req.uri.path}: $err');
      try {
        req.response.statusCode = HttpStatus.internalServerError;
        req.response.contentLength = 0;
      } catch (_) {
        // Headers already sent; tear down the socket instead of closing 200.
        try {
          req.response
              .detachSocket(writeHeaders: false)
              .then((s) => s.destroy())
              .catchError((Object _) {});
        } catch (_) {}
        return true;
      }
      req.response.close().catchError((Object _) {});
    }
    return true;
  }

  bool _authorized(HttpRequest req) {
    final h = req.headers.value(HttpHeaders.authorizationHeader)?.trimLeft();
    if (h == null || h.length < 7) return false;
    if (h.substring(0, 7).toLowerCase() != 'bearer ') return false;
    return constantTimeEquals(h.substring(7).trim(), token);
  }

  Future<void> _plain(HttpRequest req, int status) async {
    req.response.statusCode = status;
    req.response.contentLength = 0;
    await req.response.close();
  }

  Future<void> _handle(HttpRequest req) async {
    final method = req.method;
    final segs = req.uri.pathSegments.where((s) => s.isNotEmpty).toList();

    if (segs.length == 1 && segs[0] == 'health') {
      if (method != 'GET' && method != 'HEAD') return _plain(req, 405);
      final body = utf8.encode(
        jsonEncode({
          'ok': true,
          'id': config.serverId,
          'v': serverVersion,
          'clients': hub.readyClientCount,
        }),
      );
      req.response.headers.contentType = ContentType.json;
      req.response.contentLength = body.length;
      if (method == 'GET') req.response.add(body);
      await req.response.close();
      return;
    }

    if (segs.length == 2 && segs[0] == 'admin' && segs[1] == 'reset-pairings') {
      // Loopback only (the CLI on the Pi), static bearer token required.
      final peer = req.connectionInfo?.remoteAddress;
      if (peer == null || !peer.isLoopback) return _plain(req, 403);
      if (method != 'POST') return _plain(req, 405);
      if (!_authorized(req)) {
        req.response.headers.set(HttpHeaders.wwwAuthenticateHeader, 'Bearer');
        return _plain(req, 401);
      }
      await hub.resetAll();
      return _plain(req, 200);
    }

    // Static token (dev, scripts) or any paired device token (TV streaming).
    // The static token counts as owner.
    DeviceInfo? device;
    if (!_authorized(req)) {
      device = await hub.authenticateHttp(req);
      if (device == null) {
        req.response.headers.set(HttpHeaders.wwwAuthenticateHeader, 'Bearer');
        return _plain(req, 401);
      }
    }

    if (segs.length >= 2 && segs[0] == 'media') {
      if (segs[1] == 'uploads') return _handleUploads(req, segs, device);
      final id = segs[1];
      if (!_idPattern.hasMatch(id) || id.startsWith('.')) {
        return _plain(req, 400);
      }
      if (segs.length == 2 && method == 'DELETE') {
        return _deleteItem(req, id, device);
      }
      if (segs.length != 3) return _plain(req, 404);
      final variant = segs[2];
      if (variant != 'full' && !kVariants.contains(variant)) {
        return _plain(req, 404);
      }
      if (method != 'GET' && method != 'HEAD') return _plain(req, 405);
      if (variant == 'full') {
        return _serveFile(req, '${config.mediaDir}/$id', contentTypeFor(id));
      }
      final path = library.variantPath(id, variant);
      return _serveFile(req, path, await _sniffImageType(path));
    }
    return _plain(req, 404);
  }

  Future<void> _json(
    HttpRequest req,
    int status,
    Map<String, Object?> body, {
    Map<String, String> headers = const {},
  }) async {
    final bytes = utf8.encode(jsonEncode(body));
    req.response.statusCode = status;
    headers.forEach(req.response.headers.set);
    req.response.headers.contentType = ContentType.json;
    req.response.contentLength = bytes.length;
    req.response.add(bytes);
    await req.response.close();
  }

  Future<void> _refuse(HttpRequest req, UploadRefused r) {
    // A chunk may still be on the wire: do not reuse this connection.
    req.response.persistentConnection = false;
    if (r.body.isEmpty) {
      r.headers.forEach(req.response.headers.set);
      return _plain(req, r.status);
    }
    return _json(req, r.status, r.body, headers: r.headers);
  }

  Future<void> _deleteItem(
    HttpRequest req,
    String id,
    DeviceInfo? device,
  ) async {
    if (device != null && !device.isOwnerEquivalent) return _plain(req, 403);
    if (!await library.deleteItem(id)) return _plain(req, 404);
    return _plain(req, 200);
  }

  static final _contentRange = RegExp(r'^bytes (\d+)-(\d+)/(\d+)$');

  Future<void> _handleUploads(
    HttpRequest req,
    List<String> segs,
    DeviceInfo? device,
  ) async {
    // A display never uploads.
    if (device != null && device.isDisplay) return _plain(req, 403);
    final method = req.method;
    if (segs.length == 2) {
      if (method != 'POST') return _plain(req, 405);
      return _startUpload(req, device);
    }
    if (segs.length != 3) return _plain(req, 404);
    final uploadId = segs[2];
    if (!_idPattern.hasMatch(uploadId)) return _plain(req, 400);
    if (method == 'HEAD') {
      final offset = await library.uploadOffset(uploadId);
      if (offset == null) return _plain(req, 404);
      req.response.headers.set('Upload-Offset', '$offset');
      return _plain(req, 200);
    }
    if (method != 'PUT') return _plain(req, 405);
    final m = _contentRange.firstMatch(
      req.headers.value(HttpHeaders.contentRangeHeader) ?? '',
    );
    final start = int.tryParse(m?.group(1) ?? '');
    final end = int.tryParse(m?.group(2) ?? '');
    final total = int.tryParse(m?.group(3) ?? '');
    if (start == null || end == null || total == null || end < start) {
      req.response.persistentConnection = false;
      return _plain(req, 400);
    }
    if (end - start + 1 > kMaxChunkBytes) {
      req.response.persistentConnection = false;
      return _plain(req, 413);
    }
    final declared = req.contentLength;
    if (declared >= 0 && declared != end - start + 1) {
      req.response.persistentConnection = false;
      return _plain(req, 400);
    }
    try {
      final result = await library.putChunk(
        uploadId,
        start: start,
        end: end,
        total: total,
        body: req,
      );
      final item = result.item;
      if (item == null) {
        return await _json(
          req,
          200,
          {'received': result.received},
          headers: {'Upload-Offset': '${result.received}'},
        );
      }
      return await _json(req, 201, {
        'id': item.id,
        'name': item.name,
        'kind': item.kind,
        'bytes': item.bytes,
        'sha256': item.sha256,
      });
    } on UploadRefused catch (r) {
      return await _refuse(req, r);
    } on FileSystemException catch (e) {
      if (_isDiskFull(e)) {
        return await _refuse(
          req,
          UploadRefused(HttpStatus.insufficientStorage, {
            'code': 'full',
            'usedBytes': await library.usedBytes(),
            'capBytes': config.storageCapBytes,
          }),
        );
      }
      return await _serverError(req, e);
    } on HttpException {
      return _dropQuietly(req); // the client aborted the chunk
    } on SocketException {
      return _dropQuietly(req);
    } catch (e) {
      return await _serverError(req, e);
    }
  }

  static bool _isDiskFull(FileSystemException e) {
    final code = e.osError?.errorCode;
    // ENOSPC on Linux; ERROR_HANDLE_DISK_FULL / ERROR_DISK_FULL on Windows.
    return code == 28 || code == 39 || code == 112;
  }

  Future<void> _serverError(HttpRequest req, Object e) async {
    stderr.writeln('tvsaver upload error ${req.method} ${req.uri.path}: $e');
    req.response.persistentConnection = false;
    await _plain(req, 500);
  }

  /// The client is gone: nothing to answer.
  Future<void> _dropQuietly(HttpRequest req) async {
    try {
      req.response
          .detachSocket(writeHeaders: false)
          .then((s) => s.destroy(), onError: (Object _) {});
    } catch (_) {}
  }

  Future<void> _startUpload(HttpRequest req, DeviceInfo? device) async {
    final Object? body;
    try {
      final bytes = await req.fold<List<int>>(<int>[], (a, b) {
        if (a.length + b.length > 64 * 1024) throw const _BodyTooLarge();
        return a..addAll(b);
      });
      body = jsonDecode(utf8.decode(bytes));
    } on _BodyTooLarge {
      req.response.persistentConnection = false;
      return _plain(req, 413);
    } on FormatException {
      return _plain(req, 400);
    } on HttpException {
      return _dropQuietly(req); // client went away
    } on SocketException {
      return _dropQuietly(req);
    }
    if (body is! Map) return _plain(req, 400);
    final name = body['name'];
    final bytes = body['bytes'];
    final sha = body['sha256'];
    final mime = body['mime'];
    if (name is! String ||
        name.trim().isEmpty ||
        name.length > 255 ||
        bytes is! int ||
        bytes <= 0 ||
        !isValidSha256(sha) ||
        mime is! String) {
      return _plain(req, 400);
    }
    try {
      final r = await library.startUpload(
        name: name.trim(),
        bytes: bytes,
        sha256: sha as String,
        mime: mime,
        deviceId: device?.id ?? '',
      );
      return await _json(req, 200, {
        'uploadId': r.uploadId,
        'received': r.received,
      });
    } on UploadRefused catch (r) {
      return await _refuse(req, r);
    }
  }

  /// `image/jpeg`, `image/png` or `image/webp` from the first bytes of a
  /// variant file; JPEG when unknown.
  Future<String> _sniffImageType(String path) async {
    try {
      final f = await File(path).open();
      try {
        final h = await f.read(12);
        if (h.length >= 8 && h[0] == 0x89 && h[1] == 0x50) return 'image/png';
        if (h.length >= 12 && h[0] == 0x52 && h[8] == 0x57) return 'image/webp';
      } finally {
        await f.close();
      }
    } catch (_) {}
    return 'image/jpeg';
  }

  Future<void> _serveFile(
    HttpRequest req,
    String filePath,
    String contentType,
  ) async {
    final file = File(filePath);
    final int size;
    try {
      // Reject symlinks so a link inside mediaDir cannot escape the root.
      final type = await FileSystemEntity.type(filePath, followLinks: false);
      if (type != FileSystemEntityType.file) {
        await _plain(req, 404);
        return;
      }
      final st = await file.stat();
      if (st.type != FileSystemEntityType.file) {
        await _plain(req, 404);
        return;
      }
      size = st.size;
    } on FileSystemException {
      return _plain(req, 404);
    }

    final res = req.response;
    res.headers
      ..set(HttpHeaders.acceptRangesHeader, 'bytes')
      ..set(HttpHeaders.contentTypeHeader, contentType);

    final range = parseRange(req.headers.value(HttpHeaders.rangeHeader), size);
    var start = 0;
    var end = size - 1;
    switch (range) {
      case UnsatisfiableRange():
        res.statusCode = 416;
        res.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$size');
        res.contentLength = 0;
        await res.close();
        return;
      case SingleRange(start: final s, end: final e):
        start = s;
        end = e;
        res.statusCode = 206;
        res.headers.set(HttpHeaders.contentRangeHeader, 'bytes $s-$e/$size');
      case FullRange():
        res.statusCode = 200;
    }
    final length = size == 0 ? 0 : end - start + 1;
    res.contentLength = length;

    if (req.method == 'HEAD' || length == 0) {
      await res.close();
      return;
    }
    var sent = 0;
    var sourceDone = false;
    try {
      await res.addStream(
        file
            .openRead(start, end + 1)
            .transform(
              StreamTransformer<List<int>, List<int>>.fromHandlers(
                handleData: (chunk, sink) {
                  sent += chunk.length;
                  sink.add(chunk);
                },
                handleDone: (sink) {
                  sourceDone = true;
                  sink.close();
                },
              ),
            ),
      );
      if (sourceDone && sent != length) {
        throw StateError('short read: sent $sent of $length bytes');
      }
      await res.close();
    } on SocketException {
      // Client aborted mid-stream: addStream cancels the file stream (which
      // closes the handle). Nothing more to do; the server keeps running.
    } on HttpException {
      // Connection closed/reset by client mid-stream.
    } catch (err) {
      // Mid-stream read error or short read: headers with Content-Length are
      // already committed, so destroy the socket so the client never hangs.
      stderr.writeln(
        'tvsaver stream error ${req.method} ${req.uri.path}: $err',
      );
      try {
        final socket = await res.detachSocket(writeHeaders: false);
        socket.destroy();
      } catch (_) {}
    }
  }
}
