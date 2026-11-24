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
  final String token;
  try {
    token = tokenFile.existsSync() ? tokenFile.readAsStringSync().trim() : '';
  } on FileSystemException catch (e) {
    return AdminResult(
      false,
      'Cannot read the token file ${config.tokenFile}: ${e.message}',
    );
  }
  if (token.isEmpty) {
    return AdminResult(
      false,
      'Token file ${config.tokenFile} is missing or empty.',
    );
  }

  final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
  var refused = false;
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
  } on SocketException catch (e) {
    if (!_isRefused(e)) {
      return AdminResult(false, 'Cannot reach the server: ${e.message}');
    }
    refused = true;
  } on TimeoutException {
    return const AdminResult(false, 'The server did not answer in time.');
  } on HttpException catch (e) {
    return AdminResult(false, 'HTTP error talking to the server: ${e.message}');
  } finally {
    client.close(force: true);
  }

  if (refused && await _healthAnswers(config.port)) {
    return const AdminResult(
      false,
      'The server answers /health but refused the reset connection.',
    );
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
  } on FileSystemException catch (e) {
    return AdminResult(false, 'Cannot open $dbFile: ${e.message}');
  } catch (e) {
    return AdminResult(false, 'Cannot reset pairings in $dbFile: $e');
  } finally {
    await db?.close();
  }
}

bool _isRefused(SocketException e) {
  final code = e.osError?.errorCode;
  // ECONNREFUSED: 111 Linux, 61 macOS, 10061 / 1225 Windows.
  return code == 111 || code == 61 || code == 10061 || code == 1225;
}

Future<bool> _healthAnswers(int port) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
  try {
    final req = await client.getUrl(Uri.parse('http://127.0.0.1:$port/health'));
    final res = await req.close().timeout(const Duration(seconds: 3));
    await res.drain<void>();
    return true;
  } catch (_) {
    return false;
  } finally {
    client.close(force: true);
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
