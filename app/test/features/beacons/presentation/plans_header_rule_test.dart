import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/beacons/presentation/beacon_screen.dart';
import 'package:dzeroth/shared/widgets/primitives/app_back_header.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/beacons_fixtures.dart';
import '../../../support/geometry.dart';
import '../../../support/plans_tablet_rig.dart';

/// T8f, one header rule, on PlanDetail: in band A (a pushed page in the
/// pane) Back leads the pane; in band B (the LD detail beside the list,
/// with no back arrow) the title leads the detail, as a Settings category
/// page's does. The header's divider marks the pane (it spans it since T8e).
void main() {
  Future<void> done(WidgetTester tester) => tester.pumpWidget(const SizedBox());

  final header = find.descendant(
    of: find.byType(BeaconScreen),
    matching: find.byType(AppBackHeader),
  );
  Rect pane(WidgetTester tester) => tester.getRect(
    find.descendant(of: header, matching: find.byType(Divider)).first,
  );
  Rect title(WidgetTester tester) =>
      tester.getRect(find.descendant(of: header, matching: find.text('Plan')));

  for (final width in [600.0, 839.0, 840.0, 1024.0, 1199.0]) {
    for (final rtl in [false, true]) {
      testWidgets('${width.toInt()}${rtl ? ' RTL' : ''}: the header leads '
          'the ${width >= 840 ? 'detail' : 'pane'}', (tester) async {
        final rig = PlansTabletRig();
        await rig.pump(
          tester,
          location: AppRouter.planPath(kBeaconIdA),
          width: width,
          textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
        );
        final area = pane(tester);
        double lead(Rect r) => rtl ? area.right - r.right : r.left - area.left;
        final back = find.descendant(
          of: header,
          matching: find.byTooltip('Back'),
        );
        if (width < AppBreakpoints.expanded) {
          expect(lead(tester.getRect(back)), moreOrLessEquals(AppSpacing.xs));
        } else {
          // Band B: no back arrow; its 8 dp spacer, then the title.
          expect(back, findsNothing);
          expect(
            lead(title(tester)),
            moreOrLessEquals(AppSpacing.xs + AppSpacing.sm + AppSpacing.xs),
          );
        }
        expectNoOverflow(tester);
        await done(tester);
      });
    }
  }

  testWidgets('text scale 2.0 at 1024: nothing overflows; the title leads '
      'the detail', (tester) async {
    final rig = PlansTabletRig();
    await rig.pump(
      tester,
      location: AppRouter.planPath(kBeaconIdA),
      width: 1024,
      textScale: 2,
    );
    expectNoOverflow(tester);
    expect(
      title(tester).left - pane(tester).left,
      moreOrLessEquals(AppSpacing.xs + AppSpacing.sm + AppSpacing.xs),
    );
    await done(tester);
  });

  for (final width in [360.0, 1440.0]) {
    testWidgets('${width.toInt()}: Back at the column\'s edge, as before', (
      tester,
    ) async {
      final rig = PlansTabletRig();
      await rig.pump(
        tester,
        location: AppRouter.planPath(kBeaconIdA),
        width: width,
      );
      final column = tester.getRect(header);
      final back = find.descendant(
        of: header,
        matching: find.byTooltip('Back'),
      );
      if (back.evaluate().isNotEmpty) {
        expect(
          tester.getRect(back).left,
          moreOrLessEquals(column.left + AppSpacing.xs),
        );
      }
      expect(pane(tester).width, column.width);
      await done(tester);
    });
  }
}
