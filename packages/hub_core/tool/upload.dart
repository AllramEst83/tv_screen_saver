// Dev uploader for the Pi library (resumable, checksummed).
//
//   dart run tool/upload.dart <file> --host gemini-pi.local --token <token>
//       [--port 8772] [--chunk-mb 16] [--name <display name>] [--mime <type>]
//
// Interrupt it at any point and run the same command again: the Pi returns the
// unfinished upload and the transfer continues from the bytes it already has.
// Exit codes: 0 stored, 2 already in the library, 1 any failure.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

const _mimes = {
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'png': 'image/png',
  'webp': 'image/webp',
  'gif': 'image/gif',
  'avif': 'image/avif',
  'heic': 'image/heic',
  'heif': 'image/heif',
  'mp4': 'video/mp4',
  'm4v': 'video/x-m4v',
  'mov': 'video/quicktime',
  'mkv': 'video/x-matroska',
  'webm': 'video/webm',
  'ts': 'video/mp2t',
};

Never _fail(String message, [int code = 1]) {
  stderr.writeln('upload: $message');
  exit(code);
}

String _size(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB'];
  var v = bytes.toDouble();
  var u = 0;
  while (v >= 1024 && u < units.length - 1) {
    v /= 1024;
    u++;
  }
  return '${v.toStringAsFixed(u == 0 ? 0 : 1)} ${units[u]}';
}

Future<String> _hashFile(File file, int total) async {
  final out = _Sink();
  final input = sha256.startChunkedConversion(out);
  var done = 0;
  var last = DateTime.now();
  await for (final chunk in file.openRead()) {
    input.add(chunk);
    done += chunk.length;
    if (DateTime.now().difference(last) > const Duration(seconds: 1)) {
      last = DateTime.now();
      stdout.write('\rhashing ${(done * 100 / total).toStringAsFixed(0)}%   ');
    }
  }
  input.close();
  stdout.write('\r${' ' * 24}\r');
  return out.digest.toString();
}

class _Sink implements Sink<Digest> {
  late Digest digest;
  @override
  void add(Digest data) => digest = data;
  @override
  void close() {}
}

Future<void> main(List<String> args) async {
  String? path;
  String? host;
  String? token;
  String? name;
  String? mime;
  var port = 8772;
  var chunkMb = 16;
  for (var i = 0; i < args.length; i++) {
    String value() =>
        i + 1 < args.length ? args[++i] : _fail('${args[i]} needs a value');
    switch (args[i]) {
      case '--host':
        host = value();
      case '--token':
        token = value();
      case '--port':
        port = int.tryParse(value()) ?? _fail('bad --port');
      case '--chunk-mb':
        chunkMb = int.tryParse(value()) ?? _fail('bad --chunk-mb');
      case '--name':
        name = value();
      case '--mime':
        mime = value();
      default:
        if (args[i].startsWith('--')) _fail('unknown option ${args[i]}');
        path = args[i];
    }
  }
  if (path == null || host == null || token == null) {
    _fail(
      'usage: dart run tool/upload.dart <file> --host <host> --token <token> '
      '[--port 8772] [--chunk-mb 16] [--name <name>] [--mime <type>]',
    );
  }
  if (chunkMb < 1 || chunkMb > 64) _fail('--chunk-mb must be 1-64');
  final file = File(path);
  if (!file.existsSync()) _fail('no such file: $path');
  final total = file.lengthSync();
  if (total == 0) _fail('the file is empty');
  final fileName = file.uri.pathSegments.last;
  final dot = fileName.lastIndexOf('.');
  final ext = dot < 0 ? '' : fileName.substring(dot + 1).toLowerCase();
  final type = mime ?? _mimes[ext] ?? _fail('unknown type .$ext (use --mime)');

  final sha = await _hashFile(file, total);
  stdout.writeln('sha256 $sha, ${_size(total)}');

  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  final base = Uri(scheme: 'http', host: host, port: port);

  Future<(int, Map<String, String>, Map<String, dynamic>)> call(
    String method,
    String route, {
    Object? json,
    List<int>? body,
    Map<String, String> headers = const {},
  }) async {
    final req = await client.openUrl(method, base.replace(path: route));
    req.headers.set('Authorization', 'Bearer $token');
    headers.forEach(req.headers.set);
    if (json != null) {
      final bytes = utf8.encode(jsonEncode(json));
      req.headers.contentType = ContentType.json;
      req.contentLength = bytes.length;
      req.add(bytes);
    } else if (body != null) {
      req.contentLength = body.length;
      req.add(body);
    }
    final res = await req.close();
    final text = await utf8.decodeStream(res);
    final h = <String, String>{};
    res.headers.forEach((k, v) => h[k] = v.join(','));
    Map<String, dynamic> parsed = {};
    try {
      final d = jsonDecode(text);
      if (d is Map<String, dynamic>) parsed = d;
    } catch (_) {}
    return (res.statusCode, h, parsed);
  }

  final (status, _, start) = await call(
    'POST',
    '/media/uploads',
    json: {
      'name': name ?? fileName,
      'bytes': total,
      'sha256': sha,
      'mime': type,
    },
  );
  switch (status) {
    case 200:
      break;
    case 409:
      stdout.writeln('already in the library as ${start['id']}; nothing sent');
      exit(2);
    case 401:
      _fail('the Pi refused the token (401)');
    case 413:
      _fail('too large for the Pi (413)');
    case 415:
      _fail('unsupported type $type (415)');
    case 507:
      _fail(
        'the Pi is full: ${_size(start['usedBytes'] as int)} of '
        '${_size(start['capBytes'] as int)} used (507)',
      );
    default:
      _fail('could not start the upload (HTTP $status)');
  }
  final uploadId = start['uploadId'] as String;
  var offset = start['received'] as int;
  if (offset > 0) {
    stdout.writeln('resuming at ${_size(offset)} (${offset * 100 ~/ total}%)');
  }

  final chunk = chunkMb * 1024 * 1024;
  final route = '/media/uploads/$uploadId';
  final timer = Stopwatch()..start();
  var failures = 0;
  var stuck = 0;
  final raf = file.openSync();
  try {
    while (offset < total) {
      final n = total - offset < chunk ? total - offset : chunk;
      raf.setPositionSync(offset);
      final data = raf.readSync(n);
      try {
        final (code, headers, body) = await call(
          'PUT',
          route,
          body: data,
          headers: {'Content-Range': 'bytes $offset-${offset + n - 1}/$total'},
        );
        if (code == 200) {
          final got = body['received'];
          if (got is! int) _fail('the Pi answered 200 without a byte count');
          offset = got;
          failures = 0;
          stuck = 0;
        } else if (code == 201) {
          offset = total;
          stdout.writeln(
            '\rstored as ${body['id']} (${_size(total)}, sha256 matches)    ',
          );
        } else if (code == 416) {
          final m = RegExp(
            r'\*/(\d+)',
          ).firstMatch(headers['content-range'] ?? '');
          if (m == null) {
            _fail('the Pi refused the offset (416) without saying where it is');
          }
          final at = int.parse(m.group(1)!);
          if (at == offset && ++stuck >= 5) {
            _fail('the Pi keeps answering 416 at ${_size(at)}; giving up');
          }
          if (at != offset) stuck = 0;
          offset = at;
          stdout.writeln('\rPi is at ${_size(offset)}, adjusting');
        } else if (code == 422) {
          _fail('checksum mismatch: the Pi deleted the partial file (422)');
        } else if (code == 409 && body['id'] != null) {
          stdout.writeln('\rstored as ${body['id']} (already in the library)');
          exit(2);
        } else {
          _fail('chunk refused (HTTP $code)');
        }
      } on IOException catch (e) {
        if (++failures > 5) _fail('connection failed: $e');
        stdout.writeln('\rconnection problem ($e), asking the Pi where it is');
        await Future<void>.delayed(const Duration(seconds: 2));
        try {
          final (_, h, _) = await call('HEAD', route);
          offset = int.tryParse(h['upload-offset'] ?? '') ?? offset;
        } on IOException {
          // Retry the loop; the failure counter ends it.
        }
        continue;
      }
      final secs = timer.elapsedMilliseconds / 1000;
      stdout.write(
        '\r${offset * 100 ~/ total}%  ${_size(offset)} / ${_size(total)}'
        '${secs > 1 ? '  ${_size(offset ~/ secs)}/s' : ''}   ',
      );
    }
  } finally {
    raf.closeSync();
    client.close(force: true);
  }
  stdout.writeln();
}
