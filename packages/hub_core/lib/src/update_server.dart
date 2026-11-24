import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'update_manifest.dart';

/// Name the APK is served under.
const kUpdateApkRoute = 'tv-saver-tv.apk';

/// The desktop's update server (story 6-1): `GET /update.json` and
/// `GET /tv-saver-tv.apk` for the TV app's self-update. Nothing here talks to
/// the Pi.
///
/// The manifest is rebuilt from the APK and the pubspec version on every
/// request, but the checksum is only recomputed when the APK's size or time
/// changes, so rebuilding the APK while the server runs never serves a stale
/// checksum.
class UpdateServer {
  UpdateServer({
    required this.apk,
    required this.readPubspec,
    this.apkRoute = kUpdateApkRoute,
  });

  final File apk;

  /// The text of `pubspec.yaml`; read on every request.
  final String Function() readPubspec;
  final String apkRoute;

  HttpServer? _server;
  ({int ms, int len, String pubspec})? _key;
  UpdateManifest? _cached;

  int get port => _server?.port ?? 0;

  Future<UpdateManifest> manifest() async {
    final stat = apk.statSync();
    final pubspec = readPubspec();
    final key = (
      ms: stat.modified.millisecondsSinceEpoch,
      len: stat.size,
      pubspec: pubspec,
    );
    final have = _cached;
    if (have != null && _key == key) return have;
    final built = await buildManifest(
      pubspec: pubspec,
      apk: apk,
      route: apkRoute,
    );
    _cached = built;
    _key = key;
    return built;
  }

  /// Starts listening on all interfaces (the TV is on another device).
  Future<void> start({int port = 8099, String address = '0.0.0.0'}) async {
    final server = await HttpServer.bind(address, port);
    _server = server;
    server.listen(handle, onError: (Object _) {});
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  Future<void> handle(HttpRequest req) async {
    final res = req.response;
    try {
      if (req.method != 'GET' && req.method != 'HEAD') {
        res.statusCode = HttpStatus.methodNotAllowed;
        return;
      }
      final path = req.uri.path.startsWith('/')
          ? req.uri.path.substring(1)
          : req.uri.path;
      if (path == 'update.json') {
        if (!apk.existsSync()) {
          res.statusCode = HttpStatus.notFound;
          res.write('APK not found');
          return;
        }
        final body = utf8.encode((await manifest()).encode());
        res.headers.contentType = ContentType.json;
        res.contentLength = body.length;
        if (req.method == 'GET') res.add(body);
      } else if (path == apkRoute) {
        if (!apk.existsSync()) {
          res.statusCode = HttpStatus.notFound;
          res.write('APK not found');
          return;
        }
        res.headers.contentType = ContentType(
          'application',
          'vnd.android.package-archive',
        );
        res.contentLength = apk.lengthSync();
        if (req.method == 'GET') await res.addStream(apk.openRead());
      } else {
        res.statusCode = HttpStatus.notFound;
      }
    } on StateError catch (e) {
      res.statusCode = HttpStatus.internalServerError;
      res.write(e.message);
    } catch (_) {
      // The TV hung up mid-download, or the file changed under us.
      res.statusCode = HttpStatus.internalServerError;
    } finally {
      try {
        await res.close();
      } catch (_) {}
    }
  }
}

/// The manifest for [apk] and the version in [pubspec]. Throws [StateError]
/// when the pubspec has no `version: x.y.z+build` (the TV compares the build
/// number).
Future<UpdateManifest> buildManifest({
  required String pubspec,
  required File apk,
  String route = kUpdateApkRoute,
}) async {
  final version = parsePubspecVersion(pubspec);
  if (version == null) throw StateError('No version in pubspec.yaml');
  if (!RegExp(
    r'^version:\s*[^\s+#]+\+\d+',
    multiLine: true,
  ).hasMatch(pubspec)) {
    throw StateError(
      'pubspec.yaml version has no +build number (for example 0.1.0+2): the '
      'TV compares the build number, so every release needs one.',
    );
  }
  final digest = await sha256.bind(apk.openRead()).first;
  return UpdateManifest(
    versionCode: version.code,
    versionName: version.name,
    apk: route,
    sha256: digest.toString(),
  );
}

/// The addresses of this PC on private networks, for the "type this on the
/// TV" line.
Future<List<String>> lanAddresses() async {
  final found = <String>[];
  for (final i in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
    for (final a in i.addresses) {
      final s = a.address;
      if (s.startsWith('192.168.') ||
          s.startsWith('10.') ||
          RegExp(r'^172\.(1[6-9]|2\d|3[01])\.').hasMatch(s)) {
        found.add(s);
      }
    }
  }
  return found;
}

/// The address in [hosts] on the same /24 as [tvHost], or null.
String? addressOnTvNetwork(List<String> hosts, String tvHost) {
  final prefix = tvHost.substring(0, tvHost.lastIndexOf('.') + 1);
  for (final h in hosts) {
    if (h.startsWith(prefix)) return h;
  }
  return null;
}
