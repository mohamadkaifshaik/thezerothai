import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/shared/widgets/primitives/app_icon_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

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

void main() {
  group('AppIconButton', () {
    testWidgets('is 48x48, announces its tooltip and taps', (tester) async {
      final handle = tester.ensureSemantics();
      var taps = 0;
      for (final raised in [false, true]) {
        await tester.pumpWidget(
          _host(
            AppIconButton(
              icon: Icons.add,
              tooltip: 'Add',
              raised: raised,
              onPressed: () => taps++,
            ),
          ),
        );
        expect(tester.getSize(find.byType(IconButton)), const Size(48, 48));
        expect(find.byTooltip('Add'), findsOneWidget);
        expect(tester.getSemantics(find.byType(IconButton)).tooltip, 'Add');
        await tester.tap(find.byType(IconButton));
      }
      expect(taps, 2);
      handle.dispose();
    });

    testWidgets('raised is a flat white disc: no shadow', (tester) async {
      await tester.pumpWidget(
        _host(
          AppIconButton(
            icon: Icons.add,
            tooltip: 'Add',
            raised: true,
            onPressed: () {},
          ),
        ),
      );
      final shadowed = tester
          .widgetList<DecoratedBox>(
            find.descendant(
              of: find.byType(AppIconButton),
              matching: find.byType(DecoratedBox),
            ),
          )
          .where(
            (b) =>
                b.decoration is BoxDecoration &&
                (b.decoration as BoxDecoration).boxShadow != null,
          );
      expect(shadowed, isEmpty);
    });

    forEachThemeAndWidth(
      'AppIconButton meets androidTapTargetGuideline',
      (tester, env) async {
        final handle = tester.ensureSemantics();
        await pumpThemed(
          tester,
          Center(
            child: AppIconButton(
              icon: Icons.add,
              tooltip: 'Add',
              onPressed: () {},
            ),
          ),
          brightness: env.brightness,
          size: env.size,
          textScale: env.textScale,
        );
        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
        expect(tester.takeException(), isNull);
        handle.dispose();
      },
      widths: kRedesignWidths,
      textScales: kRedesignTextScales,
      heights: kRedesignHeights,
    );
  });
}
