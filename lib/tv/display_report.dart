import 'dart:ui' as ui;

/// What the TV actually renders to, versus what the panel can show.
///
/// A 4K panel can still run the app at 1920x1080 (Android TV UI scaling),
/// which would cap image sharpness. This makes the real numbers visible in
/// About and in the startup log (`adb logcat -s flutter | grep DisplayReport`).
class DisplayReport {
  const DisplayReport({
    required this.renderWidth,
    required this.renderHeight,
    required this.pixelRatio,
    required this.displayWidth,
    required this.displayHeight,
  });

  /// The Flutter view in physical pixels (what the engine draws into).
  final int renderWidth;
  final int renderHeight;

  /// Physical pixels per logical pixel.
  final double pixelRatio;

  /// The display mode in physical pixels (what the panel shows).
  final int displayWidth;
  final int displayHeight;

  /// Reads the first view; null when there is none (tests, early startup).
  static DisplayReport? read([ui.PlatformDispatcher? dispatcher]) {
    final views = (dispatcher ?? ui.PlatformDispatcher.instance).views;
    if (views.isEmpty) return null;
    final view = views.first;
    final size = view.physicalSize;
    final display = view.display.size;
    return DisplayReport(
      renderWidth: size.width.round(),
      renderHeight: size.height.round(),
      pixelRatio: view.devicePixelRatio,
      displayWidth: display.width.round(),
      displayHeight: display.height.round(),
    );
  }

  /// True when the app draws at a lower resolution than the panel.
  bool get belowDisplay =>
      renderWidth < displayWidth || renderHeight < displayHeight;

  /// True when the render surface is at least 3840 px wide (4K).
  bool get isNative4k => renderWidth >= 3840;

  /// One line for About and the log.
  String get summary {
    final render = '$renderWidth×$renderHeight';
    final panel = '$displayWidth×$displayHeight';
    final ratio = pixelRatio.toStringAsFixed(2);
    final verdict = isNative4k
        ? '4K'
        : belowDisplay
        ? 'below the panel'
        : 'not 4K';
    return 'renders $render, panel $panel, ratio $ratio ($verdict)';
  }
}
