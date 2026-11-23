import 'dart:io';

import 'package:hub_core/hub_core.dart';

Future<void> main(List<String> args) async {
  final config = ServerConfig.fromEnvironment();
  Directory(config.mediaDir).createSync(recursive: true);
  final token = loadOrCreateToken(config.tokenFile);
  final server = PiServer(config, token);
  await server.start();
  stdout.writeln(
    'tvsaver listening on 0.0.0.0:${server.port} '
    '(media ${config.mediaDir}, token file ${config.tokenFile})',
  );
  Future<void> shutdown(ProcessSignal _) async {
    await server.stop();
    exit(0);
  }

  ProcessSignal.sigint.watch().listen(shutdown);
  if (!Platform.isWindows) ProcessSignal.sigterm.watch().listen(shutdown);
}
