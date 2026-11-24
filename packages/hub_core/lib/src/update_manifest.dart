import 'dart:convert';

final _sha256Pattern = RegExp(r'^[0-9a-f]{64}$');

/// `update.json` manifest served on the LAN by `tool/serve_tv_update.dart`.
class UpdateManifest {
  const UpdateManifest({
    required this.versionCode,
    required this.versionName,
    required this.apk,
    this.sha256,
  });

  final int versionCode;
  final String versionName;
  final String apk;
  final String? sha256;

  static UpdateManifest? tryParse(String body) {
    try {
      final json = jsonDecode(body);
      if (json is! Map<String, dynamic>) return null;
      final code = json['versionCode'];
      final name = json['versionName'];
      final apk = json['apk'];
      if (code is! int ||
          code < 0 ||
          name is! String ||
          apk is! String ||
          apk.isEmpty) {
        return null;
      }
      final sha = json['sha256'];
      return UpdateManifest(
        versionCode: code,
        versionName: name,
        apk: apk,
        sha256: sha is String && _sha256Pattern.hasMatch(sha.toLowerCase())
            ? sha.toLowerCase()
            : null,
      );
    } catch (_) {
      return null;
    }
  }

  String encode() => jsonEncode({
    'versionCode': versionCode,
    'versionName': versionName,
    'apk': apk,
    if (sha256 != null) 'sha256': sha256,
  });

  bool isNewerThan(int installedVersionCode) =>
      versionCode > installedVersionCode;

  Uri? apkUri(Uri manifestUri) {
    final uri = manifestUri.resolve(apk);
    final ok =
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.isNotEmpty &&
        uri.host == manifestUri.host &&
        uri.port == manifestUri.port;
    return ok ? uri : null;
  }
}

/// Parses `version: 0.1.0+1` from `pubspec.yaml` text.
({String name, int code})? parsePubspecVersion(String pubspec) {
  final m = RegExp(
    r'^version:\s*([^\s+#]+)(?:\+(\d+))?',
    multiLine: true,
  ).firstMatch(pubspec);
  if (m == null) return null;
  return (name: m.group(1)!, code: int.tryParse(m.group(2) ?? '') ?? 1);
}

bool isValidUpdateAddress(String url) {
  final uri = Uri.tryParse(url.trim());
  return uri != null &&
      (uri.scheme == 'http' || uri.scheme == 'https') &&
      uri.host.isNotEmpty;
}
