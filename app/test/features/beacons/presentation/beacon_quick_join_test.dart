import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/beacons/domain/beacons_feature_flag.dart';
import 'package:dzeroth/features/beacons/presentation/beacon_screen.dart';
import 'package:dzeroth/features/beacons/presentation/beacons_screen.dart';
import 'package:dzeroth/features/beacons/presentation/widgets/join_note_sheet.dart';
import 'package:dzeroth/features/beacons/presentation/widgets/quick_join.dart';
import 'package:dzeroth/shared/widgets/primitives/app_pill_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../../../support/beacons_fixtures.dart';
import '../../../support/beacons_rig.dart';
import '../../../support/fake_beacons_server.dart';
import '../../../support/geometry.dart';
import '../../../support/theme_harness.dart';

/// One-tap "I'm in" (`beacon_quick_join`): the card pill, the plan page's
/// primary action, the required note in the sheet and the `note_required`
/// fallback, for every flag mode and `quick_join_allowed`.
void main() {
  late FakeBeaconsServer server;
  final today = DateTime.now();
  final start = DateTime(today.year, today.month, today.day + 1, 12);

  const flagOn = {kFeatureBeacons, kFeatureBeaconQuickJoin};
  const flagOff = {kFeatureBeacons};
  const sizes = {
    'phone': Size(390, 844),
    'tablet': Size(1024, 768),
    'desktop': Size(1440, 900),
  };

  setUp(() => server = FakeBeaconsServer());

  MatrixEnv env(Size size) =>
      MatrixEnv(brightness: Brightness.light, size: size, textScale: 1);

  Future<void> openList(
    WidgetTester tester,
    Set<String> features, {
    Size size = const Size(390, 844),
  }) async {
    await pumpPlansRouter(
      tester,
      beacons: server,
      features: features,
      env: env(size),
      routes: [
        GoRoute(path: '/plans', builder: (_, _) => const BeaconsScreen()),
        GoRoute(
          path: '/plans/:id',
          builder: (_, state) => stubPage('plan ${state.pathParameters['id']}'),
        ),
      ],
    );
  }

  Future<void> openDetail(
    WidgetTester tester,
    Set<String> features, {
    Size size = const Size(390, 844),
  }) async {
    await pumpPlansRouter(
      tester,
      beacons: server,
      features: features,
      env: env(size),
      initialLocation: '/plans/$kBeaconIdA',
      routes: [
        GoRoute(path: '/plans', builder: (_, _) => stubPage('plans')),
        GoRoute(
          path: '/plans/:id',
          builder: (_, state) =>
              BeaconScreen(beaconId: state.pathParameters['id']!),
        ),
      ],
    );
  }

  final pill = find.widgetWithText(AppPillButton, kPlanImIn);
  final sendButton = find.widgetWithText(FilledButton, 'Send request');

  group('plan card pill', () {
    for (final MapEntry(key: name, value: size) in sizes.entries) {
      testWidgets('flag on and allowed: I\'m in is shown at $name', (
        tester,
      ) async {
        server.public.add(beaconView(startAt: start, quickJoin: true));
        await openList(tester, flagOn, size: size);
        expectNoOverflow(tester);
        expect(pill, findsOneWidget);
        expect(tester.getSize(pill).height, greaterThanOrEqualTo(48));
      });
    }

    testWidgets('flag on, not allowed: no pill', (tester) async {
      server.public.add(beaconView(startAt: start));
      await openList(tester, flagOn);
      expect(pill, findsNothing);
    });

    testWidgets('flag off, allowed: no pill (today\'s card)', (tester) async {
      server.public.add(beaconView(startAt: start, quickJoin: true));
      await openList(tester, flagOff);
      expect(pill, findsNothing);
    });

    testWidgets('beacons off: no pill', (tester) async {
      server.public.add(beaconView(startAt: start, quickJoin: true));
      await openList(tester, const {kFeatureBeaconQuickJoin});
      expect(pill, findsNothing);
    });

    testWidgets('one tap sends an empty note and the card says Requested', (
      tester,
    ) async {
      server.public.add(beaconView(startAt: start, quickJoin: true));
      await openList(tester, flagOn);
      await tester.tap(pill);
      await tester.pumpAndSettle();
      expect(server.notes, ['']);
      expect(server.calls.where((c) => c == 'request'), hasLength(1));
      expect(pill, findsNothing);
      expect(find.text('Requested'), findsWidgets);
      expect(find.byType(JoinNoteSheet), findsNothing);
    });

    testWidgets('a refusal shows the plans copy and keeps the pill', (
      tester,
    ) async {
      server.public.add(beaconView(startAt: start, quickJoin: true));
      await openList(tester, flagOn);
      server.refusals.add(StateConflictException('full'));
      await tester.tap(pill);
      await tester.pumpAndSettle();
      expect(find.text('This plan is full.'), findsOneWidget);
      expect(pill, findsOneWidget);
    });

    testWidgets('tapping the card (not the pill) still opens the plan', (
      tester,
    ) async {
      server.public.add(
        beaconView(startAt: start, quickJoin: true, title: 'Flat white'),
      );
      await openList(tester, flagOn);
      await tester.tap(find.text('Flat white'));
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey('stub:plan $kBeaconIdA')), findsOneWidget);
      expect(server.notes, isEmpty);
    });

    testWidgets('note_required opens the sheet, then sends the note', (
      tester,
    ) async {
      server.public.add(beaconView(startAt: start, quickJoin: true));
      server.noteRequiredOnEmpty = true;
      await openList(tester, flagOn);
      await tester.tap(pill);
      await tester.pumpAndSettle();
      expect(find.byType(JoinNoteSheet), findsOneWidget);
      expect(find.text(kJoinNoteRequiredLine), findsOneWidget);
      expect(tester.widget<FilledButton>(sendButton).onPressed, isNull);
      await tester.enterText(find.byType(TextField), 'friend of Sana');
      await tester.pump();
      await tester.tap(sendButton);
      await tester.pumpAndSettle();
      expect(server.notes, ['', 'friend of Sana']);
      expect(find.text('Requested'), findsWidgets);
    });
  });

  group('plan detail', () {
    for (final MapEntry(key: name, value: size) in sizes.entries) {
      testWidgets('flag on and allowed: the primary action is I\'m in at '
          '$name, one tap sends an empty note', (tester) async {
        server.public.add(beaconView(startAt: start, quickJoin: true));
        await openDetail(tester, flagOn, size: size);
        expectNoOverflow(tester);
        expect(find.text('Ask to join'), findsNothing);
        await tester.tap(find.text(kPlanImIn));
        await tester.pumpAndSettle();
        expect(server.notes, ['']);
        expect(find.byType(JoinNoteSheet), findsNothing);
        expect(find.text('Withdraw request'), findsOneWidget);
      });
    }

    testWidgets('flag on, not allowed: Ask to join, the note is required', (
      tester,
    ) async {
      server.public.add(beaconView(startAt: start));
      await openDetail(tester, flagOn);
      expect(find.text(kPlanImIn), findsNothing);
      await tester.tap(find.text('Ask to join'));
      await tester.pumpAndSettle();
      expect(find.text(kJoinNoteRequiredLine), findsOneWidget);
      expect(tester.widget<FilledButton>(sendButton).onPressed, isNull);
      await tester.enterText(find.byType(TextField), '   ');
      await tester.pump();
      expect(
        tester.widget<FilledButton>(sendButton).onPressed,
        isNull,
        reason: 'whitespace is not a note',
      );
      await tester.enterText(find.byType(TextField), ' hi ');
      await tester.pump();
      await tester.tap(sendButton);
      await tester.pumpAndSettle();
      expect(server.notes, ['hi']);
    });

    for (final allowed in [false, true]) {
      testWidgets('flag off, allowed=$allowed: today\'s optional note', (
        tester,
      ) async {
        server.public.add(beaconView(startAt: start, quickJoin: allowed));
        await openDetail(tester, flagOff);
        expect(find.text(kPlanImIn), findsNothing);
        await tester.tap(find.text('Ask to join'));
        await tester.pumpAndSettle();
        expect(
          find.widgetWithText(TextField, 'Note (optional)'),
          findsOneWidget,
        );
        expect(find.text(kJoinNoteRequiredLine), findsNothing);
        expect(tester.widget<FilledButton>(sendButton).onPressed, isNotNull);
        await tester.tap(sendButton);
        await tester.pumpAndSettle();
        expect(server.notes, ['']);
      });
    }

    testWidgets('note_required on the tap opens the sheet prefilled empty', (
      tester,
    ) async {
      server.public.add(beaconView(startAt: start, quickJoin: true));
      server.noteRequiredOnEmpty = true;
      await openDetail(tester, flagOn);
      await tester.tap(find.text(kPlanImIn));
      await tester.pumpAndSettle();
      expect(find.byType(JoinNoteSheet), findsOneWidget);
      expect(find.text(kJoinNoteRequiredLine), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
      );
      expect(tester.widget<FilledButton>(sendButton).onPressed, isNull);
      await tester.enterText(find.byType(TextField), 'from the run club');
      await tester.pump();
      await tester.tap(sendButton);
      await tester.pumpAndSettle();
      expect(server.notes, ['', 'from the run club']);
      expect(find.text('Withdraw request'), findsOneWidget);
    });
  });
}
