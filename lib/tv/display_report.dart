import 'dart:ui' as ui;

import 'package:flutter/services.dart';

/// The panel's native size in physical pixels.
typedef PanelSize = ({int width, int height});

/// Channel to `MainActivity`: `panelSize` returns the native display mode's
/// `physicalWidth`/`physicalHeight`.
const displayChannel = MethodChannel('tvsaver/display');

/// What the TV actually renders to, versus what the panel can show.
///
/// A 4K panel can still run the app at 1920x1080 (Android TV UI scaling or a
/// `wm size` override), which would cap image sharpness. This makes the real
/// numbers visible on screen and in the startup log
/// (`adb logcat -s flutter | grep DisplayReport`).
class DisplayReport {
  const DisplayReport({
    required this.renderWidth,
    required this.renderHeight,
    required this.pixelRatio,
    required this.displayWidth,
    required this.displayHeight,
    this.panelVerified = true,
  });

  /// The Flutter view in physical pixels (what the engine draws into).
  final int renderWidth;
  final int renderHeight;

  /// Physical pixels per logical pixel.
  final double pixelRatio;

  /// The panel in physical pixels (the native display mode).
  final int displayWidth;
  final int displayHeight;

  /// False when the panel size could not be read from the native display
  /// mode and fell back to `view.display.size`, which Android shrinks to a
  /// `wm size` override.
  final bool panelVerified;

  /// Asks `MainActivity` for the native display mode's size.
  ///
  /// Null when the channel is missing, fails or answers something malformed.
  static Future<PanelSize?> fetchPanelSize([
    MethodChannel channel = displayChannel,
  ]) async {
    try {
      final result = await channel.invokeMapMethod<String, Object?>(
        'panelSize',
      );
      final width = result?['width'];
      final height = result?['height'];
      if (width is int && height is int && width > 0 && height > 0) {
        return (width: width, height: height);
      }
    } on PlatformException catch (_) {
    } on MissingPluginException catch (_) {}
    return null;
  }

  /// Reads the first view; null when there is none (tests, early startup).
  ///
  /// [panel] comes from [fetchPanelSize]. Without it the panel falls back to
  /// `view.display.size` and the report is marked unverified.
  static DisplayReport? read({
    ui.PlatformDispatcher? dispatcher,
    PanelSize? panel,
  }) {
    final views = (dispatcher ?? ui.PlatformDispatcher.instance).views;
    if (views.isEmpty) return null;
    final view = views.first;
    final size = view.physicalSize;
    final int displayWidth;
    final int displayHeight;
    if (panel != null) {
      displayWidth = panel.width;
      displayHeight = panel.height;
    } else {
      final display = view.display.size;
      displayWidth = display.width.round();
      displayHeight = display.height.round();
    }
    return DisplayReport(
      renderWidth: size.width.round(),
      renderHeight: size.height.round(),
      pixelRatio: view.devicePixelRatio,
      displayWidth: displayWidth,
      displayHeight: displayHeight,
      panelVerified: panel != null,
    );
  }

  /// True when the app draws at a lower resolution than the panel.
  bool get belowDisplay =>
      renderWidth < displayWidth || renderHeight < displayHeight;

  /// True when the render surface is at least 3840 px wide (4K).
  bool get isNative4k => renderWidth >= 3840;

  /// One line for the screen and the log.
  String get summary {
    final render = '$renderWidth×$renderHeight';
    final panel = '$displayWidth×$displayHeight';
    final ratio = pixelRatio.toStringAsFixed(2);
    final verdict = isNative4k
        ? '4K'
        : belowDisplay
        ? 'below the panel'
        : 'not 4K';
    final unverified = panelVerified ? '' : ' (panel unverified)';
    return 'renders $render, panel $panel, ratio $ratio ($verdict)$unverified';
  }
}
