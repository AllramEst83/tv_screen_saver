import 'package:flutter/services.dart';

/// Channel to `VideoSpike.kt` (story 1-2).
const videoChannel = MethodChannel('tvsaver/video');

/// View type of the native Media3 SurfaceView platform view.
const media3ViewType = 'tvsaver/media3view';

/// The active display mode as Android reports it.
class DisplayModeInfo {
  const DisplayModeInfo({
    required this.modeId,
    required this.width,
    required this.height,
    required this.refreshRate,
    this.supportedModes = const [],
    this.hdrTypes = const [],
  });

  final int modeId;
  final int width;
  final int height;
  final double refreshRate;
  final List<String> supportedModes;

  /// Android HDR type ids: 1 Dolby Vision, 2 HDR10, 3 HLG, 4 HDR10+.
  final List<int> hdrTypes;

  /// `3840x2160@60.000`.
  String get label => '${width}x$height@${refreshRate.toStringAsFixed(3)}';

  static DisplayModeInfo? fromMap(Map<Object?, Object?>? m) {
    if (m == null || m['width'] is! int) return null;
    return DisplayModeInfo(
      modeId: m['modeId'] as int,
      width: m['width'] as int,
      height: m['height'] as int,
      refreshRate: (m['refreshRate'] as num).toDouble(),
      supportedModes: [...?(m['supportedModes'] as List?)?.cast<String>()],
      hdrTypes: [...?(m['hdrTypes'] as List?)?.cast<int>()],
    );
  }
}

/// Container facts about a clip (MediaExtractor), for the `video_player` paths.
class ClipProbe {
  const ClipProbe({
    this.mime,
    this.hdr = 'SDR',
    this.decoder,
    this.frameRate,
    this.audio,
  });

  final String? mime;
  final String hdr;
  final String? decoder;
  final double? frameRate;
  final String? audio;

  static ClipProbe? fromMap(Map<Object?, Object?>? m) {
    if (m == null || m['error'] != null) return null;
    return ClipProbe(
      mime: m['mime'] as String?,
      hdr: (m['hdr'] as String?) ?? 'SDR',
      decoder: m['decoder'] as String?,
      frameRate: (m['frameRate'] as num?)?.toDouble(),
      audio: m['audio'] as String?,
    );
  }
}

/// What the Media3 player reports while playing.
class Media3Stats {
  const Media3Stats({
    this.decoder,
    this.hdr,
    this.droppedFrames,
    this.frameRate,
    this.error,
    this.position = Duration.zero,
    this.item,
  });

  final String? decoder;
  final String? hdr;
  final int? droppedFrames;
  final double? frameRate;
  final String? error;
  final Duration position;
  final int? item;

  static Media3Stats? fromMap(Map<Object?, Object?>? m) {
    if (m == null) return null;
    return Media3Stats(
      decoder: m['decoder'] as String?,
      hdr: m['hdr'] as String?,
      droppedFrames: m['droppedFrames'] as int?,
      frameRate: (m['frameRate'] as num?)?.toDouble(),
      error: m['error'] as String?,
      position: Duration(milliseconds: (m['positionMs'] as int?) ?? 0),
      item: m['item'] as int?,
    );
  }
}

/// The native side of the spike. Injected so tests need no platform channel.
abstract class SpikeNative {
  /// The app's `files/spike` directory; null when unavailable.
  Future<String?> spikeDir();
  Future<List<String>> decoders();
  Future<DisplayModeInfo?> displayInfo();
  Future<ClipProbe?> probe(String path);

  /// Starts the Media3 player on the SurfaceView; [loop] is `repeatOne` or
  /// `playlist`.
  Future<void> media3Open(String path, String loop);
  Future<Media3Stats?> media3Stats();
  Future<void> media3Release();
}

/// [SpikeNative] over [videoChannel]. Every call swallows platform failures
/// and answers null / empty, so a missing native side never crashes the spike.
class ChannelSpikeNative implements SpikeNative {
  const ChannelSpikeNative([this.channel = videoChannel]);

  final MethodChannel channel;

  Future<T?> _call<T>(String method, [Map<String, Object?>? args]) async {
    try {
      return await channel.invokeMethod<T>(method, args);
    } on PlatformException catch (_) {
      return null;
    } on MissingPluginException catch (_) {
      return null;
    }
  }

  @override
  Future<String?> spikeDir() => _call<String>('spikeDir');

  @override
  Future<List<String>> decoders() async => [
    ...?(await _call<List<Object?>>('decoders'))?.cast<String>(),
  ];

  @override
  Future<DisplayModeInfo?> displayInfo() async => DisplayModeInfo.fromMap(
    await _call<Map<Object?, Object?>>('displayInfo'),
  );

  @override
  Future<ClipProbe?> probe(String path) async => ClipProbe.fromMap(
    await _call<Map<Object?, Object?>>('probe', {'path': path}),
  );

  @override
  Future<void> media3Open(String path, String loop) =>
      _call<void>('m3Open', {'path': path, 'loop': loop});

  @override
  Future<Media3Stats?> media3Stats() async =>
      Media3Stats.fromMap(await _call<Map<Object?, Object?>>('m3Stats'));

  @override
  Future<void> media3Release() =>
      _call<void>('m3Control', {'action': 'release'});
}
