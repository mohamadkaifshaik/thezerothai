import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'geometry.dart';
import 'theme_harness.dart';

/// Self-tests of the shared test harness (W0-7), so that W1+ can trust it.
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
      const Color(0xFF000000),
      reason: 'the X dark page',
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
}
