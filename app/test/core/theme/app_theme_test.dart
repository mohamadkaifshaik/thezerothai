import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dzeroth/core/theme/app_theme.dart';

double _luminance(Color c) => c.computeLuminance();

double _contrast(Color a, Color b) {
  final l1 = _luminance(a);
  final l2 = _luminance(b);
  return (math.max(l1, l2) + 0.05) / (math.min(l1, l2) + 0.05);
}

void main() {
  for (final entry in {'light': appLightTheme, 'dark': appDarkTheme}.entries) {
    test('${entry.key} snackbar action and close icon meet WCAG AA', () {
      final snack = entry.value.snackBarTheme;
      final bg = snack.backgroundColor!;
      expect(snack.actionTextColor, isNotNull);
      expect(snack.closeIconColor, isNotNull);
      expect(_contrast(snack.actionTextColor!, bg), greaterThanOrEqualTo(4.5));
      // Icons are non-text UI: WCAG 1.4.11 asks for 3:1.
      expect(_contrast(snack.closeIconColor!, bg), greaterThanOrEqualTo(3.0));
    });
  }

  for (final entry in {'light': appLightTheme, 'dark': appDarkTheme}.entries) {
    final name = entry.key;
    final colors = entry.value.colorScheme;
    final layers = {
      'surface': colors.surface,
      'surfaceContainerLowest': colors.surfaceContainerLowest,
      'surfaceContainerLow': colors.surfaceContainerLow,
      'surfaceContainer': colors.surfaceContainer,
      'surfaceContainerHigh': colors.surfaceContainerHigh,
      'surfaceContainerHighest': colors.surfaceContainerHighest,
    };

    group('$name palette', () {
      test('builds a Material 3 theme of the right brightness', () {
        expect(entry.value.useMaterial3, isTrue);
        expect(
          colors.brightness,
          name == 'dark' ? Brightness.dark : Brightness.light,
        );
        expect(
          buildAppTheme(brightness: colors.brightness).colorScheme.primary,
          colors.primary,
        );
      });

      test('onSurface and onSurfaceVariant are >= 4.5:1 on every surface', () {
        for (final layer in layers.entries) {
          expect(
            _contrast(colors.onSurface, layer.value),
            greaterThanOrEqualTo(4.5),
            reason: 'onSurface on ${layer.key}',
          );
          expect(
            _contrast(colors.onSurfaceVariant, layer.value),
            greaterThanOrEqualTo(4.5),
            reason: 'onSurfaceVariant on ${layer.key}',
          );
        }
      });

      test('onPrimary is >= 4.5:1 on primary, tertiary and the disabled '
          'gradient fill', () {
        expect(
          _contrast(colors.onPrimary, colors.primary),
          greaterThanOrEqualTo(4.5),
        );
        expect(
          _contrast(colors.onPrimary, colors.tertiary),
          greaterThanOrEqualTo(4.5),
        );
        expect(
          _contrast(colors.onPrimary, colors.onSurfaceVariant),
          greaterThanOrEqualTo(4.5),
        );
        expect(
          _contrast(colors.onTertiary, colors.tertiary),
          greaterThanOrEqualTo(4.5),
        );
      });

      test('the border stays visible on the lowest raised surface', () {
        expect(
          _contrast(colors.outlineVariant, colors.surfaceContainerLow),
          greaterThanOrEqualTo(1.3),
        );
      });

      test('primary is >= 3:1 against the background (non-text UI)', () {
        expect(
          _contrast(colors.primary, colors.surface),
          greaterThanOrEqualTo(3.0),
        );
      });

      test('the gradient stops differ (indigo to violet)', () {
        expect(colors.tertiary, isNot(colors.primary));
      });
    });
  }

  test('dark surfaces layer strictly lighter, never pure black', () {
    final colors = appDarkTheme.colorScheme;
    final ladder = [
      colors.surface,
      colors.surfaceContainerLow,
      colors.surfaceContainer,
      colors.surfaceContainerHigh,
      colors.surfaceContainerHighest,
    ];
    for (var i = 1; i < ladder.length; i++) {
      expect(
        ladder[i].computeLuminance(),
        greaterThan(ladder[i - 1].computeLuminance()),
        reason: 'layer $i is lighter than layer ${i - 1}',
      );
    }
    expect(colors.surface, isNot(const Color(0xFF000000)));
  });

  test('dark palette tokens (founder decision 2026-10-21)', () {
    final colors = appDarkTheme.colorScheme;
    expect(colors.surface, const Color(0xFF070A11));
    expect(colors.onSurface, const Color(0xFFEDF3FF));
    expect(colors.primary, const Color(0xFF6A91FF));
    expect(colors.tertiary, const Color(0xFF9A7BFF));
    expect(colors.outlineVariant, const Color(0xFF212A3A));
  });
}
