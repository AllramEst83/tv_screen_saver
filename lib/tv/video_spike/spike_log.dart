import 'package:flutter/foundation.dart';

import 'spike_native.dart';

/// How the clip is put on screen.
enum SpikeView {
  /// `video_player` through a Flutter texture.
  texture('texture'),

  /// `video_player` with `VideoViewType.platformView` (SurfaceView).
  platformView('platform-view'),

  /// Native Media3 ExoPlayer on a SurfaceView platform view.
  media3('media3-surface');

  const SpikeView(this.label);
  final String label;
}

/// How a clip repeats.
enum SpikeLoop {
  /// ExoPlayer repeat-one (`video_player` `setLooping(true)`).
  repeatOne('repeat-one'),

  /// Two items of the same clip with repeat-all. Only the Media3 view can do it.
  playlist('two-item-playlist');

  const SpikeLoop(this.label);
  final String label;
}

/// Logcat sink (tag `flutter`); a function so it can be a default value.
void spikeLog(String line) => debugPrint(line);

/// `VideoSpike: ...` line for one run, grepped from logcat by the runbook.
///
/// [phase] is `playing` (a few seconds in, display read again) or `stopped`.
String videoSpikeLogLine({
  required String clip,
  required SpikeView view,
  required SpikeLoop loop,
  required String phase,
  String? decoder,
  String? hdr,
  DisplayModeInfo? displayBefore,
  DisplayModeInfo? displayNow,
  int? droppedFrames,
  double? clipFps,
  String? note,
}) {
  final parts = <String>[
    'clip=$clip',
    'mode=${view.label}',
    'loop=${loop.label}',
    'phase=$phase',
    'decoder=${decoder ?? 'unknown'}',
    'hdr=${hdr ?? 'unknown'}',
    'display_before=${displayBefore?.label ?? 'unknown'}',
    'display_now=${displayNow?.label ?? 'unknown'}',
    'dropped=${droppedFrames ?? 'n/a'}',
  ];
  final verdict = refreshVerdict(clipFps, displayNow);
  if (verdict != null) parts.add('result=$verdict');
  if (note != null) parts.add('note=$note');
  return 'VideoSpike: ${parts.join(', ')}';
}

/// "24p possible" when a ~24 Hz clip plays at a display refresh that is a
/// multiple of its frame rate in the 24 or 48 Hz family; "only 60 Hz mode"
/// otherwise. Null for clips that are not 23.976/24 fps.
String? refreshVerdict(double? clipFps, DisplayModeInfo? now) {
  if (clipFps == null || now == null) return null;
  if ((clipFps - 23.976).abs() > 0.05 && (clipFps - 24).abs() > 0.05) {
    return null;
  }
  final hz = now.refreshRate;
  final matches = [24.0, 23.976, 48.0, 47.952, 72.0, 71.928, 120.0, 119.88];
  final ok = matches.any((m) => (hz - m).abs() < 0.05);
  return ok ? '24p possible' : 'only 60 Hz mode';
}

/// Logs the decoders found by `MediaCodecList` (HEVC profiles, AC-3, E-AC-3).
Future<void> logVideoDecoders(
  SpikeNative native, [
  void Function(String line) log = spikeLog,
]) async {
  final lines = await native.decoders();
  if (lines.isEmpty) {
    log('VideoSpike: decoders unavailable');
    return;
  }
  for (final line in lines) {
    log('VideoSpike: decoder $line');
  }
}
