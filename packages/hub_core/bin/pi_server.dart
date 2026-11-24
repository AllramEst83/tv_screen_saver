import 'dart:io';

import 'package:hub_core/hub_core.dart';

Future<void> main(List<String> args) async {
  final config = ServerConfig.fromEnvironment();
  Directory(config.mediaDir).createSync(recursive: true);
  final token = loadOrCreateToken(config.tokenFile);
  final db = HubDatabase.open(config.dbFile!);
  final server = PiServer(config, token, db: db);
  try {
    await server.start();
  } on SocketException catch (e) {
    stderr.writeln('tvsaver: cannot listen on port ${config.port}: '
        '${e.osError?.message ?? e.message}');
    await db.close();
    exit(1);
  }
  stdout.writeln(
    'tvsaver listening on 0.0.0.0:${server.port} '
    '(media ${config.mediaDir}, token file ${config.tokenFile}, '
    'db ${config.dbFile})',
  );
  Future<void> shutdown(ProcessSignal _) async {
    await server.stop();
    await db.close();
    exit(0);
  }

  ProcessSignal.sigint.watch().listen(shutdown);
  if (!Platform.isWindows) ProcessSignal.sigterm.watch().listen(shutdown);
}
