import 'dart:io';
import 'dart:math';

/// 90 GB: leaves room on the Pi's 128 GB card.
const kDefaultStorageCapBytes = 90 * 1000 * 1000 * 1000;

/// Videos above this bitrate (Mbit/s) are cached on the TV before they play.
const kDefaultStreamCeilingMbps = 80;

/// The TV's cache cap: 2.5 GB.
const kDefaultTvCacheBytes = 2500 * 1000 * 1000;

/// Server configuration. Paths default to the Pi layout under `$HOME`.
class ServerConfig {
  ServerConfig({
    required this.mediaDir,
    required this.tokenFile,
    this.dbFile,
    this.port = 8772,
    this.serverId = 'tvsaver',
    this.storageCapBytes = kDefaultStorageCapBytes,
    this.streamCeilingMbps = kDefaultStreamCeilingMbps,
    this.tvCacheBytes = kDefaultTvCacheBytes,
  });

  final String mediaDir;
  final String tokenFile;

  /// SQLite file for devices and pairings; null means in memory.
  final String? dbFile;
  final int port;
  final String serverId;

  /// Most bytes the library (plus unfinished uploads) may take.
  final int storageCapBytes;

  /// Streaming ceiling in Mbit/s (`TVSAVER_STREAM_CEILING_MBPS`).
  final int streamCeilingMbps;

  /// The TV's cache cap in bytes (`TVSAVER_TV_CACHE_BYTES`).
  final int tvCacheBytes;

  factory ServerConfig.fromEnvironment([Map<String, String>? env]) {
    final e = env ?? Platform.environment;
    final home = e['HOME'] ?? e['USERPROFILE'] ?? '.';
    return ServerConfig(
      mediaDir: e['TVSAVER_MEDIA_DIR'] ?? '$home/tvsaver/media',
      tokenFile: e['TVSAVER_TOKEN_FILE'] ?? '$home/.config/tvsaver/token',
      dbFile: _nonEmpty(e['TVSAVER_DB_FILE']) ?? '$home/tvsaver/hub.db',
      port: int.tryParse(e['TVSAVER_PORT'] ?? '') ?? 8772,
      serverId: e['TVSAVER_ID'] ?? Platform.localHostname,
      storageCapBytes:
          _positiveInt(e['TVSAVER_STORAGE_CAP_BYTES']) ??
          kDefaultStorageCapBytes,
      streamCeilingMbps:
          _positiveInt(e['TVSAVER_STREAM_CEILING_MBPS']) ??
          kDefaultStreamCeilingMbps,
      tvCacheBytes:
          _positiveInt(e['TVSAVER_TV_CACHE_BYTES']) ?? kDefaultTvCacheBytes,
    );
  }
}

int? _positiveInt(String? v) {
  final n = int.tryParse(v ?? '');
  return n != null && n > 0 ? n : null;
}

String? _nonEmpty(String? v) => (v == null || v.isEmpty) ? null : v;

/// Reads the temporary bearer token, creating the file (mode 0600, random 32
/// bytes as hex) when missing. Never logs the token.
String loadOrCreateToken(String path) {
  final file = File(path);
  if (file.existsSync()) {
    final t = file.readAsStringSync().trim();
    if (t.isNotEmpty) return t;
  }
  file.parent.createSync(recursive: true);
  final rnd = Random.secure();
  final token = List.generate(
    32,
    (_) => rnd.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  file.createSync();
  if (!Platform.isWindows) {
    final res = Process.runSync('chmod', ['600', path]);
    if (res.exitCode != 0) {
      throw FileSystemException(
        'chmod 600 failed (exit ${res.exitCode}): ${res.stderr}',
        path,
      );
    }
  }
  file.writeAsStringSync('$token\n');
  return token;
}
