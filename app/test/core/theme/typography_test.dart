import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/app_fonts.dart';

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
}
