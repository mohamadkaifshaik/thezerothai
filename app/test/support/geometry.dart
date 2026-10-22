import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Geometry assertions in logical pixels. They back the "X-like" numbers of
/// `docs/x_research/` with tests that run everywhere (no pixel baselines).
///
/// The default tolerance is 1dp: the research values are measured to +-1px
/// and divided by the verified 1.25 display scale.

Rect rectOf(WidgetTester tester, Finder finder) => tester.getRect(finder);

/// The size of the single widget [finder] matches equals [width] x [height]
/// (either may be null to skip that axis).
void expectSize(
  WidgetTester tester,
  Finder finder, {
  double? width,
  double? height,
  double tolerance = 1,
}) {
  final size = tester.getSize(finder);
  if (width != null) {
    expect(size.width, closeTo(width, tolerance), reason: 'width of $finder');
  }
  if (height != null) {
    expect(
      size.height,
      closeTo(height, tolerance),
      reason: 'height of $finder',
    );
  }
}

/// The horizontal gap between the right edge of [left] and the left edge of
/// [right] equals [gap].
void expectHorizontalGap(
  WidgetTester tester,
  Finder left,
  Finder right,
  double gap, {
  double tolerance = 1,
}) {
  final a = tester.getRect(left);
  final b = tester.getRect(right);
  expect(
    b.left - a.right,
    closeTo(gap, tolerance),
    reason: 'gap between $left and $right',
  );
}

/// The vertical gap between the bottom of [upper] and the top of [lower]
/// equals [gap].
void expectVerticalGap(
  WidgetTester tester,
  Finder upper,
  Finder lower,
  double gap, {
  double tolerance = 1,
}) {
  final a = tester.getRect(upper);
  final b = tester.getRect(lower);
  expect(
    b.top - a.bottom,
    closeTo(gap, tolerance),
    reason: 'gap between $upper and $lower',
  );
}

/// The distance from the left edge of [inner] to the left edge of [outer]
/// equals [inset] (a leading padding).
void expectLeftInset(
  WidgetTester tester,
  Finder outer,
  Finder inner,
  double inset, {
  double tolerance = 1,
}) {
  expect(
    tester.getRect(inner).left - tester.getRect(outer).left,
    closeTo(inset, tolerance),
    reason: 'left inset of $inner inside $outer',
  );
}

/// No widget overflowed (a `RenderFlex overflowed` error would be thrown).
void expectNoOverflow(WidgetTester tester) {
  expect(tester.takeException(), isNull);
}
