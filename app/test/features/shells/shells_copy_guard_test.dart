import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/widgets/app_drawer.dart';
import 'package:dzeroth/features/shells/domain/shell_entries.dart';
import 'package:dzeroth/features/shells/presentation/advertise_screen.dart';
import 'package:dzeroth/features/shells/presentation/calls_screen.dart';
import 'package:dzeroth/features/shells/presentation/creator_studio_screen.dart';
import 'package:dzeroth/features/shells/presentation/premium_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/shells_copy_guard.dart';
import '../../support/shells_harness.dart';

/// W8-8: the copy guard over all four pages, the drawer rows and the More
/// menu (ADR-0026 D3). The Premium pop-up is the only place a rupee amount may
/// appear, and only the ones in `kPremiumPlans`. Runs on every copy change.
void main() {
  group('the guard itself catches what it must', () {
    void fails(String text, {bool allowPlanAmounts = false}) => expect(
      () => expectCleanShellCopy(text, allowPlanAmounts: allowPlanAmounts),
      throwsA(isA<TestFailure>()),
      reason: text,
    );

    test('forbidden words, any case', () {
      for (final word in [
        'Subscribe now',
        'UPGRADE',
        'Buy Plus',
        'free trial',
        'Join the waitlist',
        'Notify me',
        'Pre-order',
        'Reserve yours',
        'Limited offer',
        'Early bird price',
        '₹2000/year',
        'Annual plan',
      ]) {
        fails(word);
      }
    });

    test('dates', () {
      for (final date in [
        'Launching October 2026',
        'oct 28, 2026',
        '28 October',
        '28/10/2026',
        '2026-10-28',
        '28.10',
        'in 2027',
      ]) {
        fails(date);
      }
    });

    test('amounts: none outside the pop-up, only the plans inside it', () {
      fails('₹235/month');
      fails('Rs. 235');
      fails('INR 850');
      fails('₹99/month', allowPlanAmounts: true);
      fails('₹1,000/month', allowPlanAmounts: true);
      fails('₹235/month and ₹849/month', allowPlanAmounts: true);
      expectCleanShellCopy(
        '₹235/month incl. GST\n₹850/month incl. GST',
        allowPlanAmounts: true,
      );
    });

    test('plain coming-soon copy passes', () {
      expectCleanShellCopy(
        'Advertising is coming soon\nWe do not sell ads yet. 12 followers',
      );
    });
  });

  group('the four pages', () {
    final pages = {
      AppRouter.creatorStudioPath: find.byType(CreatorStudioScreen),
      AppRouter.advertisePath: find.byType(AdvertiseScreen),
      AppRouter.callsPath: find.byType(CallsScreen),
    };

    for (final width in [360.0, 600.0, 1200.0]) {
      for (final entry in pages.entries) {
        shellsTest('${entry.key} at ${width.toInt()}dp', (tester) async {
          await pumpShellsApp(
            tester,
            location: entry.key,
            size: Size(width, 900),
          );
          final text = shellVisibleText(tester, entry.value);
          expect(text, isNotEmpty);
          expect(text.toLowerCase(), contains('coming soon'));
          expectCleanShellCopy(text, where: entry.key);
        });
      }
    }

    shellsTest('Advertise with the contact button on', (tester) async {
      final before = kAdvertisingContactEmail;
      kAdvertisingContactEmail = 'comingsoon@dzeroth.com';
      addTearDown(() => kAdvertisingContactEmail = before);
      await pumpShellsApp(tester, location: AppRouter.advertisePath);
      final text = shellVisibleText(tester, find.byType(AdvertiseScreen));
      expect(text, contains('Email us'));
      expectCleanShellCopy(text, where: 'Advertise (address set)');
    });

    for (final width in [360.0, 1200.0]) {
      shellsTest('Premium pop-up at ${width.toInt()}dp: plan amounts only', (
        tester,
      ) async {
        final app = await pumpShellsApp(tester, size: Size(width, 900));
        app.router.router.push(AppRouter.premiumPath, extra: kShellPushExtra);
        await tester.pumpAndSettle();
        final text = shellVisibleText(tester, find.byType(PremiumDialog));
        expect(text, contains('₹235/month'));
        expect(text, contains('₹850/month'));
        expectCleanShellCopy(
          text,
          allowPlanAmounts: true,
          where: 'Premium pop-up',
        );
      });
    }
  });

  group('the More menu and the drawer rows', () {
    shellsTest('More menu at 1200dp', (tester) async {
      await pumpShellsApp(tester, size: const Size(1200, 900));
      await tester.tap(find.bySemanticsLabel(RegExp(r'^More, menu')));
      await tester.pumpAndSettle();
      final menu = find.byType(PopupMenuItem<ShellEntry>);
      expect(menu, findsNWidgets(4));
      final text = shellVisibleText(tester, menu);
      expect(text, contains('Premium'));
      expectCleanShellCopy(text, where: 'More menu');
    });

    shellsTest('drawer at 360dp', (tester) async {
      await pumpShellsApp(tester);
      tester.state<ScaffoldState>(find.byType(Scaffold).first).openDrawer();
      await tester.pumpAndSettle();
      final text = shellVisibleText(tester, find.byType(AppDrawer));
      expect(text, contains('Creator tools'));
      expectCleanShellCopy(text, where: 'drawer');
    });
  });
}
