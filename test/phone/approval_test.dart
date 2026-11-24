import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tv_saver/phone/phone_controller.dart';
import 'package:tv_saver/phone/screens/home_screen.dart';

import 'support.dart';

class ApprovalController extends PhoneController {
  ApprovalController(PhoneRig rig)
    : super(client: rig.client, store: rig.store);

  PendingApproval? pending;
  final List<bool> answers = [];

  void set(PendingApproval? p) {
    pending = p;
    notifyListeners();
  }

  @override
  PendingApproval? get pendingApproval => pending;

  @override
  Future<void> answerApproval(bool approve) async {
    answers.add(approve);
    set(null);
  }
}

void main() {
  late PhoneRig rig;
  late ApprovalController controller;

  setUp(() {
    rig = PhoneRig();
    controller = ApprovalController(rig);
  });
  tearDown(() async {
    controller.dispose();
    await rig.dispose();
  });

  Future<void> pumpHome(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(home: HomeScreen(controller: controller)),
    );
    await tester.pump();
  }

  testWidgets('a TV asking in shows "Approve this TV?" and Approve answers', (
    tester,
  ) async {
    await pumpHome(tester);
    expect(find.text('Approve this TV?'), findsNothing);

    controller.set(const PendingApproval('r_1', 'Living room'));
    await tester.pumpAndSettle();
    expect(find.text('Approve this TV?'), findsOneWidget);
    expect(find.textContaining('Living room'), findsOneWidget);

    await tester.tap(find.byKey(const Key('approve-yes')));
    await tester.pumpAndSettle();
    expect(controller.answers, [true]);
    expect(find.text('Approve this TV?'), findsNothing);
  });

  testWidgets('Deny dismisses without approving', (tester) async {
    await pumpHome(tester);
    controller.set(const PendingApproval('r_1', 'TV'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('approve-deny')));
    await tester.pumpAndSettle();
    expect(controller.answers, [false]);
    expect(find.text('Approve this TV?'), findsNothing);
  });

  testWidgets('the dialog closes by itself when the request ends', (
    tester,
  ) async {
    await pumpHome(tester);
    controller.set(const PendingApproval('r_1', 'TV'));
    await tester.pumpAndSettle();
    expect(find.text('Approve this TV?'), findsOneWidget);

    controller.set(null); // approved elsewhere, timed out or the TV left
    await tester.pumpAndSettle();
    expect(find.text('Approve this TV?'), findsNothing);
    expect(controller.answers, isEmpty);
  });
}
