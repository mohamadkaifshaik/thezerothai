import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dzeroth/core/theme/app_theme.dart';

import '../../support/contrast.dart';

/// Source files under `lib/` that must obey the colour rules (everything
/// except generated code and the theme file itself).
Iterable<File> _appSources() => Directory('lib')
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart'))
    .where((f) {
      final p = f.path.replaceAll('\\', '/');
      return !p.startsWith('lib/gen/') && p != 'lib/core/theme/app_theme.dart';
    });

/// [fg] composited over [bg] (contrast() ignores alpha).
Color _over(Color fg, Color bg) => Color.alphaBlend(fg, bg);

void main() {
  for (final entry in {'light': appLightTheme, 'dark': appDarkTheme}.entries) {
    test('${entry.key} snackbar action, close icon and text meet WCAG AA', () {
      final snack = entry.value.snackBarTheme;
      final bg = snack.backgroundColor!;
      expect(snack.actionTextColor, isNotNull);
      expect(snack.closeIconColor, isNotNull);
      expect(contrast(snack.actionTextColor!, bg), greaterThanOrEqualTo(4.5));
      // Icons are non-text UI: WCAG 1.4.11 asks for 3:1.
      expect(contrast(snack.closeIconColor!, bg), greaterThanOrEqualTo(3.0));
      expect(
        contrast(snack.contentTextStyle!.color!, bg),
        greaterThanOrEqualTo(4.5),
      );
    });
  }

  for (final entry in {'light': appLightTheme, 'dark': appDarkTheme}.entries) {
    final name = entry.key;
    final theme = entry.value;
    final colors = theme.colorScheme;
    final app = theme.extension<AppColors>()!;
    final steps = {
      'surface': colors.surface,
      'surfaceContainerLowest': colors.surfaceContainerLowest,
      'surfaceContainerLow': colors.surfaceContainerLow,
      'surfaceContainer': colors.surfaceContainer,
      'surfaceContainerHigh': colors.surfaceContainerHigh,
      'surfaceContainerHighest': colors.surfaceContainerHighest,
    };

    void textOnEveryStep(Color c, String role) {
      for (final step in steps.entries) {
        expect(
          contrast(c, step.value),
          greaterThanOrEqualTo(4.5),
          reason: '$role on ${step.key}',
        );
      }
    }

    group('$name palette', () {
      test('builds a Material 3 theme of the right brightness', () {
        expect(theme.useMaterial3, isTrue);
        expect(
          colors.brightness,
          name == 'dark' ? Brightness.dark : Brightness.light,
        );
        expect(
          buildAppTheme(brightness: colors.brightness).colorScheme.primary,
          colors.primary,
        );
      });

      test('onSurface is >= 4.5:1 on every container step', () {
        textOnEveryStep(colors.onSurface, 'onSurface');
      });

      test('onSurfaceVariant (also the field hint) is >= 4.5:1 on surface, '
          'surfaceContainer and surfaceContainerHigh', () {
        for (final bg in [
          colors.surface,
          colors.surfaceContainer,
          colors.surfaceContainerHigh,
        ]) {
          expect(
            contrast(colors.onSurfaceVariant, bg),
            greaterThanOrEqualTo(4.5),
            reason: 'onSurfaceVariant on $bg',
          );
        }
      });

      test('secondaryOnRaised is >= 4.5:1 on every step', () {
        textOnEveryStep(app.secondaryOnRaised, 'secondaryOnRaised');
      });

      test('text roles are >= 4.5:1 on every step', () {
        textOnEveryStep(app.accentText, 'accentText');
        textOnEveryStep(app.text2, 'text2');
        textOnEveryStep(colors.error, 'error (danger text)');
        // State colours also tint the action counts, so they are text-safe.
        textOnEveryStep(app.like, 'like');
        textOnEveryStep(app.repost, 'repost');
        textOnEveryStep(app.live, 'live');
        textOnEveryStep(app.recommendation, 'recommendation');
        textOnEveryStep(app.positive, 'positive');
      });

      test('primary text is >= 4.5:1 on surface and onPrimary on primary', () {
        expect(
          contrast(colors.primary, colors.surface),
          greaterThanOrEqualTo(4.5),
        );
        expect(
          contrast(colors.onPrimary, colors.primary),
          greaterThanOrEqualTo(4.5),
        );
        expect(
          contrast(colors.onSecondary, colors.secondary),
          greaterThanOrEqualTo(4.5),
        );
        expect(
          contrast(colors.onInverseSurface, colors.inverseSurface),
          greaterThanOrEqualTo(4.5),
        );
        expect(
          contrast(colors.inversePrimary, colors.inverseSurface),
          greaterThanOrEqualTo(4.5),
        );
      });

      test('onError is >= 4.5:1 on error; the danger fill label too', () {
        expect(
          contrast(colors.onError, colors.error),
          greaterThanOrEqualTo(4.5),
        );
        expect(
          contrast(app.onDangerFill, app.dangerFill),
          greaterThanOrEqualTo(4.5),
        );
      });

      test('outline and uiBorder are >= 3:1 on surface and surfaceContainer '
          '(component boundaries)', () {
        for (final c in [colors.outline, app.uiBorder]) {
          expect(contrast(c, colors.surface), greaterThanOrEqualTo(3.0));
          expect(
            contrast(c, colors.surfaceContainer),
            greaterThanOrEqualTo(3.0),
          );
        }
      });

      test('the selected indicator is >= 3:1 on surface (non-text UI) and '
          'text-safe', () {
        expect(
          contrast(app.selectedIndicator, colors.surface),
          greaterThanOrEqualTo(4.5),
        );
      });

      test('the strong pill label is >= 4.5:1 on its fill', () {
        expect(
          contrast(app.strongPillLabel, app.strongPillFill),
          greaterThanOrEqualTo(4.5),
        );
      });

      test('the primary gradient label is >= 4.5:1 on both ends', () {
        for (final end in app.primaryFillGradient.colors) {
          expect(
            contrast(app.primaryFillLabel, end),
            greaterThanOrEqualTo(4.5),
          );
        }
      });

      test('the floating nav bar is navy with AA glyphs', () {
        expect(app.navBarSurface, AppPalette.navy);
        expect(app.navBarSelected, AppPalette.tealElectric);
        expect(app.navBarUnselected, AppPalette.mutedOnDark);
        expect(
          contrast(app.navBarSelected, app.navBarSurface),
          greaterThanOrEqualTo(4.5),
        );
        expect(
          contrast(app.navBarUnselected, app.navBarSurface),
          greaterThanOrEqualTo(4.5),
        );
      });

      test('the hairline stays visible and is not heavier than 3:1', () {
        for (final hairline in [colors.outlineVariant, app.hairline]) {
          final ratio = contrast(
            _over(hairline, colors.surface),
            colors.surface,
          );
          expect(ratio, greaterThanOrEqualTo(1.1));
          expect(ratio, lessThan(3.0));
        }
      });

      test('tertiary has no role: it mirrors primary', () {
        expect(colors.tertiary, colors.primary);
        expect(colors.onTertiary, colors.onPrimary);
      });

      test('modal barriers use the theme scrim', () {
        expect(app.scrim, AppPalette.scrim);
        expect(theme.dialogTheme.barrierColor, app.scrim);
        expect(theme.bottomSheetTheme.modalBarrierColor, app.scrim);
        expect(theme.drawerTheme.scrimColor, app.scrim);
        expect(theme.drawerTheme.width, AppSize.drawerWidth);
      });

      test('AppColors lerp and copyWith carry every role', () {
        final other = name == 'dark' ? AppColors.light : AppColors.dark;
        expect(app.lerp(other, 0).primaryFillGradient, app.primaryFillGradient);
        expect(app.lerp(other, 1).navBarUnselected, other.navBarUnselected);
        expect(app.lerp(other, 1).text2, other.text2);
        expect(app.copyWith(hairline: other.hairline).hairline, other.hairline);
        expect(app.copyWith().selectedIndicator, app.selectedIndicator);
      });
    });
  }

  test('dark surfaces layer strictly lighter, starting at navyDeep', () {
    final colors = appDarkTheme.colorScheme;
    final ladder = [
      colors.surfaceContainerLowest,
      colors.surface,
      colors.surfaceContainerLow,
      colors.surfaceContainer,
      colors.surfaceContainerHigh,
      colors.surfaceContainerHighest,
    ];
    for (var i = 1; i < ladder.length; i++) {
      expect(
        ladder[i].computeLuminance(),
        greaterThan(ladder[i - 1].computeLuminance()),
        reason: 'layer $i is lighter than layer ${i - 1}',
      );
    }
    expect(colors.surfaceContainerLowest, AppPalette.navyDeep);
  });

  test('dark scheme (ADR-0033, navy; D2 and D4)', () {
    final colors = appDarkTheme.colorScheme;
    expect(colors.surfaceContainerLowest, AppPalette.navyDeep);
    expect(colors.surface, AppPalette.navy);
    expect(colors.surfaceContainerLow, AppPalette.darkContainerLow);
    expect(colors.surfaceContainer, AppPalette.darkContainer);
    expect(colors.surfaceContainerHigh, AppPalette.navy2);
    expect(colors.surfaceContainerHighest, AppPalette.darkContainerHighest);
    expect(colors.onSurface, AppPalette.pearl);
    expect(colors.onSurfaceVariant, AppPalette.mutedOnDark);
    expect(colors.primary, AppPalette.tealElectric);
    expect(colors.onPrimary, AppPalette.navy);
    expect(colors.secondary, AppPalette.pearl);
    expect(colors.onSecondary, AppPalette.navy);
    expect(colors.error, AppPalette.dangerOnDark);
    expect(colors.onError, AppPalette.navy);
    expect(colors.outline, AppPalette.uiBorderOnDark);
    expect(colors.outlineVariant, AppPalette.hairlineDark);
    expect(colors.inverseSurface, AppPalette.pearl);
    final app = appDarkTheme.extension<AppColors>()!;
    expect(app.accentText, AppPalette.tealElectric);
    expect(app.strongPillFill, AppPalette.pearl);
    expect(app.strongPillLabel, AppPalette.navy);
    expect(app.selectedIndicator, AppPalette.tealElectric);
    expect(app.uiBorder, AppPalette.uiBorderOnDark);
    expect(app.hairline, AppPalette.hairlineDark);
    expect(app.like, AppPalette.dangerOnDark);
    expect(app.repost, AppPalette.tealElectric);
    expect(app.live, AppPalette.dangerOnDark);
    expect(app.recommendation, AppPalette.tealElectric);
  });

  test('light scheme (ADR-0033, pearl)', () {
    final colors = appLightTheme.colorScheme;
    expect(colors.surface, AppPalette.pearl);
    expect(colors.surfaceContainerLowest, AppPalette.white);
    expect(colors.surfaceContainerLow, const Color(0xFFFAF9F6));
    expect(colors.surfaceContainer, AppPalette.white);
    expect(colors.surfaceContainerHigh, const Color(0xFFEEF1F4));
    expect(colors.surfaceContainerHighest, const Color(0xFFE6EAEE));
    expect(colors.onSurface, AppPalette.navy);
    expect(colors.onSurfaceVariant, AppPalette.mutedOnLight);
    expect(colors.primary, AppPalette.tealText);
    expect(colors.onPrimary, AppPalette.white);
    expect(colors.secondary, AppPalette.navy);
    expect(colors.onSecondary, AppPalette.pearl);
    expect(colors.error, AppPalette.danger);
    expect(colors.onError, AppPalette.white);
    expect(colors.outline, AppPalette.uiBorderOnLight);
    expect(colors.outlineVariant, AppPalette.hairlineLight);
    expect(colors.inverseSurface, AppPalette.navy);
    expect(colors.scrim, AppPalette.navyDeep);
    final app = appLightTheme.extension<AppColors>()!;
    expect(app.accentText, AppPalette.tealText);
    expect(app.strongPillFill, AppPalette.navy);
    expect(app.strongPillLabel, AppPalette.pearl);
    expect(app.selectedIndicator, AppPalette.tealText);
    expect(app.uiBorder, AppPalette.uiBorderOnLight);
    expect(app.hairline, AppPalette.hairlineLight);
    expect(app.text2, AppPalette.text2);
    expect(app.like, AppPalette.danger);
    expect(app.repost, AppPalette.tealText);
    expect(app.live, AppPalette.danger);
    expect(app.recommendation, AppPalette.tealText);
  });

  test('fills shared by both themes', () {
    for (final app in [AppColors.light, AppColors.dark]) {
      expect(app.primaryFillGradient, AppGradients.primaryButton);
      expect(app.primaryFillLabel, AppPalette.navy);
      expect(app.dangerFill, AppPalette.danger);
      expect(app.onDangerFill, AppPalette.white);
      expect(app.navBarSurface, AppPalette.navy);
    }
    expect(AppColors.photoBackground, const Color(0xFF000000));
  });

  test('the default FilledButton is the strong inverse pill', () {
    for (final theme in [appLightTheme, appDarkTheme]) {
      final app = theme.extension<AppColors>()!;
      final style = theme.filledButtonTheme.style!;
      expect(style.backgroundColor!.resolve({}), app.strongPillFill);
      expect(style.foregroundColor!.resolve({}), app.strongPillLabel);
      expect(
        style.backgroundColor!.resolve({WidgetState.disabled}),
        app.disabledPillFill,
      );
    }
  });

  test('the type scale is DM Sans and Manrope (ADR-0033; typography_test)', () {
    for (final theme in [appLightTheme, appDarkTheme]) {
      final text = theme.textTheme;
      expect(text.displayLarge!.fontFamily, AppFonts.display);
      expect(text.titleLarge!.fontFamily, AppFonts.display);
      expect(text.titleLarge!.fontSize, 20);
      expect(text.titleLarge!.fontWeight, FontWeight.w800);
      expect(text.bodyLarge!.fontFamily, AppFonts.body);
      expect(text.bodyLarge!.fontSize, 15);
      expect(text.bodyLarge!.height, closeTo(1.42, 0.001));
      expect(text.titleSmall!.fontSize, 15);
      expect(text.titleSmall!.fontWeight, FontWeight.w700);
      expect(text.headlineSmall!.fontSize, 20);
    }
  });

  test('size tokens match the research values', () {
    expect(AppSpacing.smd, 12);
    expect(AppSize.tabIndicator, 4);
    expect(AppSize.headerRow * 2, 106);
    expect(AppSize.contentMax, 600);
    expect(AppSize.sideColumn, 350);
    expect(AppSize.drawerWidth, 277);
    expect(AppSize.drawerRow, 56);
    expect(AppSize.avatarMd, 40);
    expect(AppSize.avatarSm, 32);
    expect(AppIconSize.action, 16);
    expect(AppBreakpoints.mobile, 600);
    expect(AppBreakpoints.tablet, 1200);
  });

  group('gradients only via AppGradients (ADR-0033 §6)', () {
    test('no gradient, no seed colour and no tertiary slot in use', () {
      final offenders = <String>[];
      for (final file in _appSources()) {
        final text = file.readAsStringSync();
        for (final banned in [
          'LinearGradient',
          'RadialGradient',
          'SweepGradient',
          'fromSeed',
          'colors.tertiary',
          'colorScheme.tertiary',
        ]) {
          if (text.contains(banned)) offenders.add('${file.path}: $banned');
        }
      }
      expect(offenders, isEmpty);
    });

    test('no raw colour literal outside app_theme.dart', () {
      final literal = RegExp(r'Color\(\s*0x');
      final named = RegExp(r'(?<![A-Za-z])Colors\.(?!transparent\b)\w+');
      final offenders = <String>[];
      for (final file in _appSources()) {
        final lines = file.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          final line = lines[i];
          if (line.trimLeft().startsWith('//')) continue;
          if (literal.hasMatch(line) || named.hasMatch(line)) {
            offenders.add('${file.path}:${i + 1}: ${line.trim()}');
          }
        }
      }
      expect(offenders, isEmpty);
    });
  });

  group('redesign tokens', () {
    test('palette matches tokens.json with the a11y overrides', () {
      expect(AppPalette.navy, const Color(0xFF0D1528));
      expect(AppPalette.navy2, const Color(0xFF1B2A44));
      expect(AppPalette.navyDeep, const Color(0xFF08101F));
      expect(AppPalette.pearl, const Color(0xFFF6F4EF));
      expect(AppPalette.white, const Color(0xFFFFFFFF));
      expect(AppPalette.teal, const Color(0xFF12B8A6));
      expect(AppPalette.tealDark, const Color(0xFF0B8C7F));
      expect(AppPalette.tealElectric, const Color(0xFF19D3BE));
      expect(AppPalette.text2, const Color(0xFF2A3446));
      expect(AppPalette.tealText, const Color(0xFF087066));
      expect(AppPalette.uiBorderOnLight, const Color(0xFF7A8392));
      expect(AppPalette.uiBorderOnDark, const Color(0xFF7B879B));
      expect(AppPalette.mutedOnLight, const Color(0xFF5B6475));
      expect(AppPalette.mutedOnDark, const Color(0xFF9AA3B2));
      expect(AppPalette.danger, const Color(0xFFB42318));
      expect(AppPalette.dangerOnDark, const Color(0xFFF97066));
      expect(AppPalette.hairlineLight, const Color(0x140D1528));
      expect(AppPalette.hairlineDark, const Color(0x1AF6F4EF));
      expect(AppPalette.scrim, const Color(0x7A08101F));
    });

    test('dark container ladder (D4)', () {
      expect(AppPalette.darkContainerLowest, const Color(0xFF08101F));
      expect(AppPalette.darkSurface, const Color(0xFF0D1528));
      expect(AppPalette.darkContainerLow, const Color(0xFF121C33));
      expect(AppPalette.darkContainer, const Color(0xFF16223B));
      expect(AppPalette.darkContainerHigh, const Color(0xFF1B2A44));
      expect(AppPalette.darkContainerHighest, const Color(0xFF22324F));
      final ladder = [
        AppPalette.darkContainerLowest,
        AppPalette.darkSurface,
        AppPalette.darkContainerLow,
        AppPalette.darkContainer,
        AppPalette.darkContainerHigh,
        AppPalette.darkContainerHighest,
      ];
      for (final c in ladder) {
        expect(contrast(AppPalette.mutedOnDark, c), greaterThanOrEqualTo(4.5));
        expect(contrast(AppPalette.tealElectric, c), greaterThanOrEqualTo(4.5));
        expect(contrast(AppPalette.dangerOnDark, c), greaterThanOrEqualTo(4.5));
        expect(contrast(AppPalette.uiBorderOnDark, c), greaterThanOrEqualTo(3));
      }
    });

    test('gradients', () {
      expect(AppGradients.primaryButton.colors, const [
        Color(0xFF19D3BE),
        Color(0xFF12B8A6),
      ]);
      expect(AppGradients.mineBubble.colors, AppGradients.primaryButton.colors);
      expect(AppGradients.primaryButton.begin, Alignment.topLeft);
      expect(AppGradients.primaryButton.end, Alignment.bottomRight);
      expect(AppGradients.card.colors, const [
        Color(0xFFFFFFFF),
        Color(0xFFEEF1F4),
      ]);
      expect(AppGradients.lightBubble.colors, const [
        Color(0xFFFFFFFF),
        Color(0xFFE6EAEE),
      ]);
      expect(AppGradients.darkCard.colors, const [
        Color(0xFF1B2A44),
        Color(0xFF0D1528),
      ]);
      expect(AppGradients.hero.colors, const [
        Color(0xFF1B2A44),
        Color(0xFF0D1528),
        Color(0xFF08101F),
      ]);
      expect(AppGradients.hero.stops, const [0, 0.55, 1]);
      expect(AppGradients.hero.radius, 1.2);
      expect(AppGradients.hero.center, const Alignment(0.7, -1));
    });

    test('shadows', () {
      BoxShadow s(List<BoxShadow> l) => l.single;
      expect(s(AppShadows.card).offset, const Offset(0, 11));
      expect(s(AppShadows.card).blurRadius, 25);
      expect(s(AppShadows.card).color.a, closeTo(0.18, 0.005));
      expect(s(AppShadows.brand).color.a, closeTo(0.22, 0.005));
      expect(s(AppShadows.primaryGlow).offset, const Offset(0, 10));
      expect(s(AppShadows.primaryGlow).blurRadius, 26);
      expect(s(AppShadows.primaryGlow).color.a, closeTo(0.35, 0.005));
      expect(s(AppShadows.navBar).offset, const Offset(0, 14));
      expect(s(AppShadows.navBar).blurRadius, 30);
      expect(s(AppShadows.navBar).color.a, closeTo(0.35, 0.005));
    });

    test('radius and size', () {
      expect(AppRadius.card, 24);
      expect(AppRadius.cardSmall, 20);
      expect(AppRadius.field, 16);
      expect(AppRadius.tile, 14);
      expect(AppRadius.bubble, 22);
      expect(AppRadius.bubbleTail, 6);
      expect(AppRadius.sheetTop, 32);
      expect(
        [AppRadius.sm, AppRadius.md, AppRadius.lg, AppRadius.pill],
        [8, 12, 16, 999],
      );
      expect(AppSize.buttonHeight, 52);
      expect(AppSize.buttonHeightLarge, 56);
      expect(AppSize.floatingNavHeight, 66);
      expect(AppSize.floatingNavInset, 20);
      expect(AppSize.floatingNavBottom, 24);
      expect(AppSize.fabRedesign, 58);
      expect(AppSize.avatarRow, 44);
      expect(AppSize.avatarPost, 42);
      expect(AppSize.avatarLg, 56);
      expect(AppSize.avatarXl, 120);
      expect(AppSize.bottomNav, 56);
      expect(AppSize.fab, 56);
    });

    test('typography tokens', () {
      expect(AppTypeTokens.displaySizes, [28, 32, 36, 40, 48, 52]);
      expect(AppTypeTokens.displayTracking, -0.035);
      expect(AppTypeTokens.displayLineHeight, 1.02);
      expect(AppTypeTokens.eyebrowSize, 12);
      expect(AppTypeTokens.eyebrowWeight, FontWeight.w700);
      expect(AppTypeTokens.eyebrowTracking, 0.24);
      expect(AppTypeTokens.wordmarkSize, 15);
      expect(AppTypeTokens.wordmarkTracking, 0.13);
      expect(AppTypeTokens.bodySize, 15);
      expect(AppTypeTokens.bodyLineHeight, 1.42);
      expect(AppTypeTokens.focalPostSize, 17);
      expect(AppTypeTokens.focalPostLineHeight, 24);
      expect(AppTypeTokens.weightDisplay, FontWeight.w800);
      expect(AppTypeTokens.weightUi, FontWeight.w700);
      expect(AppTypeTokens.weightLabel, FontWeight.w600);
      expect(AppTypeTokens.weightBody, FontWeight.w500);
    });

    test('motion curves and durations', () {
      expect(AppMotion.expoOut, const Cubic(0.16, 1, 0.3, 1));
      expect(AppMotion.backOut, const Cubic(0.34, 1.56, 0.64, 1));
      expect(AppMotion.expoOutShort.inMilliseconds, 300);
      expect(AppMotion.expoOutLong.inMilliseconds, 450);
      expect(AppMotion.backOutDuration.inMilliseconds, 350);
      expect(AppMotion.headlineStaggerMin.inMilliseconds, 80);
      expect(AppMotion.headlineStaggerMax.inMilliseconds, 200);
    });

    testWidgets('AppMotion.of returns zero movement under reduced motion', (
      tester,
    ) async {
      late AppMotion normal;
      late AppMotion reduced;
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(),
          child: Builder(
            builder: (c) {
              normal = AppMotion.of(c);
              return const SizedBox();
            },
          ),
        ),
      );
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Builder(
            builder: (c) {
              reduced = AppMotion.of(c);
              return const SizedBox();
            },
          ),
        ),
      );
      expect(normal.offset(24), 24);
      expect(reduced.movement, isFalse);
      expect(reduced.offset(24), 0);
    });

    test('contrast table (ADR-0033 section 1.3)', () {
      const ee = Color(0xFFEEF1F4);
      void atLeast(Color a, Color b, double min, double expected) {
        final r = contrast(a, b);
        expect(r, greaterThanOrEqualTo(min), reason: '$a on $b = $r');
        expect(r, closeTo(expected, 0.02), reason: '$a on $b = $r');
      }

      // tealText on light.
      atLeast(AppPalette.tealText, AppPalette.pearl, 4.5, 5.43);
      atLeast(AppPalette.tealText, AppPalette.white, 4.5, 5.97);
      atLeast(AppPalette.tealText, ee, 4.5, 5.26);
      // Borders.
      atLeast(AppPalette.uiBorderOnLight, AppPalette.pearl, 3, 3.48);
      atLeast(AppPalette.uiBorderOnLight, AppPalette.white, 3, 3.83);
      atLeast(AppPalette.uiBorderOnLight, ee, 3, 3.37);
      atLeast(AppPalette.uiBorderOnDark, AppPalette.navy, 3, 5.01);
      atLeast(AppPalette.uiBorderOnDark, AppPalette.navy2, 3, 3.96);
      atLeast(AppPalette.uiBorderOnDark, AppPalette.navyDeep, 3, 5.24);
      // Muted text.
      atLeast(AppPalette.mutedOnLight, AppPalette.pearl, 4.5, 5.42);
      atLeast(AppPalette.mutedOnLight, AppPalette.white, 4.5, 5.96);
      atLeast(AppPalette.mutedOnDark, AppPalette.navy, 4.5, 7.15);
      atLeast(AppPalette.mutedOnDark, AppPalette.navy2, 4.5, 5.65);
      // Label on the primary gradient (both ends).
      atLeast(AppPalette.navy, AppPalette.tealElectric, 4.5, 9.61);
      atLeast(AppPalette.navy, AppPalette.teal, 4.5, 7.30);
      // Teal text and indicator on dark.
      atLeast(AppPalette.tealElectric, AppPalette.navy, 4.5, 9.61);
      atLeast(AppPalette.tealElectric, AppPalette.navy2, 4.5, 7.60);
      // onPrimary (light).
      atLeast(AppPalette.white, AppPalette.tealText, 4.5, 5.97);
      // Danger.
      atLeast(AppPalette.danger, AppPalette.pearl, 4.5, 5.98);
      atLeast(AppPalette.white, AppPalette.danger, 4.5, 6.57);
      expect(
        contrast(AppPalette.danger, AppPalette.navy),
        lessThan(3),
        reason: 'D2: danger fill is not usable as text on navy (2.77)',
      );
      atLeast(AppPalette.dangerOnDark, AppPalette.navy, 4.5, 6.53);
      atLeast(AppPalette.dangerOnDark, AppPalette.navy2, 4.5, 5.16);
    });

    test('tealDark is large display text only', () {
      final r = contrast(AppPalette.tealDark, AppPalette.pearl);
      expect(r, closeTo(3.77, 0.02));
      expect(r, greaterThanOrEqualTo(3));
      expect(r, lessThan(4.5), reason: 'fails body text: keep it >= 24 sp');
    });

    test('teal accents fail on light, so they are never text there', () {
      expect(contrast(AppPalette.teal, AppPalette.pearl), closeTo(2.27, 0.02));
      expect(contrast(AppPalette.tealElectric, AppPalette.pearl), lessThan(3));
      // And the active light theme assigns neither to a text role.
      final scheme = appLightTheme.colorScheme;
      for (final c in [
        scheme.onSurface,
        scheme.onSurfaceVariant,
        scheme.onPrimary,
        scheme.onSecondary,
        appLightTheme.textTheme.bodyMedium?.color,
        appLightTheme.textTheme.bodySmall?.color,
        appLightTheme.textTheme.titleMedium?.color,
      ]) {
        expect(c, isNot(AppPalette.teal));
        expect(c, isNot(AppPalette.tealElectric));
      }
    });
  });

  group('auth palette contrast', () {
    void check(String label, Color fg, Map<String, Color> bgs) {
      for (final bg in bgs.entries) {
        test('$label on ${bg.key} is at least 4.5:1', () {
          expect(contrast(fg, bg.value), greaterThanOrEqualTo(4.5));
        });
      }
    }

    check('muted', AppAuthPalette.muted, {
      'paper': AppAuthPalette.paper,
      'white': AppAuthPalette.white,
      'tabTrack': AppAuthPalette.tabTrack,
      'welcome': AppAuthPalette.welcome,
    });
    check('link', AppAuthPalette.link, {'paper': AppAuthPalette.paper});
    check('darkMuted', AppAuthPalette.darkMuted, {
      'navy': AppAuthPalette.navy,
      'darkField': AppAuthPalette.darkField,
      'darkTabTrack': AppAuthPalette.darkTabTrack,
      'darkSelectedTab': AppAuthPalette.darkSelectedTab,
      'darkWelcome': AppAuthPalette.darkWelcome,
    });
  });
}
