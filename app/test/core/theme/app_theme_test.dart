import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dzeroth/core/theme/app_theme.dart';

double _contrast(Color a, Color b) {
  final l1 = a.computeLuminance();
  final l2 = b.computeLuminance();
  return (math.max(l1, l2) + 0.05) / (math.min(l1, l2) + 0.05);
}

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

void main() {
  for (final entry in {'light': appLightTheme, 'dark': appDarkTheme}.entries) {
    test('${entry.key} snackbar action and close icon meet WCAG AA', () {
      final snack = entry.value.snackBarTheme;
      final bg = snack.backgroundColor!;
      expect(snack.actionTextColor, isNotNull);
      expect(snack.closeIconColor, isNotNull);
      expect(_contrast(snack.actionTextColor!, bg), greaterThanOrEqualTo(4.5));
      // Icons are non-text UI: WCAG 1.4.11 asks for 3:1.
      expect(_contrast(snack.closeIconColor!, bg), greaterThanOrEqualTo(3.0));
    });
  }

  for (final entry in {'light': appLightTheme, 'dark': appDarkTheme}.entries) {
    final name = entry.key;
    final theme = entry.value;
    final colors = theme.colorScheme;
    final app = theme.extension<AppColors>()!;
    final raised = {
      'surfaceContainerLow': colors.surfaceContainerLow,
      'surfaceContainer': colors.surfaceContainer,
      'surfaceContainerHigh': colors.surfaceContainerHigh,
      'surfaceContainerHighest': colors.surfaceContainerHighest,
    };

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

      test('onSurface is >= 4.5:1 on every surface step', () {
        expect(_contrast(colors.onSurface, colors.surface), greaterThan(4.5));
        for (final layer in raised.entries) {
          expect(
            _contrast(colors.onSurface, layer.value),
            greaterThanOrEqualTo(4.5),
            reason: 'onSurface on ${layer.key}',
          );
        }
      });

      test('onSurfaceVariant is >= 4.5:1 on the page surface', () {
        expect(
          _contrast(colors.onSurfaceVariant, colors.surface),
          greaterThanOrEqualTo(4.5),
        );
      });

      test('secondary text on a raised surface uses secondaryOnRaised '
          '(>= 4.5:1 on every step)', () {
        for (final layer in raised.entries) {
          expect(
            _contrast(app.secondaryOnRaised, layer.value),
            greaterThanOrEqualTo(4.5),
            reason: 'secondaryOnRaised on ${layer.key}',
          );
        }
      });

      test('accentText is >= 4.5:1 on the page surface', () {
        expect(
          _contrast(app.accentText, colors.surface),
          greaterThanOrEqualTo(4.5),
        );
      });

      test('the strong pill label is >= 4.5:1 on its fill', () {
        expect(
          _contrast(app.strongPillLabel, app.strongPillFill),
          greaterThanOrEqualTo(4.5),
        );
      });

      test('the accent fill is >= 3:1 against the page (non-text UI) and '
          'the FAB glyph on it too', () {
        // Dark 7.0:1; light 3.0:1 (X's own blue on white). Used for fills,
        // indicators and icons; small text uses accentText instead.
        expect(
          _contrast(colors.primary, colors.surface),
          greaterThanOrEqualTo(3.0),
        );
        expect(
          _contrast(colors.onPrimary, colors.primary),
          greaterThanOrEqualTo(3.0),
        );
      });

      test('the hairline stays visible and is not heavier than 3:1', () {
        final ratio = _contrast(colors.outlineVariant, colors.surface);
        expect(ratio, greaterThanOrEqualTo(1.1));
        expect(ratio, lessThan(3.0));
      });

      test('there is no separate tertiary: no gradient any more', () {
        expect(colors.tertiary, colors.primary);
      });

      test('the accent is X blue in both themes', () {
        expect(colors.primary, const Color(0xFF1D9BF0));
      });

      test('semantic colours are the X state colours', () {
        expect(app.like, const Color(0xFFF91880));
        expect(app.repost, const Color(0xFF00BA7C));
        expect(app.live, const Color(0xFFF91880));
        expect(app.recommendation, const Color(0xFF794BC4));
      });

      test('modal barriers use the theme scrim', () {
        expect(theme.dialogTheme.barrierColor, app.scrim);
        expect(theme.bottomSheetTheme.modalBarrierColor, app.scrim);
        expect(theme.drawerTheme.scrimColor, app.scrim);
        expect(theme.drawerTheme.width, AppSize.drawerWidth);
      });
    });
  }

  test('dark surfaces layer strictly lighter, starting at pure black', () {
    final colors = appDarkTheme.colorScheme;
    final ladder = [
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
    expect(colors.surface, const Color(0xFF000000));
  });

  test('dark palette tokens (founder decision 2026-10-22: X colours)', () {
    final colors = appDarkTheme.colorScheme;
    expect(colors.surface, const Color(0xFF000000));
    expect(colors.onSurface, const Color(0xFFE7E9EA));
    expect(colors.onSurfaceVariant, const Color(0xFF71767B));
    expect(colors.outlineVariant, const Color(0xFF2F3336));
    expect(colors.outline, const Color(0xFF333639));
    expect(colors.primary, const Color(0xFF1D9BF0));
    final app = appDarkTheme.extension<AppColors>()!;
    expect(app.strongPillFill, const Color(0xFFEFF3F4));
    expect(app.strongPillLabel, const Color(0xFF0F1419));
    expect(app.scrim, const Color(0x665B7083));
  });

  test('light palette tokens (founder decision 2026-10-22: X colours)', () {
    final colors = appLightTheme.colorScheme;
    expect(colors.surface, const Color(0xFFFFFFFF));
    expect(colors.onSurface, const Color(0xFF0F1419));
    expect(colors.onSurfaceVariant, const Color(0xFF536471));
    expect(colors.outlineVariant, const Color(0xFFEFF3F4));
    expect(colors.outline, const Color(0xFFCFD9DE));
    expect(colors.primary, const Color(0xFF1D9BF0));
    final app = appLightTheme.extension<AppColors>()!;
    expect(app.strongPillFill, const Color(0xFF0F1419));
    expect(app.strongPillLabel, const Color(0xFFFFFFFF));
    expect(app.accentText, const Color(0xFF1478BD));
    expect(app.scrim, const Color(0x26000000));
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

  test('the type scale (founder decision 2026-10-22)', () {
    final text = appLightTheme.textTheme;
    expect(text.bodyLarge!.fontSize, 15);
    expect(text.bodyLarge!.height, closeTo(1.33, 0.001));
    expect(text.titleSmall!.fontSize, 15);
    expect(text.titleSmall!.fontWeight, FontWeight.w700);
    expect(text.titleLarge!.fontSize, 20);
    expect(text.titleLarge!.fontWeight, FontWeight.w700);
    expect(text.headlineSmall!.fontSize, 22);
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

  group('colour rules hold across lib/ (decision 2026-10-22)', () {
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
}
