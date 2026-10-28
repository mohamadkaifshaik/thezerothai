import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/features/shells/domain/premium_plans.dart';
import 'package:dzeroth/features/shells/domain/shell_entries.dart';
import 'package:dzeroth/features/shells/presentation/premium_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/geometry.dart';
import '../../support/shells_harness.dart';
import '../../support/theme_harness.dart';

/// W8-5: the Premium pop-up body (ADR-0026 D3): two static plan cards from
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
    test('Plus and Premium, monthly, in paise', () {
      expect(kPremiumPlans.map((p) => p.name), ['Plus', 'Premium']);
      expect(kPremiumPlans.map((p) => p.pricePaise), [23500, 85000]);
      expect(PremiumPlan.period, 'month');
    });

    test('labels are formatted from paise', () {
      expect(kPremiumPlans.map((p) => p.priceLabel), [
        '₹235/month',
        '₹850/month',
      ]);
      expect(kPremiumPlans.map((p) => p.spokenPrice), [
        '₹235 a month',
        '₹850 a month',
      ]);
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
          shellsTest('hero, two cards, footer, no overflow '
              '[${brightness.name} ${width.toInt()}dp x$scale]', (
            tester,
          ) async {
            await openDialog(
              tester,
              size: Size(width, 800),
              brightness: brightness,
              textScale: scale,
            );

            expect(find.text('Premium is coming soon'), findsOneWidget);
            expect(
              find.text(
                'Optional paid plans to help cover running costs. Nothing '
                'is for sale yet.',
              ),
              findsOneWidget,
            );
            expect(find.byIcon(Icons.workspace_premium_outlined), findsOne);
            expect(find.text('₹235/month'), findsOneWidget);
            expect(find.text('₹850/month'), findsOneWidget);
            expect(find.text('incl. GST'), findsNWidgets(2));
            expect(find.text('Coming soon'), findsNWidgets(2));
            expect(
              find.text(
                'No payment details are asked for anywhere in the app.',
              ),
              findsOneWidget,
            );

            // Side by side from 600 dp below text scale 2.0; stacked else.
            final plus = tester.getRect(find.text('₹235/month'));
            final premium = tester.getRect(find.text('₹850/month'));
            if (width >= 600 && scale < 2) {
              expect(plus.top, closeTo(premium.top, 1));
              expect(plus.right, lessThan(premium.left));
            } else {
              expect(plus.bottom, lessThan(premium.top));
              expect(plus.left, closeTo(premium.left, 1));
            }
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

    shellsTest('the text carries both prices with GST and "coming soon"', (
      tester,
    ) async {
      await openDialog(tester);
      final text = dialogText(tester);

      expect(text, contains('₹235/month'));
      expect(text, contains('₹850/month'));
      expect(
        RegExp(r'₹235/month\s+incl\. GST').hasMatch(text),
        isTrue,
        reason: 'Plus price is followed by incl. GST',
      );
      expect(RegExp(r'₹850/month\s+incl\. GST').hasMatch(text), isTrue);
      expect(text.toLowerCase(), contains('coming soon'));
    });

    shellsTest('copy guard: no purchase, urgency or other amounts', (
      tester,
    ) async {
      await openDialog(tester);
      final text = dialogText(tester);

      expect(
        RegExp(
          r'subscribe|upgrade|buy|trial|waitlist|notify me|pre-order|'
          r'reserve|limited|early bird|/year|annual',
          caseSensitive: false,
        ).hasMatch(text),
        isFalse,
        reason: text,
      );
      final allowed = kPremiumPlans.map((p) => formatRupees(p.pricePaise));
      final amounts = RegExp(r'₹[\d,.]+').allMatches(text).map((m) => m[0]);
      expect(amounts, isNotEmpty);
      for (final a in amounts) {
        expect(allowed, contains(a), reason: 'unexpected amount $a');
      }
      expect(RegExp(r'https?:|www\.|mailto:').hasMatch(text), isFalse);
      expect(RegExp(r'\d{4}|\d{1,2}[/-]\d{1,2}').hasMatch(text), isFalse);
    });

    shellsTest('each card reads once, as one non-button node', (tester) async {
      await openDialog(tester, size: const Size(1200, 800));
      final handle = tester.ensureSemantics();

      for (final label in [
        'Plus, ₹235 a month including GST, coming soon',
        'Premium, ₹850 a month including GST, coming soon',
      ]) {
        final finder = find.bySemanticsLabel(label);
        expect(finder, findsOneWidget, reason: label);
        final data = tester.getSemantics(finder).getSemanticsData();
        expect(data.flagsCollection.isButton, isFalse);
        expect(data.hasAction(SemanticsAction.tap), isFalse);
      }
      // The loose texts inside a card are not read again.
      expect(find.bySemanticsLabel('₹235/month'), findsNothing);
      expect(find.bySemanticsLabel('Coming soon'), findsNothing);
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
