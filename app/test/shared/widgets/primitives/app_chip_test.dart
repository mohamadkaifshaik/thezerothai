import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/shared/widgets/primitives/app_chip.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/theme_harness.dart';

double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

Widget _gallery() => Align(
  alignment: Alignment.topLeft,
  child: Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      const AppChip(label: 'Verified', showDot: true),
      AppChip(label: 'Open', onPressed: () {}),
      AppFilterPill(label: 'Following', selected: true, onPressed: () {}),
      AppFilterPill(label: 'Latest', selected: false, onPressed: () {}),
      const AppFilterPill(label: 'Off', selected: false, onPressed: null),
    ],
  ),
);

void main() {
  forEachThemeAndWidth(
    'chips and pills fit, meet tap targets and contrast',
    (tester, env) async {
      final handle = tester.ensureSemantics();
      await pumpThemed(
        tester,
        _gallery(),
        brightness: env.brightness,
        size: env.size,
        textScale: env.textScale,
      );
      expect(tester.takeException(), isNull);
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(textContrastGuideline));
      expect(
        tester.getSize(find.byType(AppChip).first).height,
        greaterThanOrEqualTo(AppChip.minHeight),
      );
      await expectGolden(tester, find.byType(Scaffold), 'chips', env);
      handle.dispose();
    },
    widths: kRedesignWidths,
    textScales: kRedesignTextScales,
    heights: kRedesignHeights,
  );

  testWidgets('a pressable chip has a 48dp hit area and taps', (tester) async {
    var taps = 0;
    await pumpThemed(
      tester,
      Align(
        alignment: Alignment.topLeft,
        child: AppChip(label: 'Open', onPressed: () => taps++),
      ),
    );
    expect(
      tester.getSize(find.byType(InkWell)).height,
      greaterThanOrEqualTo(48),
    );
    await tester.tap(find.text('Open'));
    expect(taps, 1);
  });

  testWidgets('a label-only chip has no hit area', (tester) async {
    await pumpThemed(tester, const AppChip(label: 'Verified'));
    expect(find.byType(InkWell), findsNothing);
  });

  testWidgets('chip semantics: label, button only when pressable', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await pumpThemed(
      tester,
      Column(
        children: [
          AppChip(label: 'Open', onPressed: () {}),
          const AppChip(label: 'Verified', semanticsLabel: 'Verified account'),
        ],
      ),
    );
    expect(
      tester.getSemantics(find.bySemanticsLabel('Open')),
      matchesSemantics(label: 'Open', isButton: true, hasTapAction: true),
    );
    expect(find.bySemanticsLabel('Verified account'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('the 1.5dp border grows with the text, no fixed box', (
    tester,
  ) async {
    await pumpThemed(
      tester,
      const Align(
        alignment: Alignment.topLeft,
        child: AppChip(label: 'Verified', showDot: true),
      ),
      textScale: 2,
      size: const Size(360, 800),
    );
    expect(tester.takeException(), isNull);
    final deco =
        tester
                .widget<Container>(
                  find
                      .descendant(
                        of: find.byType(AppChip),
                        matching: find.byType(Container),
                      )
                      .first,
                )
                .decoration!
            as BoxDecoration;
    expect((deco.border! as Border).top.width, 1.5);
    expect(
      tester.getSize(find.byType(AppChip)).height,
      greaterThan(AppChip.minHeight + 4),
    );
  });

  for (final brightness in Brightness.values) {
    final theme = buildAppTheme(brightness: brightness);
    final colors = theme.extension<AppColors>()!;
    final page = theme.colorScheme.surface;
    final name = brightness.name;

    test('chip outline and label >= 4.5:1 on the page ($name)', () {
      expect(
        _contrast(colors.selectedIndicator, page),
        greaterThanOrEqualTo(4.5),
      );
    });

    test('pill: unselected outline >= 3:1, labels >= 4.5:1 ($name)', () {
      final fill = AppFilterPill.unselectedFill(theme);
      expect(_contrast(colors.uiBorder, fill), greaterThanOrEqualTo(3));
      expect(
        _contrast(theme.colorScheme.onSurface, fill),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        _contrast(colors.strongPillLabel, colors.strongPillFill),
        greaterThanOrEqualTo(4.5),
      );
      expect(_contrast(colors.strongPillFill, page), greaterThanOrEqualTo(3));
    });
  }

  test('on-dark chip is >= 4.5:1 on navy', () {
    expect(
      _contrast(AppPalette.tealElectric, AppPalette.navy),
      greaterThanOrEqualTo(4.5),
    );
  });

  testWidgets('selection is not colour alone: check glyph and w700', (
    tester,
  ) async {
    await pumpThemed(
      tester,
      Row(
        children: [
          AppFilterPill(label: 'A', selected: true, onPressed: () {}),
          AppFilterPill(label: 'B', selected: false, onPressed: () {}),
        ],
      ),
    );
    final a = find.byType(AppFilterPill).first;
    final b = find.byType(AppFilterPill).last;
    expect(
      find.descendant(of: a, matching: find.byIcon(Icons.check)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: b, matching: find.byIcon(Icons.check)),
      findsNothing,
    );
    expect(
      tester.widget<Text>(find.text('A')).style!.fontWeight,
      FontWeight.w700,
    );
    expect(
      tester.widget<Text>(find.text('B')).style!.fontWeight,
      FontWeight.w600,
    );
  });

  testWidgets('pill semantics: selected, enabled, button; disabled ignored', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    var taps = 0;
    await pumpThemed(
      tester,
      Column(
        children: [
          AppFilterPill(
            label: 'Following',
            selected: true,
            onPressed: () => taps++,
          ),
          const AppFilterPill(label: 'Off', selected: false, onPressed: null),
        ],
      ),
    );
    expect(
      tester.getSemantics(find.bySemanticsLabel('Following')),
      matchesSemantics(
        label: 'Following',
        isButton: true,
        isSelected: true,
        isEnabled: true,
        hasEnabledState: true,
        hasSelectedState: true,
        hasTapAction: true,
      ),
    );
    expect(
      tester.getSemantics(find.bySemanticsLabel('Off')),
      matchesSemantics(
        label: 'Off',
        isButton: true,
        hasEnabledState: true,
        hasSelectedState: true,
      ),
    );
    await tester.tap(find.text('Following'));
    await tester.tap(find.text('Off'), warnIfMissed: false);
    expect(taps, 1);
    handle.dispose();
  });

  testWidgets('pill hit area is 48dp around a 36dp visual', (tester) async {
    await pumpThemed(
      tester,
      Align(
        alignment: Alignment.topLeft,
        child: AppFilterPill(label: 'X', selected: false, onPressed: () {}),
      ),
    );
    expect(
      tester.getSize(find.byType(AppFilterPill)).height,
      greaterThanOrEqualTo(48),
    );
    final visual = tester.getSize(
      find
          .descendant(
            of: find.byType(AppFilterPill),
            matching: find.byType(Container),
          )
          .first,
    );
    expect(visual.height, AppFilterPill.minHeight);
  });
}
