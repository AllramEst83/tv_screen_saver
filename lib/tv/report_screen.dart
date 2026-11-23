import 'package:flutter/material.dart';

import 'display_report.dart';

/// The startup log line, found by `tool/tv/display_report.sh` in logcat.
String displayReportLogLine(DisplayReport? report) => report == null
    ? 'DisplayReport: unknown'
    : 'DisplayReport: ${report.summary}';

/// Full-screen DisplayReport, readable from the sofa.
///
/// Reads the report when it first builds and again whenever the view's size
/// changes. If no view exists yet it logs `DisplayReport: unknown` and retries
/// after the first frame. Every new reading is logged.
class ReportScreen extends StatefulWidget {
  const ReportScreen({
    super.key,
    required this.version,
    this.read = DisplayReport.read,
    this.log,
  });

  /// App version shown under the report, e.g. `0.1.0 (1)`.
  final String version;

  /// Injected for tests; defaults to [DisplayReport.read].
  final DisplayReport? Function() read;

  /// Injected for tests; defaults to [debugPrint] (logcat tag `flutter`).
  final void Function(String line)? log;

  @override
  State<ReportScreen> createState() => _ReportScreenState();
}

class _ReportScreenState extends State<ReportScreen> {
  DisplayReport? _report;
  String? _lastLogged;
  bool _retryScheduled = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Depend on the view size so a resolution change re-reads the report.
    MediaQuery.sizeOf(context);
    _refresh();
  }

  void _refresh() {
    _report = widget.read();
    _logIfNew();
    if (_report == null && !_retryScheduled) {
      _retryScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _retryScheduled = false;
        if (!mounted) return;
        setState(_refresh);
      });
    }
  }

  void _logIfNew() {
    final line = displayReportLogLine(_report);
    if (line == _lastLogged) return;
    _lastLogged = line;
    final log = widget.log;
    if (log != null) {
      log(line);
    } else {
      debugPrint(line);
    }
  }

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.sizeOf(context).height;
    final report = _report;
    final title = TextStyle(
      color: Colors.white,
      fontSize: height * 0.08,
      fontWeight: FontWeight.w600,
    );
    final body = TextStyle(color: Colors.white, fontSize: height * 0.055);
    final note = TextStyle(
      color: const Color(0xFFD0D0D0),
      fontSize: height * 0.04,
    );

    return ColoredBox(
      color: Colors.black,
      child: Padding(
        // Stay clear of TV overscan.
        padding: EdgeInsets.symmetric(
          horizontal: height * 0.1,
          vertical: height * 0.08,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('TV Saver', style: title),
            SizedBox(height: height * 0.05),
            if (report == null)
              Text('Display: measuring…', style: body)
            else ...[
              Text(
                'Renders ${report.renderWidth}×${report.renderHeight}',
                style: body,
              ),
              Text(
                'Panel ${report.displayWidth}×${report.displayHeight}',
                style: body,
              ),
              SizedBox(height: height * 0.03),
              Text(report.summary, style: note),
            ],
            SizedBox(height: height * 0.05),
            Text('Version ${widget.version}', style: note),
          ],
        ),
      ),
    );
  }
}
