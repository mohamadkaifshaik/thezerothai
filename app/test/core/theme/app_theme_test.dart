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
}
