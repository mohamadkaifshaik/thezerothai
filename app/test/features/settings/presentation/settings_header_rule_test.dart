import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/core/widgets/shell_geometry.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/geometry.dart';
import '../../../support/settings_tablet_rig.dart';

/// T8f, one header rule, on the Settings leaves: the `AppBar` leaves
/// (Blocked, Muted, Change handle) put Back at the same x, the detail's (or
/// band A's pane's) leading edge.
void main() {
  Future<void> open(
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
  }

  Future<void> done(WidgetTester tester) => tester.pumpWidget(const SizedBox());

  /// The leaf's pane: the detail beside the categories in band B, the
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

  Rect backOf(WidgetTester tester) =>
      tester.getRect(find.byTooltip('Back').last);

  // The rig's real leaves (Edit profile, Download my data and Delete account
  // are stubs there; Change handle uses the same AppBar as these, and Edit
  // profile's own header is pinned in profile_edit_layout_test).
  const barLeaves = [
    AppRouter.blockedAccountsPath,
    AppRouter.mutedAccountsPath,
    AppRouter.changeHandlePath,
  ];

  for (final width in [600.0, 839.0, 840.0, 1024.0, 1199.0]) {
    for (final rtl in [false, true]) {
      final label = '${width.toInt()}${rtl ? ' RTL' : ''}';
      testWidgets(
        '$label: Back (AppBar or back header) at the same x on every leaf, the '
        "pane's leading edge",
        (tester) async {
          final dir = rtl ? TextDirection.rtl : TextDirection.ltr;
          final area = pane(width, rtl: rtl);
          double lead(Rect r) =>
              rtl ? area.right - r.right : r.left - area.left;

          final leads = <String, double>{};
          for (final leaf in barLeaves) {
            await open(tester, leaf, width: width, textDirection: dir);
            leads[leaf] = lead(backOf(tester));
            await done(tester);
          }
          final reference = leads[barLeaves.first]!;
          for (final entry in leads.entries) {
            expect(
              entry.value,
              moreOrLessEquals(reference),
              reason: '${entry.key} leads at ${entry.value}, not $reference',
            );
          }
          expect(reference, moreOrLessEquals(AppSpacing.xs));
        },
      );
    }
  }

  testWidgets('text scale 2.0 at 840: Back still at the AppBar leaf x, '
      'nothing overflows', (tester) async {
    final area = pane(840);
    await open(tester, AppRouter.blockedAccountsPath, width: 840, textScale: 2);
    final back = backOf(tester).left - area.left;
    await done(tester);
    await open(tester, AppRouter.changeHandlePath, width: 840, textScale: 2);
    expectNoOverflow(tester);
    expect(backOf(tester).left - area.left, moreOrLessEquals(back));
    await done(tester);
  });
}
