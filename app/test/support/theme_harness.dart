import 'dart:io';

import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The widths (dp) every shared-chrome test runs at: phone, the first tablet
/// width and the first desktop width (`AppBreakpoints`).
const kMatrixWidths = <double>[360, 600, 1200];

/// The text scales every shared-chrome test runs at.
const kMatrixTextScales = <double>[1.0, 1.3];

/// The widths (dp) the redesign tests run at: phone, tablet portrait and
/// desktop. Separate from [kMatrixWidths], which existing callers rely on.
const kRedesignWidths = <double>[360, 834, 1440];

/// The text scales the redesign tests run at.
const kRedesignTextScales = <double>[1.0, 2.0];

/// Viewport heights (dp) per redesign width, for the `heights:` parameter of
/// [forEachThemeAndWidth].
final kRedesignHeights = <double, double>{360: 800, 834: 1194, 1440: 900};

/// The widths (dp) the tablet-layout tests run at (tablet plan section 5.5):
/// band A (600, 744, 834) and band B (1024, 1194). Separate from
/// [kMatrixWidths] so existing matrices do not multiply.
const kTabletMatrixWidths = <double>[600, 744, 834, 1024, 1194];

/// The widths on both sides of every layout boundary: phone / tablet,
/// band A / band B, tablet / desktop.
const kBoundaryWidths = <double>[599, 600, 839, 840, 1199, 1200];

/// The text scales of the tablet matrix (1.3 stays in [kMatrixTextScales]).
const kTabletTextScales = <double>[1.0, 2.0];

/// Viewport heights (dp) per [kTabletMatrixWidths] width, for the
/// `heights:` parameter of [forEachThemeAndWidth]: portrait iPad mini
/// 744 x 1133, iPad 11-inch 834 x 1194, the 12.9/13-inch iPad Pro portrait
/// 1024 x 1366 (band B), and the 11-inch iPad in landscape 1194 x 834.
final kTabletHeights = <double, double>{
  600: 960,
  744: 1133,
  834: 1194,
  1024: 1366,
  1194: 834,
};

/// Short landscape heights (dp) of the tablet bands: a tablet in landscape
/// (768, 834) and a phone in landscape at 844 dp wide (390, rail R3).
const kTabletLandscapeHeights = <double>[768, 834, 390];

/// The full text-scale axis of the W3 client matrix: the shared
/// stops plus the accessibility maximum, 2.0. Pass it as `textScales:` to
/// [forEachThemeAndWidth] to cover every cell: 360 / 600 / 1200 dp x light /
/// dark x 1.0 / 1.3 / 2.0.
const kMatrixTextScalesLarge = <double>[1.0, 1.3, 2.0];

/// Pumps [child] inside a themed `MaterialApp` at a given logical [size],
/// [brightness] and [textScale]. The view uses a device pixel ratio of 1 so
/// that logical dp equal physical pixels (geometry assertions read dp).
///
/// The size and ratio are reset after the test.
Future<void> pumpThemed(
  WidgetTester tester,
  Widget child, {
  Brightness brightness = Brightness.light,
  Size size = const Size(400, 800),
  double textScale = 1.0,
  bool useScaffold = true,
  bool disableAnimations = false,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(brightness: brightness),
      home: MediaQuery(
        data: MediaQueryData(
          size: size,
          textScaler: TextScaler.linear(textScale),
          disableAnimations: disableAnimations,
        ),
        child: useScaffold ? Scaffold(body: child) : child,
      ),
    ),
  );
  // A theme change animates; settle so geometry and colours are final.
  await tester.pumpAndSettle();
}

/// Registers one `testWidgets` per theme x width x text scale combination.
///
/// Pass `heights: kRedesignHeights` to size each width's viewport; widths
/// missing from the map use [height].
///
/// ```dart
/// forEachThemeAndWidth('drawer header fits', (tester, env) async {
///   await pumpThemed(tester, const MyWidget(),
///       brightness: env.brightness, size: env.size, textScale: env.textScale);
///   expect(tester.takeException(), isNull);
/// });
/// ```
void forEachThemeAndWidth(
  String description,
  Future<void> Function(WidgetTester tester, MatrixEnv env) body, {
  List<double> widths = kMatrixWidths,
  List<double> textScales = kMatrixTextScales,
  double height = 800,
  Map<double, double>? heights,
}) {
  for (final brightness in Brightness.values) {
    for (final width in widths) {
      for (final scale in textScales) {
        final env = MatrixEnv(
          brightness: brightness,
          size: Size(width, heights?[width] ?? height),
          textScale: scale,
        );
        testWidgets('$description [$env]', (tester) => body(tester, env));
      }
    }
  }
}

/// One cell of the test matrix.
class MatrixEnv {
  const MatrixEnv({
    required this.brightness,
    required this.size,
    required this.textScale,
  });

  final Brightness brightness;
  final Size size;
  final double textScale;

  bool get isDark => brightness == Brightness.dark;

  @override
  String toString() => '${brightness.name} ${size.width.toInt()}dp x$textScale';
}

/// Pixel goldens are opt-in: they need baselines generated on the same OS
/// that checks them (CI runs Linux; the founder's machine is Windows), so
/// they run only when `RUN_GOLDENS=1` is set. Geometry assertions (see
/// `geometry.dart`) are the always-on safety net.
///
/// Regenerate baselines on Linux/CI with:
/// `RUN_GOLDENS=1 flutter test --update-goldens test/goldens`
bool get goldensEnabled => Platform.environment['RUN_GOLDENS'] == '1';

/// The golden file name (relative to `test/goldens/`) for [name] in [env]:
/// `<name>_<theme>_<width>_x<scale>.png`, e.g. `drawer_dark_360_x2.0.png`.
String goldenFileName(String name, MatrixEnv env) =>
    '${name}_${env.brightness.name}_${env.size.width.toInt()}'
    '_x${env.textScale}.png';

/// A golden of [finder] named by [goldenFileName] under
/// `test/goldens/`, skipped unless [goldensEnabled].
Future<void> expectGolden(
  WidgetTester tester,
  Finder finder,
  String name,
  MatrixEnv env,
) async {
  if (!goldensEnabled) return;
  await expectLater(
    finder,
    matchesGoldenFile('goldens/${goldenFileName(name, env)}'),
  );
}
