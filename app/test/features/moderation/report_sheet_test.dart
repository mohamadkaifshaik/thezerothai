import 'package:dzeroth/app/session_wiring.dart' show UnexpectedErrorReporter;
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/moderation/data/moderation_repository.dart';
import 'package:dzeroth/features/moderation/presentation/report_sheet.dart';
import 'package:dzeroth/gen/dzeroth/moderation/v1/moderation.pbenum.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class MockModerationRepository extends Mock implements ModerationRepository {}

void main() {
  late MockModerationRepository repo;
  ReportOutcome? outcome;

  setUpAll(() {
    registerFallbackValue(ReportTargetType.REPORT_TARGET_TYPE_POST);
    registerFallbackValue(ReportReason.REPORT_REASON_SPAM);
  });

  setUp(() {
    repo = MockModerationRepository();
    outcome = null;
  });

  void stubReport(Future<ReportReceipt> Function() answer) {
    when(
      () => repo.report(
        idempotencyKey: any(named: 'idempotencyKey'),
        targetType: any(named: 'targetType'),
        targetId: any(named: 'targetId'),
        reason: any(named: 'reason'),
        note: any(named: 'note'),
      ),
    ).thenAnswer((_) => answer());
  }

  Future<void> openSheet(WidgetTester tester, {String? blockLabel}) async {
    // Tall enough for the whole form (Send is below the reasons).
    tester.view.physicalSize = const Size(800, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      RepositoryProvider<ModerationRepository>.value(
        value: repo,
        child: RepositoryProvider<UnexpectedErrorReporter>.value(
          value: (e, s) {},
          child: MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: TextButton(
                    onPressed: () async {
                      outcome = await showReportSheet(
                        context,
                        targetType: ReportTargetType.REPORT_TARGET_TYPE_POST,
                        targetId: '1234567890123456789',
                        subject: "@alice's post",
                        blockLabel: blockLabel,
                      );
                    },
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  Finder sendButton() => find.widgetWithText(FilledButton, 'Send report');

  testWidgets('shows the subject and every reason; Send is disabled until a '
      'reason is chosen', (tester) async {
    await openSheet(tester);

    expect(find.text("Report @alice's post"), findsOneWidget);
    expect(find.text("It's spam"), findsOneWidget);
    expect(find.text('Something else'), findsOneWidget);
    expect(tester.widget<FilledButton>(sendButton()).onPressed, isNull);

    await tester.tap(find.text("It's spam"));
    await tester.pump();

    expect(tester.widget<FilledButton>(sendButton()).onPressed, isNotNull);
    expect(
      find.byIcon(Icons.radio_button_checked),
      findsOneWidget,
      reason: 'the selection is a radio mark, not colour alone',
    );
  });

  testWidgets('the note counter counts down and goes negative past 500', (
    tester,
  ) async {
    await openSheet(tester);
    await tester.tap(find.text("It's spam"));
    await tester.pump();

    expect(find.text('500'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('report-note')), 'abc');
    await tester.pump();
    expect(find.text('497'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('report-note')),
      'a' * 501,
    );
    await tester.pump();
    expect(find.text('-1'), findsOneWidget);
    expect(tester.widget<FilledButton>(sendButton()).onPressed, isNull);
  });

  testWidgets('a failure shows friendly inline text and keeps the sheet', (
    tester,
  ) async {
    stubReport(() async => throw const NetworkException('raw socket text'));
    await openSheet(tester);
    await tester.tap(find.text("It's spam"));
    await tester.pump();

    await tester.tap(sendButton());
    await tester.pumpAndSettle();

    expect(find.textContaining('raw socket text'), findsNothing);
    expect(find.textContaining('Your report was not sent'), findsOneWidget);
    expect(sendButton(), findsOneWidget);
  });

  testWidgets('a note the server rejects says so in plain words', (
    tester,
  ) async {
    stubReport(
      () async => throw const ValidationException('bad', field: 'note'),
    );
    await openSheet(tester);
    await tester.tap(find.text("It's spam"));
    await tester.pump();

    await tester.tap(sendButton());
    await tester.pumpAndSettle();

    expect(find.textContaining("details can't be sent"), findsOneWidget);
  });

  testWidgets('success shows the confirmation; Done closes with sent', (
    tester,
  ) async {
    stubReport(
      () async => const ReportReceipt(reportId: 'r', alreadyReported: false),
    );
    await openSheet(tester);
    await tester.tap(find.text("It's spam"));
    await tester.pump();

    await tester.tap(sendButton());
    await tester.pumpAndSettle();

    expect(find.text('Thanks for reporting'), findsOneWidget);
    expect(find.textContaining('Block @'), findsNothing);

    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(outcome, ReportOutcome.sent);
  });

  testWidgets('already reported says so', (tester) async {
    stubReport(
      () async => const ReportReceipt(reportId: 'r', alreadyReported: true),
    );
    await openSheet(tester);
    await tester.tap(find.text("It's spam"));
    await tester.pump();

    await tester.tap(sendButton());
    await tester.pumpAndSettle();

    expect(find.text("You've already reported this"), findsOneWidget);
  });

  testWidgets('the block follow-up closes with blockRequested', (tester) async {
    stubReport(
      () async => const ReportReceipt(reportId: 'r', alreadyReported: false),
    );
    await openSheet(tester, blockLabel: 'Block @alice');
    await tester.tap(find.text("It's spam"));
    await tester.pump();
    await tester.tap(sendButton());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Block @alice'));
    await tester.pumpAndSettle();

    expect(outcome, ReportOutcome.blockRequested);
  });

  testWidgets('swiping the sheet away after it was sent still reports sent', (
    tester,
  ) async {
    stubReport(
      () async => const ReportReceipt(reportId: 'r', alreadyReported: false),
    );
    await openSheet(tester);
    await tester.tap(find.text("It's spam"));
    await tester.pump();
    await tester.tap(sendButton());
    await tester.pumpAndSettle();

    // Tap the scrim: a dismissal, not a button.
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    expect(outcome, ReportOutcome.sent);
  });

  testWidgets('dismissing before sending is cancelled', (tester) async {
    await openSheet(tester);

    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    expect(outcome, ReportOutcome.cancelled);
  });
}
