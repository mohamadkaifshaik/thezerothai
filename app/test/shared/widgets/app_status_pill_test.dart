import 'package:dzeroth/shared/widgets/app_status_pill.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/theme_harness.dart';

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
      'pill ${tone.name} fits, is >= 22dp, has no semantics',
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
        expect(
          tester.getSize(find.byType(AppStatusPill)).height,
          greaterThanOrEqualTo(AppStatusPill.height),
        );
        expect(find.bySemanticsLabel('Coming soon'), findsNothing);
        handle.dispose();
      },
      textScales: kMatrixTextScalesLarge,
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
        expect(
          _contrast(text.style!.color!, deco.color!),
          greaterThanOrEqualTo(4.5),
        );
      });
    }
  }
}
