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

/// The stream's profile; when ffprobe gives none it is derived from the pixel
/// format (bit depth and chroma) so a 10-bit or 4:4:4 stream is not mistaken
/// for a plain one.
String? _profile(Map video, String codec) {
  final given = video['profile'];
  if (given is String && given.isNotEmpty) return given;
  final fmt = '${video['pix_fmt']}';
  final depth = RegExp(r'(\d+)(le|be)?$').firstMatch(fmt);
  final bits = depth == null ? 8 : (int.tryParse(depth.group(1)!) ?? 8);
  final wide = bits >= 9 && bits <= 16 ? bits : 8;
  final chroma = fmt.contains('444')
      ? '4:4:4'
      : fmt.contains('422')
      ? '4:2:2'
      : '4:2:0';
  if (codec == 'hevc') {
    if (chroma != '4:2:0' || wide > 10) return 'Rext';
    return wide == 10 ? 'Main 10' : null;
  }
  if (codec == 'h264') {
    if (chroma == '4:4:4') return 'High 4:4:4 Predictive';
    if (chroma == '4:2:2') return 'High 4:2:2';
    return wide > 8 ? 'High 10' : null;
  }
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
  final codecName = video['codec_name'];
  if (codecName is! String || codecName.trim().isEmpty) {
    throw const ProbeException('Unknown video codec');
  }
  final format = root['format'] is Map ? root['format'] as Map : const {};

  var w = _int(video['width']) ?? 0;
  var h = _int(video['height']) ?? 0;
  if (w <= 0 || h <= 0) throw const ProbeException('The video has no size');

  // Anamorphic video: the stored size is the size as displayed.
  final sar = RegExp(
    r'^(\d+):(\d+)$',
  ).firstMatch('${video['sample_aspect_ratio']}');
  if (sar != null) {
    final n = int.parse(sar.group(1)!);
    final d = int.parse(sar.group(2)!);
    if (n > 0 && d > 0 && n != d) w = (w * n / d).round();
  }

  // Rotation (phone clips): side data or the old `rotate` tag.
  num? rotation;
  final sideData = video['side_data_list'];
  var dolbyVision = false;
  int? dvProfile;
  int? dvCompat;
  if (sideData is List) {
    for (final d in sideData) {
      if (d is! Map) continue;
      if (d['rotation'] is num) rotation = d['rotation'] as num;
      final type = '${d['side_data_type']}'.toUpperCase();
      if (type.contains('DOVI') || type.contains('DOLBY VISION')) {
        dolbyVision = true;
        dvProfile = _int(d['dv_profile']);
        dvCompat = _int(d['dv_bl_signal_compatibility_id']);
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
  // A Dolby Vision file whose base layer is HDR10 (or HLG, SDR) plays on a TV
  // without Dolby Vision as that base: `DolbyVision/HDR10`.
  String? dvBase = switch (dvCompat) {
    1 => 'HDR10',
    2 => 'SDR',
    4 => 'HLG',
    _ => null,
  };
  if (dolbyVision && dvCompat == null && dvProfile != 5) {
    dvBase = transfer == 'smpte2084'
        ? 'HDR10'
        : transfer == 'arib-std-b67'
        ? 'HLG'
        : null;
  }
  final hdr = dolbyVision
      ? (dvBase == null ? 'DolbyVision' : 'DolbyVision/$dvBase')
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
    codec: codecName.trim().toLowerCase(),
    profile: _profile(video, codecName.trim().toLowerCase()),
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
  'vc1' => 'VC-1',
  'prores' => 'ProRes',
  'mjpeg' => 'Motion JPEG',
  'ac3' => 'Dolby Digital (AC-3)',
  'eac3' => 'Dolby Digital Plus (E-AC-3)',
  'dts' => 'DTS',
  'truehd' => 'Dolby TrueHD',
  _ => codec.toUpperCase(),
};

/// The decoder names in `display.capabilities` that stand for [codec]. The
/// TV sends `MediaCodecList` lines such as `OMX.x video/hevc hw=true
/// profiles=[Main,Main10] max=3840x2160` (or plain names like `hevc`). A codec
/// without a pattern here is matched as `video/<name>` / `audio/<name>`.
RegExp _decoderPattern(String codec) {
  const word = r'(?<![a-z0-9])';
  const end = r'(?![a-z0-9])';
  final esc = RegExp.escape(codec);
  return switch (codec) {
    'hevc' => RegExp('$word(hevc|h\\.?265)$end'),
    'h264' => RegExp('$word(avc|h\\.?264)$end'),
    'av1' => RegExp('${word}av1$end'),
    'vp9' => RegExp('${word}vp9$end'),
    'ac3' => RegExp('${word}ac-?3$end'),
    'eac3' => RegExp('${word}e-?ac-?3'),
    'dts' => RegExp('${word}dts'),
    'truehd' => RegExp('truehd'),
    'mpeg2video' => RegExp('${word}mpeg-?2'),
    'vc1' => RegExp('$word(vc-?1|wmv)'),
    'wmv3' => RegExp('$word(wmv|vc-?1)'),
    'h263' => RegExp('${word}h\\.?263$end'),
    'prores' => RegExp('${word}prores'),
    'mjpeg' => RegExp('$word(m?jpeg)'),
    _ => RegExp('(video|audio)/$esc$end|$word$esc$end'),
  };
}

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

(int, int)? _size(Object? v) {
  if (v is Map) {
    final w = v['width'];
    final h = v['height'];
    if (w is num && h is num) return (w.toInt(), h.toInt());
    return null;
  }
  if (v is! String) return null;
  final m = RegExp(r'(\d+)\s*x\s*(\d+)').firstMatch(v);
  return m == null ? null : (int.parse(m.group(1)!), int.parse(m.group(2)!));
}

String _sizeName(int w, int h) {
  final long = w > h ? w : h;
  final name = long >= 7000
      ? '8K'
      : long >= 3800
      ? '4K'
      : null;
  return name == null ? '${w}x$h' : '$name (${w}x$h)';
}

/// Checks a video against the capabilities a TV reported (`decoders[]`,
/// `hdr[]`, `panel`). Video codec, profile and size first, then HDR and
/// audio. [hdr] may be `DolbyVision/HDR10`: a Dolby Vision file with an HDR10
/// base layer, which also plays where only HDR10 is listed.
CapabilityVerdict checkCapabilities({
  required String? codec,
  required String? profile,
  required String? hdr,
  required String? audioCodec,
  required Map<String, Object?> capabilities,
  int? width,
  int? height,
}) {
  final decoders = _lines(capabilities['decoders']);
  final hdrTypes = {
    for (final e in _lines(capabilities['hdr']))
      e.replaceAll(RegExp(r'[^a-z0-9+]'), ''),
  };
  int? maxW;
  int? maxH; // the largest the listed decoders handle
  if (codec != null && codec.isNotEmpty) {
    final pattern = _decoderPattern(codec);
    final lines = [
      for (final d in decoders)
        if (!d.contains('audio/') && pattern.hasMatch(d)) d,
    ];
    final prof = (profile ?? '').toLowerCase().replaceAll(
      RegExp(r'[^a-z0-9]'),
      '',
    );
    if (lines.isEmpty && !_baselineVideo.contains(codec)) {
      return CapabilityVerdict.unsupported(
        '${_codecLabel(codec)} is not supported by this TV; $_convertHint',
      );
    }
    // Profiles are only checked when the TV listed them (for H.264 a plain
    // profile needs no listing, the wider ones do).
    final names = <String>{};
    for (final l in lines) {
      final m = RegExp(r'profiles=\[([^\]]*)\]').firstMatch(l);
      if (m != null) {
        names.addAll(
          m
              .group(1)!
              .split(',')
              .map((e) => e.trim().replaceAll(' ', '').toLowerCase()),
        );
      }
      final mx = _size(RegExp(r'max=(\d+x\d+)').firstMatch(l)?.group(1));
      if (mx != null) {
        if (maxW == null || mx.$1 > maxW) maxW = mx.$1;
        if (maxH == null || mx.$2 > maxH) maxH = mx.$2;
      }
    }
    if (codec == 'hevc' && names.isNotEmpty) {
      if (prof.contains('rext') ||
          prof.contains('444') ||
          prof.contains('422') ||
          prof.contains('12')) {
        final ok = names.any(
          (e) =>
              e.contains('444') ||
              e.contains('422') ||
              e.contains('12') ||
              e.contains('rext'),
        );
        if (!ok) {
          return CapabilityVerdict.unsupported(
            'HEVC ${profile ?? 'Rext'} (4:2:2, 4:4:4 or 12-bit) is not '
            'supported by this TV; $_convertHint',
          );
        }
      } else if (prof.startsWith('main10') &&
          !names.any((e) => e.startsWith('main10'))) {
        return const CapabilityVerdict.unsupported(
          'HEVC Main10 is not supported by this TV; $_convertHint',
        );
      }
    }
    if (codec == 'h264') {
      final need = prof.contains('444')
          ? '444'
          : prof.contains('422')
          ? '422'
          : prof.contains('high10')
          ? 'high10'
          : null;
      if (need != null && !names.any((e) => e.contains(need))) {
        return CapabilityVerdict.unsupported(
          'H.264 ${profile ?? ''} is not supported by this TV; '
          '$_convertHint',
        );
      }
    }
  }

  if (width != null && height != null) {
    final limit =
        (maxW != null && maxH != null ? (maxW, maxH) : null) ??
        _size(capabilities['panel']);
    if (limit != null) {
      final long = width > height ? width : height;
      final short = width > height ? height : width;
      final lLong = limit.$1 > limit.$2 ? limit.$1 : limit.$2;
      final lShort = limit.$1 > limit.$2 ? limit.$2 : limit.$1;
      if (long > lLong || short > lShort) {
        return CapabilityVerdict.unsupported(
          '${_sizeName(width, height)} is larger than this TV can show '
          '(${limit.$1}x${limit.$2}); $_convertHint',
        );
      }
    }
  }

  if (hdr != null && hdr != 'SDR') {
    final parts = hdr.split('/');
    final base = parts.length > 1 ? parts[1] : null;
    bool has(String t) => hdrTypes.contains(t.toLowerCase());
    final ok = has(parts[0]) || (base != null && (base == 'SDR' || has(base)));
    if (!ok) {
      final label = parts[0] == 'DolbyVision' ? 'Dolby Vision' : parts[0];
      return CapabilityVerdict.unsupported(
        '$label is not supported by this TV; $_convertHint',
      );
    }
  }

  if (audioCodec != null &&
      audioCodec.isNotEmpty &&
      !_baselineAudio.contains(audioCodec)) {
    final pattern = _decoderPattern(audioCodec);
    final listed = decoders.any(
      (d) => !d.contains('video/') && pattern.hasMatch(d),
    );
    if (!listed) {
      return CapabilityVerdict.unsupported(
        '${_codecLabel(audioCodec)} sound is not supported by this TV; '
        '$_convertHint',
      );
    }
  }
  return const CapabilityVerdict.supported();
}
