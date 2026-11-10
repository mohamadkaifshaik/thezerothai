import 'package:dzeroth/shared/widgets/primitives/app_badge.dart';
import 'package:dzeroth/shared/widgets/primitives/app_status_pill.dart';
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

void main() {
  for (final tone in AppStatusTone.values) {
    forEachThemeAndWidth(
      'pill ${tone.name} fits, is >= 24dp, has no semantics',
      (tester, env) async {
        final handle = tester.ensureSemantics();
        await pumpThemed(
          tester,
          Align(
            alignment: Alignment.topLeft,
            child: AppStatusPill(label: 'Coming soon', tone: tone),
          ),
          brightness: env.brightness,
          size: env.size,
          textScale: env.textScale,
        );
        expect(tester.takeException(), isNull);
        final height = tester.getSize(find.byType(AppStatusPill)).height;
        expect(height, greaterThanOrEqualTo(24));
        if (env.textScale == 2.0) {
          // Grows with the text: never a fixed box.
          expect(height, greaterThan(AppStatusPill.height + 4));
        }
        expect(find.bySemanticsLabel('Coming soon'), findsNothing);
        handle.dispose();
      },
      widths: kRedesignWidths,
      textScales: kRedesignTextScales,
      heights: kRedesignHeights,
    );

    for (final brightness in Brightness.values) {
      testWidgets('pill ${tone.name} label is >= 4.5:1 in ${brightness.name}', (
        tester,
      ) async {
        await pumpThemed(
          tester,
          AppStatusPill(label: 'Coming soon', tone: tone),
          brightness: brightness,
        );
        final text = tester.widget<Text>(find.text('Coming soon'));
        final deco =
            tester
                    .widget<Container>(
                      find.descendant(
                        of: find.byType(AppStatusPill),
                        matching: find.byType(Container),
                      ),
                    )
                    .decoration!
                as BoxDecoration;
        final page = Theme.of(tester.element(find.byType(AppStatusPill)))
            .colorScheme
            .surface;
        final fill = Color.alphaBlend(deco.color!, page);
        expect(_contrast(text.style!.color!, fill), greaterThanOrEqualTo(4.5));
      });
    }
  }

  testWidgets('info pill is an accent tint badge', (tester) async {
    await pumpThemed(
      tester,
      const AppStatusPill(label: 'Soon', tone: AppStatusTone.info),
    );
    final badge = tester.widget<AppTintBadge>(find.byType(AppTintBadge));
    expect(badge.tone, AppTintTone.accent);
    expect(badge.excludeSemantics, isTrue);
  });
}
