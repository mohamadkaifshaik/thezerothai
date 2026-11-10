import 'dart:math' as math;
import 'dart:ui';

/// WCAG 2.x contrast ratio between [a] and [b] (1.0 to 21.0), from relative
/// luminance. Shared by theme and primitive tests.
double contrast(Color a, Color b) {
  final l1 = a.computeLuminance();
  final l2 = b.computeLuminance();
  return (math.max(l1, l2) + 0.05) / (math.min(l1, l2) + 0.05);
}
