import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/core/widgets/shell_geometry.dart';
import 'package:dzeroth/shared/widgets/primitives/app_form_header.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/geometry.dart';
import '../../../support/settings_tablet_rig.dart';

/// T8f, one header rule, on the Settings leaves: an `AppBar` leaf (Blocked,
/// Muted) and an `AppFormHeader` leaf (Change handle) put Back or Cancel at
/// the same x, the detail's (or band A's pane's) leading edge. Before, the
/// form leaf's Cancel sat in the 680 column: 4 dp further in where the
/// column filled the pane, and 23 dp at 1199.
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
      tester.getRect(find.byType(BackButton).last);

  Rect cancelOf(WidgetTester tester) => tester.getRect(
    find.descendant(
      of: find.byType(AppFormHeader),
      matching: find.widgetWithText(TextButton, 'Cancel'),
    ),
  );

  // The rig's real leaves (Edit profile, Download my data and Delete account
  // are stubs there; Edit profile uses the same AppFormHeader as Change
  // handle, and the other two the same AppBar as Blocked).
  const barLeaves = [
    AppRouter.blockedAccountsPath,
    AppRouter.mutedAccountsPath,
  ];
  const formLeaves = [AppRouter.changeHandlePath];

  for (final width in [600.0, 839.0, 840.0, 1024.0, 1199.0]) {
    for (final rtl in [false, true]) {
      final label = '${width.toInt()}${rtl ? ' RTL' : ''}';
      testWidgets('$label: Back (AppBar) and Cancel (AppFormHeader) at the '
          'same x, the pane\'s leading edge', (tester) async {
        final dir = rtl ? TextDirection.rtl : TextDirection.ltr;
        final area = pane(width, rtl: rtl);
        double lead(Rect r) => rtl ? area.right - r.right : r.left - area.left;

        final leads = <String, double>{};
        for (final leaf in barLeaves) {
          await open(tester, leaf, width: width, textDirection: dir);
          leads[leaf] = lead(backOf(tester));
          await done(tester);
        }
        for (final leaf in formLeaves) {
          await open(tester, leaf, width: width, textDirection: dir);
          leads[leaf] = lead(cancelOf(tester));
          // The title follows Cancel.
          final title = tester.getRect(
            find.descendant(
              of: find.byType(AppFormHeader),
              matching: find.byWidgetPredicate(
                (w) => w is Semantics && (w.properties.header ?? false),
              ),
            ),
          );
          final cancel = cancelOf(tester);
          if (rtl) {
            expect(title.right, lessThanOrEqualTo(cancel.left));
          } else {
            expect(title.left, greaterThanOrEqualTo(cancel.right));
          }
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
      });
    }
  }

  testWidgets('text scale 2.0 at 840: Cancel still at the AppBar leaf\'s x, '
      'nothing overflows', (tester) async {
    final area = pane(840);
    await open(tester, AppRouter.blockedAccountsPath, width: 840, textScale: 2);
    final back = backOf(tester).left - area.left;
    await done(tester);
    await open(tester, AppRouter.changeHandlePath, width: 840, textScale: 2);
    expectNoOverflow(tester);
    expect(cancelOf(tester).left - area.left, moreOrLessEquals(back));
    expect(cancelOf(tester).right, lessThanOrEqualTo(area.right));
    await done(tester);
  });

  for (final width in [360.0, 1440.0]) {
    testWidgets('${width.toInt()}: Change handle\'s Cancel where it was', (
      tester,
    ) async {
      await open(tester, AppRouter.changeHandlePath, width: width);
      final header = tester.getRect(find.byType(AppFormHeader));
      expect(
        cancelOf(tester).left,
        moreOrLessEquals(header.left + AppSpacing.sm),
      );
      await done(tester);
    });
  }
}
