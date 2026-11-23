import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tv_saver/main_tv.dart';
import 'package:tv_saver/tv/display_report.dart';
import 'package:tv_saver/tv/report_screen.dart';

const _fullHdOn4k = DisplayReport(
  renderWidth: 1920,
  renderHeight: 1080,
  pixelRatio: 1,
  displayWidth: 3840,
  displayHeight: 2160,
);

const _native4k = DisplayReport(
  renderWidth: 3840,
  renderHeight: 2160,
  pixelRatio: 2,
  displayWidth: 3840,
  displayHeight: 2160,
);

Widget _host(ReportScreen screen) => MaterialApp(home: Scaffold(body: screen));

void main() {
  testWidgets('1080p override: shows and logs "below the panel"', (
    tester,
  ) async {
    final logs = <String>[];
    await tester.pumpWidget(
      _host(
        ReportScreen(
          version: '0.1.0 (1)',
          read: () => _fullHdOn4k,
          log: logs.add,
        ),
      ),
    );

    expect(find.text('Renders 1920×1080'), findsOneWidget);
    expect(find.text('Panel 3840×2160'), findsOneWidget);
    expect(find.textContaining('(below the panel)'), findsOneWidget);
    expect(find.text('Version 0.1.0 (1)'), findsOneWidget);
    expect(logs, [
      'DisplayReport: renders 1920×1080, panel 3840×2160, ratio 1.00 '
          '(below the panel)',
    ]);
  });

  testWidgets('native 4K: shows "(4K)"', (tester) async {
    final logs = <String>[];
    await tester.pumpWidget(
      _host(ReportScreen(version: '1', read: () => _native4k, log: logs.add)),
    );

    expect(find.textContaining('(4K)'), findsOneWidget);
    expect(logs.single, contains('(4K)'));
  });

  testWidgets('no view yet: logs unknown, retries on the first frame', (
    tester,
  ) async {
    final logs = <String>[];
    var reads = 0;
    // No view on the first read; it exists by the time the first frame is done.
    DisplayReport? read() => reads++ == 0 ? null : _fullHdOn4k;
    await tester.pumpWidget(
      _host(ReportScreen(version: '1', read: read, log: logs.add)),
    );

    // First frame drawn without a reading; no crash.
    expect(tester.takeException(), isNull);
    expect(find.text('Display: measuring…'), findsOneWidget);
    expect(logs.first, 'DisplayReport: unknown');

    // The post-frame retry got the reading; the next frame shows it.
    await tester.pump();

    expect(find.text('Renders 1920×1080'), findsOneWidget);
    expect(logs, hasLength(2));
    expect(logs.last, startsWith('DisplayReport: renders 1920×1080'));
  });

  testWidgets('a stable reading is logged once across rebuilds', (
    tester,
  ) async {
    final logs = <String>[];
    Widget app() =>
        _host(ReportScreen(version: '1', read: () => _native4k, log: logs.add));
    await tester.pumpWidget(app());
    tester.view.physicalSize = const Size(1600, 900);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pump();

    expect(logs, hasLength(1));
  });

  testWidgets('the TV app shows the report with high-contrast text', (
    tester,
  ) async {
    await tester.pumpWidget(const TvSaverApp(version: '0.1.0 (1)'));

    expect(find.text('TV Saver'), findsOneWidget);
    expect(find.text('Version 0.1.0 (1)'), findsOneWidget);
    final title = tester.widget<Text>(find.text('TV Saver'));
    expect(title.style!.color, Colors.white);
    // Sofa-readable: the title is 8 % of the screen height.
    final height =
        tester.view.physicalSize.height / tester.view.devicePixelRatio;
    expect(title.style!.fontSize, closeTo(height * 0.08, 0.01));
  });
}
