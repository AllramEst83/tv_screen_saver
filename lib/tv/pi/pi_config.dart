import 'dart:convert';
import 'dart:io';

/// Hint shown when `pi_config.json` is missing, malformed, or auth fails.
const setupPhase2Hint =
    'PI_HOST=<pi-ip> bash tool/pi/setup_phase2.sh <tv-ip>:5555';

/// Error thrown when `pi_config.json` is missing or invalid. Never embeds the
/// bearer token.
class PiConfigException implements Exception {
  const PiConfigException(this.message);

  final String message;

  @override
  String toString() => 'PiConfigException: $message';
}

/// Returns the expected path of `pi_config.json` inside [filesDir].
String piConfigPath(String filesDir) => '$filesDir/pi_config.json';

/// Configuration pushed to the TV app's external files directory by
/// `tool/pi/setup_phase2.sh`.
class PiConfig {
  const PiConfig({
    required this.host,
    required this.port,
    required this.token,
    required this.playlist,
    required this.throughputFile,
  });

  final String host;
  final int port;
  final String token;
  final List<String> playlist;
  final String throughputFile;

  Uri get baseUri => Uri(scheme: 'http', host: host, port: port);

  Uri get healthUri => baseUri.replace(path: '/health');

  Uri mediaUri(String id) =>
      baseUri.replace(pathSegments: ['media', id, 'full']);

  List<Uri> get playlistUris => [for (final id in playlist) mediaUri(id)];

  Uri get throughputUri => mediaUri(throughputFile);

  Map<String, String> get authHeaders => {'Authorization': 'Bearer $token'};

  /// Parses [raw] JSON into a validated [PiConfig].
  static PiConfig parse(String raw) {
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      throw const PiConfigException('pi_config.json is not valid JSON');
    }
    if (decoded is! Map<String, Object?>) {
      throw const PiConfigException('pi_config.json must be a JSON object');
    }

    final host = _requireString(decoded['host'], 'host');
    final portRaw = decoded['port'];
    final int port;
    if (portRaw == null) {
      port = 8772;
    } else if (portRaw is int && portRaw > 0 && portRaw <= 65535) {
      port = portRaw;
    } else {
      throw const PiConfigException('invalid "port" in pi_config.json');
    }
    final token = _requireString(decoded['token'], 'token');

    final playlistRaw = decoded['playlist'];
    if (playlistRaw is! List || playlistRaw.isEmpty) {
      throw const PiConfigException(
        '"playlist" must be a non-empty list in pi_config.json',
      );
    }
    final playlist = <String>[];
    for (final entry in playlistRaw) {
      playlist.add(_requireString(entry, 'playlist entry'));
    }

    final throughputFile = _requireString(
      decoded['throughputFile'],
      'throughputFile',
    );

    return PiConfig(
      host: host,
      port: port,
      token: token,
      playlist: List.unmodifiable(playlist),
      throughputFile: throughputFile,
    );
  }

  static String _requireString(Object? value, String field) {
    if (value is! String || value.trim().isEmpty) {
      throw PiConfigException('missing or empty "$field" in pi_config.json');
    }
    return value.trim();
  }

  @override
  String toString() =>
      'PiConfig(host: $host, port: $port, token: <redacted>, '
      'playlist: $playlist, throughputFile: $throughputFile)';
}

/// Reads and parses `pi_config.json` from [filesDir].
Future<PiConfig> loadPiConfig(String filesDir) async {
  final file = File(piConfigPath(filesDir));
  if (!await file.exists()) {
    throw PiConfigException('pi_config.json not found in $filesDir');
  }
  try {
    final raw = await file.readAsString();
    return PiConfig.parse(raw);
  } on PiConfigException {
    rethrow;
  } on FileSystemException catch (e) {
    throw PiConfigException('cannot read pi_config.json: ${e.message}');
  }
}
