import 'dart:math' as math;

import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/shared/widgets/app_pill_button.dart';
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
  group('AppPillButton', () {
    testWidgets('renders in dark and light', (tester) async {
      for (final brightness in Brightness.values) {
        await tester.pumpWidget(
          _host(
            AppPillButton(label: 'Post', onPressed: () {}),
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
        _host(AppPillButton(label: 'Post', onPressed: () => taps++)),
      );

      await tester.tap(find.byType(AppPillButton));
      expect(taps, 1);
    });

    testWidgets('ignores taps when busy, and shows progress', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        _host(
          AppPillButton(label: 'Post', busy: true, onPressed: () => taps++),
        ),
      );

      await tester.tap(find.byType(AppPillButton));
      expect(taps, 0);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('ignores taps when onPressed is null', (tester) async {
      await tester.pumpWidget(
        _host(const AppPillButton(label: 'Post', onPressed: null)),
      );

      await tester.tap(find.byType(AppPillButton));
      expect(tester.takeException(), isNull);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('announces its label exactly once, as a button', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _host(AppPillButton(label: 'Post', onPressed: () {})),
      );

      final node = tester.getSemantics(find.byType(AppPillButton));
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
        const AppPillButton(label: 'Post', onPressed: null),
        AppPillButton(label: 'Post', busy: true, onPressed: () {}),
      ]) {
        await tester.pumpWidget(_host(button));

        expect(
          tester.getSemantics(find.byType(AppPillButton)),
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

    testWidgets('busySemanticsLabel is announced, as a live region, only '
        'while busy; the visible text stays', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _host(
          AppPillButton(
            label: 'Reply',
            busySemanticsLabel: 'Sending reply',
            onPressed: () {},
          ),
        ),
      );
      expect(find.bySemanticsLabel('Reply'), findsOneWidget);
      expect(find.bySemanticsLabel('Sending reply'), findsNothing);

      await tester.pumpWidget(
        _host(
          AppPillButton(
            label: 'Reply',
            busy: true,
            busySemanticsLabel: 'Sending reply',
            onPressed: () {},
          ),
        ),
      );
      expect(find.bySemanticsLabel('Sending reply'), findsOneWidget);
      expect(find.bySemanticsLabel('Reply'), findsNothing);
      expect(
        tester.getSemantics(find.byType(AppPillButton)),
        isSemantics(label: 'Sending reply', isButton: true, isLiveRegion: true),
      );
      expect(find.text('Reply'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('without busySemanticsLabel a busy button is not a live '
        'region', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _host(AppPillButton(label: 'Post', busy: true, onPressed: () {})),
      );
      expect(
        tester.getSemantics(find.byType(AppPillButton)),
        isNot(isSemantics(isLiveRegion: true)),
      );
      handle.dispose();
    });

    testWidgets('meets the minimum tap target, even with a short label', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(AppPillButton(label: 'Go', onPressed: () {})),
      );

      final size = tester.getSize(find.byType(AppPillButton));
      expect(size.height, greaterThanOrEqualTo(AppSpacing.minTapTarget));
      expect(size.width, greaterThanOrEqualTo(AppSpacing.minTapTarget));
    });

    testWidgets('the strong pill label is readable on its fill (>= 4.5:1), '
        'enabled in both themes', (tester) async {
      for (final brightness in Brightness.values) {
        final colors = buildAppTheme(brightness: brightness)
            .extension<AppColors>()!;
        expect(
          _contrast(colors.strongPillLabel, colors.strongPillFill),
          greaterThanOrEqualTo(4.5),
          reason: '$brightness strong pill',
        );
      }
    });

    testWidgets('is the inverse pill: light on dark, dark on light, flat '
        '(no gradient)', (tester) async {
      for (final brightness in Brightness.values) {
        await tester.pumpWidget(
          _host(
            AppPillButton(label: 'Post', onPressed: () {}),
            brightness: brightness,
          ),
        );
        await tester.pumpAndSettle(); // the theme change animates
        final ink = tester.widget<Ink>(find.byType(Ink));
        final decoration = ink.decoration! as BoxDecoration;
        expect(decoration.gradient, isNull, reason: '$brightness');
        expect(
          decoration.color,
          brightness == Brightness.dark
              ? const Color(0xFFEFF3F4)
              : const Color(0xFF0F1419),
        );
      }
    });

    testWidgets('disabled and busy show the flat disabled fill', (
      tester,
    ) async {
      final colors = buildAppTheme(brightness: Brightness.dark)
          .extension<AppColors>()!;
      for (final button in [
        const AppPillButton(label: 'Post', onPressed: null),
        AppPillButton(label: 'Post', busy: true, onPressed: () {}),
      ]) {
        await tester.pumpWidget(_host(button));
        final ink = tester.widget<Ink>(find.byType(Ink));
        expect(
          (ink.decoration! as BoxDecoration).color,
          colors.disabledPillFill,
        );
      }
    });

    testWidgets('compact draws a 36dp pill inside a 48dp tap target', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(AppPillButton(label: 'Post', compact: true, onPressed: () {})),
      );

      expect(
        tester.getSize(find.byType(AppPillButton)).height,
        AppSpacing.minTapTarget,
      );
      expect(tester.getSize(find.byType(Ink)).height, AppSize.pillCompact);
    });

    testWidgets('the regular pill fills the width a form gives it', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          SizedBox(
            width: 300,
            child: AppPillButton(label: 'Continue', onPressed: () {}),
          ),
        ),
      );

      expect(tester.getSize(find.byType(Ink)).width, 300);
      expect(tester.getSize(find.byType(Ink)).height, AppSpacing.minTapTarget);
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
                child: AppPillButton(
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
      const button = AppPillButton(
        label: 'const',
        icon: Icons.send,
        onPressed: null,
      );
      await tester.pumpWidget(_host(button));
      expect(find.text('const'), findsOneWidget);
    });
  });
}
