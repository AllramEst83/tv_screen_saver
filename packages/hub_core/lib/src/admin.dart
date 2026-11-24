import 'dart:async';
import 'dart:io';

import 'config.dart';
import 'db/hub_database.dart';

/// Outcome of an admin command: [message] is meant for the terminal.
class AdminResult {
  const AdminResult(this.ok, this.message);

  final bool ok;
  final String message;
}

/// `tvsaver admin reset-pairings`: deletes every device and pairing.
///
/// If the server runs, asks it over loopback (it also closes all sockets).
/// If it is not running, deletes the rows in the database file directly.
Future<AdminResult> resetPairings(ServerConfig config) async {
  final tokenFile = File(config.tokenFile);
  final token = tokenFile.existsSync()
      ? tokenFile.readAsStringSync().trim()
      : '';

  final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
  try {
    final req = await client.postUrl(
      Uri.parse('http://127.0.0.1:${config.port}/admin/reset-pairings'),
    );
    req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    req.contentLength = 0;
    final res = await req.close().timeout(const Duration(seconds: 15));
    await res.drain<void>();
    if (res.statusCode == HttpStatus.ok) {
      return const AdminResult(
        true,
        'All pairings were reset. The next TV is the first display and the '
        'next phone is the owner.',
      );
    }
    return AdminResult(
      false,
      'The server refused the reset (HTTP ${res.statusCode}). '
      'Check the token file ${config.tokenFile}.',
    );
  } on SocketException {
    // Not running: fall through to the database file.
  } on TimeoutException {
    return const AdminResult(false, 'The server did not answer in time.');
  } finally {
    client.close(force: true);
  }

  final dbFile = config.dbFile;
  if (dbFile == null || !File(dbFile).existsSync()) {
    return AdminResult(false, 'No database file found at ${dbFile ?? '-'}.');
  }
  HubDatabase? db;
  try {
    db = HubDatabase.open(dbFile);
    await db.deleteAllDevices();
    return const AdminResult(
      true,
      'The server is not running. Pairings were deleted in the database.',
    );
  } catch (e) {
    return AdminResult(false, 'Cannot reset pairings in $dbFile: $e');
  } finally {
    await db?.close();
  }
}

/// Dispatches `admin <command>`; returns null when [args] is not an admin
/// command.
Future<AdminResult?> runAdminCommand(
  List<String> args,
  ServerConfig config,
) async {
  if (args.isEmpty || args.first != 'admin') return null;
  if (args.length == 2 && args[1] == 'reset-pairings') {
    return resetPairings(config);
  }
  return const AdminResult(false, 'Usage: tvsaver admin reset-pairings');
}
