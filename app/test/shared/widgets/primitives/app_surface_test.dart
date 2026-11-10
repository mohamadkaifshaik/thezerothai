import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/shared/widgets/primitives/app_surface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/contrast.dart';
import '../../../support/theme_harness.dart';

Widget _host(
  Widget child, {
  Brightness brightness = Brightness.dark,
  double textScale = 1,
}) => MaterialApp(
  theme: buildAppTheme(brightness: brightness),
  home: MediaQuery(
    data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
    child: Scaffold(body: SingleChildScrollView(child: child)),
  ),
);

void main() {
  group('AppSurface', () {
    testWidgets('renders its child in dark and light', (tester) async {
      for (final brightness in Brightness.values) {
        await tester.pumpWidget(
          _host(
            const AppSurface(child: Text('Local data')),
            brightness: brightness,
          ),
        );
        expect(find.text('Local data'), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
    });

    testWidgets('uses theme surfaces, and a higher one when elevated', (
      tester,
    ) async {
      Color? fill() =>
          (tester
                      .widget<Container>(
                        find.descendant(
                          of: find.byType(AppSurface),
                          matching: find.byType(Container),
                        ),
                      )
                      .decoration!
                  as BoxDecoration)
              .color;

      await tester.pumpWidget(_host(const AppSurface(child: Text('a'))));
      final colors = Theme.of(tester.element(find.text('a'))).colorScheme;
      expect(fill(), AppPalette.navy2);
      await tester.pumpWidget(
        _host(const AppSurface(child: Text('a')), brightness: Brightness.light),
      );
      // MaterialApp animates between themes; let it finish.
      await tester.pumpAndSettle();
      expect(fill(), AppPalette.white);
      await tester.pumpWidget(_host(const AppSurface(child: Text('a'))));
      await tester.pumpAndSettle();

      await tester.pumpWidget(
        _host(const AppSurface(elevated: true, child: Text('a'))),
      );
      expect(fill(), colors.surfaceContainerHighest);
    });

    testWidgets('long content at text scale 2.0 and 320 dp does not overflow', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      for (final brightness in Brightness.values) {
        await tester.pumpWidget(
          _host(
            const AppSurface(
              child: Text(
                'A fairly long line of panel content that has to wrap '
                'across several lines at a large text scale.',
              ),
            ),
            brightness: brightness,
            textScale: 2,
          ),
        );
        expect(tester.takeException(), isNull);
      }
    });

    testWidgets('can be built with const', (tester) async {
      // Compiles only while the constructor and its defaults stay const.
      const surface = AppSurface(elevated: true, child: Text('const'));
      await tester.pumpWidget(_host(surface));
      expect(find.text('const'), findsOneWidget);
    });
  });

  forEachThemeAndWidth(
    'AppSurface look: hairline, cardSmall radius, contrast, no overflow',
    (tester, env) async {
      await pumpThemed(
        tester,
        const AppSurface(
          child: Text('A long line of content that wraps at big text scales'),
        ),
        brightness: env.brightness,
        size: env.size,
        textScale: env.textScale,
      );
      expect(tester.takeException(), isNull);
      final deco =
          tester
                  .widget<Container>(
                    find
                        .descendant(
                          of: find.byType(AppSurface),
                          matching: find.byType(Container),
                        )
                        .first,
                  )
                  .decoration!
              as BoxDecoration;
      final colors = env.isDark ? AppColors.dark : AppColors.light;
      expect(deco.borderRadius, BorderRadius.circular(AppRadius.cardSmall));
      expect((deco.border! as Border).top.color, colors.hairline);
      final scheme = buildAppTheme(brightness: env.brightness).colorScheme;
      expect(
        contrast(scheme.onSurface, deco.color!),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        contrast(scheme.onSurfaceVariant, deco.color!),
        greaterThanOrEqualTo(4.5),
      );
    },
    widths: kRedesignWidths,
    textScales: kRedesignTextScales,
  );
}
