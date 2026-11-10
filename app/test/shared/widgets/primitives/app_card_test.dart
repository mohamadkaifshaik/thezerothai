import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/shared/widgets/primitives/app_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/contrast.dart';
import '../../../support/theme_harness.dart';

BoxDecoration _cardDecoration(WidgetTester tester) {
  final box = tester.widget<Container>(
    find
        .descendant(of: find.byType(AppCard), matching: find.byType(Container))
        .first,
  );
  return box.decoration! as BoxDecoration;
}

void main() {
  group('AppCard', () {
    forEachThemeAndWidth(
      'tokens, highlight, contrast and no fixed height',
      (tester, env) async {
        await pumpThemed(
          tester,
          const SingleChildScrollView(
            child: AppCard(
              child: Text(
                'A long card body that must wrap, never clip, at big text.',
              ),
            ),
          ),
          brightness: env.brightness,
          size: env.size,
          textScale: env.textScale,
        );
        expect(tester.takeException(), isNull);

        final deco = _cardDecoration(tester);
        expect(deco.boxShadow, AppShadows.card);
        expect(deco.borderRadius, BorderRadius.circular(AppRadius.card));
        final gradient = deco.gradient! as LinearGradient;
        expect(
          gradient,
          env.isDark ? AppGradients.darkCard : AppGradients.card,
        );

        final highlight = tester.getSize(
          find.byKey(const ValueKey('app-card-highlight')),
        );
        expect(highlight.height, AppCard.highlightHeight);

        final scheme = buildAppTheme(brightness: env.brightness).colorScheme;
        for (final stop in gradient.colors) {
          expect(contrast(scheme.onSurface, stop), greaterThanOrEqualTo(4.5));
          expect(
            contrast(scheme.onSurfaceVariant, stop),
            greaterThanOrEqualTo(4.5),
          );
        }

        // No fixed height: the card is as tall as its (scaled) text.
        final cardHeight = tester.getSize(find.byType(AppCard)).height;
        final textHeight = tester.getSize(find.byType(Text)).height;
        expect(cardHeight, textHeight + 2 * AppSpacing.md);
      },
      widths: kRedesignWidths,
      textScales: kRedesignTextScales,
    );

    testWidgets('the highlight is decorative: not hit-testable or announced', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      var taps = 0;
      await pumpThemed(
        tester,
        AppCard(
          child: TextButton(onPressed: () => taps++, child: const Text('Go')),
        ),
      );
      await tester.tap(find.text('Go'));
      expect(taps, 1);
      expect(
        find.ancestor(
          of: find.byKey(const ValueKey('app-card-highlight')),
          matching: find.byType(ExcludeSemantics),
        ),
        findsWidgets,
      );
      handle.dispose();
    });
  });

  group('AppPlanStrip', () {
    forEachThemeAndWidth(
      'navy strip, radius, text contrast, tap target',
      (tester, env) async {
        var taps = 0;
        await pumpThemed(
          tester,
          Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: AppPlanStrip(
              onTap: () => taps++,
              child: const Text('Saturday 7 pm, Cubbon Park, 5 going'),
            ),
          ),
          brightness: env.brightness,
          size: env.size,
          textScale: env.textScale,
        );
        expect(tester.takeException(), isNull);
        final material = tester.widget<Material>(
          find
              .descendant(
                of: find.byType(AppPlanStrip),
                matching: find.byType(Material),
              )
              .first,
        );
        expect(material.color, AppPalette.navy);
        expect(
          material.borderRadius,
          BorderRadius.circular(AppRadius.cardSmall),
        );
        expect(
          contrast(AppPalette.pearl, AppPalette.navy),
          greaterThanOrEqualTo(4.5),
        );
        expect(
          contrast(AppPlanStrip.accent, AppPalette.navy),
          greaterThanOrEqualTo(4.5),
        );
        expect(
          tester.getSize(find.byType(InkWell)).height,
          greaterThanOrEqualTo(AppSpacing.minTapTarget),
        );
        await tester.tap(find.byType(InkWell));
        expect(taps, 1);
      },
      widths: kRedesignWidths,
      textScales: kRedesignTextScales,
    );
  });
}
