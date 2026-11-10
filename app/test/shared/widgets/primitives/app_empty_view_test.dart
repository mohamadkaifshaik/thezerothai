import 'package:dzeroth/shared/widgets/primitives/app_empty_view.dart';
import 'package:dzeroth/shared/widgets/primitives/app_pill_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/theme_harness.dart';

void main() {
  forEachThemeAndWidth(
    'empty view: centred on phones, start-aligned wider, action, no overflow',
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
      final title = find.text('Nothing here yet');
      if (env.size.width < 600) {
        // Phones: centred (owner decision 2026-11-09, mobile designs).
        expect(tester.getCenter(title).dx, closeTo(env.size.width / 2, 1));
      } else {
        // Tablet and desktop: leading edge = the 24dp horizontal padding.
        expect(tester.getTopLeft(title).dx, 24);
      }
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

  testWidgets('centered: false keeps a phone start-aligned', (tester) async {
    await pumpThemed(
      tester,
      const AppEmptyView(title: 'Nothing', centered: false),
      size: const Size(360, 800),
    );
    expect(tester.getTopLeft(find.text('Nothing')).dx, 24);
  });

  testWidgets('centered: true centres on a wide window', (tester) async {
    await pumpThemed(
      tester,
      const AppEmptyView(title: 'Nothing', centered: true),
      size: const Size(1440, 900),
    );
    expect(tester.getCenter(find.text('Nothing')).dx, closeTo(720, 1));
  });
}
