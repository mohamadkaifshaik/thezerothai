import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/core/widgets/shell_geometry.dart';
import 'package:dzeroth/features/beacons/presentation/beacon_screen.dart';
import 'package:dzeroth/shared/widgets/primitives/app_main_column.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/beacons_fixtures.dart';
import '../../../support/plans_tablet_rig.dart';
import '../../../support/geometry.dart';

/// T8e: PlanDetail's reading column (tablet plan sections 3 and 4.1
/// "PlanDetail": F in band A, the LD detail in band B). The plan is at most
/// 680 and centred in its pane or detail; a detail narrower than 680 is
/// filled. Phones and desktop keep the 600 column.
void main() {
  Rect column(WidgetTester tester) => tester.getRect(
    find.descendant(
      of: find.byType(BeaconScreen),
      matching: find.byType(AppMainColumnBleed),
    ),
  );
  Future<void> done(WidgetTester tester) => tester.pumpWidget(const SizedBox());

  for (final (width, rtl) in [
    (600.0, false),
    (839.0, false),
    (840.0, false),
    (1024.0, false),
    (1199.0, false),
    (1199.0, true),
  ]) {
    testWidgets('${width.toInt()}${rtl ? ' RTL' : ''}: at most 680, centred '
        'in the ${width >= 840 ? 'detail' : 'pane'}', (tester) async {
      final rig = PlansTabletRig();
      await rig.pump(
        tester,
        location: AppRouter.planPath(kBeaconIdA),
        width: width,
        textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
      );
      final c = width - AppSize.railCompact;
      final Rect area;
      if (width < AppBreakpoints.expanded) {
        area = Rect.fromLTWH(rtl ? 0 : 80, 0, c, 900);
      } else {
        final list = ShellGeometry.listPaneWidthFor(c);
        area = Rect.fromLTWH(rtl ? 0 : 80 + list + 1, 0, c - list - 1, 900);
      }
      final col = column(tester);
      expect(
        col.width,
        moreOrLessEquals(
          area.width < AppSize.readableMax ? area.width : AppSize.readableMax,
        ),
      );
      expect(col.center.dx, moreOrLessEquals(area.center.dx));
      expectNoOverflow(tester);
      await done(tester);
    });
  }

  testWidgets('text scale 2.0 at 839: nothing overflows', (tester) async {
    final rig = PlansTabletRig();
    await rig.pump(
      tester,
      location: AppRouter.planPath(kBeaconIdA),
      width: 839,
      textScale: 2,
    );
    expectNoOverflow(tester);
    expect(column(tester).width, AppSize.readableMax);
    await done(tester);
  });

  for (final width in [360.0, 1440.0]) {
    testWidgets('${width.toInt()}: today\'s column', (tester) async {
      final rig = PlansTabletRig();
      await rig.pump(
        tester,
        location: AppRouter.planPath(kBeaconIdA),
        width: width,
      );
      final col = column(tester);
      expect(col.width, lessThanOrEqualTo(AppLayout.mainColumnMaxWidth));
      await done(tester);
    });
  }
}
