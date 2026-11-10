import 'package:dzeroth/core/widgets/app_state_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/contrast.dart';
import '../../support/theme_harness.dart';

void main() {
  testWidgets('feature off and permission denied keep the existing copy', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              const Expanded(child: AppStateView.featureOff()),
              Expanded(child: AppStateView.permissionDenied()),
            ],
          ),
        ),
      ),
    );
    expect(find.text("This feature isn't available yet."), findsOneWidget);
    expect(find.text("You can't do that in this community."), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
  });

  forEachThemeAndWidth(
    'state view: live region, no overflow, muted body contrast',
    (tester, env) async {
      final handle = tester.ensureSemantics();
      await pumpThemed(
        tester,
        const AppStateView(
          title: 'Plans are paused',
          icon: Icons.pause_circle_outline,
          body: 'Your plans and requests are safe.',
        ),
        brightness: env.brightness,
        size: env.size,
        textScale: env.textScale,
      );
      expect(tester.takeException(), isNull);
      final node = tester.getSemantics(find.byType(AppStateView));
      expect(find.bySemanticsLabel('Plans are paused'), findsOneWidget);
      expect(node.flagsCollection.isLiveRegion, isTrue);
      final scheme = Theme.of(tester.element(find.byType(AppStateView)))
          .colorScheme;
      expect(
        contrast(scheme.onSurfaceVariant, scheme.surface),
        greaterThanOrEqualTo(4.5),
      );
      await expectGolden(tester, find.byType(AppStateView), 'state_view', env);
      handle.dispose();
    },
    widths: kRedesignWidths,
    textScales: kRedesignTextScales,
    heights: kRedesignHeights,
  );
}
