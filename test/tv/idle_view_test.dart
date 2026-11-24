import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tv_saver/tv/display/idle_view.dart';

void main() {
  Widget host(Widget child, {bool h24 = true}) => MaterialApp(
    home: Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: h24),
        child: Scaffold(backgroundColor: Colors.black, body: child),
      ),
    ),
  );

  testWidgets('shows the clock, the date, the status line and the Pi dot', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        IdleView(
          status: IdleView.readyText,
          now: () => DateTime(2026, 11, 24, 9, 5),
        ),
      ),
    );
    expect(find.text('09:05'), findsOneWidget);
    expect(find.text('Tuesday, November 24, 2026'), findsOneWidget);
    expect(find.text('Ready — choose something on your phone'), findsOne);
    expect(find.byKey(const Key('idle-dot')), findsOneWidget);
    expect(find.bySemanticsLabel('Pi connected'), findsOneWidget);
    // Near black, not a picture.
    expect(IdleView.background.computeLuminance(), lessThan(0.01));
  });

  testWidgets('follows the TV 12 hour setting and its language', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        IdleView(status: 'x', now: () => DateTime(2026, 11, 24, 21, 5)),
        h24: false,
      ),
    );
    expect(find.text('9:05 PM'), findsOneWidget);
    expect(find.text('21:05'), findsNothing);
  });

  testWidgets('a time jump is corrected by the next drift', (tester) async {
    var now = DateTime(2026, 11, 24, 9, 5, 10);
    await tester.pumpWidget(host(IdleView(status: 'x', now: () => now)));
    expect(find.text('09:05'), findsOneWidget);
    // The clock is set back by an hour; within a minute the screen
    // shows the right time again.
    now = DateTime(2026, 11, 24, 8, 5, 20);
    await tester.pump(const Duration(minutes: 1));
    expect(find.text('08:05'), findsOneWidget);
  });

  testWidgets('the dot and the line say when the Pi is not reachable', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        const IdleView(
          status: 'The Pi is not reachable. Trying again…',
          link: IdleLink.unreachable,
        ),
      ),
    );
    expect(find.text('The Pi is not reachable. Trying again…'), findsOne);
    expect(find.bySemanticsLabel('Pi not reachable'), findsOneWidget);
  });

  testWidgets('the clock follows the minute', (tester) async {
    var now = DateTime(2026, 11, 24, 21, 59, 30);
    await tester.pumpWidget(host(IdleView(status: 'x', now: () => now)));
    expect(find.text('21:59'), findsOneWidget);
    now = DateTime(2026, 11, 24, 22, 0, 1);
    await tester.pump(const Duration(seconds: 31));
    expect(find.text('22:00'), findsOneWidget);
  });

  testWidgets('the group drifts to a new spot every minute and sits still '
      'in between', (tester) async {
    await tester.pumpWidget(host(IdleView(status: 'x', random: Random(7))));
    Offset where() => tester.getTopLeft(find.byKey(const Key('idle-group')));
    final start = where();

    await tester.pump(const Duration(seconds: 59));
    expect(where(), start, reason: 'nothing moves before the minute is up');

    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 21)); // the slow move ends
    final first = where();
    expect(first, isNot(start));

    await tester.pump(const Duration(seconds: 30));
    expect(where(), first);

    await tester.pump(const Duration(seconds: 31));
    await tester.pump(const Duration(seconds: 21));
    final second = where();
    expect(second, isNot(first));

    // The group stays on screen.
    final size = tester.getSize(find.byKey(const Key('idle-view')));
    final box = tester.getRect(find.byKey(const Key('idle-group')));
    expect(box.left, greaterThanOrEqualTo(0));
    expect(box.top, greaterThanOrEqualTo(0));
    expect(box.right, lessThanOrEqualTo(size.width));
    expect(box.bottom, lessThanOrEqualTo(size.height));
  });

  testWidgets('a drift moves smoothly: halfway through it is between the '
      'two spots', (tester) async {
    await tester.pumpWidget(host(IdleView(status: 'x', random: Random(3))));
    Offset where() => tester.getTopLeft(find.byKey(const Key('idle-group')));
    final start = where();
    await tester.pump(const Duration(minutes: 1));
    await tester.pump(const Duration(seconds: 10));
    final mid = where();
    await tester.pump(const Duration(seconds: 11));
    final end = where();
    expect(mid, isNot(start));
    expect(mid, isNot(end));
  });
}
