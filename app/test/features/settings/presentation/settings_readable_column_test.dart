import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/core/widgets/shell_geometry.dart';
import 'package:dzeroth/features/graph/presentation/managed_accounts_screen.dart';
import 'package:dzeroth/features/graph/presentation/widgets/paged_user_list.dart';
import 'package:dzeroth/features/profile/presentation/change_handle_screen.dart';
import 'package:dzeroth/shared/widgets/primitives/app_form_header.dart';
import 'package:dzeroth/shared/widgets/primitives/app_main_column.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/settings_tablet_rig.dart';
import '../../../support/geometry.dart';

/// T8e: the Settings leaves move from their 600 dp caps to the readable
/// column (tablet plan sections 3 and 4.1 "ChangeHandle ... ManagedAccounts":
/// F (readable) in band A, an LD detail in band B). The reading content is at
/// most 680 and centred in the detail (or the pane in band A); the header
/// spans it. Phones and desktop keep today's widths.
void main() {
  Future<SettingsTabletRig> open(
    WidgetTester tester,
    String location, {
    required double width,
    TextDirection textDirection = TextDirection.ltr,
    double textScale = 1,
    Set<String> flags = kSettingsTabletFlags,
  }) async {
    final rig = SettingsTabletRig();
    await rig.pump(
      tester,
      location: location,
      width: width,
      textDirection: textDirection,
      textScale: textScale,
      flags: flags,
    );
    return rig;
  }

  Future<void> done(WidgetTester tester) => tester.pumpWidget(const SizedBox());

  /// The page's pane: the detail beside the categories in band B, the
  /// content area in band A.
  Rect pane(double width, {bool rtl = false}) {
    final c = width - AppSize.railCompact;
    if (width < AppBreakpoints.expanded) {
      return Rect.fromLTWH(rtl ? 0 : 80, 0, c, 900);
    }
    final list = ShellGeometry.listPaneWidthFor(c);
    final detail = c - list - 1;
    return Rect.fromLTWH(rtl ? 0 : 80 + list + 1, 0, detail, 900);
  }

  double capped(double width) =>
      width < AppSize.readableMax ? width : AppSize.readableMax;

  group('Change handle (a form leaf in AppMainColumn)', () {
    Rect column(WidgetTester tester) => tester.getRect(
      find.descendant(
        of: find.byType(ChangeHandleScreen),
        matching: find.byType(AppMainColumnBleed),
      ),
    );
    Rect divider(WidgetTester tester) => tester.getRect(
      find.descendant(
        of: find.byType(AppFormHeader),
        matching: find.byType(Divider),
      ),
    );

    for (final (width, rtl) in [
      (600.0, false),
      (839.0, false),
      (840.0, false),
      (1024.0, false),
      (1199.0, false),
      (1199.0, true),
    ]) {
      testWidgets('${width.toInt()}${rtl ? ' RTL' : ''}: the column in the '
          '${width >= 840 ? 'detail' : 'pane'}, the header across it', (
        tester,
      ) async {
        await open(
          tester,
          AppRouter.changeHandlePath,
          width: width,
          textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
        );
        final area = pane(width, rtl: rtl);
        final col = column(tester);
        expect(col.width, moreOrLessEquals(capped(area.width)));
        expect(col.center.dx, moreOrLessEquals(area.center.dx));
        expect(divider(tester).left, moreOrLessEquals(area.left));
        expect(divider(tester).right, moreOrLessEquals(area.right));
        expectNoOverflow(tester);
        await done(tester);
      });
    }

    testWidgets('text scale 2.0 at 1199: nothing overflows', (tester) async {
      await open(tester, AppRouter.changeHandlePath, width: 1199, textScale: 2);
      expectNoOverflow(tester);
      expect(column(tester).width, AppSize.readableMax);
      await done(tester);
    });

    for (final width in [360.0, 1440.0]) {
      testWidgets('${width.toInt()}: today\'s column', (tester) async {
        await open(tester, AppRouter.changeHandlePath, width: width);
        final col = column(tester);
        expect(col.width, lessThanOrEqualTo(AppLayout.mainColumnMaxWidth));
        expect(divider(tester).width, col.width);
        await done(tester);
      });
    }
  });

  group('Blocked accounts (an AppBar leaf with a list)', () {
    Rect list(WidgetTester tester) =>
        tester.getRect(find.byType(PagedUserList));

    for (final width in [839.0, 1024.0, 1199.0]) {
      testWidgets('${width.toInt()}: the list at most 680, centred; the bar '
          'across the pane', (tester) async {
        await open(tester, AppRouter.blockedAccountsPath, width: width);
        final area = pane(width);
        expect(list(tester).width, moreOrLessEquals(capped(area.width)));
        expect(list(tester).center.dx, moreOrLessEquals(area.center.dx));
        final bar = tester.getRect(
          find.descendant(
            of: find.byType(BlockedAccountsScreen),
            matching: find.byType(AppBar),
          ),
        );
        expect(bar.left, moreOrLessEquals(area.left));
        expect(bar.right, moreOrLessEquals(area.right));
        await done(tester);
      });
    }

    for (final width in [360.0, 1440.0]) {
      testWidgets('${width.toInt()}: uncapped, as before', (tester) async {
        await open(tester, AppRouter.blockedAccountsPath, width: width);
        final page = tester.getRect(find.byType(BlockedAccountsScreen));
        expect(list(tester).width, page.width);
        await done(tester);
      });
    }
  });
}
