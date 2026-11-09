import 'dart:math' as math;

import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/shared/widgets/primitives/app_pill_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/app_fonts.dart';
import '../../../support/theme_harness.dart';

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
  // Real font metrics only when baselines are being checked or made.
  setUpAll(() async {
    if (goldensEnabled) await loadAppFonts();
  });

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
            AppPillButton(
              label: 'Post',
              variant: AppButtonVariant.navy,
              onPressed: () {},
            ),
            brightness: brightness,
          ),
        );
        await tester.pumpAndSettle(); // the theme change animates
        final ink = tester.widget<Ink>(find.byType(Ink));
        final decoration = ink.decoration! as BoxDecoration;
        expect(decoration.gradient, isNull, reason: '$brightness');
        expect(
          decoration.color,
          brightness == Brightness.dark ? AppPalette.pearl : AppPalette.navy,
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

    testWidgets('the glow is static: it stays under reduced motion', (
      tester,
    ) async {
      await pumpThemed(
        tester,
        AppPillButton(label: 'Post', onPressed: () {}),
        disableAnimations: true,
      );
      final d =
          tester.widget<Ink>(find.byType(Ink)).decoration! as BoxDecoration;
      expect(d.boxShadow, AppShadows.primaryGlow);
      expect(d.gradient, AppGradients.primaryButton);
    });

    testWidgets('singleLine ellipsizes (the form header caps the width)', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          SizedBox(
            width: 120,
            child: AppPillButton(
              label: 'Schedule everything',
              singleLine: true,
              onPressed: () {},
            ),
          ),
          textScale: 2,
        ),
      );
      final text = tester.widget<Text>(find.text('Schedule everything'));
      expect(text.maxLines, 1);
      expect(text.overflow, TextOverflow.ellipsis);
      expect(tester.takeException(), isNull);
    });

    test('default variant is primary and size is regular', () {
      const b = AppPillButton(label: 'x', onPressed: null);
      expect(b.variant, AppButtonVariant.primary);
      expect(b.size, AppButtonSize.regular);
    });

    testWidgets('primary paints the gradient and glow; disabled is flat', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(AppPillButton(label: 'Post', onPressed: () {})),
      );
      var d = tester.widget<Ink>(find.byType(Ink)).decoration! as BoxDecoration;
      expect(d.gradient, AppGradients.primaryButton);
      expect(d.boxShadow, AppShadows.primaryGlow);

      await tester.pumpWidget(
        _host(const AppPillButton(label: 'Post', onPressed: null)),
      );
      d = tester.widget<Ink>(find.byType(Ink)).decoration! as BoxDecoration;
      expect(d.gradient, isNull);
      expect(d.color, isNotNull);
    });

    testWidgets('large is 52dp tall', (tester) async {
      await tester.pumpWidget(
        _host(
          AppPillButton(
            label: 'Go',
            size: AppButtonSize.large,
            onPressed: () {},
          ),
        ),
      );
      expect(tester.getSize(find.byType(Ink)).height, 52);
    });

    test('every variant label pair is >= 4.5:1 in both themes', () {
      for (final brightness in Brightness.values) {
        final theme = buildAppTheme(brightness: brightness);
        final c = theme.extension<AppColors>()!;
        final page = theme.scaffoldBackgroundColor;
        final pairs = <String, double>{
          // Gradient: check the label against both stops.
          for (final (i, stop) in AppGradients.primaryButton.colors.indexed)
            'primary stop $i': _contrast(c.primaryFillLabel, stop),
          'navy': _contrast(c.strongPillLabel, c.strongPillFill),
          'danger': _contrast(c.onDangerFill, c.dangerFill),
          'white': _contrast(AppPalette.navy, AppPalette.white),
          'outline': _contrast(theme.colorScheme.onSurface, page),
          'text': _contrast(c.accentText, page),
          'disabled': _contrast(c.disabledPillLabel, c.disabledPillFill),
        };
        pairs.forEach((name, ratio) {
          expect(ratio, greaterThanOrEqualTo(4.5), reason: '$brightness $name');
        });
        expect(
          _contrast(c.uiBorder, page),
          greaterThanOrEqualTo(3),
          reason: '$brightness outline border',
        );
      }
    });

    testWidgets('danger is the #B42318 fill with a white label', (
      tester,
    ) async {
      for (final brightness in Brightness.values) {
        await tester.pumpWidget(
          _host(
            AppPillButton(
              label: 'Delete',
              variant: AppButtonVariant.danger,
              onPressed: () {},
            ),
            brightness: brightness,
          ),
        );
        await tester.pumpAndSettle();
        final d =
            tester.widget<Ink>(find.byType(Ink)).decoration! as BoxDecoration;
        expect(d.color, AppPalette.danger);
        expect(
          tester.widget<Text>(find.text('Delete')).style?.color,
          AppPalette.white,
        );
      }
    });

    testWidgets('busy under reduced motion shows a still arc', (tester) async {
      await pumpThemed(
        tester,
        AppPillButton(label: 'Post', busy: true, onPressed: () {}),
        disableAnimations: true,
      );
      final p = tester.widget<CircularProgressIndicator>(
        find.byType(CircularProgressIndicator),
      );
      expect(p.value, isNotNull);
    });

    for (final variant in AppButtonVariant.values) {
      forEachThemeAndWidth(
        'AppPillButton ${variant.name}: no overflow, 48dp target, label '
        'wraps in a 320dp row',
        (tester, env) async {
          await pumpThemed(
            tester,
            Center(
              child: SizedBox(
                width: 320,
                child: Row(
                  children: [
                    Expanded(
                      child: AppPillButton(
                        label: 'Post to everyone who follows you',
                        icon: Icons.send,
                        variant: variant,
                        onPressed: () {},
                      ),
                    ),
                  ],
                ),
              ),
            ),
            brightness: env.brightness,
            size: env.size,
            textScale: env.textScale,
          );
          expect(tester.takeException(), isNull);
          final box = tester.getSize(find.byType(AppPillButton));
          expect(box.height, greaterThanOrEqualTo(AppSpacing.minTapTarget));
          final label = tester.widget<Text>(
            find.text('Post to everyone who follows you'),
          );
          expect(label.maxLines, isNull);
          expect(label.overflow, isNot(TextOverflow.ellipsis));
          final para = tester.renderObject<RenderParagraph>(
            find.text('Post to everyone who follows you'),
          );
          expect(para.didExceedMaxLines, isFalse);
          if (env.textScale == 2) {
            // It really wrapped: it is taller than one line of text.
            expect(
              para.size.height,
              greaterThan(para.text.style!.fontSize! * 3),
            );
          }
          await expectGolden(
            tester,
            find.byType(AppPillButton),
            'pill_button_${variant.name}',
            env,
          );
        },
        widths: kRedesignWidths,
        textScales: kRedesignTextScales,
        heights: kRedesignHeights,
      );
    }

    forEachThemeAndWidth(
      'AppPillButton compact meets androidTapTargetGuideline',
      (tester, env) async {
        final handle = tester.ensureSemantics();
        await pumpThemed(
          tester,
          Center(
            child: AppPillButton(
              label: 'Save',
              compact: true,
              onPressed: () {},
            ),
          ),
          brightness: env.brightness,
          size: env.size,
          textScale: env.textScale,
        );
        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
        handle.dispose();
      },
      widths: kRedesignWidths,
      textScales: kRedesignTextScales,
      heights: kRedesignHeights,
    );
  });
}
