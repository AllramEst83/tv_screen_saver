import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'config.dart';
import 'mime.dart';
import 'range.dart';

const serverVersion = 1;

final _idPattern = RegExp(r'^[A-Za-z0-9._-]+$');

/// Constant-time comparison of two strings (length is not hidden).
bool constantTimeEquals(String a, String b) {
  final x = utf8.encode(a);
  final y = utf8.encode(b);
  var diff = x.length ^ y.length;
  final n = x.length > y.length ? x.length : y.length;
  for (var i = 0; i < n; i++) {
    diff |= (i < x.length ? x[i] : 0) ^ (i < y.length ? y[i] : 0);
  }
  return diff == 0;
}

class PiServer {
  PiServer(this.config, this.token);

  final ServerConfig config;
  final String token;
  HttpServer? _http;

  int get port => _http!.port;

  Future<void> start({String address = '0.0.0.0'}) async {
    final http = await HttpServer.bind(address, config.port);
    _http = http;
    http.listen(
      (req) => _handle(req).catchError((Object err, StackTrace _) {
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
          return;
        }
        req.response.close().catchError((Object _) {});
      }),
      onError: (Object err) {
        stderr.writeln('tvsaver server error: $err');
      },
    );
  }

  Future<void> stop() async => _http?.close(force: true);

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
      final body = utf8.encode(jsonEncode({
        'ok': true,
        'id': config.serverId,
        'v': serverVersion,
        'clients': 0,
      }));
      req.response.headers.contentType = ContentType.json;
      req.response.contentLength = body.length;
      if (method == 'GET') req.response.add(body);
      await req.response.close();
      return;
    }

    if (!_authorized(req)) {
      req.response.headers.set(HttpHeaders.wwwAuthenticateHeader, 'Bearer');
      return _plain(req, 401);
    }

    if (segs.length >= 2 && segs[0] == 'media') {
      final id = segs[1];
      if (!_idPattern.hasMatch(id) || id == '.' || id == '..') {
        return _plain(req, 400);
      }
      if (segs.length != 3 || segs[2] != 'full') return _plain(req, 404);
      if (method != 'GET' && method != 'HEAD') return _plain(req, 405);
      return _serveFile(req, id);
    }
    return _plain(req, 404);
  }

  Future<void> _serveFile(HttpRequest req, String id) async {
    final filePath = '${config.mediaDir}/$id';
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
      ..set(HttpHeaders.contentTypeHeader, contentTypeFor(id));

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
        file.openRead(start, end + 1).transform(
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
      stderr.writeln('tvsaver stream error ${req.method} ${req.uri.path}: $err');
      try {
        final socket = await res.detachSocket(writeHeaders: false);
        socket.destroy();
      } catch (_) {}
    }
  }
}
