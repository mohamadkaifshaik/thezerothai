import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/widgets/service_paused_view.dart';
import 'package:dzeroth/shared/widgets/primitives/app_pill_button.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/contrast.dart';
import '../../support/theme_harness.dart';

void main() {
  forEachThemeAndWidth(
    'service paused view shows the copy and fits',
    (tester, env) async {
      var retries = 0;
      await pumpThemed(
        tester,
        ServicePausedView(onRetry: () => retries++),
        brightness: env.brightness,
        size: env.size,
        textScale: env.textScale,
        useScaffold: false,
      );
      expect(tester.takeException(), isNull);
      expect(find.text(ServicePausedView.title), findsOneWidget);
      expect(find.text(ServicePausedException.userMessage), findsOneWidget);
      final retry = find.text('Retry');
      expect(retry, findsOneWidget);
      expect(
        tester.getSize(find.byType(AppPillButton)).height,
        greaterThanOrEqualTo(48),
      );
      await expectGolden(
        tester,
        find.byType(ServicePausedView),
        'service_paused',
        env,
      );
      await tester.tap(retry);
      expect(retries, 1);
    },
    widths: kRedesignWidths,
    textScales: kRedesignTextScales,
    heights: kRedesignHeights,
  );

  test('hero text and Retry label are contrast-safe on every hero stop', () {
    // The hero always renders in the dark theme, in both app themes.
    final scheme = appDarkTheme.colorScheme;
    for (final stop in AppGradients.hero.colors) {
      expect(contrast(scheme.onSurface, stop), greaterThanOrEqualTo(4.5));
      expect(
        contrast(scheme.onSurfaceVariant, stop),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        contrast(AppPalette.navy, AppPalette.tealElectric),
        greaterThanOrEqualTo(4.5),
      );
    }
  });

  testWidgets('checking shows the busy state and ignores taps', (tester) async {
    var retries = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: appLightTheme,
        home: ServicePausedView(onRetry: () => retries++, checking: true),
      ),
    );
    await tester.tap(find.text('Retry'));
    expect(retries, 0);
  });
}
