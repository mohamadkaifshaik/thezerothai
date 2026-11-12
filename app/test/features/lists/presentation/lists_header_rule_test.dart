import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/lists/presentation/list_detail_screen.dart';
import 'package:dzeroth/features/lists/presentation/lists_screen.dart';
import 'package:dzeroth/shared/widgets/primitives/app_back_header.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/geometry.dart';
import '../../../support/lists_tablet_rig.dart';

/// T8f, one header rule, in the shell's panes: Lists (an `AppMainColumn`
/// page in the primary pane) and a List (its header is a sliver of
/// `TimelineFeedView`, laid out across the pane). Back leads the pane, the
/// actions end it, and both take real taps there; the header's divider
/// marks the pane (it spans it since T8e).
void main() {
  Future<void> done(WidgetTester tester) => tester.pumpWidget(const SizedBox());

  Finder headerOf(Type screen) => find.descendant(
    of: find.byType(screen),
    matching: find.byType(AppBackHeader),
  );

  Rect paneOf(WidgetTester tester, Type screen) => tester.getRect(
    find.descendant(of: headerOf(screen), matching: find.byType(Divider)),
  );

  Rect controlOf(WidgetTester tester, Type screen, String tooltip) =>
      tester.getRect(
        find.descendant(
          of: headerOf(screen),
          matching: find.byTooltip(tooltip),
        ),
      );

  for (final width in [600.0, 839.0, 840.0, 1024.0, 1199.0]) {
    for (final rtl in [false, true]) {
      final label = '${width.toInt()}${rtl ? ' RTL' : ''}';

      testWidgets('$label: Lists, Create at the pane edge and no Back (a rail '
          'destination)', (tester) async {
        final rig = ListsTabletRig();
        await rig.pump(
          tester,
          push: [AppRouter.listsPath],
          width: width,
          location: AppRouter.homePath,
          textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
        );
        final pane = paneOf(tester, ListsScreen);
        final create = controlOf(tester, ListsScreen, 'Create a new List');
        expect(
          find.descendant(
            of: headerOf(ListsScreen),
            matching: find.byTooltip('Back'),
          ),
          findsNothing,
        );
        if (rtl) {
          expect(create.left, moreOrLessEquals(pane.left + AppSpacing.xs));
        } else {
          expect(create.right, moreOrLessEquals(pane.right - AppSpacing.xs));
        }
        expectNoOverflow(tester);
        await done(tester);
      });

      testWidgets('$label: a List (a feed header), Back and More options at '
          'the pane edges', (tester) async {
        final rig = ListsTabletRig();
        await rig.pump(
          tester,
          push: [AppRouter.listPath(kRigListId)],
          width: width,
          textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
        );
        final pane = paneOf(tester, ListDetailScreen);
        final back = controlOf(tester, ListDetailScreen, 'Back');
        final more = find.descendant(
          of: headerOf(ListDetailScreen),
          matching: find.byTooltip('More options'),
        );
        if (rtl) {
          expect(back.right, moreOrLessEquals(pane.right - AppSpacing.xs));
        } else {
          expect(back.left, moreOrLessEquals(pane.left + AppSpacing.xs));
        }
        if (more.evaluate().isNotEmpty) {
          final rect = tester.getRect(more);
          if (rtl) {
            expect(rect.left, moreOrLessEquals(pane.left + AppSpacing.xs));
          } else {
            expect(rect.right, moreOrLessEquals(pane.right - AppSpacing.xs));
          }
        }
        expectNoOverflow(tester);
        await tester.tapAt(back.center);
        await tester.pumpAndSettle();
        expect(find.byType(ListDetailScreen), findsNothing);
        await done(tester);
      });
    }
  }

  testWidgets("1440: a List's Back where it was (the column's edge)", (
    tester,
  ) async {
    final rig = ListsTabletRig();
    await rig.pump(tester, push: [AppRouter.listPath(kRigListId)], width: 1440);
    final header = tester.getRect(headerOf(ListDetailScreen));
    final back = controlOf(tester, ListDetailScreen, 'Back');
    expect(back.left, moreOrLessEquals(header.left + AppSpacing.xs));
    await done(tester);
  });
}
