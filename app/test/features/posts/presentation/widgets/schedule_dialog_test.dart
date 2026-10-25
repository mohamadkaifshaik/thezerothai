import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/posts/domain/schedule_rules.dart';
import 'package:dzeroth/features/posts/presentation/widgets/schedule_dialog.dart';
import 'package:dzeroth/shared/format/scheduled_time.dart';
import 'package:dzeroth/shared/widgets/app_pill_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The Schedule dialog (CMP-D6, ADR-0021 D4): layout, validation, the images
/// note, and how it is left. The clock and the pickers are injected.
void main() {
  final year = DateTime.now().year;
  // 10:07:30 on a mid-year day: the default time is 10:10.
  final now = DateTime(year, 6, 15, 10, 7, 30);
  final defaultTime = DateTime(year, 6, 15, 10, 10);

  ScheduleDialogResult? result;
  var closed = false;

  setUp(() {
    result = null;
    closed = false;
  });

  Future<void> open(
    WidgetTester tester, {
    Size size = const Size(1000, 800),
    Brightness brightness = Brightness.light,
    double textScale = 1,
    DateTime? initial,
    bool hasMedia = false,
    String? notice,
    SchedulePickDate? pickDate,
    SchedulePickTime? pickTime,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(brightness: brightness),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () async {
                  result = await showScheduleDialog(
                    context,
                    initial: initial,
                    hasMedia: hasMedia,
                    notice: notice,
                    clock: () => now,
                    pickDate: pickDate ?? _noDate,
                    pickTime: pickTime ?? _noTime,
                  );
                  closed = true;
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  AppPillButton confirmPill(WidgetTester tester) =>
      tester.widget<AppPillButton>(find.byType(AppPillButton));

  testWidgets('wide: a centred dialog with the specified parts', (
    tester,
  ) async {
    await open(tester);

    expect(find.byType(Dialog), findsOneWidget);
    expect(find.text('Schedule'), findsOneWidget);
    expect(find.text('Close'), findsOneWidget);
    expect(find.text('Confirm'), findsOneWidget);
    expect(find.text(willSendOnText(defaultTime)), findsOneWidget);
    expect(find.textContaining('Time zone: '), findsOneWidget);
    expect(find.text('Scheduled posts'), findsOneWidget);
    // No images note without photos, no Remove without a schedule.
    expect(find.text(kScheduleImagesNote), findsNothing);
    expect(find.text('Remove schedule'), findsNothing);
  });

  testWidgets('narrow: a full-screen route, not a dialog', (tester) async {
    await open(tester, size: const Size(360, 740));

    expect(find.byType(Dialog), findsNothing);
    expect(find.text('Schedule'), findsOneWidget);
    expect(find.text('Confirm'), findsOneWidget);
  });

  testWidgets('the default is enabled and Confirm answers it as UTC', (
    tester,
  ) async {
    await open(tester);
    expect(confirmPill(tester).onPressed, isNotNull);
    expect(find.text(kScheduleTooSoonMessage), findsNothing);

    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();

    final chosen = result as ScheduleChosen;
    expect(chosen.publishAt.isUtc, isTrue);
    expect(chosen.publishAt, defaultTime.toUtc());
    expect(find.byType(Dialog), findsNothing);
  });

  testWidgets('too soon: the helper text shows and Confirm is disabled', (
    tester,
  ) async {
    await open(tester, initial: DateTime(year, 6, 15, 10, 8));

    expect(
      find.text('Pick a time at least 2 minutes from now'),
      findsOneWidget,
    );
    expect(confirmPill(tester).onPressed, isNull);
    await tester.tap(find.text('Confirm'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(closed, isFalse, reason: 'a disabled Confirm does nothing');
  });

  testWidgets('too far: the helper text shows and Confirm is disabled', (
    tester,
  ) async {
    await open(tester, initial: now.add(const Duration(days: 61)));

    expect(find.text('Pick a time within 60 days'), findsOneWidget);
    expect(confirmPill(tester).onPressed, isNull);
  });

  testWidgets('a server notice shows under the pickers', (tester) async {
    await open(tester, notice: 'That time is not available.');
    expect(find.text('That time is not available.'), findsOneWidget);
    expect(confirmPill(tester).onPressed, isNotNull);
  });

  testWidgets('the images note shows with photos attached, word for word', (
    tester,
  ) async {
    await open(tester, hasMedia: true);
    expect(
      find.text(
        'Images are uploaded now and can be reached by anyone with the link '
        'before the post goes out.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('Close leaves with no answer', (tester) async {
    await open(tester);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(closed, isTrue);
    expect(result, isNull);
  });

  testWidgets('with a schedule set: Remove schedule answers ScheduleRemoved', (
    tester,
  ) async {
    final set = DateTime(year, 6, 20, 9, 30);
    await open(tester, initial: set);
    expect(find.text(willSendOnText(set)), findsOneWidget);

    await tester.tap(find.text('Remove schedule'));
    await tester.pumpAndSettle();
    expect(result, isA<ScheduleRemoved>());
  });

  testWidgets('the footer link answers ScheduleOpenList', (tester) async {
    await open(tester);
    await tester.tap(find.text('Scheduled posts'));
    await tester.pumpAndSettle();
    expect(result, isA<ScheduleOpenList>());
  });

  testWidgets('the date row opens the picker limited to the 60 day window', (
    tester,
  ) async {
    DateTime? gotFirst;
    DateTime? gotLast;
    DateTime? gotInitial;
    await open(
      tester,
      pickDate:
          (context, {required initial, required first, required last}) async {
            gotInitial = initial;
            gotFirst = first;
            gotLast = last;
            return DateTime(year, 6, 20);
          },
    );
    await tester.tap(find.bySemanticsLabel(RegExp('^Date, ')));
    await tester.pumpAndSettle();

    expect(gotInitial, DateTime(year, 6, 15));
    expect(gotFirst, DateTime(year, 6, 15));
    expect(gotLast, DateUtils.dateOnly(now.add(kScheduledHorizon)));
    // The picked date keeps the time of day.
    expect(
      find.text(willSendOnText(DateTime(year, 6, 20, 10, 10))),
      findsOneWidget,
    );
  });

  testWidgets('the time row applies the picked time', (tester) async {
    await open(
      tester,
      pickTime: (context, {required initial}) async {
        expect(initial, const TimeOfDay(hour: 10, minute: 10));
        return const TimeOfDay(hour: 21, minute: 37);
      },
    );
    await tester.tap(find.bySemanticsLabel(RegExp('^Time, ')));
    await tester.pumpAndSettle();

    expect(
      find.text(willSendOnText(DateTime(year, 6, 15, 21, 37))),
      findsOneWidget,
    );
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();
    expect(
      (result as ScheduleChosen).publishAt,
      DateTime(year, 6, 15, 21, 37).toUtc(),
    );
  });

  testWidgets('picking a time that is too soon disables Confirm at once', (
    tester,
  ) async {
    await open(
      tester,
      pickTime: (context, {required initial}) async =>
          const TimeOfDay(hour: 10, minute: 8),
    );
    await tester.tap(find.bySemanticsLabel(RegExp('^Time, ')));
    await tester.pumpAndSettle();

    expect(find.text(kScheduleTooSoonMessage), findsOneWidget);
    expect(confirmPill(tester).onPressed, isNull);
  });

  Future<void> openWithPlatformPickers(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(brightness: Brightness.light),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showScheduleDialog(context, clock: () => now),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('the platform date picker opens from the date row', (
    tester,
  ) async {
    await openWithPlatformPickers(tester);
    await tester.tap(find.bySemanticsLabel(RegExp('^Date, ')));
    await tester.pumpAndSettle();
    expect(find.byType(DatePickerDialog), findsOneWidget);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.byType(DatePickerDialog), findsNothing);
    expect(find.text(willSendOnText(defaultTime)), findsOneWidget);
  });

  testWidgets('the platform time picker opens from the time row', (
    tester,
  ) async {
    await openWithPlatformPickers(tester);
    await tester.tap(find.bySemanticsLabel(RegExp('^Time, ')));
    await tester.pumpAndSettle();
    expect(find.byType(TimePickerDialog), findsOneWidget);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.byType(TimePickerDialog), findsNothing);
  });

  testWidgets('date and time rows are labelled buttons of at least 48dp', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await open(tester);

    for (final label in ['Date, ', 'Time, ']) {
      final finder = find.bySemanticsLabel(RegExp('^$label'));
      final node = tester.getSemantics(finder);
      expect(node.rect.height, greaterThanOrEqualTo(48), reason: label);
      expect(
        node.getSemanticsData().flagsCollection.isButton,
        isTrue,
        reason: label,
      );
    }
    expect(find.bySemanticsLabel(RegExp('^Time zone: ')), findsOneWidget);
    handle.dispose();
  });

  for (final brightness in Brightness.values) {
    testWidgets('text x2 on a 320dp phone, ${brightness.name}: no overflow', (
      tester,
    ) async {
      await open(
        tester,
        size: const Size(320, 640),
        brightness: brightness,
        textScale: 2,
        initial: now.add(const Duration(days: 61)),
        hasMedia: true,
      );
      expect(tester.takeException(), isNull);
      expect(find.text(kScheduleImagesNote), findsOneWidget);
      expect(find.text('Remove schedule'), findsOneWidget);
    });
  }
}

Future<DateTime?> _noDate(
  BuildContext context, {
  required DateTime initial,
  required DateTime first,
  required DateTime last,
}) async => null;

Future<TimeOfDay?> _noTime(
  BuildContext context, {
  required TimeOfDay initial,
}) async => null;
