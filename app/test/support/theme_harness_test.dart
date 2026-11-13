import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'app_fonts.dart';
import 'contrast.dart';
import 'geometry.dart';
import 'theme_harness.dart';

/// Self-tests of the shared test harness, so that W1+ can trust it.
void main() {
  testWidgets('pumpThemed applies size, theme and text scale', (tester) async {
    late BuildContext captured;
    await pumpThemed(
      tester,
      Builder(
        builder: (context) {
          captured = context;
          return const SizedBox(key: Key('box'), width: 100, height: 50);
        },
      ),
      brightness: Brightness.dark,
      size: const Size(360, 640),
      textScale: 1.3,
    );

    expect(MediaQuery.sizeOf(captured), const Size(360, 640));
    expect(MediaQuery.textScalerOf(captured).scale(10), closeTo(13, 0.001));
    expect(Theme.of(captured).brightness, Brightness.dark);
    expect(
      Theme.of(captured).colorScheme.surface,
      AppPalette.navy,
      reason: 'the navy dark page',
    );
    expectSize(tester, find.byKey(const Key('box')), width: 100, height: 50);
  });

  testWidgets('the geometry helpers measure gaps and insets', (tester) async {
    await pumpThemed(
      tester,
      Align(
        alignment: Alignment.topLeft,
        child: Padding(
          padding: const EdgeInsets.only(left: 16, top: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: const [
                  SizedBox(key: Key('a'), width: 40, height: 40),
                  SizedBox(width: 8),
                  SizedBox(key: Key('b'), width: 40, height: 40),
                ],
              ),
              const SizedBox(height: 12),
              const SizedBox(key: Key('c'), width: 40, height: 40),
            ],
          ),
        ),
      ),
    );

    expectHorizontalGap(
      tester,
      find.byKey(const Key('a')),
      find.byKey(const Key('b')),
      8,
    );
    expectVerticalGap(
      tester,
      find.byKey(const Key('a')),
      find.byKey(const Key('c')),
      AppSpacing.smd,
    );
    expectLeftInset(
      tester,
      find.byType(Scaffold),
      find.byKey(const Key('a')),
      AppSpacing.md,
    );
    expectNoOverflow(tester);
  });

  var cells = 0;
  forEachThemeAndWidth('the matrix visits every theme, width and scale', (
    tester,
    env,
  ) async {
    cells++;
    await pumpThemed(
      tester,
      const SizedBox.expand(key: Key('fill')),
      brightness: env.brightness,
      size: env.size,
      textScale: env.textScale,
    );
    expectSize(
      tester,
      find.byKey(const Key('fill')),
      width: env.size.width,
      height: env.size.height,
    );
    expect(
      Theme.of(tester.element(find.byKey(const Key('fill')))).brightness,
      env.brightness,
    );
  });

  tearDownAll(() {
    // 2 themes x 3 widths x 2 text scales.
    expect(cells, 12);
  });

  test('goldens are opt-in', () {
    // Off unless RUN_GOLDENS=1 (documented in theme_harness.dart).
    expect(goldensEnabled, isFalse);
  });

  group('redesign matrix', () {
    test('constants leave the shared matrix untouched', () {
      expect(kRedesignWidths, [360, 834, 1440]);
      expect(kRedesignTextScales, [1.0, 2.0]);
      expect(kRedesignHeights, {360: 800, 834: 1194, 1440: 900});
      expect(kMatrixWidths, [360, 600, 1200]);
      expect(kMatrixTextScales, [1.0, 1.3]);
    });

    test('golden names carry theme, width and text scale', () {
      const env = MatrixEnv(
        brightness: Brightness.dark,
        size: Size(834, 1194),
        textScale: 2.0,
      );
      expect(goldenFileName('drawer', env), 'drawer_dark_834_x2.0.png');
    });

    final seen = <String>[];
    forEachThemeAndWidth(
      'heights map sizes the viewport per width',
      (tester, env) async {
        seen.add('${env.size.width.toInt()}x${env.size.height.toInt()}');
        await pumpThemed(
          tester,
          const SizedBox.expand(key: Key('fill')),
          brightness: env.brightness,
          size: env.size,
          textScale: env.textScale,
        );
        expectSize(
          tester,
          find.byKey(const Key('fill')),
          width: env.size.width,
          height: kRedesignHeights[env.size.width]!,
        );
      },
      widths: kRedesignWidths,
      textScales: kRedesignTextScales,
      heights: kRedesignHeights,
    );

    tearDownAll(() {
      // 2 themes x 3 widths x 2 text scales.
      expect(seen.length, 12);
      expect(seen.toSet(), {'360x800', '834x1194', '1440x900'});
    });

    testWidgets('pumpThemed passes disableAnimations through', (tester) async {
      late BuildContext captured;
      Widget probe() => Builder(
        builder: (context) {
          captured = context;
          return const SizedBox();
        },
      );
      await pumpThemed(tester, probe());
      expect(MediaQuery.disableAnimationsOf(captured), isFalse);
      await pumpThemed(tester, probe(), disableAnimations: true);
      expect(MediaQuery.disableAnimationsOf(captured), isTrue);
    });
  });

  test('contrast matches known WCAG ratios', () {
    expect(
      contrast(const Color(0xFF000000), const Color(0xFFFFFFFF)),
      closeTo(21, 0.001),
    );
    expect(
      contrast(const Color(0xFFFFFFFF), const Color(0xFFFFFFFF)),
      closeTo(1, 0.001),
    );
  });

  group('loadAppFonts', () {
    const sample = 'Wide Wide Wimpy 0123';

    double width(String family, FontWeight weight) {
      final painter = TextPainter(
        text: TextSpan(
          text: sample,
          style: TextStyle(
            fontFamily: family,
            fontSize: 20,
            fontWeight: weight,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final w = painter.width;
      painter.dispose();
      return w;
    }

    test('the real fonts replace the test font metrics', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final before = {
        for (final f in ['Inter']) f: width(f, FontWeight.w400),
      };
      await loadAppFonts();
      for (final f in ['Inter']) {
        expect(
          width(f, FontWeight.w400),
          isNot(closeTo(before[f]!, 0.01)),
          reason: '$f should differ from the Ahem test font',
        );
      }
    });
  });
}
