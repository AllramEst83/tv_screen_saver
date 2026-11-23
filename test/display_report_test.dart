import 'dart:ui' as ui;

import 'package:tv_saver/tv/display_report.dart';
import 'package:tv_saver/tv/report_screen.dart';
import 'package:flutter_test/flutter_test.dart';

class _NoViews extends Fake implements ui.PlatformDispatcher {
  @override
  Iterable<ui.FlutterView> get views => const [];
}

void main() {
  DisplayReport report(int rw, int rh, int dw, int dh, {double ratio = 2}) =>
      DisplayReport(
        renderWidth: rw,
        renderHeight: rh,
        pixelRatio: ratio,
        displayWidth: dw,
        displayHeight: dh,
      );

  test('4K render on a 4K panel is native 4K', () {
    final r = report(3840, 2160, 3840, 2160);
    expect(r.isNative4k, isTrue);
    expect(r.belowDisplay, isFalse);
    expect(r.summary, contains('(4K)'));
    expect(r.summary, contains('3840×2160'));
  });

  test('1080p render on a 4K panel is flagged as below the panel', () {
    final r = report(1920, 1080, 3840, 2160, ratio: 1);
    expect(r.isNative4k, isFalse);
    expect(r.belowDisplay, isTrue);
    expect(r.summary, contains('below the panel'));
  });

  test('1080p render on a 1080p panel is not 4K but not below', () {
    final r = report(1920, 1080, 1920, 1080, ratio: 1);
    expect(r.belowDisplay, isFalse);
    expect(r.summary, contains('not 4K'));
  });

  test('read returns null when there is no view yet', () {
    expect(DisplayReport.read(_NoViews()), isNull);
  });

  test('log line: summary when known, "unknown" when there is no view', () {
    expect(displayReportLogLine(null), 'DisplayReport: unknown');
    expect(
      displayReportLogLine(report(1920, 1080, 3840, 2160, ratio: 1)),
      'DisplayReport: renders 1920×1080, panel 3840×2160, ratio 1.00 '
      '(below the panel)',
    );
  });

  test('read returns a report from the test binding view', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    final r = DisplayReport.read();
    expect(r, isNotNull);
    expect(r!.renderWidth, greaterThan(0));
  });
}
