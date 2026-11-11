import 'dart:async';

import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/core/widgets/app_nav_rail.dart';
import 'package:dzeroth/core/widgets/context_pane.dart';
import 'package:dzeroth/core/widgets/shell_geometry.dart';
import 'package:dzeroth/features/beacons/domain/beacon_labels.dart';
import 'package:dzeroth/features/beacons/domain/beacons_feature_flag.dart';
import 'package:dzeroth/features/beacons/presentation/beacon_people_screen.dart';
import 'package:dzeroth/features/beacons/presentation/beacon_screen.dart';
import 'package:dzeroth/features/beacons/presentation/beacons_screen.dart';
import 'package:dzeroth/features/beacons/presentation/plans_list_detail.dart';
import 'package:dzeroth/features/beacons/presentation/widgets/beacon_row.dart';
import 'package:dzeroth/features/beacons/presentation/widgets/your_plans_section.dart';
import 'package:dzeroth/gen/dzeroth/beacons/v1/beacons.pb.dart' as pb;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/beacons_fixtures.dart';
import '../../../support/geometry.dart';
import '../../../support/plans_tablet_rig.dart';
import '../../../support/theme_harness.dart';

const _kIdC = '1234567890123456791';
final _mine1 = kRigMine[0].$1;

/// The title text of a plan row.
Finder _row(String title) =>
    find.ancestor(of: find.text(title), matching: find.byType(BeaconRow));

/// Whether the row of [title] in [scope] is marked selected (semantics).
bool _selected(WidgetTester tester, Finder scope, String title) {
  final row = find.descendant(of: scope, matching: _row(title)).first;
  return isSemantics(isSelected: true).matches(tester.getSemantics(row), {});
}

Rect _primary(WidgetTester tester) =>
    tester.getRect(find.byKey(const ValueKey('tablet-primary')));

/// The list's own Plans header back button, in [scope].
Finder _back(Finder scope) =>
    find.descendant(of: scope, matching: find.byTooltip('Back'));

/// Plans list–detail on the tablet layout (tablet plan T5: section 3 code LD,
/// section 4.1 Home/PlanDetail/PlanPeople/MyPlans rows, section 5.2).
void main() {
  // Off the tablet layout (`ui_shell` + `ui_tablet`, 600-1199) nothing new
  // appears and nothing new is sent: no list pane, no "Your plans", no
  // ListMyBeacons. Band B shows the list pane with "Your plans" on top and
  // the placeholder; band A the list with "Your plans" inline.
  group('flag modes x widths (/plans)', () {
    const widths = <double>[360, 599, 600, 839, 840, 1024, 1199, 1200];
    for (final MapEntry(key: mode, value: flags) in kPlansFlagModes.entries) {
      for (final width in widths) {
        testWidgets('$mode at ${width.toInt()}', (tester) async {
          final rig = PlansTabletRig();
          await rig.pump(tester, width: width, flags: flags);

          final tablet =
              mode == 'ui_shell + ui_tablet' &&
              width >= AppBreakpoints.mobile &&
              width < AppBreakpoints.tablet;
          final bandB = tablet && width >= AppBreakpoints.expanded;

          expect(findPlansPane(), bandB ? findsOneWidget : findsNothing);
          expect(
            find.byType(YourPlansSection),
            tablet ? findsOneWidget : findsNothing,
          );
          expect(find.text(kPickAPlan), bandB ? findsOneWidget : findsNothing);
          // The plans are listed once, in the pane (B) or the page.
          expect(find.text(kRigPlans.first.$2), findsOneWidget);
          expect(
            (bandB ? inPlansPane : inShellPage)(find.text(kRigPlans.first.$2)),
            findsOneWidget,
          );
          // One ListBeacons whatever the layout; ListMyBeacons (limit 2)
          // only on the tablet layout.
          expect(rig.count('list:'), 1);
          expect(rig.server.mineLimits, tablet ? [2] : isEmpty);
          // No context pane beside a list-detail page.
          expect(find.byType(ContextPane), findsNothing);
          expectNoOverflow(tester);
        });
      }
    }
  });

  group('band B: list pane | detail (840-1199)', () {
    for (final (width, list) in const [
      (840.0, 320.0),
      (1024.0, 377.0),
      (1199.0, 400.0),
    ]) {
      testWidgets('${width.toInt()}: rail | list $list | hairline | detail', (
        tester,
      ) async {
        final rig = PlansTabletRig();
        await rig.pump(tester, width: width);

        final content = width - AppSize.railCompact;
        expect(ShellGeometry.listPaneWidthFor(content), list);
        expect(tester.getRect(findPlansPane()).left, AppSize.railCompact);
        expect(tester.getRect(findPlansPane()).width, list);
        expect(_primary(tester).width, content - list - 1);
        expect(AppSize.railCompact + list + 1 + _primary(tester).width, width);
        expectNoOverflow(tester);
      });
    }

    testWidgets('RTL: rail on the right, then the list, then the detail', (
      tester,
    ) async {
      final rig = PlansTabletRig();
      await rig.pump(tester, textDirection: TextDirection.rtl);

      final rail = tester.getRect(find.byType(AppNavRail));
      final pane = tester.getRect(findPlansPane());
      expect(rail.right, 1024);
      expect(pane.right, rail.left);
      expect(_primary(tester).right, lessThan(pane.left));
    });

    testWidgets('/plans: "Your plans" (2 rows + See all) on top of the list, '
        'the placeholder beside it, no back arrow in the pane', (tester) async {
      final rig = PlansTabletRig();
      await rig.pump(tester);

      final section = inPlansPane(find.byType(YourPlansSection));
      expect(section, findsOneWidget);
      expect(inPlansPane(find.text(kYourPlansTitle)), findsOneWidget);
      expect(inPlansPane(find.text(kRigMine[0].$2)), findsOneWidget);
      expect(inPlansPane(find.text(kRigMine[1].$2)), findsOneWidget);
      expect(find.text(kRigMine[2].$2), findsNothing);
      expect(inPlansPane(find.text('See all')), findsOneWidget);
      // Above the plans list.
      expect(
        tester.getRect(section).bottom,
        lessThanOrEqualTo(
          tester.getRect(inPlansPane(find.text(kRigPlans[0].$2))).top,
        ),
      );
      expect(_back(findPlansPane()), findsNothing);
      expect(inPlansPane(find.byTooltip('My plans')), findsOneWidget);
      expect(inPlansPane(find.byTooltip('New plan')), findsOneWidget);
      // The placeholder: icon, one line, New plan.
      expect(inShellPage(find.text(kPickAPlan)), findsOneWidget);
      expect(
        inShellPage(find.widgetWithText(FilledButton, 'New plan')),
        findsOneWidget,
      );
    });

    testWidgets('a row replaces the detail (go): selected, no back arrow, '
        'no list reload', (tester) async {
      final rig = PlansTabletRig();
      await rig.pump(tester);

      await tester.tap(inPlansPane(find.text(kRigPlans[0].$2)));
      await tester.pumpAndSettle();

      expect(rig.uri.path, AppRouter.planPath(kBeaconIdA));
      expect(rig.router.canPop(), isFalse, reason: 'go, not push');
      expect(find.byType(BeaconScreen), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(BeaconScreen),
          matching: find.text(kRigPlans[0].$2),
        ),
        findsOneWidget,
      );
      expect(_selected(tester, findPlansPane(), kRigPlans[0].$2), isTrue);
      expect(_selected(tester, findPlansPane(), kRigPlans[1].$2), isFalse);
      expect(_back(find.byType(BeaconScreen)), findsNothing);
      expect(rig.count('list:'), 1);
      expect(rig.count('mine'), 1);

      // Another row: the detail follows, the selection moves.
      await tester.tap(inPlansPane(find.text(kRigPlans[1].$2)));
      await tester.pumpAndSettle();
      expect(rig.uri.path, AppRouter.planPath(kBeaconIdB));
      expect(
        find.descendant(
          of: find.byType(BeaconScreen),
          matching: find.text(kRigPlans[1].$2),
        ),
        findsOneWidget,
      );
      expect(_selected(tester, findPlansPane(), kRigPlans[1].$2), isTrue);
      expect(_selected(tester, findPlansPane(), kRigPlans[0].$2), isFalse);
      expect(rig.count('list:'), 1);
    });

    testWidgets('a "Your plans" row opens it beside the list (go)', (
      tester,
    ) async {
      final rig = PlansTabletRig();
      await rig.pump(tester);

      await tester.tap(inPlansPane(find.text(kRigMine[0].$2)));
      await tester.pumpAndSettle();

      expect(rig.uri.path, AppRouter.planPath(_mine1));
      expect(findPlansPane(), findsOneWidget);
      expect(_selected(tester, findPlansPane(), kRigMine[0].$2), isTrue);
    });

    testWidgets('typed /plans/:id: the pane loads the list and "Your plans" '
        'once; the plan is selected', (tester) async {
      final rig = PlansTabletRig();
      await rig.pump(tester, location: AppRouter.planPath(_kIdC));

      expect(findPlansPane(), findsOneWidget);
      expect(_selected(tester, findPlansPane(), kRigPlans[2].$2), isTrue);
      expect(rig.count('list:'), 1);
      expect(rig.server.mineLimits, [2]);
      expect(rig.count('get'), 1);
    });

    testWidgets('See all and the header actions push their pages (no list '
        'pane there)', (tester) async {
      final rig = PlansTabletRig();
      await rig.pump(tester);

      await tester.tap(inPlansPane(find.text('See all')));
      await tester.pumpAndSettle();
      expect(rig.uri.path, AppRouter.plansMinePath);
      expect(findPlansPane(), findsNothing);

      rig.router.pop();
      await tester.pumpAndSettle();
      expect(rig.uri.path, AppRouter.plansPath);
      expect(findPlansPane(), findsOneWidget);
    });

    testWidgets('the placeholder\'s New plan pushes the form; the list '
        'reloads on return', (tester) async {
      final rig = PlansTabletRig();
      await rig.pump(tester);

      await tester.tap(find.widgetWithText(FilledButton, 'New plan'));
      await tester.pumpAndSettle();
      expect(rig.uri.path, AppRouter.planNewPath);
      expect(find.text('New plan stub'), findsOneWidget);

      rig.router.pop();
      await tester.pumpAndSettle();
      expect(rig.count('list:'), 2);
      expect(rig.count('mine'), 2);
    });

    testWidgets('a write in the detail reloads the pane: a cancelled plan '
        'shows Cancelled there', (tester) async {
      final rig = PlansTabletRig();
      rig.server.public[0] = beaconView(
        startAt: DateTime.now().add(const Duration(hours: 1)),
        id: kBeaconIdA,
        title: kRigPlans[0].$2,
        canManage: true,
      );
      await rig.pump(tester, location: AppRouter.planPath(kBeaconIdA));
      expect(inPlansPane(find.text('Cancelled')), findsNothing);

      await tester.ensureVisible(find.text('Cancel plan'));
      await tester.tap(find.text('Cancel plan'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Cancel plan'));
      await tester.pumpAndSettle();

      expect(rig.count('cancel'), 1);
      expect(rig.count('list:'), 2);
      expect(inPlansPane(find.text('Cancelled')), findsOneWidget);
    });

    testWidgets('People pushed from the detail has no list pane; back '
        'brings the pane back and reloads it', (tester) async {
      final rig = PlansTabletRig();
      rig.server.public[0] = beaconView(
        startAt: DateTime.now().add(const Duration(hours: 1)),
        id: kBeaconIdA,
        title: kRigPlans[0].$2,
        accepted: 1,
        canManage: true,
      );
      await rig.pump(tester, location: AppRouter.planPath(kBeaconIdA));
      expect(findPlansPane(), findsOneWidget);

      await tester.ensureVisible(find.text('People · 1 going'));
      await tester.tap(find.text('People · 1 going'));
      await tester.pumpAndSettle();
      expect(rig.uri.path, AppRouter.planPeoplePath(kBeaconIdA));
      expect(find.byType(BeaconPeopleScreen), findsOneWidget);
      expect(findPlansPane(), findsNothing);
      expect(_primary(tester).width, 1024 - AppSize.railCompact);

      rig.router.pop();
      await tester.pumpAndSettle();
      expect(rig.uri.path, AppRouter.planPath(kBeaconIdA));
      expect(findPlansPane(), findsOneWidget);
      expect(_selected(tester, findPlansPane(), kRigPlans[0].$2), isTrue);
      expect(rig.count('list:'), 2);
    });

    // The pane follows the top page of the shell's navigator: a root page
    // over the shell that leaves it visible (a dialog page) changes nothing.
    for (final location in [
      AppRouter.plansPath,
      AppRouter.planPath(kBeaconIdB),
    ]) {
      testWidgets('$location: a non-opaque root page over it keeps the pane, '
          'the page and the selection', (tester) async {
        final rig = PlansTabletRig();
        await rig.pump(tester, location: location);
        final onPlan = location != AppRouter.plansPath;

        unawaited(rig.router.push(kRigOverlayPath));
        await tester.pumpAndSettle();
        expect(find.text('Overlay stub'), findsOneWidget);
        expect(findPlansPane(), findsOneWidget);
        expect(find.text(kPickAPlan), onPlan ? findsNothing : findsOneWidget);
        if (onPlan) {
          expect(_selected(tester, findPlansPane(), kRigPlans[1].$2), isTrue);
          expect(_back(find.byType(BeaconScreen)), findsNothing);
        }

        rig.router.pop();
        await tester.pumpAndSettle();
        expect(findPlansPane(), findsOneWidget);
        expect(rig.count('list:'), 1);
      });
    }

    testWidgets('a profile pushed from People has no pane either', (
      tester,
    ) async {
      final rig = PlansTabletRig();
      rig.server.public[0] = beaconView(
        startAt: DateTime.now().add(const Duration(hours: 1)),
        id: kBeaconIdA,
        title: kRigPlans[0].$2,
        accepted: 1,
        canManage: true,
      );
      rig.server.going[kBeaconIdA] = [participant(userId: 'ann', name: 'Ann')];
      await rig.pump(tester, location: AppRouter.planPath(kBeaconIdA));

      await tester.ensureVisible(find.text('People · 1 going'));
      await tester.tap(find.text('People · 1 going'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ann'));
      await tester.pumpAndSettle();

      expect(find.text('Profile stub'), findsOneWidget);
      expect(findPlansPane(), findsNothing);

      rig.router.pop();
      await tester.pumpAndSettle();
      rig.router.pop();
      await tester.pumpAndSettle();
      expect(rig.uri.path, AppRouter.planPath(kBeaconIdA));
      expect(findPlansPane(), findsOneWidget);
    });

    testWidgets('My plans opens a plan with go: the list pane comes back', (
      tester,
    ) async {
      final rig = PlansTabletRig();
      await rig.pump(tester, location: AppRouter.plansMinePath);
      expect(findPlansPane(), findsNothing);

      await tester.tap(find.text(kRigMine[1].$2));
      await tester.pumpAndSettle();

      expect(rig.uri.path, AppRouter.planPath(kRigMine[1].$1));
      expect(rig.router.canPop(), isFalse);
      expect(findPlansPane(), findsOneWidget);
    });
  });

  group('band A: the list, pushed detail (600-839)', () {
    testWidgets('"Your plans" inline at the top; a row pushes the plan with '
        'Back; back reloads the list', (tester) async {
      final rig = PlansTabletRig();
      await rig.pump(tester, width: 744, height: 1133);

      expect(findPlansPane(), findsNothing);
      expect(_primary(tester).width, 744 - AppSize.railCompact);
      final section = inShellPage(find.byType(YourPlansSection));
      expect(section, findsOneWidget);
      expect(
        tester.getRect(section).bottom,
        lessThanOrEqualTo(tester.getRect(find.text(kRigPlans[0].$2)).top),
      );

      await tester.tap(find.text(kRigPlans[0].$2));
      await tester.pumpAndSettle();
      expect(rig.uri.path, AppRouter.planPath(kBeaconIdA));
      expect(rig.router.canPop(), isTrue, reason: 'push');
      expect(_back(find.byType(BeaconScreen)), findsOneWidget);

      await tester.tap(_back(find.byType(BeaconScreen)));
      await tester.pumpAndSettle();
      expect(rig.uri.path, AppRouter.plansPath);
      expect(rig.count('list:'), 2);
      expect(rig.count('mine'), 2);
    });

    testWidgets('typed /plans/:id with nothing to pop: Back goes up to '
        '/plans', (tester) async {
      final rig = PlansTabletRig();
      await rig.pump(tester, width: 700, location: AppRouter.planPath(_kIdC));

      await tester.tap(_back(find.byType(BeaconScreen)));
      await tester.pumpAndSettle();
      expect(rig.uri.path, AppRouter.plansPath);
    });

    testWidgets('See all pushes My plans; a row there is pushed', (
      tester,
    ) async {
      final rig = PlansTabletRig();
      await rig.pump(tester, width: 700);

      await tester.tap(find.text('See all'));
      await tester.pumpAndSettle();
      expect(rig.uri.path, AppRouter.plansMinePath);

      await tester.tap(find.text(kRigMine[2].$2));
      await tester.pumpAndSettle();
      expect(rig.uri.path, AppRouter.planPath(kRigMine[2].$1));
      expect(rig.router.canPop(), isTrue);
    });
  });

  group('"Your plans" states', () {
    testWidgets('empty: no section, no gap', (tester) async {
      final rig = PlansTabletRig();
      rig.server.mine.clear();
      await rig.pump(tester);

      expect(find.text(kYourPlansTitle), findsNothing);
      expect(find.byKey(const ValueKey('your-plans')), findsNothing);
      expect(rig.server.mineLimits, [2]);
    });

    testWidgets('failed: the error copy and Try again, which asks again; '
        'the list is untouched', (tester) async {
      final rig = PlansTabletRig();
      rig.server.mineRefusals.add(NetworkException('offline'));
      await rig.pump(tester, width: 700);

      final section = find.byType(YourPlansSection);
      expect(
        find.descendant(of: section, matching: find.text(kYourPlansTitle)),
        findsOneWidget,
      );
      final retry = find.descendant(
        of: section,
        matching: find.text('Try again'),
      );
      expect(retry, findsOneWidget);
      expect(find.text(kRigPlans[0].$2), findsOneWidget);

      await tester.tap(retry);
      await tester.pumpAndSettle();
      expect(find.text(kRigMine[0].$2), findsOneWidget);
      expect(rig.server.mineLimits, [2, 2]);
      expect(rig.count('list:'), 1);
    });

    testWidgets('FEATURE_DISABLED on "Your plans" alone: no section; the '
        'list stays', (tester) async {
      final rig = PlansTabletRig();
      rig.server.mineRefusals.add(FeatureDisabledException('beacons'));
      await rig.pump(tester, width: 700);

      expect(find.byKey(const ValueKey('your-plans')), findsNothing);
      expect(find.text(kYourPlansTitle), findsNothing);
      expect(find.text(kRigPlans[0].$2), findsOneWidget);
    });
  });

  // Tablet plan section 5.2: the list cubit is hoisted, so the list pane
  // appearing or going away at 840 sends nothing; the selection is the URL.
  group('across 839 <-> 840', () {
    testWidgets('/plans: the list moves into the pane and back; one load, '
        'the same cubit', (tester) async {
      final rig = PlansTabletRig();
      await rig.pump(tester, width: 839);
      final list = rig.session!.list;
      final mine = rig.session!.yourPlans;
      expect(findPlansPane(), findsNothing);

      await rig.resize(tester, 840);
      expect(findPlansPane(), findsOneWidget);
      expect(inPlansPane(find.text(kRigPlans[0].$2)), findsOneWidget);
      expect(find.text(kPickAPlan), findsOneWidget);

      await rig.resize(tester, 839);
      expect(findPlansPane(), findsNothing);
      expect(inShellPage(find.text(kRigPlans[0].$2)), findsOneWidget);

      await rig.resize(tester, 1024);
      expect(rig.count('list:'), 1);
      expect(rig.count('mine'), 1);
      expect(rig.session!.list, same(list));
      expect(rig.session!.yourPlans, same(mine));
    });

    testWidgets('/plans/:id: the detail page is kept (no second GetBeacon); '
        'the back arrow comes and goes; the selection follows the URL', (
      tester,
    ) async {
      final rig = PlansTabletRig();
      await rig.pump(tester, location: AppRouter.planPath(kBeaconIdB));
      expect(_back(find.byType(BeaconScreen)), findsNothing);
      final detail = tester.state(find.byType(BeaconScreen));

      await rig.resize(tester, 839);
      expect(findPlansPane(), findsNothing);
      expect(_back(find.byType(BeaconScreen)), findsOneWidget);
      expect(tester.state(find.byType(BeaconScreen)), same(detail));

      await rig.resize(tester, 840);
      expect(_selected(tester, findPlansPane(), kRigPlans[1].$2), isTrue);
      expect(tester.state(find.byType(BeaconScreen)), same(detail));
      expect(rig.count('get'), 1);
      expect(rig.count('list:'), 1);
    });

    testWidgets('1199 <-> 1200: desktop has no list pane and no "Your plans"; '
        'the plan stays open', (tester) async {
      final rig = PlansTabletRig();
      await rig.pump(
        tester,
        width: 1199,
        location: AppRouter.planPath(kBeaconIdA),
      );
      expect(findPlansPane(), findsOneWidget);

      await rig.resize(tester, 1200);
      expect(findPlansPane(), findsNothing);
      expect(rig.uri.path, AppRouter.planPath(kBeaconIdA));
      expect(find.byType(BeaconScreen), findsOneWidget);
    });
  });

  group('gates', () {
    testWidgets('beacons off at 1024: the paused page, full width; nothing '
        'created or sent', (tester) async {
      final rig = PlansTabletRig();
      await rig.pump(
        tester,
        flags: {...kPlansTabletFlags}..remove(kFeatureBeacons),
      );

      expect(find.text(kPlansPausedTitle), findsOneWidget);
      expect(findPlansPane(), findsNothing);
      expect(_primary(tester).width, 1024 - AppSize.railCompact);
      expect(rig.session!.listIfCreated, isNull);
      expect(rig.session!.yourPlansIfCreated, isNull);
      expect(rig.server.calls, isEmpty);
    });

    testWidgets('beacons turning off in mid-session drops the pane', (
      tester,
    ) async {
      final rig = PlansTabletRig();
      await rig.pump(tester);
      expect(findPlansPane(), findsOneWidget);

      rig.flagChanges.add({...kPlansTabletFlags}..remove(kFeatureBeacons));
      await tester.pumpAndSettle();

      expect(findPlansPane(), findsNothing);
      expect(find.text(kPlansPausedTitle), findsOneWidget);
    });

    testWidgets('no app-level session: no pane; the page keeps its own list '
        '(full width)', (tester) async {
      final rig = PlansTabletRig();
      await rig.pump(tester, hoisted: false);

      expect(findPlansPane(), findsNothing);
      expect(find.text(kPickAPlan), findsNothing);
      expect(inShellPage(find.text(kRigPlans[0].$2)), findsOneWidget);
      expect(rig.count('list:'), 1);
    });
  });

  // R-inline: the meeting point's privacy note at every width, phones and
  // desktop included.
  group('meeting point note (all widths)', () {
    for (final width in const <double>[360, 599, 700, 840, 1024, 1300]) {
      testWidgets('${width.toInt()}', (tester) async {
        final rig = PlansTabletRig();
        await rig.pump(
          tester,
          width: width,
          location: AppRouter.planPath(kBeaconIdA),
        );

        final note = find.text(kMeetingPointNote);
        expect(note, findsOneWidget);
        // The detail's venue line (band B also lists the plan in the pane).
        final venue = tester.getRect(
          find.descendant(
            of: find.byType(BeaconScreen),
            matching: find.text('Venue of ${kRigPlans[0].$2}'),
          ),
        );
        expect(tester.getRect(note).top, greaterThanOrEqualTo(venue.bottom));
        expect(tester.getRect(note).left, venue.left);
        expectNoOverflow(tester);
      });
    }
  });

  // R-inline: PlanPeople's summary under the header at every width; no pane
  // and no list pane in band B (code F).
  group('PlanPeople summary (all widths)', () {
    Future<PlansTabletRig> organiser(WidgetTester tester, double width) async {
      final rig = PlansTabletRig();
      rig.server.public[0] = beaconView(
        startAt: DateTime.now().add(const Duration(hours: 1)),
        id: kBeaconIdA,
        title: kRigPlans[0].$2,
        openSpots: 4,
        accepted: 1,
        canManage: true,
      );
      rig.server.going[kBeaconIdA] = [participant(userId: 'ann', name: 'Ann')];
      rig.server.requests[kBeaconIdA] = [
        participant(
          userId: 'cy',
          name: 'Cy',
          state: pb.ParticipantState.PARTICIPANT_STATE_REQUESTED,
        ),
      ];
      await rig.pump(
        tester,
        width: width,
        location: AppRouter.planPeoplePath(kBeaconIdA),
      );
      return rig;
    }

    for (final width in const <double>[360, 700, 840, 1024, 1300]) {
      testWidgets('organiser at ${width.toInt()}: going, requests, open '
          'spots and the note', (tester) async {
        await organiser(tester, width);

        final summary = find.byKey(const ValueKey('plan-people-summary'));
        expect(summary, findsOneWidget);
        expect(
          find.descendant(of: summary, matching: find.text(kRigPlans[0].$2)),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: summary,
            matching: find.text('1 going · 1 request · 3 open spots'),
          ),
          findsOneWidget,
        );
        expect(find.text(kPeopleListNote), findsOneWidget);
        expect(findPlansPane(), findsNothing);
        expect(find.byType(ContextPane), findsNothing);
        expectNoOverflow(tester);
      });
    }

    testWidgets('the counts follow an accept', (tester) async {
      final rig = await organiser(tester, 1024);

      await tester.tap(find.text('Requests'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Accept'));
      await tester.pumpAndSettle();

      expect(rig.count('respond:accept'), 1);
      expect(find.text('2 going · 0 requests · 2 open spots'), findsOneWidget);
    });

    testWidgets('a visitor who may not list: the counts, no requests, and '
        'the page says who may see it (once)', (tester) async {
      final rig = PlansTabletRig();
      await rig.pump(
        tester,
        width: 700,
        location: AppRouter.planPeoplePath(kBeaconIdA),
      );

      expect(find.text('0 going · 3 open spots'), findsOneWidget);
      expect(find.text(kPeopleListNote), findsNothing);
      expect(
        find.text('Only people who are going can see this list.'),
        findsOneWidget,
      );
    });
  });

  group('tablet matrix cells (plan section 5.5, 20 cells)', () {
    for (final brightness in Brightness.values) {
      for (final width in kTabletMatrixWidths) {
        for (final scale in kTabletTextScales) {
          testWidgets('${brightness.name} ${width.toInt()}dp x$scale', (
            tester,
          ) async {
            final rig = PlansTabletRig();
            await rig.pump(
              tester,
              width: width,
              height: kTabletHeights[width]!,
              location: AppRouter.planPath(kBeaconIdA),
              textScale: scale,
              brightness: brightness,
            );

            expect(tester.takeException(), isNull);
            expect(tester.getRect(find.byType(AppNavRail)).left, 0);
            final content = width - AppSize.railCompact;
            final page = _primary(tester);
            if (width < AppBreakpoints.expanded) {
              expect(findPlansPane(), findsNothing);
              expect(page.left, AppSize.railCompact);
              expect(page.width, content);
            } else {
              final list = ShellGeometry.listPaneWidthFor(content);
              expect(
                tester.getRect(find.byKey(const ValueKey('tablet-list-pane'))),
                Rect.fromLTWH(AppSize.railCompact, 0, list + 1, page.height),
              );
              expect(page.width, content - list - 1);
              expect(AppSize.railCompact + list + 1 + page.width, width);
            }
            expect(find.text(kMeetingPointNote), findsOneWidget);
          });
        }
      }
    }
  });

  testWidgets('text scale 2.0, band B, 1024 x 768: the pane and "Your plans" '
      'fit; rows stay 48dp targets', (tester) async {
    final rig = PlansTabletRig();
    await rig.pump(tester, height: 768, textScale: 2);

    expectNoOverflow(tester);
    expect(inPlansPane(find.text(kYourPlansTitle)), findsOneWidget);
    for (final row in tester.widgetList(inPlansPane(find.byType(BeaconRow)))) {
      expect(
        tester.getSize(find.byWidget(row)).height,
        greaterThanOrEqualTo(AppSpacing.minTapTarget),
      );
    }
    // Keep a reference to rig so its tear-downs run with the test.
    expect(rig.count('list:'), 1);
  });

  testWidgets('semantics: the selected pane row says so', (tester) async {
    final handle = tester.ensureSemantics();
    final rig = PlansTabletRig();
    await rig.pump(tester, location: AppRouter.planPath(kBeaconIdA));

    expect(
      tester.getSemantics(inPlansPane(_row(kRigPlans[0].$2)).first),
      isSemantics(isButton: true, isSelected: true, hasSelectedState: true),
    );
    expect(rig.count('get'), 1);
    handle.dispose();
  });
}
