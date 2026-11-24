// Serves the TV app's APK from this PC for the TV's self-update (story 6-1).
//
//   1. Raise `version:` in pubspec.yaml for every release (the number after
//      the `+` is what the TV compares).
//   2. Build:  flutter build apk --release --flavor tv -t lib/main_tv.dart --target-platform android-arm
//   3. Serve:  dart run tool/serve_tv_update.dart [apk-path] [port] [--tv=<tv-ip>]
//
// The PC and the TV must be on the same network (the TV is on Floor 1: put the
// PC's Wi-Fi there). On the TV: Menu key, Down, then enter the printed address
// once; it is remembered. The Pi is not involved.
import 'dart:io';

import 'package:hub_core/hub_core.dart';

const defaultApk = 'build/app/outputs/flutter-apk/app-tv-release.apk';
const defaultPort = 8099;

Future<String?> findTvHost(List<String> flags) async {
  for (final f in flags) {
    if (f.startsWith('--tv=')) return f.substring(5);
  }
  try {
    final out = await Process.run('adb', ['devices']);
    final m = RegExp(
      r'^(\d+\.\d+\.\d+\.\d+):\d+\s+device\b',
      multiLine: true,
    ).firstMatch('${out.stdout}');
    return m?.group(1);
  } catch (_) {
    return null;
  }
}

Future<void> main(List<String> allArgs) async {
  final flags = allArgs.where((a) => a.startsWith('--')).toList();
  final args = allArgs.where((a) => !a.startsWith('--')).toList();
  if (flags.contains('--help')) {
    stdout.writeln(
      'dart run tool/serve_tv_update.dart [apk-path] [port] [--tv=<tv-ip>]',
    );
    return;
  }
  final apk = File(args.isNotEmpty ? args[0] : defaultApk);
  final port = args.length > 1 ? int.tryParse(args[1]) : defaultPort;
  if (port == null || port < 1 || port > 65535) {
    stderr.writeln('Invalid port "${args[1]}": use a number from 1 to 65535.');
    exit(64);
  }
  if (!apk.existsSync()) {
    stderr.writeln('No APK at ${apk.path}. Build it first:');
    stderr.writeln(
      '  flutter build apk --release --flavor tv -t lib/main_tv.dart '
      '--target-platform android-arm',
    );
    exit(66);
  }
  final pubspec = File('pubspec.yaml');
  if (!pubspec.existsSync()) {
    stderr.writeln('Run this from the project root (pubspec.yaml not found).');
    exit(66);
  }
  final server = UpdateServer(
    apk: apk,
    readPubspec: pubspec.readAsStringSync,
  );
  try {
    final m = await server.manifest();
    stdout.writeln(
      'Serving version ${m.versionName} (build ${m.versionCode}), '
      '${(apk.lengthSync() / 1024 / 1024).toStringAsFixed(1)} MB, '
      'sha256 ${m.sha256!.substring(0, 12)}...',
    );
  } on StateError catch (e) {
    stderr.writeln(e.message);
    exit(65);
  }
  try {
    await server.start(port: port);
  } on SocketException catch (e) {
    stderr.writeln('Cannot listen on port $port: ${e.message}');
    exit(73);
  }
  final hosts = await lanAddresses();
  final tv = await findTvHost(flags);
  final best = tv == null ? null : addressOnTvNetwork(hosts, tv);
  stdout.writeln('On the TV (Menu key, then Down) enter one of:');
  for (final h in hosts) {
    final mark = h == best ? '   <- same network as the TV ($tv)' : '';
    stdout.writeln('  http://$h:$port/update.json$mark');
  }
  if (hosts.isEmpty) stdout.writeln('  (no LAN address found on this PC)');
  stdout.writeln('Ctrl-C to stop.');
}
