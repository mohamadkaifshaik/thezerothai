import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/communities/presentation/community_members_screen.dart';
import 'package:dzeroth/shared/widgets/primitives/app_back_header.dart';
import 'package:dzeroth/shared/widgets/primitives/app_main_column.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/communities_tablet_rig.dart';
import '../../../support/geometry.dart';

/// T8e: CommunityMembers' reading column (tablet plan section 4.1: F in band
/// A, P in band B). The members are at most 680 and centred in the primary
/// pane, while the header's divider spans the pane; a primary pane of 680
/// or less is filled. (The Members / Banned tabs are a moderator's; the tab
/// bar's hairline is covered by `app_main_column_test`.)
void main() {
  Rect column(WidgetTester tester) => tester.getRect(
    find.descendant(
      of: find.byType(CommunityMembersScreen),
      matching: find.byType(AppMainColumnBleed),
    ),
  );

  Future<void> done(WidgetTester tester) => tester.pumpWidget(const SizedBox());

  for (final width in [600.0, 744.0, 839.0, 840.0, 1024.0, 1199.0]) {
    testWidgets('${width.toInt()}: the column, the header and the tab bar', (
      tester,
    ) async {
      final rig = CommunitiesTabletRig();
      await rig.pump(
        tester,
        location: AppRouter.communityMembersPath(kRigCommunityId),
        width: width,
      );
      // The primary pane (beside a context pane in band B when the page
      // has sections).
      final area = tester.getRect(find.byKey(const ValueKey('tablet-primary')));
      expect(area.left, 80);
      final primary = area.width;
      final col = column(tester);
      final expected = primary < AppSize.readableMax
          ? primary
          : AppSize.readableMax;
      expect(col.width, moreOrLessEquals(expected));
      expect(col.center.dx, moreOrLessEquals(area.center.dx));
      final divider = tester.getRect(
        find
            .descendant(
              of: find.byType(AppBackHeader),
              matching: find.byType(Divider),
            )
            .first,
      );
      expect(divider.left, moreOrLessEquals(area.left));
      expect(divider.right, moreOrLessEquals(area.right));
      expectNoOverflow(tester);
      await done(tester);
    });
  }

  testWidgets('text scale 2.0 at 839: nothing overflows', (tester) async {
    final rig = CommunitiesTabletRig();
    await rig.pump(
      tester,
      location: AppRouter.communityMembersPath(kRigCommunityId),
      width: 839,
      textScale: 2,
    );
    expectNoOverflow(tester);
    await done(tester);
  });
}
