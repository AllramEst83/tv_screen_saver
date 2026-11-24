import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../images/image_prep.dart';

/// Where the bytes of a picture or video to add come from.
abstract class UploadSource {
  String get name;
  Future<Uint8List> read();

  /// The file itself, when there is one. A video is read from it piece by
  /// piece and never held in memory whole.
  File? get file => null;
}

const _videoMimes = {
  'mp4': 'video/mp4',
  'm4v': 'video/x-m4v',
  'mov': 'video/quicktime',
  'mkv': 'video/x-matroska',
  'webm': 'video/webm',
  'ts': 'video/mp2t',
};

/// The video type of a file name, or null when it is not a video the Pi
/// accepts (pictures have their own path).
String? videoMimeOf(String name) {
  final dot = name.lastIndexOf('.');
  if (dot < 0) return null;
  return _videoMimes[name.substring(dot + 1).toLowerCase()];
}

/// What is sent: the final bytes' length and checksum, and a way to read any
/// part of them.
class _Payload {
  const _Payload({
    required this.sha256,
    required this.mime,
    required this.length,
    required this.slice,
  });

  final String sha256;
  final String mime;
  final int length;
  final Future<Uint8List> Function(int from, int to) slice;
}

class BytesUploadSource extends UploadSource {
  BytesUploadSource(this.name, this.bytes);

  @override
  final String name;
  final Uint8List bytes;

  @override
  Future<Uint8List> read() async => bytes;
}

class FileUploadSource extends UploadSource {
  FileUploadSource(this.file, {String? name})
    : name = name ?? file.uri.pathSegments.last;

  @override
  final File file;

  @override
  final String name;

  @override
  Future<Uint8List> read() => file.readAsBytes();
}

enum UploadStatus { waiting, preparing, uploading, done, failed }

/// One picture moving from the phone to the Pi.
class UploadItem extends ChangeNotifier {
  UploadItem(this.source);

  final UploadSource source;
  UploadStatus _status = UploadStatus.waiting;
  double _progress = 0;
  String? _error;
  String? _libraryId;
  bool _alreadyThere = false;
  _Payload? _payload;

  String get name => source.name;
  UploadStatus get status => _status;

  /// 0..1 while uploading.
  double get progress => _progress;
  String? get error => _error;

  /// Library id once [status] is done.
  String? get libraryId => _libraryId;

  /// The Pi already had this picture; nothing was sent.
  bool get alreadyThere => _alreadyThere;

  void _set({
    UploadStatus? status,
    double? progress,
    String? error,
    bool clearError = false,
    String? libraryId,
    bool? alreadyThere,
  }) {
    _status = status ?? _status;
    _progress = progress ?? _progress;
    _error = clearError ? null : (error ?? _error);
    _libraryId = libraryId ?? _libraryId;
    _alreadyThere = alreadyThere ?? _alreadyThere;
    notifyListeners();
  }
}

/// What the uploader needs from the connection to the Pi.
typedef LibraryRequest = Future<Map<String, dynamic>> Function(
  String type,
  Map<String, Object?> args,
);
typedef OpenAuthorized = Future<HttpClientRequest> Function(
  String method,
  String path, {
  Map<String, String> headers,
});

/// Sequential upload queue: prepare, hash, `library.exists`, resumable
/// chunked `POST`/`PUT /media/uploads`, retry.
class ImageUploader extends ChangeNotifier {
  ImageUploader({
    required this.request,
    required this.open,
    this.chunkBytes = 8 * 1000 * 1000,
    this.prepare = prepareImage,
  });

  final LibraryRequest request;
  final OpenAuthorized open;
  final int chunkBytes;
  final Future<PreparedImage> Function(Uint8List) prepare;
  final List<UploadItem> items = [];
  bool _running = false;
  bool _disposed = false;

  static const failedMessage = 'Upload failed. Try again.';
  static const fullMessage = 'The Pi is full';
  static const duplicateMessage = 'Already in the library';

  bool get busy => items.any(
    (i) =>
        i.status == UploadStatus.waiting ||
        i.status == UploadStatus.preparing ||
        i.status == UploadStatus.uploading,
  );

  List<UploadItem> add(Iterable<UploadSource> sources) {
    final added = [for (final s in sources) UploadItem(s)];
    items.addAll(added);
    notifyListeners();
    unawaited(_pump());
    return added;
  }

  /// Tries a failed [item] again; it continues from the Pi's offset.
  void retry(UploadItem item) {
    if (item.status != UploadStatus.failed) return;
    item._set(status: UploadStatus.waiting, progress: 0, clearError: true);
    unawaited(_pump());
  }

  /// Removes finished and failed items from the list.
  void clearFinished() {
    items.removeWhere(
      (i) => i.status == UploadStatus.done || i.status == UploadStatus.failed,
    );
    notifyListeners();
  }

  /// Resolves when the queue is idle (tests).
  Future<void> whenIdle() async {
    while (busy || _running) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  Future<void> _pump() async {
    if (_running) return;
    _running = true;
    try {
      while (!_disposed) {
        final next = items
            .where((i) => i.status == UploadStatus.waiting)
            .firstOrNull;
        if (next == null) break;
        await _uploadOne(next);
      }
    } finally {
      _running = false;
    }
  }

  static String messageFor(int status) => switch (status) {
    HttpStatus.unauthorized => 'This phone is no longer paired',
    HttpStatus.forbidden => 'This phone may not add pictures',
    HttpStatus.requestEntityTooLarge => 'Too large for the Pi',
    HttpStatus.unsupportedMediaType => 'Not a supported picture or video',
    HttpStatus.unprocessableEntity => 'Damaged on the way. Try again.',
    HttpStatus.insufficientStorage => fullMessage,
    _ => failedMessage,
  };

  Future<void> _uploadOne(UploadItem item) async {
    try {
      item._set(status: UploadStatus.preparing, progress: 0);
      var prepared = item._payload;
      if (prepared == null) {
        try {
          prepared = await _payloadOf(item.source);
        } on ImagePrepException catch (e) {
          item._set(status: UploadStatus.failed, error: e.message);
          return;
        }
        item._payload = prepared;
      }
      if (_disposed) return;

      final exists = await request('library.exists', {
        'sha256': prepared.sha256,
      });
      if (exists['exists'] == true) return _already(item, exists['id']);

      item._set(status: UploadStatus.uploading, progress: 0);
      final start = await _post(item.name, prepared);
      if (start.status == HttpStatus.conflict) {
        return _already(item, start.json['id']);
      }
      if (start.status != HttpStatus.ok && start.status != HttpStatus.created) {
        item._set(status: UploadStatus.failed, error: _failure(start));
        return;
      }
      final uploadId = start.json['uploadId'];
      if (uploadId is! String) {
        item._set(status: UploadStatus.failed, error: failedMessage);
        return;
      }
      var offset = (start.json['received'] as num?)?.toInt() ?? 0;
      final total = prepared.length;
      item._set(progress: total == 0 ? 0 : offset / total);
      var resyncs = 0;
      while (offset < total) {
        if (_disposed) return;
        final end = (offset + chunkBytes).clamp(0, total);
        final res = await _put(uploadId, prepared, offset, end);
        if (res.status == HttpStatus.requestedRangeNotSatisfiable &&
            resyncs++ < 3 &&
            res.offset != null) {
          offset = res.offset!;
          continue;
        }
        if (res.status == HttpStatus.created) {
          final id = res.json['id'];
          item._set(
            status: UploadStatus.done,
            progress: 1,
            libraryId: id is String ? id : null,
          );
          return;
        }
        if (res.status == HttpStatus.ok) {
          offset = res.offset ?? end;
          item._set(progress: offset / total);
          continue;
        }
        item._set(status: UploadStatus.failed, error: _failure(res));
        return;
      }
      item._set(status: UploadStatus.failed, error: failedMessage);
    } catch (_) {
      // Never log the picture or its metadata; the message is all the user
      // gets.
      item._set(status: UploadStatus.failed, error: failedMessage);
    }
  }

  void _already(UploadItem item, Object? id) => item._set(
    status: UploadStatus.done,
    progress: 1,
    libraryId: id is String ? id : null,
    alreadyThere: true,
  );

  /// The words for a refused request; a video the Pi found too heavy says why.
  static String _failure(_Answer a) {
    if (a.status == HttpStatus.unprocessableEntity &&
        a.json['code'] == 'too_heavy') {
      final reason = a.json['reason'];
      return reason is String && reason.isNotEmpty
          ? 'Too heavy for the TV: $reason'
          : 'Too heavy for the TV';
    }
    return messageFor(a.status);
  }

  /// Pictures are prepared (scaled, cleaned); a video is sent as it is, read
  /// from its file in pieces, after its checksum is made the same way.
  Future<_Payload> _payloadOf(UploadSource source) async {
    final videoMime = videoMimeOf(source.name);
    if (videoMime == null) {
      final p = await prepare(await source.read());
      return _Payload(
        sha256: p.sha256,
        mime: p.mime,
        length: p.bytes.length,
        slice: (from, to) async => Uint8List.sublistView(p.bytes, from, to),
      );
    }
    final file = source.file;
    if (file == null || !await file.exists()) {
      throw const ImagePrepException('That video cannot be read');
    }
    final length = await file.length();
    if (length == 0) throw const ImagePrepException('That video is empty');
    final digest = await sha256.bind(file.openRead()).first;
    return _Payload(
      sha256: digest.toString(),
      mime: videoMime,
      length: length,
      slice: (from, to) async {
        final raf = await file.open();
        try {
          await raf.setPosition(from);
          return await raf.read(to - from);
        } finally {
          await raf.close();
        }
      },
    );
  }

  Future<_Answer> _post(String name, _Payload p) async {
    final req = await open(
      'POST',
      '/media/uploads',
      headers: {HttpHeaders.contentTypeHeader: 'application/json'},
    );
    req.add(
      utf8.encode(
        jsonEncode({
          'name': name,
          'bytes': p.length,
          'sha256': p.sha256,
          'mime': p.mime,
        }),
      ),
    );
    return _answer(await req.close().timeout(const Duration(seconds: 30)));
  }

  Future<_Answer> _put(String id, _Payload p, int from, int to) async {
    final req = await open(
      'PUT',
      '/media/uploads/$id',
      headers: {
        HttpHeaders.contentTypeHeader: 'application/octet-stream',
        HttpHeaders.contentRangeHeader: 'bytes $from-${to - 1}/${p.length}',
      },
    );
    req.contentLength = to - from;
    req.add(await p.slice(from, to));
    return _answer(await req.close().timeout(const Duration(seconds: 120)));
  }

  Future<_Answer> _answer(HttpClientResponse res) async {
    final body = await res
        .fold<List<int>>(<int>[], (a, b) => a..addAll(b))
        .timeout(const Duration(seconds: 60));
    var json = const <String, dynamic>{};
    try {
      final j = jsonDecode(utf8.decode(body));
      if (j is Map<String, dynamic>) json = j;
    } catch (_) {}
    int? offset;
    final range = res.headers.value(HttpHeaders.contentRangeHeader);
    final m = range == null ? null : RegExp(r'\*/(\d+)').firstMatch(range);
    if (m != null) offset = int.parse(m.group(1)!);
    offset ??= int.tryParse(res.headers.value('upload-offset') ?? '');
    offset ??= (json['received'] as num?)?.toInt();
    return _Answer(res.statusCode, json, offset);
  }
}

class _Answer {
  const _Answer(this.status, this.json, this.offset);

  final int status;
  final Map<String, dynamic> json;
  final int? offset;
}
