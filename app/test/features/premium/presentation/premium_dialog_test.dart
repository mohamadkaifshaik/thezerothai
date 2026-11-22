import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/features/premium/domain/premium_plans.dart';
import 'package:dzeroth/core/router/shell_entries.dart';
import 'package:dzeroth/features/premium/presentation/premium_dialog.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/geometry.dart';
import '../../../support/shells_copy_guard.dart';
import '../../../support/shells_harness.dart';
import '../../../support/theme_harness.dart';

/// The Premium pop-up body: two static plan cards from
/// `kPremiumPlans`, "Coming soon", nothing to act on.
void main() {
  Future<void> openDialog(
    WidgetTester tester, {
    Size size = const Size(360, 800),
    Brightness brightness = Brightness.light,
    double textScale = 1.0,
  }) async {
    final app = await pumpShellsApp(
      tester,
      size: size,
      brightness: brightness,
      textScale: textScale,
    );
    app.router.router.push(AppRouter.premiumPath, extra: kShellPushExtra);
    await tester.pumpAndSettle();
  }

  /// Every string the dialog shows (Text and RichText), in tree order.
  String dialogText(WidgetTester tester) {
    final out = <String>[];
    for (final w in tester.widgetList<Text>(
      find.descendant(
        of: find.byType(PremiumDialog),
        matching: find.byType(Text),
      ),
    )) {
      out.add(w.data ?? w.textSpan?.toPlainText() ?? '');
    }
    return out.join('\n');
  }

  group('kPremiumPlans', () {
    test('single monthly Plus plan', () {
      expect(kPremiumPlans.single.name, 'Plus');
      expect(kPremiumPlans.single.pricePaise, 9900);
      expect(kPremiumPlans.single.priceLabel, '₹99/month');
    });

    test('formatRupees: en_IN grouping, decimals only when needed', () {
      expect(formatRupees(23500), '₹235');
      expect(formatRupees(100000), '₹1,000');
      expect(formatRupees(12345600), '₹1,23,456');
      expect(formatRupees(9950), '₹99.50');
      expect(formatRupees(0), '₹0');
    });
  });

  group('Premium dialog body', () {
    for (final brightness in Brightness.values) {
      for (final width in kMatrixWidths) {
        for (final scale in kMatrixTextScalesLarge) {
          shellsTest('headline, two cards, footer, no overflow '
              '[${brightness.name} ${width.toInt()}dp x$scale]', (
            tester,
          ) async {
            await openDialog(
              tester,
              size: Size(width, 800),
              brightness: brightness,
              textScale: scale,
            );

            expect(find.text('Compare plans'), findsOneWidget);
            expect(find.text('No subscription needed'), findsOneWidget);
            expect(find.text('₹99/month'), findsOneWidget);
            expect(find.textContaining('15,000'), findsOneWidget);
            expect(find.textContaining('280 characters'), findsOneWidget);
            expectNoOverflow(tester);
          });
        }
      }
    }

    shellsTest('the only button is Close', (tester) async {
      await openDialog(tester);

      final handle = tester.ensureSemantics();
      final buttons = <String>[];
      void walk(SemanticsNode n) {
        final data = n.getSemanticsData();
        if (data.flagsCollection.isButton) buttons.add(data.label);
        n.visitChildren((c) {
          walk(c);
          return true;
        });
      }

      walk(tester.getSemantics(find.byType(PremiumDialog)));
      expect(buttons, hasLength(1));
      handle.dispose();
    });

    shellsTest('copy guard: no purchase, urgency or other amounts', (
      tester,
    ) async {
      await openDialog(tester);
      final text = dialogText(tester);

      // The shared guard (words, dates, amounts): support/shells_copy_guard.
      expectCleanShellCopy(text, allowPlanAmounts: true, where: 'pop-up');
      expect(RegExp(r'₹[\d,.]+').hasMatch(text), isTrue);
      expect(RegExp(r'https?:|www\.|mailto:').hasMatch(text), isFalse);
    });

    shellsTest('each card reads once, as one non-button node', (tester) async {
      await openDialog(tester, size: const Size(1200, 800));
      final handle = tester.ensureSemantics();

      for (final details in ['280 characters', 'article publishing']) {
        final finder = find.bySemanticsLabel(RegExp(details));
        expect(finder, findsOneWidget);
        expect(
          tester
              .getSemantics(finder)
              .getSemanticsData()
              .hasAction(SemanticsAction.tap),
          isFalse,
        );
      }
      handle.dispose();
    });

    shellsTest('focus moves into the dialog title', (tester) async {
      await openDialog(tester);

      final focused = FocusManager.instance.primaryFocus?.context;
      expect(focused, isNotNull);
      expect(
        find.descendant(
          of: find.byElementPredicate((e) => e == focused),
          matching: find.byKey(PremiumDialog.titleKey),
        ),
        findsOneWidget,
      );
    });

    shellsTest('Close dismisses it', (tester) async {
      await openDialog(tester, size: const Size(800, 800));
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(find.byType(PremiumDialog), findsNothing);
    });
  });
}
