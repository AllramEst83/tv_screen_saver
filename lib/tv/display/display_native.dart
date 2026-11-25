import 'package:flutter/services.dart';

import '../video_spike/spike_native.dart';

/// The native side of the paired display: one Media3 item at a time on the
/// SurfaceView platform view. Injected so tests need no platform channel.
abstract class DisplayVideoNative {
  /// The HEVC / AC-3 decoder lines of MediaCodecList (for the capabilities).
  Future<List<String>> decoders();

  /// The active display mode, with the HDR types the panel reports.
  Future<DisplayModeInfo?> displayInfo();

  /// Streams [url] with [headers] from [startMs]; replaces the current item.
  Future<void> open({
    required String url,
    required Map<String, String> headers,
    int startMs = 0,
    bool muted = false,
    bool playing = true,
    bool loop = false,
  });

  /// Draws the photo at [path] on the video surface at the panel's own size
  /// (3840x2160), so the 1080p Flutter plane does not halve it. True once it
  /// is on screen; false when this TV cannot (the caller shows it with a
  /// Flutter widget). The photo on screen stays until the new one is ready.
  Future<bool> showImage({
    required String path,
    int crossfadeMs = 0,
    bool kenBurns = false,
    int durationMs = 0,
  });

  /// The native photo is no longer wanted (a clip is next, or nothing):
  /// free it. The photo surface itself is a view Dart puts in the tree only
  /// while a photo shows.
  Future<void> clearImage();

  Future<void> pause();
  Future<void> resume();
  Future<void> seek(int positionMs);

  /// Player volume only; the TV's own volume is never touched.
  Future<void> setMuted(bool muted);
  Future<Media3Stats?> stats();
  Future<void> release();

  /// Set by the player bridge: called when the current item played to its end.
  void Function()? onEnded;
}

/// [DisplayVideoNative] over [videoChannel]. Platform failures answer null or
/// nothing, so a missing native side never crashes the TV app.
class ChannelDisplayNative implements DisplayVideoNative {
  ChannelDisplayNative([this.channel = videoChannel]) {
    channel.setMethodCallHandler((call) async {
      if (call.method == 'm3Ended') onEnded?.call();
      return null;
    });
  }

  final MethodChannel channel;

  @override
  void Function()? onEnded;

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
  Future<List<String>> decoders() async => [
    ...?(await _call<List<Object?>>('decoders'))?.cast<String>(),
  ];

  @override
  Future<DisplayModeInfo?> displayInfo() async => DisplayModeInfo.fromMap(
    await _call<Map<Object?, Object?>>('displayInfo'),
  );

  @override
  Future<void> open({
    required String url,
    required Map<String, String> headers,
    int startMs = 0,
    bool muted = false,
    bool playing = true,
    bool loop = false,
  }) => _call<void>('m3OpenItem', {
    'url': url,
    'headers': headers,
    'startMs': startMs,
    'muted': muted,
    'playing': playing,
    'loop': loop,
  });

  @override
  Future<bool> showImage({
    required String path,
    int crossfadeMs = 0,
    bool kenBurns = false,
    int durationMs = 0,
  }) async =>
      await _call<bool>('m3ShowImage', {
        'path': path,
        'crossfadeMs': crossfadeMs,
        'kenBurns': kenBurns,
        'durationMs': durationMs,
      }) ??
      false;

  @override
  Future<void> clearImage() => _call<void>('m3ClearImage');

  @override
  Future<void> pause() => _call<void>('m3Control', {'action': 'pause'});

  @override
  Future<void> resume() => _call<void>('m3Control', {'action': 'resume'});

  @override
  Future<void> seek(int positionMs) =>
      _call<void>('m3Control', {'action': 'seek', 'positionMs': positionMs});

  @override
  Future<void> setMuted(bool muted) =>
      _call<void>('m3Control', {'action': 'mute', 'muted': muted});

  @override
  Future<Media3Stats?> stats() async =>
      Media3Stats.fromMap(await _call<Map<Object?, Object?>>('m3Stats'));

  @override
  Future<void> release() => _call<void>('m3Control', {'action': 'release'});
}
