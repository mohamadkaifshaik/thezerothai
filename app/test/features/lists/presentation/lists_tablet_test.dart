import 'package:dzeroth/core/router/app_router.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/lists_tablet_rig.dart';
import '../../../support/tablet_modal_harness.dart'
    show openDialogRect, tabletContentRect;

// Menus and dialogs on the tablet layout (plan section 4.2): the List's
// overflow menu stays anchored, and the Remove confirm and the List editor
// are dialogs on the content area.

final _listPath = AppRouter.listPath(kRigListId);
final _membersPath = AppRouter.listMembersPath(kRigListId);

/// Opens the List as the app does: a row of Lists pushes it.
Future<void> _openList(
  WidgetTester tester,
  ListsTabletRig rig, {
  double width = 1024,
}) => rig.pump(
  tester,
  location: AppRouter.listsPath,
  push: [_listPath],
  width: width,
);

void main() {
  group('section 4.2: menus and dialogs', () {
    for (final w in <double>[834, 1024]) {
      testWidgets('at $w "More options" on a List stays an anchored menu', (
        tester,
      ) async {
        final rig = ListsTabletRig();
        await _openList(tester, rig, width: w);
        final button = inListsPage(find.byTooltip('More options'));
        await tester.tap(button);
        await tester.pumpAndSettle();
        final item = find.text('Report List');
        expect(item, findsOneWidget);
        expect(find.byType(Dialog), findsNothing);
        expect(find.byType(BottomSheet), findsNothing);
        final itemRect = tester.getRect(item);
        expect(
          (itemRect.center - tester.getCenter(button)).distance,
          lessThan(300),
        );
        expect(
          itemRect.right,
          lessThanOrEqualTo(tester.getRect(findListsPage()).right),
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(item, findsNothing);
      });
    }

    for (final w in <double>[700, 1024]) {
      final content = tabletContentRect(Size(w, 900));

      testWidgets('at $w the Remove confirm is a D 280-400 on the content '
          'area; Escape cancels', (tester) async {
        final rig = ListsTabletRig()..server.viewerOwnsList = true;
        await rig.pump(
          tester,
          location: AppRouter.listsPath,
          push: [_listPath, _membersPath],
          width: w,
        );
        await tester.tap(find.bySemanticsLabel('Remove @mia from this List'));
        await tester.pumpAndSettle();
        expect(find.text('Remove @mia?'), findsOneWidget);
        final rect = openDialogRect(tester);
        expect(rect.width, inInclusiveRange(280, 400));
        expect(rect.center.dx, closeTo(content.center.dx, 1));
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.text('Remove @mia?'), findsNothing);
        expect(rig.server.count('RemoveListMember'), 0);
      });

      testWidgets('at $w the List editor is a dialog on the content area, '
          'and its Delete confirm a D 280-400; Escape cancels', (tester) async {
        final rig = ListsTabletRig();
        await rig.pump(tester, width: w);
        await tester.tap(find.byTooltip('Edit Books'));
        await tester.pumpAndSettle();
        expect(find.text('Edit List'), findsOneWidget);
        final editor = openDialogRect(tester);
        expect(editor.width, lessThanOrEqualTo(480));
        expect(editor.width, lessThanOrEqualTo(content.width - 48));
        expect(editor.center.dx, closeTo(content.center.dx, 1));

        await tester.ensureVisible(find.text('Delete List'));
        await tester.tap(find.text('Delete List'));
        await tester.pumpAndSettle();
        expect(find.text('Delete this List?'), findsOneWidget);
        final confirm = tester.getRect(
          find
              .descendant(
                of: find.byType(AlertDialog),
                matching: find.byType(Material),
              )
              .first,
        );
        expect(confirm.width, inInclusiveRange(280, 400));
        expect(confirm.center.dx, closeTo(content.center.dx, 1));
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.text('Delete this List?'), findsNothing);
        expect(find.text('Edit List'), findsOneWidget);
      });
    }
  });
}
