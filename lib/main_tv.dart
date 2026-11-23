import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'tv/display_report.dart';
import 'tv/report_screen.dart';

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
        body: ReportScreen(
          version: version,
          read: () => DisplayReport.read(panel: panel),
        ),
      ),
    );
  }
}
