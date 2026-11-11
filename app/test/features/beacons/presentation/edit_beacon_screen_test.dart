import 'dart:async';

import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/beacons/domain/beacons_feature_flag.dart';
import 'package:dzeroth/features/beacons/domain/beacon_labels.dart';
import 'package:dzeroth/features/beacons/presentation/beacons_error_messages.dart';
import 'package:dzeroth/features/beacons/presentation/bloc/edit_beacon_cubit.dart';
import 'package:dzeroth/features/beacons/presentation/edit_beacon_screen.dart';
import 'package:dzeroth/features/beacons/presentation/widgets/plan_form_fields.dart';
import 'package:dzeroth/gen/dzeroth/beacons/v1/beacons.pb.dart' as pb;
import 'package:dzeroth/shared/format/scheduled_time.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:dzeroth/shared/widgets/primitives/app_pill_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../../../support/beacons_fixtures.dart';
import '../../../support/beacons_rig.dart';
import '../../../support/fake_beacons_server.dart';
import '../../../support/geometry.dart';
import '../../../support/theme_harness.dart' show MatrixEnv;

/// `/plans/:id/edit`: prefilled, the immutable lines read-only, Save only when
/// something changed and open spots cover the people going (Review Focus 4).
void main() {
  late FakeBeaconsServer server;
  final start = DateTime.now().add(const Duration(hours: 2));

  setUp(() {
    server = FakeBeaconsServer();
    server.public.add(
      beaconView(
        startAt: start,
        title: 'Coffee',
        details: 'Bring a book',
        venue: 'Hall',
        openSpots: 3,
        accepted: 2,
        canManage: true,
      ),
    );
  });

  Future<GoRouter> open(WidgetTester tester) => pumpPlansRouter(
    tester,
    beacons: server,
    initialLocation: '/plans/$kBeaconIdA/edit',
    routes: [
      GoRoute(
        path: '/plans/:id',
        builder: (_, state) => stubPage('plan ${state.pathParameters['id']}'),
      ),
      GoRoute(
        path: '/plans/:id/edit',
        builder: (_, state) =>
            EditBeaconScreen(beaconId: state.pathParameters['id']!),
      ),
    ],
  );

  Finder field(String label) => find.widgetWithText(TextField, label);

  bool chipSelected(WidgetTester tester, String label) => tester
      .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, label))
      .selected;

  bool saveEnabled(WidgetTester tester) =>
      tester
          .widget<AppPillButton>(find.widgetWithText(AppPillButton, 'Save'))
          .onPressed !=
      null;

  testWidgets('prefilled, read-only lines, Save waits for a change', (
    tester,
  ) async {
    await open(tester);

    expectNoOverflow(tester);
    expect(find.text('Edit plan'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Coffee'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Bring a book'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Hall'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    // F28: the date, time, duration and cost are fields now, with the
    // designs' helper; activity, chat and audience stay as they were set.
    expect(find.byTooltip('Pick a date'), findsOneWidget);
    expect(find.byTooltip('Pick a time'), findsOneWidget);
    expect(find.text(kPlanEditNotifyHelper), findsOneWidget);
    expect(chipSelected(tester, '60 min'), isTrue);
    expect(chipSelected(tester, 'Free'), isTrue);
    expect(find.text(kPlanSetAtCreation), findsOneWidget);
    expect(find.text('Coffee · Chat: Quiet'), findsOneWidget);
    expect(find.text('Who can see it: Public'), findsOneWidget);
    expect(find.textContaining("can't be changed"), findsNothing);
    expect(saveEnabled(tester), isFalse);

    await tester.enterText(field('Title'), 'Tea');
    await tester.pump();
    expect(saveEnabled(tester), isTrue);
  });

  testWidgets('open spots cannot go below the people going', (tester) async {
    await open(tester);
    // F28 put the date, time, duration and cost above it: scroll to it.
    await tester.ensureVisible(find.byTooltip('Fewer spots'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Fewer spots'));
    await tester.pump();
    expect(find.text('2'), findsOneWidget);
    expect(saveEnabled(tester), isTrue);
    expect(
      tester
          .widget<IconButton>(
            find.widgetWithIcon(IconButton, Icons.remove_circle_outline),
          )
          .onPressed,
      isNull,
    );
  });

  testWidgets('a server refusal keeps the form with its copy', (tester) async {
    await open(tester);
    // The refusal answers the Save, not the load.
    server.refusals.add(ValidationException('bad', field: 'open_spots'));
    await tester.enterText(field('Title'), 'Tea');
    await tester.pump();
    await tester.tap(find.widgetWithText(AppPillButton, 'Save'));
    await tester.pumpAndSettle();
    expect(
      find.text("Open spots can't go below the people already going."),
      findsOneWidget,
    );
    expect(find.text('Edit plan'), findsOneWidget);
  });

  testWidgets('a valid save sends only the changed fields and goes back to the '
      'plan', (tester) async {
    final router = await open(tester);
    await tester.enterText(field('Title'), ' Tea ');
    await tester.enterText(field('Meeting point'), 'Library');
    await tester.pump();
    await tester.tap(find.widgetWithText(AppPillButton, 'Save'));
    await tester.pumpAndSettle();

    final sent = server.lastUpdate!;
    expect(sent.hasTitle(), isTrue);
    expect(sent.title, 'Tea');
    expect(sent.hasVenue(), isTrue);
    expect(sent.venue, 'Library');
    expect(sent.hasDetails(), isFalse);
    expect(sent.hasOpenSpots(), isFalse);
    expect(server.receivedKeys, hasLength(1));
    expect(router.state.uri.path, '/plans/$kBeaconIdA');
    expect(server.public.single.beacon.title, 'Tea');
    expect(kBeaconTitleMaxLength, 60);
  });

  testWidgets('a line break in the details is refused before sending', (
    tester,
  ) async {
    await open(tester);
    await tester.enterText(field('Details'), 'line one\nline two');
    await tester.pump();
    expect(find.text('Use one line of plain text.'), findsOneWidget);
    expect(saveEnabled(tester), isFalse);
  });

  group('leaving with edits (C03)', () {
    Future<GoRouter> openPushed(WidgetTester tester) async {
      final router = await open(tester);
      router.go('/plans/$kBeaconIdA');
      await tester.pumpAndSettle();
      unawaited(router.push<void>('/plans/$kBeaconIdA/edit'));
      await tester.pumpAndSettle();
      return router;
    }

    testWidgets('an untouched form leaves without asking', (tester) async {
      final router = await openPushed(tester);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Discard your changes?'), findsNothing);
      expect(router.state.uri.path, '/plans/$kBeaconIdA');
    });

    testWidgets('platform back with edits asks; Keep editing stays, Discard '
        'leaves', (tester) async {
      final router = await openPushed(tester);
      await tester.enterText(field('Title'), 'Tea');
      await tester.pump();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Discard your changes?'), findsOneWidget);
      await tester.tap(find.text('Keep editing'));
      await tester.pumpAndSettle();
      expect(router.state.uri.path, '/plans/$kBeaconIdA/edit');

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Discard'));
      await tester.pumpAndSettle();
      expect(router.state.uri.path, '/plans/$kBeaconIdA');
      expect(server.lastUpdate, isNull);
    });

    testWidgets('a successful save leaves without a prompt', (tester) async {
      final router = await openPushed(tester);
      await tester.enterText(field('Title'), 'Tea');
      await tester.pump();
      await tester.tap(find.widgetWithText(AppPillButton, 'Save'));
      await tester.pumpAndSettle();
      expect(find.text('Discard your changes?'), findsNothing);
      expect(router.state.uri.path, '/plans/$kBeaconIdA');
      expect(server.lastUpdate, isNotNull);
    });
  });

  // F28: the organiser moves the date and time, the duration or the cost
  // until the plan starts. Seams: a fixed now (tomorrow 9:00) and pickers
  // that answer at once.
  group('date, time, duration and cost (F28)', () {
    final t = DateTime.now();
    var now = DateTime(t.year, t.month, t.day + 1, 9);
    late DateTime start;
    final clockAtOpen = DateTime(t.year, t.month, t.day + 1, 9);
    DateTime? pickedDate;
    TimeOfDay? pickedTime;

    void plan({required DateTime startAt, int accepted = 2}) {
      start = startAt;
      server.public
        ..clear()
        ..add(
          beaconView(
            startAt: startAt,
            title: 'Coffee',
            details: 'Bring a book',
            venue: 'Hall',
            openSpots: 3,
            accepted: accepted,
            canManage: true,
          ),
        );
    }

    Future<GoRouter> openSeamed(WidgetTester tester, {MatrixEnv? env}) =>
        pumpPlansRouter(
          tester,
          beacons: server,
          env: env,
          initialLocation: '/plans/$kBeaconIdA/edit',
          routes: [
            GoRoute(
              path: '/plans/:id',
              builder: (_, state) =>
                  stubPage('plan ${state.pathParameters['id']}'),
            ),
            GoRoute(
              path: '/plans/:id/edit',
              builder: (_, state) => EditBeaconScreen(
                beaconId: state.pathParameters['id']!,
                now: () => now,
                pickDate: (
                  context, {
                  required initial,
                  required first,
                  required last,
                }) async => pickedDate,
                pickTime: (context, {required initial}) async => pickedTime,
              ),
            ),
          ],
        );

    setUp(() {
      now = clockAtOpen;
      pickedDate = null;
      pickedTime = null;
      plan(startAt: now.add(const Duration(hours: 2)));
    });

    Future<void> tapField(WidgetTester tester, Finder f) async {
      await tester.ensureVisible(f);
      await tester.pumpAndSettle();
      await tester.tap(f);
      await tester.pumpAndSettle();
    }

    Future<void> save(WidgetTester tester) async {
      await tester.tap(find.widgetWithText(AppPillButton, 'Save'));
      await tester.pumpAndSettle();
    }

    testWidgets('a new date: Save sends the start alone and goes back', (
      tester,
    ) async {
      final router = await openSeamed(tester);
      final next = DateTime(start.year, start.month, start.day + 1);
      pickedDate = next;
      await tapField(tester, find.byTooltip('Pick a date'));
      expect(
        find.descendant(
          of: find.byTooltip('Pick a date'),
          matching: find.text(formatScheduledDate(next)),
        ),
        findsOneWidget,
      );
      expect(saveEnabled(tester), isTrue);
      await save(tester);

      final sent = server.lastUpdate!;
      expect(sent.hasStartAt(), isTrue);
      expect(
        sent.startAt.toDateTime(),
        DateTime(
          next.year,
          next.month,
          next.day,
          start.hour,
          start.minute,
        ).toUtc(),
      );
      expect(sent.hasTitle(), isFalse);
      expect(sent.hasDurationMinutes(), isFalse);
      expect(sent.hasCost(), isFalse);
      expect(router.state.uri.path, '/plans/$kBeaconIdA');
    });

    testWidgets('a new time, then the stored one again: nothing to save', (
      tester,
    ) async {
      await openSeamed(tester);
      pickedTime = TimeOfDay(hour: start.hour + 1, minute: start.minute);
      await tapField(tester, find.byTooltip('Pick a time'));
      expect(saveEnabled(tester), isTrue);
      pickedTime = TimeOfDay.fromDateTime(start);
      await tapField(tester, find.byTooltip('Pick a time'));
      expect(saveEnabled(tester), isFalse);
    });

    testWidgets('the start passing while the form is open keeps the fields '
        'and the unsaved time; the server says "started"', (tester) async {
      await openSeamed(tester);
      pickedTime = TimeOfDay(hour: start.hour + 1, minute: start.minute);
      await tapField(tester, find.byTooltip('Pick a time'));
      expect(saveEnabled(tester), isTrue);

      // The stored start passes; any rebuild used to drop the fields.
      now = start.add(const Duration(minutes: 1));
      await tester.enterText(field('Title'), 'Tea');
      await tester.pump();
      expect(find.byTooltip('Pick a time'), findsOneWidget);
      expect(find.byTooltip('Pick a date'), findsOneWidget);
      expect(find.text(kPlanFixedNow), findsNothing);
      expect(saveEnabled(tester), isTrue);

      server.refusals.add(StateConflictException('started'));
      await save(tester);
      expect(find.text('Edit plan'), findsOneWidget);
      expect(
        find.text(beaconsErrorMessage(StateConflictException('started'))),
        findsOneWidget,
      );
    });

    testWidgets('a stored length that is not a chip shows as the selected '
        'one', (tester) async {
      server.public.single.beacon.durationMinutes = 50;
      await openSeamed(tester);
      expect(chipSelected(tester, '50 min'), isTrue);
      expect(chipSelected(tester, '60 min'), isFalse);
      expect(saveEnabled(tester), isFalse);
    });

    testWidgets('duration and cost chips send those two only', (tester) async {
      await openSeamed(tester);
      await tapField(tester, find.widgetWithText(ChoiceChip, '90 min'));
      await tapField(tester, find.widgetWithText(ChoiceChip, 'Split evenly'));
      expect(chipSelected(tester, '90 min'), isTrue);
      await save(tester);

      final sent = server.lastUpdate!;
      expect(sent.durationMinutes, 90);
      expect(sent.cost, pb.BeaconCost.BEACON_COST_SPLIT_EVENLY);
      expect(sent.hasStartAt(), isFalse);
      expect(sent.hasTitle(), isFalse);
    });

    testWidgets('a new start under 5 minutes away is refused before sending', (
      tester,
    ) async {
      await openSeamed(tester);
      pickedTime = TimeOfDay(hour: now.hour, minute: now.minute + 1);
      await tapField(tester, find.byTooltip('Pick a time'));
      expect(
        find.text('Pick a time at least 5 minutes from now.'),
        findsOneWidget,
      );
      expect(saveEnabled(tester), isFalse);
      expect(server.lastUpdate, isNull);
    });

    testWidgets('a plan starting in 3 minutes still takes a title edit (its '
        'start is not re-checked)', (tester) async {
      plan(startAt: now.add(const Duration(minutes: 3)));
      await openSeamed(tester);
      expect(find.byTooltip('Pick a date'), findsOneWidget);
      await tester.enterText(field('Title'), 'Tea');
      await tester.pump();
      expect(
        find.text('Pick a time at least 5 minutes from now.'),
        findsNothing,
      );
      expect(saveEnabled(tester), isTrue);
      await save(tester);
      expect(server.lastUpdate!.hasStartAt(), isFalse);
      expect(server.lastUpdate!.title, 'Tea');
    });

    testWidgets('a plan that has started: no date, time, duration or cost; '
        'the read-only lines say why; the text still saves', (tester) async {
      plan(startAt: now.subtract(const Duration(minutes: 10)));
      await openSeamed(tester);
      expect(tester.takeException(), isNull);
      expect(find.byTooltip('Pick a date'), findsNothing);
      expect(find.byTooltip('Pick a time'), findsNothing);
      expect(find.widgetWithText(ChoiceChip, '90 min'), findsNothing);
      expect(find.widgetWithText(ChoiceChip, 'Split evenly'), findsNothing);
      expect(find.text(kPlanEditNotifyHelper), findsNothing);
      expect(find.text(kPlanStartedNote), findsOneWidget);
      expect(
        find.text('Starts ${beaconWhenText(server.public.single.beacon)}'),
        findsOneWidget,
      );
      expect(find.text('Cost: Free'), findsOneWidget);

      await tester.enterText(field('Title'), 'Tea');
      await tester.pump();
      await save(tester);
      expect(server.lastUpdate!.title, 'Tea');
      expect(server.lastUpdate!.hasStartAt(), isFalse);
    });

    testWidgets('a server that ignores the new cost: the copy, and the form '
        'stays', (tester) async {
      server.ignoresSchedule = true;
      final router = await openSeamed(tester);
      await tapField(tester, find.widgetWithText(ChoiceChip, 'Split evenly'));
      await save(tester);
      expect(find.text(kPlanScheduleNotSaved), findsOneWidget);
      expect(find.text('Edit plan'), findsOneWidget);
      expect(router.state.uri.path, '/plans/$kBeaconIdA/edit');
      expect(saveEnabled(tester), isTrue);
    });

    testWidgets('a schedule change alone asks before leaving', (tester) async {
      final router = await openSeamed(tester);
      router.go('/plans/$kBeaconIdA');
      await tester.pumpAndSettle();
      unawaited(router.push<void>('/plans/$kBeaconIdA/edit'));
      await tester.pumpAndSettle();
      await tapField(tester, find.widgetWithText(ChoiceChip, '30 min'));
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Discard your changes?'), findsOneWidget);
    });

    for (final (w, scale) in const <(double, double)>[
      (360, 1),
      (360, 2),
      (600, 2),
      (1024, 2),
    ]) {
      testWidgets('at ${w.toInt()} x$scale: no overflow; the date and time '
          'are whole', (tester) async {
        await openSeamed(
          tester,
          env: MatrixEnv(
            brightness: Brightness.light,
            size: Size(w, 900),
            textScale: scale,
          ),
        );
        expect(tester.takeException(), isNull);
        expectNoOverflow(tester);
        for (final tip in ['Pick a date', 'Pick a time']) {
          await tester.ensureVisible(find.byTooltip(tip));
          await tester.pumpAndSettle();
          expectMinTarget(tester, find.byTooltip(tip), reason: tip);
          final value = tester.renderObject<RenderParagraph>(
            find.descendant(
              of: find.descendant(
                of: find.byTooltip(tip),
                matching: find.byType(Text),
              ),
              matching: find.byType(RichText),
            ),
          );
          expect(value.didExceedMaxLines, isFalse, reason: tip);
        }
      });
    }

    testWidgets('semantics: Date and Time are buttons named with their '
        'value', (tester) async {
      final handle = tester.ensureSemantics();
      await openSeamed(tester);
      expect(
        find.bySemanticsLabel('Date, ${formatScheduledDate(start)}'),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel('Time, ${formatScheduledClock(start)}'),
        findsOneWidget,
      );
      handle.dispose();
    });
  });
}
