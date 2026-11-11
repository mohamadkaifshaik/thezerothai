import 'package:dzeroth/core/feature_flags/ui_shell_feature_flag.dart';
import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/router/shell_entries.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/core/widgets/app_nav_rail.dart';
import 'package:dzeroth/features/premium/presentation/premium_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/shells_harness.dart';
import '../../../support/tablet_modal_harness.dart' show openDialogRect;
import '../../../support/geometry.dart';

/// Premium on the tablet layout (tablet plan section 4.1 "Premium", 5.4;
/// T8e): the guarded dialog page is `min(600, C - 48)` wide and centred on
/// the content area beside the rail at 600-1199 dp, with the barrier over
/// the whole window (rail included). Push-only, unchanged. Phones keep the
/// full-screen dialog and desktop the 600 dp card centred on the window.

const _tablet = {...kShellFlags, kFeatureUiTablet};

Future<ShellsApp> _open(
  WidgetTester tester, {
  required double width,
  double height = 900,
  Set<String> flags = _tablet,
  TextDirection textDirection = TextDirection.ltr,
  EdgeInsets padding = EdgeInsets.zero,
  double textScale = 1,
}) async {
  final app = await pumpShellsApp(
    tester,
    flags: flags,
    location: AppRouter.creatorStudioPath,
    size: Size(width, height),
    textDirection: textDirection,
    padding: padding,
    textScale: textScale,
  );
  app.router.router.push(AppRouter.premiumPath, extra: kShellPushExtra);
  await tester.pumpAndSettle();
  expect(find.byType(PremiumDialog), findsOneWidget);
  return app;
}

/// The content area (`C = W - 80 - insets`, the rail leading).
Rect _content(
  double width,
  double height, {
  EdgeInsets padding = EdgeInsets.zero,
  TextDirection textDirection = TextDirection.ltr,
}) {
  final ltr = textDirection == TextDirection.ltr;
  final leading = ltr ? padding.left : padding.right;
  final trailing = ltr ? padding.right : padding.left;
  final rail = AppSize.railCompact + leading;
  return Rect.fromLTWH(
    ltr ? rail : trailing,
    0,
    width - rail - trailing,
    height,
  );
}

void main() {
  setUpAll(() {
    // The shells exist in this build (`kVisibleShells`).
    expect(kVisibleShells, contains(ShellKind.premium));
  });

  group('the tablet layout: min(600, C - 48), centred on the content area', () {
    for (final width in [600.0, 744.0, 839.0, 840.0, 1024.0, 1199.0]) {
      testWidgets('${width.toInt()}', (tester) async {
        await _open(tester, width: width);
        final content = _content(width, 900);
        final dialog = openDialogRect(tester);
        final expected = content.width - 48 < 600 ? content.width - 48 : 600.0;
        expect(dialog.width, moreOrLessEquals(expected, epsilon: 0.5));
        expect(dialog.center.dx, moreOrLessEquals(content.center.dx));
        // Never over the rail.
        expect(dialog.left, greaterThanOrEqualTo(content.left + 24 - 0.5));
        expectNoOverflow(tester);
      });
    }

    testWidgets('the barrier covers the rail: a tap on it closes the dialog '
        'and selects nothing', (tester) async {
      final app = await _open(tester, width: 1024);
      final rail = tester.getRect(find.byType(AppNavRail));
      await tester.tapAt(Offset(rail.center.dx, 200));
      await tester.pumpAndSettle();
      expect(find.byType(PremiumDialog), findsNothing);
      expect(app.path, AppRouter.creatorStudioPath);
    });

    testWidgets('RTL at 1024: centred on the content area left of the rail', (
      tester,
    ) async {
      await _open(tester, width: 1024, textDirection: TextDirection.rtl);
      final content = _content(1024, 900, textDirection: TextDirection.rtl);
      expect(content.right, 1024 - 80);
      final dialog = openDialogRect(tester);
      expect(dialog.width, 600);
      expect(dialog.center.dx, moreOrLessEquals(content.center.dx));
    });

    for (final direction in TextDirection.values) {
      testWidgets('a landscape notch (44) and a status bar (32) at 700, '
          '${direction.name}: counted once', (tester) async {
        const padding = EdgeInsets.only(left: 44, top: 32);
        await _open(
          tester,
          width: 700,
          padding: padding,
          textDirection: direction,
        );
        final content = _content(
          700,
          900,
          padding: padding,
          textDirection: direction,
        );
        final dialog = openDialogRect(tester);
        // C = 700 - 80 - 44 = 576 in both directions (the notch is on the
        // left: the rail's side in LTR, the trailing side in RTL).
        expect(content.width, 576);
        expect(dialog.width, moreOrLessEquals(576 - 48, epsilon: 0.5));
        expect(dialog.center.dx, moreOrLessEquals(content.center.dx));
        expect(dialog.top, greaterThanOrEqualTo(32));
      });
    }

    for (final width in [600.0, 1024.0]) {
      testWidgets('text scale 2.0 at ${width.toInt()}: nothing overflows', (
        tester,
      ) async {
        await _open(tester, width: width, textScale: 2);
        expectNoOverflow(tester);
        final dialog = openDialogRect(tester);
        expect(dialog.bottom, lessThanOrEqualTo(900 - 24 + 0.5));
        expect(find.byTooltip('Close'), findsOneWidget);
      });
    }
  });

  group('phones and desktop: today\'s presentation', () {
    for (final width in [360.0, 599.0]) {
      testWidgets('${width.toInt()}: full screen', (tester) async {
        await _open(tester, width: width);
        expect(tester.getSize(find.byType(Dialog)).width, width);
      });
    }

    for (final width in [1200.0, 1440.0]) {
      testWidgets('${width.toInt()}: a 600 card centred on the window', (
        tester,
      ) async {
        await _open(tester, width: width);
        final dialog = openDialogRect(tester);
        expect(dialog.width, 600);
        expect(dialog.center.dx, moreOrLessEquals(width / 2));
      });
    }

    testWidgets('1024 with ui_tablet off: centred on the window', (
      tester,
    ) async {
      await _open(tester, width: 1024, flags: kShellFlags);
      final dialog = openDialogRect(tester);
      expect(dialog.width, 600);
      expect(dialog.center.dx, moreOrLessEquals(1024 / 2));
    });
  });
}
