import 'package:dzeroth/core/theme/app_theme.dart';
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

/// [finder] is at least 48 x 48 dp (`AppSpacing.minTapTarget`), the target
/// the `ui-catalog` demands of every control. Pass the widget that owns the
/// target (a button, an `IconButton`, the semantics node of a link), not its
/// visual (a 36dp pill sits in a 48dp padded button).
void expectMinTarget(WidgetTester tester, Finder finder, {String? reason}) {
  final size = tester.getSize(finder.first);
  final why = reason ?? finder.describeMatch(Plurality.one);
  expect(
    size.width,
    greaterThanOrEqualTo(AppSpacing.minTapTarget - 0.5),
    reason: 'width of $why',
  );
  expect(
    size.height,
    greaterThanOrEqualTo(AppSpacing.minTapTarget - 0.5),
    reason: 'height of $why',
  );
}

/// [inner] lies inside the screen horizontally (nothing is pushed off its
/// left or right edge); [screenWidth] is the view's logical width.
void expectInsideHorizontally(
  WidgetTester tester,
  Finder inner,
  double screenWidth, {
  String? reason,
}) {
  final rect = tester.getRect(inner.first);
  final why = reason ?? inner.describeMatch(Plurality.one);
  expect(rect.left, greaterThanOrEqualTo(-0.5), reason: 'left of $why');
  expect(
    rect.right,
    lessThanOrEqualTo(screenWidth + 0.5),
    reason: 'right of $why',
  );
}
