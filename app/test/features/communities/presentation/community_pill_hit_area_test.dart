import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/gen/dzeroth/communities/v1/communities.pb.dart' as pb;
import 'package:dzeroth/shared/widgets/primitives/app_pill_button.dart';
import 'package:dzeroth/shared/widgets/primitives/pin_to_home.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/communities_tablet_rig.dart';

/// The compact pills of the communities pages take a tap anywhere in their
/// 48 dp box (the shared `AppPillButton`), at a phone, a tablet and a desktop
/// width, and each tap next to a neighbour still goes to the nearest control.
///
/// - The Join pill of an Explore row: inline at 360 and 1440, under the name
///   in band B's context pane at 1024.
/// - Pin to Home beside Join in the community header.

const _widths = <double>[360, 1024, 1440];

/// The Join pill of the "Book club" Explore row.
Finder _joinPill() => find.descendant(
  of: find.byKey(const ValueKey('explore-78')),
  matching: find.byType(AppPillButton),
);

/// The pill (the 36 dp `Ink`) inside [button].
Rect _pillOf(WidgetTester tester, Finder button) =>
    tester.getRect(find.descendant(of: button, matching: find.byType(Ink)));

/// Scrolls [button] into view and checks the whole box is on screen (an
/// off-screen `tapAt` silently misses).
Future<Rect> _boxInView(WidgetTester tester, Finder button) async {
  expect(button, findsOneWidget);
  await tester.ensureVisible(button);
  await tester.pumpAndSettle();
  final box = tester.getRect(button);
  final view = Offset.zero & tester.view.physicalSize;
  expect(view.contains(box.topLeft) && view.contains(box.bottomRight), isTrue);
  expect(box.height, AppSpacing.minTapTarget);
  expect(_pillOf(tester, button).height, AppSize.pillCompact);
  return box;
}

void main() {
  group('the Join pill of an Explore row takes a tap anywhere in its box', () {
    for (final width in _widths) {
      for (final dy in <double>[-5, 5]) {
        final where = dy < 0 ? 'above' : 'below';
        testWidgets('$width dp: 5 dp $where the 36 dp pill joins, and opens '
            'nothing', (tester) async {
          final rig = CommunitiesTabletRig();
          await rig.pump(tester, width: width, height: 1100);
          // R10 (F23): inline, the directory is the Explore tab.
          if (width != 1024) await showExploreTab(tester);
          await _boxInView(tester, _joinPill());
          final pill = _pillOf(tester, _joinPill());
          await tester.tapAt(
            Offset(pill.center.dx, dy < 0 ? pill.top + dy : pill.bottom + dy),
          );
          await tester.pumpAndSettle();
          expect(rig.server.count('join:78'), 1);
          expect(rig.uri.path, AppRouter.communitiesPath);
        });
      }
    }
  });

  group('the Join pill and its row: each tap goes to the nearest', () {
    for (final width in _widths) {
      testWidgets('$width dp: just outside the box opens the row, just '
          'inside it joins', (tester) async {
        final rig = CommunitiesTabletRig();
        await rig.pump(tester, width: width, height: 1100);
        // R10 (F23): inline, the directory is the Explore tab.
        if (width != 1024) await showExploreTab(tester);
        final box = await _boxInView(tester, _joinPill());
        final pill = _pillOf(tester, _joinPill());
        final row = tester.getRect(
          find
              .descendant(
                of: find.byKey(const ValueKey('explore-78')),
                matching: find.byType(InkWell),
              )
              .first,
        );
        // Under the row: in the pane (1024), or a card row whose name would
        // get under 140 dp beside the pill (R10 review item 14; 360 in the
        // test font).
        final paneRow = box.top >= row.bottom - 0.5;
        if (paneRow) {
          // The pill sits under the row: its box starts where the row's ink
          // ends (the 6 dp band was the row's dead space).
          expect(row.bottom, box.top);
        } else {
          // Inline the pill follows the row's ink, which ends at the box.
          expect(row.right, lessThanOrEqualTo(box.left));
          expect(box.left - row.right, lessThan(AppSpacing.sm));
        }
        // Just outside the box, on the row: the row opens the community.
        final outside = paneRow
            ? Offset(pill.center.dx, box.top - 1)
            : Offset(box.left - 1, pill.top - 5);
        expect(row.contains(outside), isTrue);
        await tester.tapAt(outside);
        await tester.pumpAndSettle();
        expect(rig.uri.path, AppRouter.communityPath('78'));
        expect(rig.server.count('join:'), 0);

        rig.router.pop();
        await tester.pumpAndSettle();
        expect(rig.uri.path, AppRouter.communitiesPath);
        expect(tester.getRect(_joinPill()), box);
        // Just inside the box, beside the pill: the Join pill.
        await tester.tapAt(
          paneRow
              ? Offset(pill.center.dx, box.top + 1)
              : Offset(box.left + 1, pill.top - 5),
        );
        await tester.pumpAndSettle();
        expect(rig.server.count('join:78'), 1);
        expect(rig.uri.path, AppRouter.communitiesPath);
      });
    }
  });

  group('the community header: Join and Pin to Home side by side', () {
    Finder headerJoin() => find.ancestor(
      of: find.text('Join'),
      matching: find.byType(AppPillButton),
    );
    Finder pin() => find.descendant(
      of: find.byType(PinToHomeButton),
      matching: find.byType(AppPillButton),
    );

    Future<CommunitiesTabletRig> pumpHeader(
      WidgetTester tester,
      double width,
    ) async {
      final rig = CommunitiesTabletRig();
      rig.server.viewerRole = pb.CommunityRole.COMMUNITY_ROLE_NONE;
      await rig.pump(
        tester,
        location: AppRouter.communityPath(kRigCommunityId),
        width: width,
        height: 1100,
      );
      await _boxInView(tester, headerJoin());
      await _boxInView(tester, pin());
      return rig;
    }

    for (final width in _widths) {
      for (final dy in <double>[-5, 5]) {
        final where = dy < 0 ? 'above' : 'below';
        testWidgets('$width dp: 5 dp $where Pin to Home pins, and does not '
            'join', (tester) async {
          final rig = await pumpHeader(tester, width);
          final pill = _pillOf(tester, pin());
          await tester.tapAt(
            Offset(pill.center.dx, dy < 0 ? pill.top + dy : pill.bottom + dy),
          );
          await tester.pumpAndSettle();
          expect(rig.pinCalls, 1);
          expect(rig.server.count('join:'), 0);
        });
      }

      testWidgets('$width dp: each band goes to its own pill; the gap and '
          'the space above take nothing', (tester) async {
        final rig = await pumpHeader(tester, width);
        final joinBox = tester.getRect(headerJoin());
        final pinBox = tester.getRect(pin());
        // R10b: Join is on the people row (at its end) and Pin to Home on
        // the row under it, so the boxes are stacked and do not overlap.
        expect(pinBox.top, greaterThanOrEqualTo(joinBox.bottom));
        final join = _pillOf(tester, headerJoin());
        final pinPill = _pillOf(tester, pin());

        // The gap between the two rows, over Join.
        await tester.tapAt(
          Offset(joinBox.center.dx, (joinBox.bottom + pinBox.top) / 2),
        );
        // Just above the boxes (the space under the members link).
        await tester.tapAt(Offset(join.center.dx, joinBox.top - 1));
        await tester.pumpAndSettle();
        expect(rig.pinCalls, 0);
        expect(rig.server.count('join:'), 0);
        expect(rig.uri.path, AppRouter.communityPath(kRigCommunityId));

        // The first dp of Pin's box, then the last of Join's (a join turns
        // Join into the wider "Joined", which moves Pin: Join goes last).
        await tester.tapAt(Offset(pinBox.left + 1, pinPill.top - 5));
        await tester.pumpAndSettle();
        expect(rig.pinCalls, 1);
        expect(rig.server.count('join:'), 0);
        expect(tester.getRect(pin()), pinBox);
        await tester.tapAt(Offset(joinBox.right - 1, join.bottom + 5));
        await tester.pumpAndSettle();
        expect(rig.server.count('join:$kRigCommunityId'), 1);
        expect(rig.pinCalls, 1);
      });
    }
  });

  for (final width in _widths) {
    testWidgets('$width dp: the row and its Join pill stay one spoken node '
        'each; the pill node is the 48 dp box', (tester) async {
      final handle = tester.ensureSemantics();
      final rig = CommunitiesTabletRig();
      await rig.pump(tester, width: width, height: 1100);
      // R10 (F23): inline, the directory is the Explore tab.
      if (width != 1024) await showExploreTab(tester);
      final box = await _boxInView(tester, _joinPill());
      expect(find.bySemanticsLabel('Join Book club'), findsOneWidget);
      final node = tester.getSemantics(find.bySemanticsLabel('Join Book club'));
      expect(node.rect.size, box.size);
      expect(find.bySemanticsLabel(RegExp(r'^Book club, ')), findsOneWidget);
      handle.dispose();
    });
  }
}
