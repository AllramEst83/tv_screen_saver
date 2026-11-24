import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:tv_saver/tv/display/display_player.dart';
import 'package:tv_saver/tv/display/image_stage.dart';

void main() {
  late Directory tmp;
  late ValueNotifier<ImageSlot?> slots;
  var nonce = 0;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('stage');
    slots = ValueNotifier(null);
  });

  tearDown(() {
    slots.dispose();
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows keeps a decoded file open for a moment.
    }
  });

  File picture(String name, int r) {
    final image = img.Image(width: 64, height: 36)
      ..clear(img.ColorRgb8(r, 40, 40));
    final f = File('${tmp.path}/$name');
    f.writeAsBytesSync(img.encodePng(image));
    return f;
  }

  ImageSlot slot(File f, {bool crossfade = true, bool kenBurns = false}) =>
      ImageSlot(
        file: f,
        nonce: ++nonce,
        crossfade: crossfade,
        kenBurns: kenBurns,
        durationMs: 4000,
      );

  Widget stage() => Directionality(
    textDirection: TextDirection.ltr,
    child: ImageStage(slots: slots),
  );

  Future<void> decoded(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
    }
  }

  testWidgets('shows nothing until a photo is set, then the photo', (
    tester,
  ) async {
    await tester.pumpWidget(stage());
    expect(find.byType(Image), findsNothing);
    slots.value = slot(picture('a.png', 200));
    await decoded(tester);
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(Image), findsOneWidget);
    final image = tester.widget<Image>(find.byType(Image));
    expect(image.fit, BoxFit.contain);
    expect(image.filterQuality, FilterQuality.high);
    expect(image.image, isA<ResizeImage>());
  });

  testWidgets('the next photo cross-fades over the old one', (tester) async {
    await tester.pumpWidget(stage());
    slots.value = slot(picture('a.png', 200));
    await decoded(tester);
    await tester.pump(const Duration(seconds: 1));
    slots.value = slot(picture('b.png', 100));
    await decoded(tester);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(Image), findsNWidgets(2)); // both during the fade
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('a cut replaces the photo at once', (tester) async {
    await tester.pumpWidget(stage());
    slots.value = slot(picture('a.png', 200), crossfade: false);
    await decoded(tester);
    await tester.pump();
    slots.value = slot(picture('b.png', 100), crossfade: false);
    await decoded(tester);
    await tester.pump();
    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('clearing the slot removes the photo', (tester) async {
    await tester.pumpWidget(stage());
    slots.value = slot(picture('a.png', 200));
    await decoded(tester);
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(Image), findsOneWidget);
    slots.value = null;
    await tester.pump();
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('Ken Burns zooms slowly on the GPU', (tester) async {
    await tester.pumpWidget(stage());
    slots.value = slot(picture('a.png', 200), kenBurns: true);
    await decoded(tester);
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(ScaleTransition), findsWidgets);
    double scale() => tester
        .widgetList<ScaleTransition>(find.byType(ScaleTransition))
        .last
        .scale
        .value;
    final early = scale();
    await tester.pump(const Duration(seconds: 3));
    expect(scale(), greaterThan(early));
    expect(scale(), lessThanOrEqualTo(1.08));
  });

  testWidgets('an unreadable file is skipped and the next photo still shows', (
    tester,
  ) async {
    await tester.pumpWidget(stage());
    final bad = File('${tmp.path}/bad.png')..writeAsBytesSync([1, 2, 3]);
    slots.value = slot(bad);
    await decoded(tester);
    expect(find.byType(Image), findsNothing);
    slots.value = slot(picture('ok.png', 150));
    await decoded(tester);
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(Image), findsOneWidget);
  });
}
