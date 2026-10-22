import 'dart:io';

import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The widths (dp) every shared-chrome test runs at: phone, the first tablet
/// width and the first desktop width (`AppBreakpoints`).
const kMatrixWidths = <double>[360, 600, 1200];

/// The text scales every shared-chrome test runs at.
const kMatrixTextScales = <double>[1.0, 1.3];

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
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(brightness: brightness),
      home: MediaQuery(
        data: MediaQueryData(
          size: size,
          textScaler: TextScaler.linear(textScale),
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
}) {
  for (final brightness in Brightness.values) {
    for (final width in widths) {
      for (final scale in textScales) {
        final env = MatrixEnv(
          brightness: brightness,
          size: Size(width, height),
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

/// A golden of [finder] named `<name>_<theme>_<width>.png` under
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
    matchesGoldenFile(
      'goldens/${name}_${env.brightness.name}_${env.size.width.toInt()}.png',
    ),
  );
}
