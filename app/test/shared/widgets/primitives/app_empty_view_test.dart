import 'package:dzeroth/shared/widgets/primitives/app_empty_view.dart';
import 'package:dzeroth/shared/widgets/primitives/app_pill_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/theme_harness.dart';

void main() {
  forEachThemeAndWidth(
    'empty view: start-aligned, action, no overflow',
    (tester, env) async {
      await pumpThemed(
        tester,
        AppEmptyView(
          icon: Icons.inbox_outlined,
          title: 'Nothing here yet',
          subtitle: "When there's something to show, it will appear here.",
          action: AppPillButton(label: 'Refresh', onPressed: () {}),
        ),
        brightness: env.brightness,
        size: env.size,
        textScale: env.textScale,
      );
      expect(tester.takeException(), isNull);
      // Leading edge = the 24dp horizontal padding.
      expect(tester.getTopLeft(find.text('Nothing here yet')).dx, 24);
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      expect(
        tester.getSize(find.byType(AppPillButton)).width,
        lessThan(env.size.width < 400 ? env.size.width : 400),
      );
      await expectGolden(tester, find.byType(AppEmptyView), 'empty_view', env);
    },
    widths: kRedesignWidths,
    textScales: kRedesignTextScales,
    heights: kRedesignHeights,
  );

  testWidgets('icon is optional; centered mode centres the title', (
    tester,
  ) async {
    await pumpThemed(
      tester,
      const AppEmptyView(title: 'Nothing', centered: true),
    );
    expect(find.byType(Icon), findsNothing);
    expect(tester.getCenter(find.text('Nothing')).dx, closeTo(200, 1));
  });
}
