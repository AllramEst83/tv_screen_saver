import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tv_saver/tv/display_report.dart';
import 'package:tv_saver/tv/report_screen.dart';

class _NoViews extends Fake implements ui.PlatformDispatcher {
  @override
  Iterable<ui.FlutterView> get views => const [];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  DisplayReport report(
    int rw,
    int rh,
    int dw,
    int dh, {
    double ratio = 2,
    bool verified = true,
  }) => DisplayReport(
    renderWidth: rw,
    renderHeight: rh,
    pixelRatio: ratio,
    displayWidth: dw,
    displayHeight: dh,
    panelVerified: verified,
  );

  test('4K render on a 4K panel is native 4K', () {
    final r = report(3840, 2160, 3840, 2160);
    expect(r.isNative4k, isTrue);
    expect(r.belowDisplay, isFalse);
    expect(r.summary, contains('(4K)'));
    expect(r.summary, contains('3840×2160'));
    expect(r.summary, isNot(contains('unverified')));
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

  test('an unverified panel is marked in the summary', () {
    final r = report(1920, 1080, 1920, 1080, ratio: 1, verified: false);
    expect(
      r.summary,
      'renders 1920×1080, panel 1920×1080, ratio 1.00 (not 4K) '
      '(panel unverified)',
    );
  });

  test('read returns null when there is no view yet', () {
    expect(DisplayReport.read(dispatcher: _NoViews()), isNull);
  });

  test('log line: summary when known, "unknown" when there is no view', () {
    expect(displayReportLogLine(null), 'DisplayReport: unknown');
    expect(
      displayReportLogLine(report(1920, 1080, 3840, 2160, ratio: 1)),
      'DisplayReport: renders 1920×1080, panel 3840×2160, ratio 1.00 '
      '(below the panel)',
    );
  });

  group('read on a view with a wm size override', () {
    // X90K as measured: the view and view.display both report the 1920×1080
    // override; only the native display mode knows the 3840×2160 panel.
    testWidgets('panel from the channel: "below the panel", verified', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 2;
      tester.view.display.size = const Size(1920, 1080);
      addTearDown(tester.view.reset);
      addTearDown(tester.view.display.reset);

      final r = DisplayReport.read(
        dispatcher: tester.binding.platformDispatcher,
        panel: (width: 3840, height: 2160),
      )!;

      expect(r.displayWidth, 3840);
      expect(r.displayHeight, 2160);
      expect(r.panelVerified, isTrue);
      expect(
        r.summary,
        'renders 1920×1080, panel 3840×2160, ratio 2.00 (below the panel)',
      );
    });

    testWidgets('no panel: falls back to view.display, marked unverified', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 2;
      tester.view.display.size = const Size(1920, 1080);
      addTearDown(tester.view.reset);
      addTearDown(tester.view.display.reset);

      final r = DisplayReport.read(
        dispatcher: tester.binding.platformDispatcher,
      )!;

      expect(r.displayWidth, 1920);
      expect(r.panelVerified, isFalse);
      expect(r.summary, endsWith('(not 4K) (panel unverified)'));
    });
  });

  group('fetchPanelSize', () {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    void answer(Future<Object?>? Function(MethodCall call) handler) {
      messenger.setMockMethodCallHandler(displayChannel, handler);
      addTearDown(
        () => messenger.setMockMethodCallHandler(displayChannel, null),
      );
    }

    test('returns the native display mode size', () async {
      final calls = <String>[];
      answer((call) async {
        calls.add(call.method);
        return {'width': 3840, 'height': 2160};
      });

      expect(await DisplayReport.fetchPanelSize(), (width: 3840, height: 2160));
      expect(calls, ['panelSize']);
    });

    test('null when the platform side fails', () async {
      answer((call) async => throw PlatformException(code: 'no_display'));
      expect(await DisplayReport.fetchPanelSize(), isNull);
    });

    test('null when the channel is not implemented', () async {
      // No handler: MissingPluginException.
      expect(await DisplayReport.fetchPanelSize(), isNull);
    });

    test('null when the answer is malformed', () async {
      answer((call) async => {'width': 3840});
      expect(await DisplayReport.fetchPanelSize(), isNull);
      answer((call) async => {'width': 0, 'height': 0});
      expect(await DisplayReport.fetchPanelSize(), isNull);
    });
  });
}
