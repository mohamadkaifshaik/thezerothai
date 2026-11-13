import 'package:dzeroth/core/feature_flags/ui_shell_feature_flag.dart';
import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/router/shell_entries.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/core/widgets/app_nav_rail.dart';
import 'package:dzeroth/core/widgets/shell_geometry.dart';
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
/// full-screen dialog. On the desktop layout (>= 1200 dp, both flags; D1) it
/// is the 600 dp card centred on the shell's feed column; desktop with
/// either flag off keeps it centred on the window.

const _tablet = {...kShellFlags, kFeatureUiTablet};

Future<ShellsApp> _open(
  WidgetTester tester, {
  required double width,
  double height = 900,
  Set<String> flags = _tablet,
  TextDirection textDirection = TextDirection.ltr,
  EdgeInsets padding = EdgeInsets.zero,
  double textScale = 1,
  String location = AppRouter.creatorStudioPath,
  ValueNotifier<double>? textScaleNotifier,
}) async {
  final app = await pumpShellsApp(
    tester,
    flags: flags,
    location: location,
    size: Size(width, height),
    textDirection: textDirection,
    padding: padding,
    textScale: textScale,
    textScaleNotifier: textScaleNotifier,
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

  // D1: the desktop layout (both flags, >= 1200 dp) centres it on the
  // shell's feed column, placed by the page under it: the side column
  // (Creator Studio) or the Settings master pane.
  group('desktop layout: centred on the feed column', () {
    /// The column, from the rendered rail (`desktop_column_test.dart` ties
    /// the formula to the rendered column).
    Rect column(
      WidgetTester tester,
      double width, {
      bool master = false,
      TextDirection textDirection = TextDirection.ltr,
    }) {
      final rail = tester.getRect(find.byType(NavigationRail));
      final rect = ShellGeometry.desktopColumnFor(
        Size(width, 900),
        EdgeInsets.zero,
        master: master,
        side: !master,
        railWidth: rail.width,
        textDirection: textDirection,
      );
      // It starts where the rail (and the master pane) end.
      final before = master ? AppSize.sideColumn : 0;
      if (textDirection == TextDirection.ltr) {
        expect(rect.left, moreOrLessEquals(rail.right + before));
      } else {
        expect(rect.right, moreOrLessEquals(rail.left - before));
      }
      return rect;
    }

    for (final width in [1200.0, 1280.0, 1440.0, 1920.0]) {
      testWidgets('${width.toInt()}, over Creator Studio: 600 wide on the '
          'column', (tester) async {
        await _open(tester, width: width);
        final dialog = openDialogRect(tester);
        expect(dialog.width, 600);
        expect(
          dialog.center.dx,
          moreOrLessEquals(column(tester, width).center.dx),
        );
      });
    }

    testWidgets('1440, over Settings: on the column beside the master pane', (
      tester,
    ) async {
      await _open(tester, width: 1440, location: AppRouter.settingsPath);
      final dialog = openDialogRect(tester);
      expect(dialog.width, 600);
      expect(
        dialog.center.dx,
        moreOrLessEquals(column(tester, 1440, master: true).center.dx),
      );
    });

    testWidgets('1440, right to left: on the column left of the rail', (
      tester,
    ) async {
      await _open(tester, width: 1440, textDirection: TextDirection.rtl);
      expect(
        openDialogRect(tester).center.dx,
        moreOrLessEquals(
          column(tester, 1440, textDirection: TextDirection.rtl).center.dx,
        ),
      );
    });

    testWidgets('1440 at text scale 2.0: the wider rail is followed', (
      tester,
    ) async {
      await _open(tester, width: 1440, textScale: 2);
      expect(
        openDialogRect(tester).center.dx,
        moreOrLessEquals(column(tester, 1440).center.dx),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('text scale 1.0 -> 2.0 while it is open: the wider rail is '
        'followed', (tester) async {
      final scale = ValueNotifier<double>(1);
      addTearDown(scale.dispose);
      await _open(tester, width: 1440, textScaleNotifier: scale);
      final before = tester.getRect(find.byType(NavigationRail)).width;

      scale.value = 2;
      await tester.pumpAndSettle();

      expect(
        tester.getRect(find.byType(NavigationRail)).width,
        greaterThan(before),
      );
      expect(
        openDialogRect(tester).center.dx,
        moreOrLessEquals(column(tester, 1440).center.dx),
      );
    });

    testWidgets('1440, over Settings, widened from 1024 while open: on the '
        'column beside the master pane', (tester) async {
      await _open(tester, width: 1024, location: AppRouter.settingsPath);

      tester.view.physicalSize = const Size(1440, 900);
      await tester.pumpAndSettle();

      expect(
        openDialogRect(tester).center.dx,
        moreOrLessEquals(column(tester, 1440, master: true).center.dx),
      );
    });

    testWidgets('the barrier covers the rail: a tap there closes it and '
        'selects nothing', (tester) async {
      final app = await _open(tester, width: 1440);
      await tester.tapAt(
        tester.getCenter(
          find.descendant(
            of: find.byType(NavigationRail),
            matching: find.text('Home'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(PremiumDialog), findsNothing);
      expect(app.path, AppRouter.creatorStudioPath);
    });
  });

  group('phones and desktop: today\'s presentation', () {
    for (final width in [360.0, 599.0]) {
      testWidgets('${width.toInt()}: full screen', (tester) async {
        await _open(tester, width: width);
        expect(tester.getSize(find.byType(Dialog)).width, width);
      });
    }

    // Desktop with either flag off: the 600 card on the window, as before.
    for (final flags in [
      kShellFlags,
      // `ui_tablet` without `ui_shell` (`shells` keeps the route).
      {..._tablet}..remove(kFeatureUiShell),
    ]) {
      testWidgets('1440 with $flags: a 600 card centred on the window', (
        tester,
      ) async {
        await _open(tester, width: 1440, flags: flags);
        final dialog = openDialogRect(tester);
        expect(dialog.width, 600);
        expect(dialog.center.dx, moreOrLessEquals(1440 / 2));
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
