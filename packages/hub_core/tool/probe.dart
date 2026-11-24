// Runs the media worker's probe and variant steps on one file and prints the
// result, so the tools can be checked on any machine (for example the Pi).
//
//   dart run tool/probe.dart <file> [--out <dir>] [--tv-caps <json file>]
//
// Videos: ffprobe metadata, then poster and thumb with ffmpeg. Images: size
// with vipsheader, then the 1920 and thumb variants with libvips. The variants
// are written to `--out` (default: a temporary directory that is printed).
// With `--tv-caps` (the `display.capabilities` JSON) a video is also checked
// against the TV. Exit codes: 0 done, 1 failure, 2 a tool is missing.
import 'dart:convert';
import 'dart:io';

import 'package:hub_core/hub_core.dart';

Future<void> main(List<String> args) async {
  String? file;
  String? out;
  String? capsFile;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--out' || '--tv-caps':
        if (i + 1 >= args.length) {
          stderr.writeln('${args[i]} needs a value');
          exit(1);
        }
        if (args[i] == '--out') {
          out = args[++i];
        } else {
          capsFile = args[++i];
        }
      default:
        file = args[i];
    }
  }
  if (file == null || !File(file).existsSync()) {
    stderr.writeln(
      'usage: dart run tool/probe.dart <file> [--out <dir>] '
      '[--tv-caps <json file>]',
    );
    exit(1);
  }
  final runner = ProcessToolRunner();
  final tools = MediaTools(runner);
  final dir = out ?? Directory.systemTemp.createTempSync('tvsaver-probe').path;
  final id = file.split(RegExp(r'[\/]')).last;
  final bytes = File(file).lengthSync();
  final kind = kindForFileName(id);
  final report = <String, Object?>{'file': file, 'bytes': bytes};
  try {
    if (kind == 'video') {
      if (!await runner.isAvailable('ffprobe')) {
        stderr.writeln('ffprobe is not installed');
        exit(2);
      }
      final info = await tools.probeVideo(file, fileBytes: bytes);
      report['kind'] = 'video';
      report['probe'] = info.toJson();
      if (capsFile != null) {
        final Object? caps;
        try {
          caps = jsonDecode(File(capsFile).readAsStringSync());
        } on FormatException catch (e) {
          stderr.writeln('--tv-caps is not valid JSON: ${e.message}');
          exit(1);
        } on FileSystemException catch (e) {
          stderr.writeln('--tv-caps cannot be read: ${e.message}');
          exit(1);
        }
        if (caps is! Map) {
          stderr.writeln('--tv-caps must be a JSON object');
          exit(1);
        }
        final v = checkCapabilities(
          codec: info.codec,
          profile: info.profile,
          hdr: info.hdr,
          audioCodec: info.audioCodec,
          capabilities: Map<String, Object?>.from(caps),
          width: info.width,
          height: info.height,
        );
        report['tv'] = v.supported ? 'supported' : v.reason;
      }
      if (!await runner.isAvailable('ffmpeg')) {
        stderr.writeln('ffmpeg is not installed');
        exit(2);
      }
      report['variants'] = await tools.videoVariants(
        source: file,
        info: info,
        outDir: dir,
        id: id,
      );
    } else if (kind == 'image') {
      if (!await runner.isAvailable('vips') ||
          !await runner.isAvailable('vipsheader')) {
        stderr.writeln('vips / vipsheader is not installed');
        exit(2);
      }
      final info = await tools.probeImage(file);
      report['kind'] = 'image';
      report['size'] = '${info.width}x${info.height}';
      report['variants'] = await tools.imageVariants(
        source: file,
        info: info,
        sourceBytes: bytes,
        outDir: dir,
        id: id,
      );
    } else {
      stderr.writeln('not a photo or video file name: $id');
      exit(1);
    }
  } on MediaToolException catch (e) {
    stderr.writeln('failed: ${e.reason}');
    exit(1);
  }
  report['variantsDir'] = dir;
  stdout.writeln(const JsonEncoder.withIndent('  ').convert(report));
}
