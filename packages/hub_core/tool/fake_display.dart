// Dev stand-in for the TV: connects to the hub as a display, opens a pairing
// session and prints the QR code (as text and ASCII art) and the PIN, so a
// phone can be paired before the TV app has a pairing screen.
//
//   dart run tool/fake_display.dart [host[:port]] [--token-file <path>] [--name <name>]
//
// Defaults: gemini-pi.local:8772, token file `.fake_display_token` in the
// current directory (the display token; delete it to join as a new display).
// Ctrl+C closes the pairing session and exits.
import 'dart:async';
import 'dart:io';

import 'package:hub_core/hub_core.dart';
import 'package:qr/qr.dart';

Future<void> main(List<String> args) async {
  var target = 'gemini-pi.local:$kDefaultHubPort';
  var tokenPath = '.fake_display_token';
  var name = 'Fake TV';
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--token-file':
        tokenPath = args[++i];
      case '--name':
        name = args[++i];
      case '-h' || '--help':
        stdout.writeln(
          'usage: dart run tool/fake_display.dart [host[:port]] '
          '[--token-file <path>] [--name <name>]',
        );
        return;
      default:
        target = args[i];
    }
  }
  final sep = target.lastIndexOf(':');
  final host = sep > 0 ? target.substring(0, sep) : target;
  final port = sep > 0
      ? int.tryParse(target.substring(sep + 1)) ?? kDefaultHubPort
      : kDefaultHubPort;

  final tokenFile = File(tokenPath);
  String? token;
  if (tokenFile.existsSync()) {
    final t = tokenFile.readAsStringSync().trim();
    if (t.isNotEmpty) token = t;
  }

  final ws = await WebSocket.connect(
    Uri(scheme: 'ws', host: host, port: port, path: kWsPath).toString(),
  );
  stdout.writeln('Connected to $host:$port as display "$name".');
  ws.add(
    encodeFrame(HubMsg.hello, {
      'v': kProtocolVersion,
      'client': name,
      'kind': 'display',
      'token': ?token,
    }),
  );

  var rid = 0;
  Timer? ping;
  var closing = false;

  Future<void> shutdown() async {
    if (closing) return;
    closing = true;
    ping?.cancel();
    try {
      ws.add(encodeFrame('devices.cancelPairing', {'rid': ++rid}));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await ws.close();
    } catch (_) {}
    exit(0);
  }

  ProcessSignal.sigint.watch().listen((_) => shutdown());

  await for (final raw in ws) {
    final msg = decodeFrame(raw);
    if (msg == null) continue;
    switch (msg['t']) {
      case HubMsg.paired:
        final t = msg['token'];
        if (t is String && t.isNotEmpty) {
          tokenFile.writeAsStringSync(t);
          stdout.writeln('Paired as the display. Token saved to $tokenPath.');
        }
      case HubMsg.ready:
        stdout.writeln('Ready. Opening a pairing session...');
        ws.add(encodeFrame('devices.startPairing', {'rid': ++rid}));
        ping = Timer.periodic(
          const Duration(seconds: 5),
          (_) => ws.add(
            encodeFrame(HubMsg.ping, {
              'ts': DateTime.now().millisecondsSinceEpoch,
            }),
          ),
        );
      case 'display.pairing':
        printPairing(msg);
      case HubMsg.err:
        stderr.writeln('Error from hub: ${msg['code']}: ${msg['msg']}');
      case HubMsg.pairRequired:
        stderr.writeln('The hub wants approval for this TV from a paired phone.');
      case HubMsg.replaced:
        stderr.writeln('Replaced by another connection.');
        await shutdown();
      default:
        break;
    }
  }
  ping?.cancel();
  stdout.writeln('Connection closed.');
}

void printPairing(Map<String, dynamic> msg) {
  final uri = msg['qr'] as String?;
  final pin = msg['pin'];
  final expires = (msg['expiresAt'] as num?)?.toInt();
  stdout.writeln('');
  stdout.writeln('=== Pairing ${DateTime.now().toIso8601String()} ===');
  if (uri != null) {
    stdout.writeln(uri);
    stdout.write(asciiQr(uri));
  }
  stdout.writeln('PIN: $pin');
  if (expires != null) {
    final left = DateTime.fromMillisecondsSinceEpoch(
      expires,
    ).difference(DateTime.now());
    stdout.writeln('Expires in about ${left.inSeconds} s.');
  }
}

/// Two QR rows per text line, using half blocks. Light-on-dark terminals
/// show it inverted, so the quiet zone is drawn explicitly.
String asciiQr(String data) {
  final code = QrCode.fromData(
    data: data,
    errorCorrectLevel: QrErrorCorrectLevel.M,
  );
  final img = QrImage(code);
  final n = img.moduleCount;
  const quiet = 2;
  bool dark(int r, int c) =>
      r >= 0 && c >= 0 && r < n && c < n && img.isDark(r, c);
  final out = StringBuffer();
  for (var r = -quiet; r < n + quiet; r += 2) {
    for (var c = -quiet; c < n + quiet; c++) {
      final top = dark(r, c);
      final bottom = dark(r + 1, c);
      // Dark modules print as spaces on a white block background.
      out.write(
        switch ((top, bottom)) {
          (true, true) => ' ',
          (true, false) => '▄',
          (false, true) => '▀',
          (false, false) => '█',
        },
      );
    }
    out.writeln();
  }
  return out.toString();
}
