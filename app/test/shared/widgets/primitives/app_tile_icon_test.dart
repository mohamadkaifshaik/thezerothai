import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/shared/widgets/primitives/app_tile_icon.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/contrast.dart';
import '../../../support/theme_harness.dart';

void main() {
  forEachThemeAndWidth(
    'AppTileIcon: tile radius, teal tint, accent glyph, decorative',
    (tester, env) async {
      await pumpThemed(
        tester,
        const AppTileIcon(icon: Icons.list),
        brightness: env.brightness,
        size: env.size,
        textScale: env.textScale,
      );
      expect(tester.takeException(), isNull);
      final deco =
          tester.widget<Container>(find.byType(Container).first).decoration!
              as BoxDecoration;
      final colors = env.isDark ? AppColors.dark : AppColors.light;
      expect(deco.borderRadius, BorderRadius.circular(AppRadius.tile));
      expect(deco.color, colors.accentText.withValues(alpha: 0.12));
      expect(
        tester.widget<Icon>(find.byIcon(Icons.list)).color,
        colors.accentText,
      );
      expect(tester.getSize(find.byType(AppTileIcon)).width, AppSpacing.xxl);

      // The glyph keeps 4.5:1 on the tint over the card surface.
      final scheme = buildAppTheme(brightness: env.brightness).colorScheme;
      final base = env.isDark
          ? scheme.surfaceContainerHigh
          : scheme.surfaceContainerLowest;
      final tint = Color.alphaBlend(deco.color!, base);
      expect(contrast(colors.accentText, tint), greaterThanOrEqualTo(4.5));
      expect(
        find.descendant(
          of: find.byType(AppTileIcon),
          matching: find.byType(ExcludeSemantics),
        ),
        findsWidgets,
      );
    },
    widths: kRedesignWidths,
    textScales: kRedesignTextScales,
  );

  testWidgets('destructive tints with the error colour', (tester) async {
    await pumpThemed(
      tester,
      const AppTileIcon(icon: Icons.logout, destructive: true),
    );
    final scheme = Theme.of(tester.element(find.byType(AppTileIcon)))
        .colorScheme;
    expect(tester.widget<Icon>(find.byIcon(Icons.logout)).color, scheme.error);
  });
}
