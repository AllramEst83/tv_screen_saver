import 'dart:convert';

/// What `ffprobe` says about a video.
class ProbeInfo {
  const ProbeInfo({
    required this.width,
    required this.height,
    required this.durationMs,
    required this.codec,
    required this.profile,
    required this.hdr,
    required this.fps,
    required this.bitrate,
    required this.audioCodec,
    this.audioProfile,
  });

  /// Size as displayed (rotation applied).
  final int width;
  final int height;
  final int? durationMs;

  /// `ffprobe` codec name: `hevc`, `h264`, `av1`...
  final String codec;

  /// `ffprobe` profile: `Main 10`, `High`...
  final String? profile;

  /// `SDR`, `HDR10`, `HLG` or `DolbyVision`.
  final String hdr;
  final double? fps;

  /// Bits per second (container figure, else computed from size).
  final int? bitrate;
  final String? audioCodec;
  final String? audioProfile;

  Map<String, Object?> toJson() => {
    'width': width,
    'height': height,
    'durationMs': durationMs,
    'codec': codec,
    'profile': profile,
    'hdr': hdr,
    'fps': fps,
    'bitrate': bitrate,
    'audioCodec': audioCodec,
  };
}

/// ffprobe could not make sense of a file.
class ProbeException implements Exception {
  const ProbeException(this.reason);

  final String reason;

  @override
  String toString() => 'ProbeException($reason)';
}

/// The arguments that make `ffprobe` print what [parseFfprobe] reads.
List<String> ffprobeArgs(String path) => [
  '-v',
  'error',
  '-print_format',
  'json',
  '-show_format',
  '-show_streams',
  path,
];

double? _rate(Object? v) {
  if (v is! String) return null;
  final parts = v.split('/');
  final n = double.tryParse(parts[0]);
  final d = parts.length > 1 ? double.tryParse(parts[1]) : 1;
  if (n == null || d == null || d == 0 || n <= 0) return null;
  return n / d;
}

int? _int(Object? v) {
  if (v is int) return v;
  if (v is String) return int.tryParse(v);
  return null;
}

/// Parses `ffprobe -print_format json -show_format -show_streams` output.
/// [fileBytes] is used for the bitrate when the container gives none.
/// Throws [ProbeException] when there is no video stream.
ProbeInfo parseFfprobe(String json, {int? fileBytes}) {
  final Object? root;
  try {
    root = jsonDecode(json);
  } on FormatException {
    throw const ProbeException('ffprobe gave no readable answer');
  }
  if (root is! Map) throw const ProbeException('ffprobe gave no answer');
  final streams = [
    for (final s in (root['streams'] as List? ?? const []))
      if (s is Map) s,
  ];
  Map? video;
  Map? audio;
  for (final s in streams) {
    final type = s['codec_type'];
    final disposition = s['disposition'];
    final attached = disposition is Map && disposition['attached_pic'] == 1;
    if (type == 'video' && !attached) video ??= s;
    if (type == 'audio') audio ??= s;
  }
  if (video == null) throw const ProbeException('The file has no video track');
  final format = root['format'] is Map ? root['format'] as Map : const {};

  var w = _int(video['width']) ?? 0;
  var h = _int(video['height']) ?? 0;
  if (w <= 0 || h <= 0) throw const ProbeException('The video has no size');

  // Rotation (phone clips): side data or the old `rotate` tag.
  num? rotation;
  final sideData = video['side_data_list'];
  var dolbyVision = false;
  if (sideData is List) {
    for (final d in sideData) {
      if (d is! Map) continue;
      if (d['rotation'] is num) rotation = d['rotation'] as num;
      final type = '${d['side_data_type']}'.toUpperCase();
      if (type.contains('DOVI') || type.contains('DOLBY VISION')) {
        dolbyVision = true;
      }
    }
  }
  final tags = video['tags'];
  if (rotation == null && tags is Map && tags['rotate'] != null) {
    rotation = num.tryParse('${tags['rotate']}');
  }
  if (rotation != null && rotation.round().abs() % 180 == 90) {
    final t = w;
    w = h;
    h = t;
  }

  final tag = '${video['codec_tag_string']}'.toLowerCase();
  if (tag == 'dvh1' || tag == 'dvhe' || tag == 'dav1') dolbyVision = true;
  final transfer = '${video['color_transfer']}';
  final hdr = dolbyVision
      ? 'DolbyVision'
      : transfer == 'smpte2084'
      ? 'HDR10'
      : transfer == 'arib-std-b67'
      ? 'HLG'
      : 'SDR';

  final durationSec =
      double.tryParse('${format['duration']}') ??
      double.tryParse('${video['duration']}');
  final durationMs = durationSec == null || durationSec <= 0
      ? null
      : (durationSec * 1000).round();

  var bitrate = _int(format['bit_rate']) ?? _int(video['bit_rate']);
  if ((bitrate == null || bitrate <= 0) &&
      fileBytes != null &&
      durationSec != null &&
      durationSec > 0) {
    bitrate = (fileBytes * 8 / durationSec).round();
  }
  if (bitrate != null && bitrate <= 0) bitrate = null;

  final fps = _rate(video['avg_frame_rate']) ?? _rate(video['r_frame_rate']);

  return ProbeInfo(
    width: w,
    height: h,
    durationMs: durationMs,
    codec: '${video['codec_name']}'.toLowerCase(),
    profile: video['profile'] is String ? video['profile'] as String : null,
    hdr: hdr,
    fps: fps == null ? null : (fps * 1000).round() / 1000,
    bitrate: bitrate,
    audioCodec: audio == null ? null : '${audio['codec_name']}'.toLowerCase(),
    audioProfile: audio != null && audio['profile'] is String
        ? audio['profile'] as String
        : null,
  );
}

/// How the TV's capabilities judge a video.
class CapabilityVerdict {
  const CapabilityVerdict.supported() : supported = true, reason = null;
  const CapabilityVerdict.unsupported(String this.reason) : supported = false;

  final bool supported;
  final String? reason;
}

const _convertHint = 'convert it on the PC';

String _codecLabel(String codec) => switch (codec) {
  'hevc' => 'HEVC',
  'h264' => 'H.264',
  'av1' => 'AV1',
  'vp9' => 'VP9',
  'vp8' => 'VP8',
  'mpeg4' => 'MPEG-4',
  'mpeg2video' => 'MPEG-2',
  'ac3' => 'Dolby Digital (AC-3)',
  'eac3' => 'Dolby Digital Plus (E-AC-3)',
  'dts' => 'DTS',
  'truehd' => 'Dolby TrueHD',
  _ => codec.toUpperCase(),
};

/// The decoder names in `display.capabilities` that stand for [codec]. The
/// TV sends `MediaCodecList` lines such as `OMX.x video/hevc hw=true
/// profiles=[Main,Main10] max=3840x2160` (or plain names like `hevc`).
RegExp? _decoderPattern(String codec) => switch (codec) {
  'hevc' => RegExp(r'(?<![a-z0-9])(hevc|h\.?265)(?![a-z0-9])'),
  'h264' => RegExp(r'(?<![a-z0-9])(avc|h\.?264)(?![a-z0-9])'),
  'av1' => RegExp(r'(?<![a-z0-9])av1(?![a-z0-9])'),
  'vp9' => RegExp(r'(?<![a-z0-9])vp9(?![a-z0-9])'),
  'ac3' => RegExp(r'(?<![a-z0-9])ac-?3(?![a-z0-9])'),
  'eac3' => RegExp(r'(?<![a-z0-9])e-?ac-?3'),
  'dts' => RegExp(r'(?<![a-z0-9])dts'),
  'truehd' => RegExp(r'truehd'),
  _ => null,
};

/// Codecs every Android TV decodes, so a TV that does not list them is still
/// assumed to play them.
const _baselineVideo = {'h264', 'vp8', 'mpeg4'};
const _baselineAudio = {
  'aac',
  'mp3',
  'mp2',
  'opus',
  'vorbis',
  'flac',
  'alac',
  'pcm_s16le',
  'pcm_s24le',
  'pcm_s16be',
  'pcm_f32le',
};

List<String> _lines(Object? v) => [
  if (v is List)
    for (final e in v)
      if (e is String) e.toLowerCase(),
];

/// Checks a video against the capabilities a TV reported (`decoders[]`,
/// `hdr[]`). Video codec first, then profile, HDR and audio.
CapabilityVerdict checkCapabilities({
  required String? codec,
  required String? profile,
  required String? hdr,
  required String? audioCodec,
  required Map<String, Object?> capabilities,
}) {
  final decoders = _lines(capabilities['decoders']);
  final hdrTypes = {
    for (final e in _lines(capabilities['hdr']))
      e.replaceAll(RegExp(r'[^a-z0-9+]'), ''),
  };

  if (codec != null && codec.isNotEmpty && !_baselineVideo.contains(codec)) {
    final pattern = _decoderPattern(codec);
    final lines = pattern == null
        ? <String>[]
        : [
            for (final d in decoders)
              if (d.contains('video/') || !d.contains('audio/'))
                if (pattern.hasMatch(d)) d,
          ];
    if (lines.isEmpty) {
      return CapabilityVerdict.unsupported(
        '${_codecLabel(codec)} is not supported by this TV; $_convertHint',
      );
    }
    // Profiles are only checked when the TV listed them.
    final listed = <String>{};
    var any = false;
    for (final l in lines) {
      final m = RegExp(r'profiles=\[([^\]]*)\]').firstMatch(l);
      if (m == null) continue;
      any = true;
      listed.addAll(m.group(1)!.split(',').map((e) => e.trim()));
    }
    if (codec == 'hevc' && any && profile != null) {
      final p = profile.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
      if (p.startsWith('main10') &&
          !listed.any((e) => e.startsWith('main10'))) {
        return const CapabilityVerdict.unsupported(
          'HEVC Main10 is not supported by this TV; $_convertHint',
        );
      }
    }
  }

  if (hdr != null && hdr != 'SDR') {
    final key = hdr.toLowerCase();
    if (!hdrTypes.contains(key)) {
      final label = switch (hdr) {
        'DolbyVision' => 'Dolby Vision',
        _ => hdr,
      };
      return CapabilityVerdict.unsupported(
        '$label is not supported by this TV; $_convertHint',
      );
    }
  }

  if (audioCodec != null &&
      audioCodec.isNotEmpty &&
      !_baselineAudio.contains(audioCodec)) {
    final pattern = _decoderPattern(audioCodec);
    final listed =
        pattern != null &&
        decoders.any((d) => !d.contains('video/') && pattern.hasMatch(d));
    if (!listed) {
      return CapabilityVerdict.unsupported(
        '${_codecLabel(audioCodec)} sound is not supported by this TV; '
        '$_convertHint',
      );
    }
  }
  return const CapabilityVerdict.supported();
}
