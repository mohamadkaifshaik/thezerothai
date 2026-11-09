import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/app_fonts.dart';
import '../../support/contrast.dart';
import '../../support/theme_harness.dart';

const _sample = 'Dzeroth weight axis ₹235 · Hamburgefonstiv';

double _width(TextStyle style) {
  final painter = TextPainter(
    text: TextSpan(text: _sample, style: style),
    textDirection: TextDirection.ltr,
  )..layout();
  final width = painter.width;
  painter.dispose();
  return width;
}

Map<String, TextStyle> _styles(TextTheme t) => {
  'displayLarge': t.displayLarge!,
  'displayMedium': t.displayMedium!,
  'displaySmall': t.displaySmall!,
  'headlineLarge': t.headlineLarge!,
  'headlineMedium': t.headlineMedium!,
  'headlineSmall': t.headlineSmall!,
  'titleLarge': t.titleLarge!,
  'titleMedium': t.titleMedium!,
  'titleSmall': t.titleSmall!,
  'bodyLarge': t.bodyLarge!,
  'bodyMedium': t.bodyMedium!,
  'bodySmall': t.bodySmall!,
  'labelLarge': t.labelLarge!,
  'labelMedium': t.labelMedium!,
  'labelSmall': t.labelSmall!,
};

// (family, size, weight, line height) per style; PR 1.4 of the redesign plan.
const _scale = <String, (String, double, FontWeight, double)>{
  'displayLarge': ('Manrope', 52, FontWeight.w800, 1.02),
  'displayMedium': ('Manrope', 40, FontWeight.w800, 1.02),
  'displaySmall': ('Manrope', 28, FontWeight.w800, 1.02),
  'headlineLarge': ('Manrope', 24, FontWeight.w800, 1.25),
  'headlineMedium': ('Manrope', 22, FontWeight.w800, 1.25),
  'headlineSmall': ('Manrope', 20, FontWeight.w800, 1.25),
  'titleLarge': ('Manrope', 20, FontWeight.w800, 1.25),
  'titleMedium': ('DM Sans', 17, FontWeight.w700, 1.3),
  'titleSmall': ('DM Sans', 15, FontWeight.w700, 1.33),
  'bodyLarge': ('DM Sans', 15, FontWeight.w500, 1.42),
  'bodyMedium': ('DM Sans', 14, FontWeight.w500, 1.4),
  'bodySmall': ('DM Sans', 13, FontWeight.w500, 1.35),
  'labelLarge': ('DM Sans', 15, FontWeight.w700, 1.33),
  'labelMedium': ('DM Sans', 14, FontWeight.w600, 1.33),
  'labelSmall': ('DM Sans', 12, FontWeight.w600, 1.33),
};

class _Specimen extends StatelessWidget {
  const _Specimen();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final styles = _styles(theme.textTheme);
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.md),
      children: [
        Text('PLANS NEAR YOU', style: AppTextStyles.eyebrow(theme)),
        Text('DZEROTH', style: AppTextStyles.wordmark(theme)),
        Text.rich(
          TextSpan(
            text: 'Say it ',
            style: styles['displaySmall'],
            children: [
              TextSpan(
                text: 'first.',
                style: AppTextStyles.displayAccent(theme),
              ),
            ],
          ),
        ),
        for (final entry in styles.entries)
          Text('${entry.key} ₹235 · it’s …', style: entry.value),
        Text(
          'The opened post reads at 17 on a 24 line.',
          style: AppTextStyles.focalPost(theme),
        ),
      ],
    );
  }
}

const _weights = [
  FontWeight.w400,
  FontWeight.w500,
  FontWeight.w600,
  FontWeight.w700,
  FontWeight.w800,
];

void main() {
  setUpAll(loadAppFonts);

  // Spike (redesign plan §1.2): DM Sans and Manrope are single variable TTFs
  // declared without `weight:` entries. If the engine maps `fontWeight` onto
  // the `wght` axis, a string measures exactly as wide as with the matching
  // `FontVariation('wght', w)` (outcome A: the theme sets `fontWeight` only).
  // Otherwise only `fontVariations` moves the axis (outcome B).
  //
  // Evidence scope: the flutter_tester host engine only. CanvasKit (web) and
  // Android need a manual check; this test stays as a regression guard.
  group('variable weight axis (spike)', () {
    for (final family in ['DM Sans', 'Manrope']) {
      test('$family: fontWeight drives the wght axis', () {
        double byWeight(FontWeight w) =>
            _width(TextStyle(fontFamily: family, fontSize: 20, fontWeight: w));
        double byAxis(FontWeight w) => _width(
          TextStyle(
            fontFamily: family,
            fontSize: 20,
            fontVariations: [FontVariation('wght', w.value.toDouble())],
          ),
        );

        var previous = 0.0;
        for (final w in _weights) {
          final width = byWeight(w);
          expect(width, byAxis(w), reason: '$family $w equals its wght twin');
          expect(width, greaterThan(previous), reason: '$family $w is wider');
          previous = width;
        }
      });

      test('$family: copyWith(fontWeight:) moves the axis again', () {
        final heavy = TextStyle(
          fontFamily: family,
          fontSize: 20,
          fontWeight: FontWeight.w800,
        );
        final regular = heavy.copyWith(fontWeight: FontWeight.w400);
        expect(_width(regular), isNot(_width(heavy)));
        expect(
          _width(regular),
          _width(
            TextStyle(
              fontFamily: family,
              fontSize: 20,
              fontVariations: const [FontVariation('wght', 400)],
            ),
          ),
        );
      });
    }
  });

  group('type scale (ADR-0033 §2)', () {
    for (final theme in [appLightTheme, appDarkTheme]) {
      final name = theme.brightness.name;
      final styles = _styles(theme.textTheme);

      test('$name: families, sizes, weights and line heights', () {
        for (final MapEntry(:key, :value) in _scale.entries) {
          final (family, size, weight, height) = value;
          final style = styles[key]!;
          expect(style.fontFamily, family, reason: key);
          expect(style.fontSize, size, reason: key);
          expect(style.fontWeight, weight, reason: key);
          expect(style.height, closeTo(height, 0.001), reason: key);
          // Weight comes from fontWeight alone (outcome A).
          expect(style.fontVariations, isNull, reason: key);
        }
      });

      test('$name: tracking is relative to size', () {
        for (final MapEntry(:key, :value) in styles.entries) {
          final expected = key.startsWith('display')
              ? AppTypeTokens.displayTracking * value.fontSize!
              : 0.0;
          expect(value.letterSpacing, closeTo(expected, 1e-9), reason: key);
        }
      });

      test('$name: nothing below 12 sp', () {
        final all = [
          ...styles.values,
          AppTextStyles.eyebrow(theme),
          AppTextStyles.wordmark(theme),
          AppTextStyles.focalPost(theme),
          AppTextStyles.displayAccent(theme),
        ];
        for (final style in all) {
          expect(style.fontSize, greaterThanOrEqualTo(12));
        }
      });

      test('$name: text uses onSurface; default family is DM Sans', () {
        for (final MapEntry(:key, :value) in styles.entries) {
          expect(value.color, theme.colorScheme.onSurface, reason: key);
        }
        // ThemeData.fontFamily reaches text outside the text theme.
        expect(theme.primaryTextTheme.bodyMedium!.fontFamily, AppFonts.body);
      });

      test('$name: AppTextStyles', () {
        final colors = theme.extension<AppColors>()!;
        final eyebrow = AppTextStyles.eyebrow(theme);
        expect(eyebrow.fontFamily, AppFonts.display);
        expect(eyebrow.fontSize, 12);
        expect(eyebrow.fontWeight, FontWeight.w700);
        expect(eyebrow.letterSpacing, closeTo(0.24 * 12, 1e-9));
        final wordmark = AppTextStyles.wordmark(theme);
        expect(wordmark.fontFamily, AppFonts.display);
        expect(wordmark.fontSize, 15);
        expect(wordmark.fontWeight, FontWeight.w700);
        expect(wordmark.letterSpacing, closeTo(0.13 * 15, 1e-9));
        final focal = AppTextStyles.focalPost(theme);
        expect(focal.fontFamily, AppFonts.body);
        expect(focal.fontSize, AppFocalPost.bodySize);
        expect(focal.fontSize! * focal.height!, closeTo(24, 1e-9));
        for (final size in AppTypeTokens.displaySizes) {
          final accent = AppTextStyles.displayAccent(theme, size: size);
          expect(accent.fontFamily, AppFonts.display);
          expect(accent.fontWeight, FontWeight.w800);
          expect(accent.letterSpacing, closeTo(-0.035 * size, 1e-9));
          expect(accent.color, colors.accentText);
        }
        // Accent and eyebrow colours stay AA on the page.
        for (final style in [eyebrow, AppTextStyles.displayAccent(theme)]) {
          expect(
            contrast(style.color!, theme.colorScheme.surface),
            greaterThanOrEqualTo(4.5),
          );
        }
      });
    }
  });

  forEachThemeAndWidth(
    'a two-line title reflows without overflow',
    (tester, env) async {
      await pumpThemed(
        tester,
        Builder(
          builder: (context) {
            final text = Theme.of(context).textTheme;
            return Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 360,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'A screen title that is long enough to need two lines',
                      key: const ValueKey('title'),
                      style: text.titleLarge,
                    ),
                    Text('Body text under it', style: text.bodyLarge),
                  ],
                ),
              ),
            );
          },
        ),
        brightness: env.brightness,
        size: env.size,
        textScale: env.textScale,
      );
      expect(tester.takeException(), isNull);
      final title = tester.getSize(find.byKey(const ValueKey('title')));
      // At least two lines of 20 sp x 1.25, scaled.
      expect(title.height, greaterThanOrEqualTo(2 * 20 * 1.25 * env.textScale));
    },
    widths: const [360],
    textScales: kRedesignTextScales,
    heights: kRedesignHeights,
  );

  forEachThemeAndWidth(
    'the type specimen builds',
    (tester, env) async {
      await pumpThemed(
        tester,
        const _Specimen(),
        brightness: env.brightness,
        size: env.size,
        textScale: env.textScale,
      );
      expect(tester.takeException(), isNull);
      await expectGolden(tester, find.byType(_Specimen), 'type_specimen', env);
    },
    widths: const [360, 1440],
    textScales: kRedesignTextScales,
    heights: kRedesignHeights,
  );
}
