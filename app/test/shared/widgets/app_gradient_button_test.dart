import 'dart:math' as math;

import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/shared/widgets/app_gradient_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(
  Widget child, {
  Brightness brightness = Brightness.dark,
  double textScale = 1,
}) => MaterialApp(
  theme: buildAppTheme(brightness: brightness),
  home: MediaQuery(
    data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
    child: Scaffold(body: Center(child: child)),
  ),
);

double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

void main() {
  group('AppGradientButton', () {
    testWidgets('renders in dark and light', (tester) async {
      for (final brightness in Brightness.values) {
        await tester.pumpWidget(
          _host(
            AppGradientButton(label: 'Post', onPressed: () {}),
            brightness: brightness,
          ),
        );
        expect(find.text('Post'), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
    });

    testWidgets('taps work when enabled', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        _host(AppGradientButton(label: 'Post', onPressed: () => taps++)),
      );

      await tester.tap(find.byType(AppGradientButton));
      expect(taps, 1);
    });

    testWidgets('ignores taps when busy, and shows progress', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        _host(
          AppGradientButton(label: 'Post', busy: true, onPressed: () => taps++),
        ),
      );

      await tester.tap(find.byType(AppGradientButton));
      expect(taps, 0);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('ignores taps when onPressed is null', (tester) async {
      await tester.pumpWidget(
        _host(const AppGradientButton(label: 'Post', onPressed: null)),
      );

      await tester.tap(find.byType(AppGradientButton));
      expect(tester.takeException(), isNull);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('announces its label exactly once, as a button', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _host(AppGradientButton(label: 'Post', onPressed: () {})),
      );

      final node = tester.getSemantics(find.byType(AppGradientButton));
      expect(node.label, 'Post');
      expect(
        node,
        matchesSemantics(
          label: 'Post',
          isButton: true,
          isEnabled: true,
          hasEnabledState: true,
          hasTapAction: true,
        ),
      );
      expect(find.bySemanticsLabel('Post'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('is announced as a disabled button when busy or null', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      for (final button in [
        const AppGradientButton(label: 'Post', onPressed: null),
        AppGradientButton(label: 'Post', busy: true, onPressed: () {}),
      ]) {
        await tester.pumpWidget(_host(button));

        expect(
          tester.getSemantics(find.byType(AppGradientButton)),
          matchesSemantics(
            label: 'Post',
            isButton: true,
            hasEnabledState: true,
          ),
        );
        expect(find.bySemanticsLabel('Post'), findsOneWidget);
      }
      handle.dispose();
    });

    testWidgets('meets the minimum tap target, even with a short label', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(AppGradientButton(label: 'Go', onPressed: () {})),
      );

      final size = tester.getSize(find.byType(AppGradientButton));
      expect(size.height, greaterThanOrEqualTo(AppSpacing.minTapTarget));
      expect(size.width, greaterThanOrEqualTo(AppSpacing.minTapTarget));
    });

    testWidgets('label text is readable on the gradient (>= 4.5:1)', (
      tester,
    ) async {
      for (final brightness in Brightness.values) {
        final colors = buildAppTheme(brightness: brightness).colorScheme;
        // Enabled: primary -> tertiary; disabled/busy: flat onSurfaceVariant.
        for (final stop in [
          colors.primary,
          colors.tertiary,
          colors.onSurfaceVariant,
        ]) {
          expect(
            _contrast(colors.onPrimary, stop),
            greaterThanOrEqualTo(4.5),
            reason: '$brightness onPrimary on $stop',
          );
        }
      }
    });

    testWidgets('long label with icon at 2.0 scale and 320 dp does not '
        'overflow', (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      for (final brightness in Brightness.values) {
        for (final busy in [false, true]) {
          await tester.pumpWidget(
            _host(
              SizedBox(
                width: 280,
                child: AppGradientButton(
                  label: 'Post to everyone who follows you',
                  icon: Icons.send,
                  busy: busy,
                  onPressed: () {},
                ),
              ),
              brightness: brightness,
              textScale: 2,
            ),
          );
          expect(tester.takeException(), isNull);
        }
      }
    });

    testWidgets('can be built with const', (tester) async {
      // Compiles only while the constructor stays const.
      const button = AppGradientButton(
        label: 'const',
        icon: Icons.send,
        onPressed: null,
      );
      await tester.pumpWidget(_host(button));
      expect(find.text('const'), findsOneWidget);
    });
  });
}
