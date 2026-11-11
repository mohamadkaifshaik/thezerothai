import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/shared/widgets/primitives/app_tab_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/geometry.dart';
import '../../../support/profile_tablet_rig.dart';

/// T8e: the Profile's tab bar in the readable column (tablet plan sections
/// 2.2, 3 and 6.3). The tabs sit in the 680 column (`readableInset`); their
/// hairline spans the primary pane. Only band A above 760 has a column
/// narrower than the pane; elsewhere the painter draws nothing.
void main() {
  Future<void> done(WidgetTester tester) => tester.pumpWidget(const SizedBox());

  for (final width in [600.0, 834.0, 839.0, 1024.0, 1199.0]) {
    testWidgets('${width.toInt()} dp: the tabs in the column, their hairline '
        'across the pane', (tester) async {
      final rig = ProfileTabletRig();
      await rig.pump(tester, width: width);
      final primary = tester.getRect(
        find.byKey(const ValueKey('tablet-primary')),
      );
      final column = primary.width < AppSize.readableMax
          ? primary.width
          : AppSize.readableMax;
      final bar = tester.getRect(inProfilePage(find.byType(AppTabBar)));
      expect(bar.width, moreOrLessEquals(column));
      expect(bar.center.dx, moreOrLessEquals(primary.center.dx));
      final bleed = (primary.width - column) / 2;
      final hairline = tester.renderObject(
        inProfilePage(find.byKey(AppTabBar.hairlineKey)),
      );
      if (bleed > 0) {
        expect(
          hairline,
          paints
            ..rect(rect: Rect.fromLTRB(-bleed, bar.height - 1, 0, bar.height))
            ..rect(
              rect: Rect.fromLTRB(
                bar.width,
                bar.height - 1,
                bar.width + bleed,
                bar.height,
              ),
            ),
        );
      } else {
        expect(hairline, isNot(paints..rect()));
      }
      expectNoOverflow(tester);
      await done(tester);
    });
  }

  for (final width in [360.0, 1440.0]) {
    testWidgets('${width.toInt()} dp: no bleed (today\'s tab bar)', (
      tester,
    ) async {
      final rig = ProfileTabletRig();
      await rig.pump(tester, width: width);
      expect(
        tester.renderObject(inProfilePage(find.byKey(AppTabBar.hairlineKey))),
        isNot(paints..rect()),
      );
      await done(tester);
    });
  }
}
