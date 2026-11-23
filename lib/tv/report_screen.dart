import 'package:flutter/material.dart';

import 'display_report.dart';

/// The startup log line, found by `tool/tv/display_report.sh` in logcat.
String displayReportLogLine(DisplayReport? report) => report == null
    ? 'DisplayReport: unknown'
    : 'DisplayReport: ${report.summary}';

/// Logged once when no view appeared within [maxNullRetries] frames.
const displayReportGaveUpLine =
    'DisplayReport: unknown, gave up after $maxNullRetries retries';

/// Post-frame retries while there is no view, before giving up.
const maxNullRetries = 10;

/// Full-screen DisplayReport, readable from the sofa.
///
/// Reads the report when it first builds and again whenever the view's size
/// changes. If no view exists yet it logs `DisplayReport: unknown` and retries
/// after each frame, at most [maxNullRetries] times, then stops and logs
/// [displayReportGaveUpLine] once. Every new reading is logged once.
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
  int _retries = 0;
  bool _gaveUp = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Depend on the view size and pixel ratio so a resolution change re-reads
    // the report (1080p -> 4K can keep the logical size and only double the
    // ratio).
    MediaQuery.sizeOf(context);
    MediaQuery.devicePixelRatioOf(context);
    _refresh();
  }

  void _refresh() {
    _report = widget.read();
    _logIfNew();
    if (_report != null || _retryScheduled || _gaveUp) return;
    if (_retries >= maxNullRetries) {
      _gaveUp = true;
      _emit(displayReportGaveUpLine);
      return;
    }
    _retries++;
    _retryScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _retryScheduled = false;
      if (!mounted) return;
      setState(_refresh);
    });
  }

  void _logIfNew() {
    final line = displayReportLogLine(_report);
    if (line == _lastLogged) return;
    _lastLogged = line;
    _emit(line);
  }

  void _emit(String line) {
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
              Text(
                _gaveUp ? 'Display: unknown' : 'Display: measuring…',
                style: body,
              )
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
