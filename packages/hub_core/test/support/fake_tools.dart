import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:hub_core/hub_core.dart';

String ffprobeJson({
  String codec = 'hevc',
  String? profile = 'Main 10',
  String? pixFmt,
  String? sar,
  String transfer = 'bt709',
  String tag = 'hvc1',
  String? audio = 'aac',
  int width = 3840,
  int height = 2160,
  String duration = '100.0',
  int? bitRate = 60000000,
  List<Map<String, Object?>> sideData = const [],
  Map<String, Object?> tags = const {},
}) => jsonEncode({
  'streams': [
    {
      'codec_type': 'video',
      'codec_name': codec,
      'profile': ?profile,
      'pix_fmt': ?pixFmt,
      'sample_aspect_ratio': ?sar,
      'width': width,
      'height': height,
      'color_transfer': transfer,
      'codec_tag_string': tag,
      'avg_frame_rate': '24000/1001',
      'side_data_list': sideData,
      'tags': tags,
    },
    if (audio != null)
      {'codec_type': 'audio', 'codec_name': audio, 'profile': 'LC'},
  ],
  'format': {'duration': duration, 'bit_rate': ?bitRate?.toString()},
});

const tvCaps = {
  'decoders': [
    'OMX.x video/hevc hw=true profiles=[Main,Main10,Main10HDR10] max=3840x2160',
    'OMX.y audio/ac3 hw=true channels<=6',
    'OMX.y audio/eac3 hw=true channels<=8',
  ],
  'hdr': ['HDR10', 'HLG'],
  'render': '3840x2160',
  'panel': '3840x2160',
};

/// Answers tool calls from a script and records them.
class FakeRunner implements ToolRunner {
  FakeRunner({
    this.available = const {'ffprobe', 'ffmpeg', 'vips', 'vipsheader'},
  });

  Set<String> available;
  String probeOutput = ffprobeJson();
  bool probeFails = false;
  bool hang = false;
  Set<String> hangOn = {};
  String imageHeader = 'width: 4000\nheight: 3000\norientation: 6\n';
  bool rejectKeepIcc = false;
  final calls = <List<String>>[];
  final envs = <Map<String, String>>[];
  Completer<void>? gate;

  @override
  Future<bool> isAvailable(String tool) async => available.contains(tool);

  @override
  void cancelAll() {}

  @override
  Future<ToolResult> run(
    String tool,
    List<String> args, {
    required Duration timeout,
    Map<String, String>? environment,
    String? workingDirectory,
  }) async {
    calls.add([tool, ...args]);
    envs.add(environment ?? const {});
    String at(String path) => workingDirectory == null || File(path).isAbsolute
        ? path
        : '$workingDirectory/$path';
    final g = gate;
    if (g != null && tool == 'ffmpeg') await g.future;
    if (hang || hangOn.contains(tool)) {
      return const ToolResult(-9, '', '', timedOut: true);
    }
    switch (tool) {
      case 'ffprobe':
        return probeFails
            ? const ToolResult(1, '', 'Invalid data found\n')
            : ToolResult(0, probeOutput, '');
      case 'vipsheader':
        return imageHeader.isEmpty
            ? const ToolResult(1, '', 'not an image\n')
            : ToolResult(0, imageHeader, '');
      case 'ffmpeg':
        File(at(args.last)).writeAsBytesSync(List.filled(10, 1));
        return const ToolResult(0, '', '');
      case 'vips':
        if (rejectKeepIcc && args[2].contains('keep=icc')) {
          return const ToolResult(1, '', 'unknown option keep\n');
        }
        final out = at(args[2].split('[').first);
        File(out).writeAsBytesSync(List.filled(10, 1));
        return const ToolResult(0, '', '');
    }
    return const ToolResult(127, '', 'unknown tool');
  }
}
