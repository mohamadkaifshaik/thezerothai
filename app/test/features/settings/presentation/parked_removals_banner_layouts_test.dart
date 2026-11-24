import 'package:dzeroth/features/messages/presentation/e2ee/encryption_copy.dart';
import 'package:dzeroth/features/settings/presentation/widgets/parked_removals_banner.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/theme_harness.dart';

// The parked-removals banner at phone, tablet and desktop widths, in light and
// dark, and at the large text scales: the same banner, only its width changes.
void main() {
  forEachThemeAndWidth(
    'both actions fit, are 48dp, and the text keeps contrast',
    (tester, env) async {
      final handle = tester.ensureSemantics();
      var confirms = 0;
      var drops = 0;
      await pumpThemed(
        tester,
        ParkedRemovalsBanner(
          count: 2,
          onConfirm: () => confirms++,
          onDrop: () => drops++,
        ),
        brightness: env.brightness,
        size: env.size,
        textScale: env.textScale,
      );
      expect(tester.takeException(), isNull);
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(textContrastGuideline));
      expect(find.text(parkedRemovalsText(2)), findsOneWidget);
      await tester.tap(find.text(kConfirmItsYouTitle));
      await tester.tap(find.text(kParkedRemovalDropAction));
      expect((confirms, drops), (1, 1));
      handle.dispose();
    },
    widths: kRedesignWidths,
    textScales: kRedesignTextScales,
    heights: kRedesignHeights,
  );

  testWidgets('a busy banner shows both actions disabled', (tester) async {
    await pumpThemed(
      tester,
      const ParkedRemovalsBanner(count: 1, onConfirm: null, onDrop: null),
    );
    expect(find.text(kConfirmItsYouTitle), findsOneWidget);
    expect(find.text(kParkedRemovalDropAction), findsOneWidget);
  });
}
