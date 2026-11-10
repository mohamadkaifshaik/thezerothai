import 'dart:math' as math;
import 'dart:ui' show Tristate;

import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/shared/widgets/primitives/app_menu_item_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/contrast.dart';
import '../../../support/theme_harness.dart';

Widget _host(
  Widget child, {
  Brightness brightness = Brightness.dark,
  double textScale = 1,
  double width = 240,
}) => MaterialApp(
  theme: buildAppTheme(brightness: brightness),
  home: MediaQuery(
    data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
    child: Scaffold(
      body: Center(
        child: SizedBox(width: width, child: child),
      ),
    ),
  ),
);

double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

void main() {
  group('AppMenuItemRow', () {
    testWidgets('shows the icon and the label in both themes', (tester) async {
      for (final brightness in Brightness.values) {
        await tester.pumpWidget(
          _host(
            const AppMenuItemRow(icon: Icons.block, label: 'Block @alice'),
            brightness: brightness,
          ),
        );
        expect(find.text('Block @alice'), findsOneWidget);
        expect(find.byIcon(Icons.block), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
    });

    testWidgets('neutral: label in onSurface, icon in onSurfaceVariant', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(const AppMenuItemRow(icon: Icons.block, label: 'Block')),
      );
      final colors = appDarkTheme.colorScheme;
      expect(
        tester.widget<Text>(find.text('Block')).style?.color,
        colors.onSurface,
      );
      expect(
        tester.widget<Icon>(find.byIcon(Icons.block)).color,
        colors.onSurfaceVariant,
      );
    });

    testWidgets('destructive: label and icon in the error colour, readable '
        'on the menu surface', (tester) async {
      for (final brightness in Brightness.values) {
        await tester.pumpWidget(
          _host(
            const AppMenuItemRow(
              icon: Icons.delete_outline,
              label: 'Delete',
              destructive: true,
            ),
            brightness: brightness,
          ),
        );
        // MaterialApp animates a theme change; read the settled colours.
        await tester.pumpAndSettle();
        final colors = buildAppTheme(brightness: brightness).colorScheme;
        expect(
          tester.widget<Text>(find.text('Delete')).style?.color,
          colors.error,
        );
        expect(
          tester.widget<Icon>(find.byIcon(Icons.delete_outline)).color,
          colors.error,
        );
        expect(
          _contrast(colors.error, colors.surfaceContainerHigh),
          greaterThanOrEqualTo(4.5),
          reason: '$brightness error on the menu surface',
        );
      }
    });

    testWidgets('the icon is decorative: the label is spoken once', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _host(
          const AppMenuItemRow(icon: Icons.flag_outlined, label: 'Report post'),
        ),
      );
      expect(find.bySemanticsLabel('Report post'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('flag')), findsNothing);
      handle.dispose();
    });

    testWidgets('a long label at 2.0 scale and a narrow menu wraps without '
        'overflow', (tester) async {
      await tester.pumpWidget(
        _host(
          const AppMenuItemRow(
            icon: Icons.volume_off_outlined,
            label: 'Mute @a_very_long_handle_name_indeed',
          ),
          textScale: 2,
          width: 160,
        ),
      );
      expect(tester.takeException(), isNull);
    });

    forEachThemeAndWidth(
      'is 48 dp tall and reflows without overflow',
      (tester, env) async {
        await pumpThemed(
          tester,
          const Column(
            children: [
              AppMenuItemRow(icon: Icons.block, label: 'Block'),
              AppMenuItemRow(
                icon: Icons.volume_off_outlined,
                label: 'Mute @a_very_long_handle_name_indeed for a week',
                selected: true,
              ),
              AppMenuItemRow(
                icon: Icons.delete_outline,
                label: 'Delete',
                destructive: true,
              ),
            ],
          ),
          brightness: env.brightness,
          size: env.size,
          textScale: env.textScale,
        );
        expect(tester.takeException(), isNull);
        for (final row in tester.widgetList(find.byType(AppMenuItemRow))) {
          expect(
            tester.getSize(find.byWidget(row)).height,
            greaterThanOrEqualTo(48),
          );
        }
        await expectLater(tester, meetsGuideline(textContrastGuideline));
      },
      widths: kRedesignWidths,
      textScales: kRedesignTextScales,
      heights: kRedesignHeights,
    );

    testWidgets('selected: accent colour, a check glyph and the selected '
        'flag, so it is not colour alone', (tester) async {
      final handle = tester.ensureSemantics();
      for (final brightness in Brightness.values) {
        await tester.pumpWidget(
          _host(
            const Column(
              children: [
                AppMenuItemRow(
                  icon: Icons.sort,
                  label: 'Newest',
                  selected: true,
                ),
                AppMenuItemRow(
                  icon: Icons.sort,
                  label: 'Oldest',
                  selected: false,
                ),
              ],
            ),
            brightness: brightness,
          ),
        );
        await tester.pumpAndSettle();
        final theme = buildAppTheme(brightness: brightness);
        final accent = theme.extension<AppColors>()!.accentText;
        expect(find.byIcon(Icons.check), findsOneWidget);
        expect(tester.widget<Text>(find.text('Newest')).style?.color, accent);
        expect(
          tester.widget<Text>(find.text('Oldest')).style?.color,
          theme.colorScheme.onSurface,
        );
        expect(
          _contrast(accent, theme.colorScheme.surfaceContainerHigh),
          greaterThanOrEqualTo(4.5),
          reason: '$brightness accent on the menu surface',
        );
        final on = tester.getSemantics(find.text('Newest'));
        final off = tester.getSemantics(find.text('Oldest'));
        expect(on.flagsCollection.isSelected, Tristate.isTrue);
        expect(off.flagsCollection.isSelected, Tristate.isFalse);
      }
      handle.dispose();
    });
  });

  forEachThemeAndWidth(
    'AppMenuItemRow is at least 48 dp tall, fits and keeps contrast',
    (tester, env) async {
      await pumpThemed(
        tester,
        const AppMenuItemRow(
          icon: Icons.block,
          label: 'Block this account and hide their posts',
          destructive: true,
        ),
        brightness: env.brightness,
        size: env.size,
        textScale: env.textScale,
      );
      expect(tester.takeException(), isNull);
      expect(
        tester.getSize(find.byType(AppMenuItemRow)).height,
        greaterThanOrEqualTo(AppSpacing.minTapTarget),
      );
      final scheme = buildAppTheme(brightness: env.brightness).colorScheme;
      expect(contrast(scheme.error, scheme.surface), greaterThanOrEqualTo(4.5));
    },
    widths: kRedesignWidths,
    textScales: kRedesignTextScales,
  );
}
