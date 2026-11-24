import 'dart:io';
import 'dart:math';

/// Server configuration. Paths default to the Pi layout under `$HOME`.
class ServerConfig {
  ServerConfig({
    required this.mediaDir,
    required this.tokenFile,
    this.dbFile,
    this.port = 8772,
    this.serverId = 'tvsaver',
  });

  final String mediaDir;
  final String tokenFile;

  /// SQLite file for devices and pairings; null means in memory.
  final String? dbFile;
  final int port;
  final String serverId;

  factory ServerConfig.fromEnvironment([Map<String, String>? env]) {
    final e = env ?? Platform.environment;
    final home = e['HOME'] ?? e['USERPROFILE'] ?? '.';
    return ServerConfig(
      mediaDir: e['TVSAVER_MEDIA_DIR'] ?? '$home/tvsaver/media',
      tokenFile: e['TVSAVER_TOKEN_FILE'] ?? '$home/.config/tvsaver/token',
      dbFile: e['TVSAVER_DB_FILE'] ?? '$home/tvsaver/hub.db',
      port: int.tryParse(e['TVSAVER_PORT'] ?? '') ?? 8772,
      serverId: e['TVSAVER_ID'] ?? Platform.localHostname,
    );
  }
}

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
