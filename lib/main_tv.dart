import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'tv/display_report.dart';
import 'tv/pi/pi_screen.dart';
import 'tv/report_screen.dart';
import 'tv/video_spike/spike_log.dart';
import 'tv/video_spike/spike_native.dart';
import 'tv/video_spike/spike_screen.dart';

/// TV app entry point (flavor `tv`, `com.codedbykay.tvsaver.tv`).
///
/// Phase 1 spike: full screen, shows and logs the DisplayReport.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

  var version = '?';
  try {
    final info = await PackageInfo.fromPlatform();
    version = '${info.version} (${info.buildNumber})';
  } catch (e) {
    debugPrint('TV Saver: version unavailable: $e');
  }
  debugPrint('TV Saver: version $version');

  // The true panel size from the native display mode; a `wm size` override
  // shrinks `view.display.size`, so that is only the fallback.
  final panel = await DisplayReport.fetchPanelSize();
  if (panel == null) {
    debugPrint('TV Saver: native panel size unavailable, panel unverified');
  }

  // Story 1-2: what the TV can decode (HEVC profiles, AC-3 / E-AC-3).
  unawaited(logVideoDecoders(const ChannelSpikeNative()));

  runApp(TvSaverApp(version: version, panel: panel));
}

class TvSaverApp extends StatelessWidget {
  const TvSaverApp({super.key, required this.version, this.panel});

  final String version;

  /// Native panel size from [DisplayReport.fetchPanelSize]; null falls back
  /// to `view.display.size` (marked "panel unverified").
  final PanelSize? panel;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TV Saver',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(brightness: Brightness.dark),
      home: Scaffold(
        backgroundColor: Colors.black,
        body: _SpikeLauncher(
          child: ReportScreen(
            version: version,
            read: () => DisplayReport.read(panel: panel),
          ),
        ),
      ),
    );
  }
}

/// Wraps the report screen: OK / Enter opens the Pi stream & throughput screen
/// (story 2-3), Right arrow opens the local video spike (story 1-2). The
/// report screen itself is unchanged.
class _SpikeLauncher extends StatelessWidget {
  const _SpikeLauncher({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.sizeOf(context).height;
    return Focus(
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        final key = event.logicalKey;
        if (key == LogicalKeyboardKey.select ||
            key == LogicalKeyboardKey.enter) {
          Navigator.of(
            context,
          ).push(MaterialPageRoute<void>(builder: (_) => const PiScreen()));
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.arrowRight) {
          Navigator.of(
            context,
          ).push(MaterialPageRoute<void>(builder: (_) => const SpikeScreen()));
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Stack(
        children: [
          child,
          Positioned(
            right: height * 0.1,
            bottom: height * 0.08,
            child: Text(
              'OK: Pi stream   Right: video spike',
              style: TextStyle(
                color: const Color(0xFFD0D0D0),
                fontSize: height * 0.035,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
