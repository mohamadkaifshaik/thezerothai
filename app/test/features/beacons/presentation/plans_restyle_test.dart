import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/features/beacons/domain/beacon_labels.dart';
import 'package:dzeroth/features/beacons/presentation/beacon_people_screen.dart';
import 'package:dzeroth/features/beacons/presentation/widgets/beacon_row.dart';
import 'package:dzeroth/features/beacons/presentation/widgets/plan_summary.dart';
import 'package:dzeroth/gen/dzeroth/beacons/v1/beacons.pb.dart' as pb;
import 'package:dzeroth/shared/widgets/primitives/app_pill_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/beacons_fixtures.dart';
import '../../../support/geometry.dart';
import '../../../support/plans_tablet_rig.dart';

const _widths = <double>[360, 599, 600, 839, 840, 1024, 1199, 1200, 1440];
final _hero = find.byKey(const ValueKey('plan-hero'));
final _peopleCard = find.byKey(const ValueKey('plan-people-card'));
final _headline = find.byKey(const ValueKey('plans-headline'));

/// The rig's first plan as the caller's own (Organising, Edit, Cancel).
void _organise(PlansTabletRig rig, {int accepted = 1}) {
  final view = rig.server.public.first;
  view.beacon.acceptedCount = accepted;
  view.viewer = pb.ViewerState(
    role: pb.ViewerRole.VIEWER_ROLE_ORGANISER,
    canManage: true,
  );
}

Finder _inCard(String title, Finder f) => find.descendant(
  of: find.ancestor(of: find.text(title), matching: find.byType(BeaconRow)),
  matching: f,
);

/// R12: the plan screens on the designs (Plans list, PlanDetail and its
/// visitor states, PlanPeople, My plans). The forms are covered in
/// `plans_form_tablet_test.dart` and `edit_beacon_screen_test.dart`.
void main() {
  group('Plans list: cards and the headline', () {
    for (final w in _widths) {
      testWidgets('at ${w.toInt()}: plan cards with the eyebrow and the '
          'viewer\'s part; the headline on the page only', (tester) async {
        final rig = PlansTabletRig();
        _organise(rig);
        await rig.pump(tester, width: w, height: 1000);
        expect(tester.takeException(), isNull);
        expectNoOverflow(tester);

        expect(
          _inCard('Coffee at noon', find.text('PLAN · COFFEE')),
          findsOneWidget,
        );
        expect(
          _inCard('Coffee at noon', find.text('Organising')),
          findsOneWidget,
        );
        expect(
          _inCard('Coffee at noon', find.text('1 of 3 seats taken')),
          findsOneWidget,
        );
        // Not the caller's: no part to say.
        expect(_inCard('Evening walk', find.text('Organising')), findsNothing);
        final pane = findPlansPane().evaluate().isNotEmpty;
        expect(_headline, pane ? findsNothing : findsOneWidget);
        expectMinTarget(tester, find.byType(BeaconRow).first);
      });
    }

    testWidgets('a requested and a going plan say so on their cards', (
      tester,
    ) async {
      final rig = PlansTabletRig();
      rig.server.public[1].viewer = pb.ViewerState(
        participantState: pb.ParticipantState.PARTICIPANT_STATE_REQUESTED,
        canWithdraw: true,
      );
      rig.server.public[2].viewer = pb.ViewerState(
        participantState: pb.ParticipantState.PARTICIPANT_STATE_ACCEPTED,
        canLeave: true,
      );
      await rig.pump(tester, width: 360, height: 2000);
      expect(_inCard('Evening walk', find.text('Requested')), findsOneWidget);
      expect(_inCard('Study group', find.text("You're going")), findsOneWidget);
    });

    testWidgets('semantics: one button per card with its part', (tester) async {
      final handle = tester.ensureSemantics();
      final rig = PlansTabletRig();
      _organise(rig);
      await rig.pump(tester, width: 360);
      expect(
        find.bySemanticsLabel(
          RegExp(r'^Coffee, Coffee at noon, .*Organising$'),
        ),
        findsOneWidget,
      );
      handle.dispose();
    });
  });

  group('PlanDetail: the hero, the People card and the actions', () {
    for (final w in _widths) {
      testWidgets('organiser at ${w.toInt()}: hero, Edit on the organiser '
          'row, People card, Cancel plan with its note', (tester) async {
        final rig = PlansTabletRig();
        _organise(rig);
        await rig.pump(
          tester,
          location: AppRouter.planPath(kBeaconIdA),
          width: w,
          height: 1400,
        );
        expect(tester.takeException(), isNull);
        expectNoOverflow(tester);
        expect(_hero, findsOneWidget);
        expect(
          find.descendant(of: _hero, matching: find.text('PLAN · COFFEE')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: _hero, matching: find.text('Coffee at noon')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: _hero, matching: find.text(kMeetingPointNote)),
          findsOneWidget,
        );
        expect(find.text('People · 1 going'), findsOneWidget);
        expect(find.text('2 open spots left'), findsOneWidget);
        expect(find.widgetWithText(AppPillButton, 'Edit'), findsOneWidget);
        expect(
          find.widgetWithText(AppPillButton, 'Cancel plan'),
          findsOneWidget,
        );
        expect(
          find.text(
            'You approve each request. Cancel plan asks first; people who '
            'joined get a notification.',
          ),
          findsOneWidget,
        );
        expectMinTarget(tester, _peopleCard);
      });
    }

    testWidgets('a visitor: Ask to join with the organiser\'s note; the '
        'People card only counts, with who may see the list', (tester) async {
      final rig = PlansTabletRig();
      rig.server.public.first.viewer = pb.ViewerState(canRequest: true);
      await rig.pump(
        tester,
        location: AppRouter.planPath(kBeaconIdA),
        width: 360,
        height: 1400,
      );
      expect(find.widgetWithText(AppPillButton, 'Ask to join'), findsOne);
      expect(find.text('Orla approves each request.'), findsOneWidget);
      expect(find.text(kPeopleListNote), findsOneWidget);
      // Not a way into the list: no chevron, no button.
      expect(
        find.descendant(
          of: _peopleCard,
          matching: find.byIcon(Icons.chevron_right),
        ),
        findsNothing,
      );
      expect(find.widgetWithText(AppPillButton, 'Edit'), findsNothing);
    });

    testWidgets('going, at 2.0 on a phone: the pill goes under the name, '
        'nothing overflows, Leave plan is whole', (tester) async {
      final rig = PlansTabletRig();
      rig.server.public.first.viewer = pb.ViewerState(
        participantState: pb.ParticipantState.PARTICIPANT_STATE_ACCEPTED,
        canLeave: true,
      );
      await rig.pump(
        tester,
        location: AppRouter.planPath(kBeaconIdA),
        width: 360,
        height: 2400,
        textScale: 2,
      );
      expect(tester.takeException(), isNull);
      expectNoOverflow(tester);
      final pill = tester.getRect(find.text("You're going"));
      final name = tester.getRect(find.text('Orla'));
      expect(pill.top, greaterThanOrEqualTo(name.bottom));
      expect(
        find.text('Everyone going can see who else is going.'),
        findsOneWidget,
      );
    });

    testWidgets('RTL at 360: the eyebrow starts at the right of the hero', (
      tester,
    ) async {
      final rig = PlansTabletRig();
      await rig.pump(
        tester,
        location: AppRouter.planPath(kBeaconIdA),
        width: 360,
        height: 1400,
        textDirection: TextDirection.rtl,
      );
      expect(tester.takeException(), isNull);
      final hero = tester.getRect(_hero);
      final eyebrow = tester.getRect(
        find.descendant(of: _hero, matching: find.text('PLAN · COFFEE')),
      );
      expect(hero.right - eyebrow.right, lessThan(hero.width / 3));
    });

    testWidgets('the preview draws the same hero', (tester) async {
      final rig = PlansTabletRig();
      await rig.pump(
        tester,
        location: AppRouter.planNewPath,
        width: 1024,
        height: 1100,
        realForms: true,
      );
      expect(
        find.descendant(of: find.byType(PlanSummary), matching: _hero),
        findsOneWidget,
      );
    });
  });

  group('PlanPeople: request cards', () {
    testWidgets('a request: Decline and Accept pills under it, 48 dp; the '
        'menu has no second Decline', (tester) async {
      final rig = PlansTabletRig();
      _organise(rig);
      rig.server.requests[kBeaconIdA] = [
        participant(
          userId: 'u3',
          name: 'Cy',
          state: pb.ParticipantState.PARTICIPANT_STATE_REQUESTED,
          note: 'Can I bring a friend?',
        ),
      ];
      await rig.pump(
        tester,
        location: AppRouter.planPeoplePath(kBeaconIdA),
        width: 360,
      );
      await tester.tap(find.text('Requests'));
      await tester.pumpAndSettle();
      final decline = find.widgetWithText(AppPillButton, 'Decline');
      final accept = find.widgetWithText(AppPillButton, 'Accept');
      expect(decline, findsOneWidget);
      expect(accept, findsOneWidget);
      expectMinTarget(tester, decline);
      expectMinTarget(tester, accept);
      expect(
        tester.getRect(decline).top,
        greaterThan(tester.getRect(find.text('Can I bring a friend?')).bottom),
      );
      // The menu keeps only Decline and block.
      await tester.tap(find.byTooltip('Request options'));
      await tester.pumpAndSettle();
      expect(find.text('Decline and block'), findsOneWidget);
      expect(find.text('Decline'), findsOneWidget); // the pill only
      await tester.tapAt(Offset.zero);
      await tester.pumpAndSettle();
      expectNoOverflow(tester);
    });
  });

  group('My plans: the part in the eyebrow', () {
    testWidgets('an organised plan reads ORGANISING · COFFEE, with no second '
        'badge', (tester) async {
      final rig = PlansTabletRig();
      rig.server.mine.first.viewer = pb.ViewerState(
        role: pb.ViewerRole.VIEWER_ROLE_ORGANISER,
        canManage: true,
      );
      await rig.pump(tester, location: AppRouter.plansMinePath, width: 360);
      expect(
        _inCard('My run', find.text('ORGANISING · COFFEE')),
        findsOneWidget,
      );
      expect(_inCard('My run', find.text('Organising')), findsNothing);
      expect(_inCard('My lunch', find.text('PLAN · COFFEE')), findsOneWidget);
    });
  });
}
