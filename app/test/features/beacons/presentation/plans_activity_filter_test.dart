import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/beacons/presentation/beacons_screen.dart';
import 'package:dzeroth/features/beacons/presentation/widgets/beacon_row.dart';
import 'package:dzeroth/features/beacons/presentation/widgets/plans_activity_filter.dart';
import 'package:dzeroth/gen/dzeroth/beacons/v1/beacons.pb.dart' as pb;
import 'package:dzeroth/shared/widgets/primitives/app_chip.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';

import '../../../support/geometry.dart';
import '../../../support/plans_tablet_rig.dart';

const _widths = <double>[360, 599, 600, 839, 840, 1024, 1199, 1200, 1440];
const _labels = [
  'All',
  'Coffee',
  'Meal',
  'Study',
  'Sports',
  'Walk',
  'Shopping',
];

const _all = pb.BeaconActivity.BEACON_ACTIVITY_UNSPECIFIED;
const _coffee = pb.BeaconActivity.BEACON_ACTIVITY_COFFEE;
const _walk = pb.BeaconActivity.BEACON_ACTIVITY_WALK;
const _study = pb.BeaconActivity.BEACON_ACTIVITY_STUDY;
const _shopping = pb.BeaconActivity.BEACON_ACTIVITY_SHOPPING;

Finder _row() => find.byKey(kPlansActivityFilterKey);

Finder _pill(String label) => find.descendant(
  of: _row(),
  matching: find.widgetWithText(AppFilterPill, label),
);

bool _selected(WidgetTester tester, String label) =>
    tester.widget<AppFilterPill>(_pill(label)).selected;

Finder _rowTitled(String title) =>
    find.ancestor(of: find.text(title), matching: find.byType(BeaconRow));

/// The rig's plans as Coffee, Walk and Study, in that order.
PlansTabletRig _rig() {
  final rig = PlansTabletRig();
  rig.server.public[1].beacon.activity = _walk;
  rig.server.public[2].beacon.activity = _study;
  return rig;
}

Future<void> _tap(WidgetTester tester, String label) async {
  await tester.ensureVisible(_pill(label));
  await tester.pumpAndSettle();
  await tester.tap(_pill(label));
  await tester.pumpAndSettle();
}

/// F29: the Plans list's activity chips (All, Coffee, Meal, Study, Sports,
/// Walk, Shopping). They filter on the server (ListBeacons `activity`) and
/// are part of the list wherever it is drawn: the `/plans` page, and the
/// band B list pane of the tablet layout. Gated on `beacons` with the list.
void main() {
  group('the chip row: flag modes x widths', () {
    for (final MapEntry(key: mode, value: flags) in kPlansFlagModes.entries) {
      for (final w in _widths) {
        testWidgets('$mode at ${w.toInt()}: All selected, then the six '
            'activities; one ListBeacons with no activity', (tester) async {
          final rig = _rig();
          await rig.pump(tester, width: w, height: 900, flags: flags);
          expect(tester.takeException(), isNull);
          expectNoOverflow(tester);

          expect(_row(), findsOneWidget);
          final pills = find.descendant(
            of: _row(),
            matching: find.byType(AppFilterPill),
          );
          expect([
            for (final p in tester.widgetList<AppFilterPill>(pills)) p.label,
          ], _labels);
          expect(_selected(tester, 'All'), isTrue);
          for (final l in _labels.skip(1)) {
            expect(_selected(tester, l), isFalse, reason: l);
          }
          expect(rig.server.listActivities, [_all]);
        });
      }
    }
  });

  testWidgets('beacons off: the paused page, no chip row, nothing sent', (
    tester,
  ) async {
    final rig = _rig();
    await rig.pump(tester, width: 360, flags: const <String>{});
    expect(find.text(kPlansPausedTitle), findsOneWidget);
    expect(_row(), findsNothing);
    expect(rig.server.calls, isEmpty);
  });

  for (final w in const <double>[360, 1024]) {
    testWidgets('at ${w.toInt()}: a chip filters on the server, All brings '
        'every plan back', (tester) async {
      final rig = _rig();
      await rig.pump(tester, width: w, height: 900);

      await _tap(tester, 'Walk');
      expect(rig.server.listActivities.last, _walk);
      expect(_selected(tester, 'Walk'), isTrue);
      expect(_selected(tester, 'All'), isFalse);
      expect(_rowTitled('Evening walk'), findsOneWidget);
      expect(_rowTitled('Coffee at noon'), findsNothing);
      expect(_rowTitled('Study group'), findsNothing);

      await _tap(tester, 'All');
      expect(rig.server.listActivities.last, _all);
      expect(_rowTitled('Coffee at noon'), findsOneWidget);
      expect(_rowTitled('Evening walk'), findsOneWidget);
      expect(_rowTitled('Study group'), findsOneWidget);
    });
  }

  testWidgets('the same chip again sends nothing', (tester) async {
    final rig = _rig();
    await rig.pump(tester, width: 360);
    await _tap(tester, 'Coffee');
    final sent = rig.server.listActivities.length;
    await _tap(tester, 'Coffee');
    expect(rig.server.listActivities, hasLength(sent));
  });

  testWidgets('a filter with no plans: its own empty state, and See all '
      'plans goes back to All', (tester) async {
    final rig = _rig();
    await rig.pump(tester, width: 360);

    await _tap(tester, 'Shopping');
    expect(rig.server.listActivities.last, _shopping);
    expect(find.text('No shopping plans yet'), findsOneWidget);
    expect(find.text('No plans yet'), findsNothing);
    expect(find.byType(BeaconRow), findsNothing);
    // The chips stay, so another activity is one tap away.
    expect(_row(), findsOneWidget);

    await tester.tap(find.text('See all plans'));
    await tester.pumpAndSettle();
    expect(_selected(tester, 'All'), isTrue);
    expect(rig.server.listActivities.last, _all);
    expect(find.byType(BeaconRow), findsNWidgets(3));
  });

  testWidgets('the unfiltered empty state keeps its copy and has no See all '
      'plans', (tester) async {
    final rig = _rig();
    rig.server.public.clear();
    await rig.pump(tester, width: 360);
    expect(find.text('No plans yet'), findsOneWidget);
    expect(find.text('See all plans'), findsNothing);
  });

  testWidgets('a failed filtered load keeps the chips over the error; All '
      'recovers', (tester) async {
    final rig = _rig();
    await rig.pump(tester, width: 360);
    rig.server.refusals.add(NetworkException('offline'));

    await _tap(tester, 'Study');
    expect(
      find.text('No connection. Check your network and try again.'),
      findsOneWidget,
    );
    expect(_row(), findsOneWidget);
    expect(_selected(tester, 'Study'), isTrue);

    await _tap(tester, 'All');
    expect(find.byType(BeaconRow), findsNWidgets(3));
  });

  testWidgets('a server without the filter: only the chosen activity is '
      'shown', (tester) async {
    final rig = _rig();
    rig.server.ignoresActivity = true;
    await rig.pump(tester, width: 360);

    await _tap(tester, 'Coffee');
    expect(rig.server.listActivities.last, _coffee);
    expect(_rowTitled('Coffee at noon'), findsOneWidget);
    expect(_rowTitled('Evening walk'), findsNothing);
    expect(_rowTitled('Study group'), findsNothing);
  });

  testWidgets('band B: the chips are in the list pane; the filter survives '
      '1024 -> 839 -> 1024 with no new ListBeacons', (tester) async {
    final rig = _rig();
    await rig.pump(tester, width: 1024);
    expect(inPlansPane(_row()), findsOneWidget);

    await _tap(tester, 'Walk');
    final sent = rig.server.listActivities.length;

    tester.view.physicalSize = const Size(839, 900);
    await tester.pumpAndSettle();
    expect(findPlansPane(), findsNothing);
    expect(_selected(tester, 'Walk'), isTrue);
    expect(_rowTitled('Coffee at noon'), findsNothing);

    tester.view.physicalSize = const Size(1024, 900);
    await tester.pumpAndSettle();
    expect(inPlansPane(_row()), findsOneWidget);
    expect(_selected(tester, 'Walk'), isTrue);
    expect(rig.server.listActivities, hasLength(sent));
  });

  testWidgets('RTL at 360: All sits at the start (right) edge', (tester) async {
    final rig = _rig();
    await rig.pump(tester, width: 360, textDirection: TextDirection.rtl);
    expect(tester.takeException(), isNull);
    final all = tester.getRect(_pill('All'));
    final coffee = tester.getRect(_pill('Coffee'));
    expect(all.right, greaterThan(coffee.right));
    expect(all.right, closeTo(360 - AppSpacing.md, AppSpacing.md));
  });

  for (final w in const <double>[360, 1024]) {
    testWidgets('text scale 2.0 at ${w.toInt()}: no overflow, no label cut, '
        '48 dp targets, the row scrolls to Shopping', (tester) async {
      final rig = _rig();
      await rig.pump(tester, width: w, height: 900, textScale: 2);
      expect(tester.takeException(), isNull);
      expectNoOverflow(tester);
      for (final l in _labels) {
        await tester.ensureVisible(_pill(l));
        await tester.pumpAndSettle();
        expectMinTarget(tester, _pill(l), reason: l);
        final text = tester.renderObject<RenderParagraph>(
          find.descendant(of: _pill(l), matching: find.text(l)),
        );
        expect(text.didExceedMaxLines, isFalse, reason: l);
      }
      await _tap(tester, 'Shopping');
      expect(_selected(tester, 'Shopping'), isTrue);
    });
  }

  testWidgets('semantics: one selected button per chip, in a named group', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final rig = _rig();
    await rig.pump(tester, width: 360);
    expect(
      tester.getSemantics(_pill('All')),
      matchesSemantics(
        label: 'All',
        isButton: true,
        isSelected: true,
        hasSelectedState: true,
        isEnabled: true,
        hasEnabledState: true,
        hasTapAction: true,
      ),
    );
    expect(find.bySemanticsLabel(kPlansActivityFilterLabel), findsOneWidget);
    handle.dispose();
  });
}
