import 'dart:ui' show Tristate;

import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/shared/widgets/primitives/sheet_option_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/contrast.dart';
import '../../../support/theme_harness.dart';

const _long =
    'Everyone who follows you and everyone they follow, including accounts '
    'you have not met yet';

Widget _rows({void Function()? onTap}) => Column(
  children: [
    SheetOptionRow(
      icon: Icons.public,
      label: _long,
      selected: true,
      onTap: onTap ?? () {},
    ),
    SheetOptionRow(
      icon: Icons.group_outlined,
      label: 'Followers',
      selected: false,
      onTap: () {},
    ),
    const SheetOptionRow(
      icon: Icons.lock_outline,
      label: 'Disabled',
      onTap: null,
    ),
  ],
);

void main() {
  group('SheetOptionRow', () {
    forEachThemeAndWidth(
      'rows are 48 dp, wrap and do not overflow',
      (tester, env) async {
        await pumpThemed(
          tester,
          _rows(),
          brightness: env.brightness,
          size: env.size,
          textScale: env.textScale,
        );
        expect(tester.takeException(), isNull);
        for (final row in tester.widgetList(find.byType(SheetOptionRow))) {
          final r = tester.getRect(find.byWidget(row));
          expect(r.height, greaterThanOrEqualTo(48));
          expect(r.right, lessThanOrEqualTo(env.size.width));
        }
        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
        await expectLater(tester, meetsGuideline(textContrastGuideline));
      },
      widths: kRedesignWidths,
      textScales: kRedesignTextScales,
      heights: kRedesignHeights,
    );

    testWidgets('the selected row shows a check and the accent colour', (
      tester,
    ) async {
      for (final brightness in Brightness.values) {
        await pumpThemed(tester, _rows(), brightness: brightness);
        final element = tester.element(find.byType(SheetOptionRow).first);
        final colors = element.appColors;
        expect(find.byIcon(Icons.check), findsOneWidget);
        expect(
          tester.widget<Icon>(find.byIcon(Icons.check)).color,
          colors.accentText,
        );
        expect(
          tester.widget<Text>(find.text(_long)).style?.color,
          colors.accentText,
        );
        expect(
          tester.widget<Text>(find.text('Followers')).style?.color,
          isNot(colors.accentText),
        );
        // The accent text reads on the sheet surface.
        expect(
          contrast(
            colors.accentText,
            Theme.of(element).bottomSheetTheme.backgroundColor!,
          ),
          greaterThanOrEqualTo(4.5),
          reason: '$brightness',
        );
      }
    });

    testWidgets('a caller trailing replaces the check', (tester) async {
      await pumpThemed(
        tester,
        SheetOptionRow(
          icon: Icons.public,
          label: 'Everyone',
          selected: true,
          trailing: const Icon(Icons.radio_button_checked),
          onTap: () {},
        ),
      );
      expect(find.byIcon(Icons.check), findsNothing);
      expect(find.byIcon(Icons.radio_button_checked), findsOneWidget);
    });

    testWidgets('semantics: selected, enabled and the label spoken once', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpThemed(tester, _rows());
      final selected = tester.getSemantics(find.text(_long));
      expect(selected.flagsCollection.isSelected, Tristate.isTrue);
      expect(selected.flagsCollection.isButton, isTrue);
      expect(find.bySemanticsLabel('check'), findsNothing);
      final other = tester.getSemantics(find.text('Followers'));
      expect(other.flagsCollection.isSelected, Tristate.isFalse);
      final off = tester.getSemantics(find.text('Disabled'));
      expect(off.flagsCollection.isEnabled, Tristate.isFalse);
      handle.dispose();
    });

    testWidgets('Enter activates the focused row', (tester) async {
      var taps = 0;
      await pumpThemed(tester, _rows(onTap: () => taps++));
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(taps, 1);
    });
  });
}
