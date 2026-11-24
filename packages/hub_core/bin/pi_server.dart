import 'dart:io';

import 'package:hub_core/hub_core.dart';

Future<void> main(List<String> args) async {
  final config = ServerConfig.fromEnvironment();
  final admin = await runAdminCommand(args, config);
  if (admin != null) {
    (admin.ok ? stdout : stderr).writeln('tvsaver: ${admin.message}');
    exit(admin.ok ? 0 : 1);
  }
  final dbFile = config.dbFile;
  if (dbFile == null) {
    stderr.writeln('tvsaver: no database file configured (TVSAVER_DB_FILE)');
    exit(1);
  }
  Directory(config.mediaDir).createSync(recursive: true);
  final token = loadOrCreateToken(config.tokenFile);

  final HubDatabase db;
  try {
    db = HubDatabase.open(dbFile);
    await db.customSelect('SELECT 1').get(); // probe: fails fast
  } catch (e) {
    stderr.writeln(
      'tvsaver: cannot open database $dbFile: $e\n'
      'Check the path is writable and libsqlite3 is installed '
      '(sudo apt install libsqlite3-0).',
    );
    exit(1);
  }

  final server = PiServer(config, token, db: db);
  try {
    await server.start();
  } on SocketException catch (e) {
    stderr.writeln(
      'tvsaver: cannot listen on port ${config.port}: '
      '${e.osError?.message ?? e.message}',
    );
    await db.close();
    exit(1);
  }
  stdout.writeln(
    'tvsaver listening on 0.0.0.0:${server.port} '
    '(media ${config.mediaDir}, token file ${config.tokenFile}, '
    'db $dbFile)',
  );
  var stopping = false;
  Future<void> shutdown(ProcessSignal _) async {
    if (stopping) return;
    stopping = true;
    await server.stop();
    await db.close();
    exit(0);
  }

  ProcessSignal.sigint.watch().listen(shutdown);
  if (!Platform.isWindows) ProcessSignal.sigterm.watch().listen(shutdown);
}
