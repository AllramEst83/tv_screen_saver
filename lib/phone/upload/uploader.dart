import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../images/image_prep.dart';

/// Where the bytes of a picture to add come from.
abstract class UploadSource {
  String get name;
  Future<Uint8List> read();
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
  PreparedImage? _prepared;

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
    HttpStatus.unsupportedMediaType => 'Not a supported picture',
    HttpStatus.unprocessableEntity => 'Damaged on the way. Try again.',
    HttpStatus.insufficientStorage => fullMessage,
    _ => failedMessage,
  };

  Future<void> _uploadOne(UploadItem item) async {
    try {
      item._set(status: UploadStatus.preparing, progress: 0);
      var prepared = item._prepared;
      if (prepared == null) {
        try {
          prepared = await prepare(await item.source.read());
        } on ImagePrepException catch (e) {
          item._set(status: UploadStatus.failed, error: e.message);
          return;
        }
        item._prepared = prepared;
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
        item._set(status: UploadStatus.failed, error: messageFor(start.status));
        return;
      }
      final uploadId = start.json['uploadId'];
      if (uploadId is! String) {
        item._set(status: UploadStatus.failed, error: failedMessage);
        return;
      }
      var offset = (start.json['received'] as num?)?.toInt() ?? 0;
      final total = prepared.bytes.length;
      item._set(progress: total == 0 ? 0 : offset / total);
      var resyncs = 0;
      while (offset < total) {
        if (_disposed) return;
        final end = (offset + chunkBytes).clamp(0, total);
        final res = await _put(uploadId, prepared.bytes, offset, end);
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
        item._set(status: UploadStatus.failed, error: messageFor(res.status));
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

  Future<_Answer> _post(String name, PreparedImage p) async {
    final req = await open(
      'POST',
      '/media/uploads',
      headers: {HttpHeaders.contentTypeHeader: 'application/json'},
    );
    req.add(
      utf8.encode(
        jsonEncode({
          'name': name,
          'bytes': p.bytes.length,
          'sha256': p.sha256,
          'mime': p.mime,
        }),
      ),
    );
    return _answer(await req.close().timeout(const Duration(seconds: 30)));
  }

  Future<_Answer> _put(String id, Uint8List bytes, int from, int to) async {
    final req = await open(
      'PUT',
      '/media/uploads/$id',
      headers: {
        HttpHeaders.contentTypeHeader: 'application/octet-stream',
        HttpHeaders.contentRangeHeader: 'bytes $from-${to - 1}/${bytes.length}',
      },
    );
    req.contentLength = to - from;
    req.add(Uint8List.sublistView(bytes, from, to));
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
