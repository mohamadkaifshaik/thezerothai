import 'dart:async';

import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/communities/domain/communities_feature_flag.dart';
import 'package:dzeroth/features/communities/presentation/widgets/community_header.dart';
import 'package:dzeroth/features/communities/presentation/widgets/community_join_control.dart';
import 'package:dzeroth/gen/dzeroth/communities/v1/communities.pb.dart' as pb;
import 'package:dzeroth/shared/widgets/primitives/app_tab_bar.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/communities_tablet_rig.dart';
import '../../../support/context_pane_rig.dart' show findContextPane;

/// The R10 UX review's items (Must-fix 1-3, Should-fix 4-11, Nice-to-have
/// 12-14), each written before its fix.

final _searchFlags = {
  ...kCommunitiesTabletFlags,
  kFeatureCommunityMemberSearch,
};

final _membersPath = AppRouter.communityMembersPath(kRigCommunityId);
final _communityPath = AppRouter.communityPath(kRigCommunityId);

const _communitiesHint = 'Search communities';
const _membersHint = 'Search members by handle';

Finder _field(String hint) => find.byWidgetPredicate(
  (w) => w is TextField && w.decoration?.hintText == hint,
);

Future<void> _typeMembers(WidgetTester tester, String text) async {
  await tester.enterText(_field(_membersHint), text);
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pumpAndSettle();
}

List<pb.Community> _directoryOf(int n) => [
  for (var i = 0; i < n; i++)
    pb.Community(
      communityId: '${100 + i}',
      name: 'Club $i',
      memberCount: Int64(2),
      viewerRole: pb.CommunityRole.COMMUNITY_ROLE_NONE,
    ),
];

void main() {
  group('1-2. the no-match copy, and no "Try Search"', () {
    for (final w in <double>[360, 1024]) {
      testWidgets('$w: 50 loaded rows: "No matches among the Communities '
          'shown." and no Try Search', (tester) async {
        final rig = CommunitiesTabletRig();
        rig.server.directory = _directoryOf(50);
        await rig.pump(tester, width: w);
        await showExploreTab(tester);
        await tester.enterText(_field(_communitiesHint), 'zzz');
        await tester.pumpAndSettle();
        expect(
          find.text('No matches among the Communities shown.'),
          findsOneWidget,
        );
        expect(find.text('Try Search'), findsNothing);
      });
    }

    testWidgets('a whole list: "No Communities match."', (tester) async {
      final rig = CommunitiesTabletRig();
      rig.server.directory = _directoryOf(49);
      await rig.pump(tester, width: 360);
      await showExploreTab(tester);
      await tester.enterText(_field(_communitiesHint), 'zzz');
      await tester.pumpAndSettle();
      expect(find.text('No Communities match.'), findsOneWidget);
    });
  });

  group('3. no tab label is ellipsized at large text', () {
    List<RenderParagraph> tabLabels(WidgetTester tester) => tester
        .renderObjectList<RenderParagraph>(
          find.descendant(
            of: find.byType(AppTabBar),
            matching: find.byType(RichText),
          ),
        )
        .toList();

    for (final w in <double>[320, 360]) {
      for (final scale in <double>[1.3, 2.0]) {
        testWidgets('$w x$scale: Communities and Members (moderator)', (
          tester,
        ) async {
          final rig = CommunitiesTabletRig();
          rig.server.viewerRole = pb.CommunityRole.COMMUNITY_ROLE_MODERATOR;
          await rig.pump(tester, width: w, height: 900, textScale: scale);
          var labels = tabLabels(tester);
          expect(labels, hasLength(2));
          for (final p in labels) {
            expect(p.didExceedMaxLines, isFalse, reason: p.text.toPlainText());
          }
          final members = CommunitiesTabletRig();
          members.server.viewerRole = pb.CommunityRole.COMMUNITY_ROLE_MODERATOR;
          await members.pump(
            tester,
            location: _membersPath,
            width: w,
            height: 900,
            textScale: scale,
          );
          labels = tabLabels(tester);
          expect(labels, hasLength(3));
          for (final p in labels) {
            expect(p.didExceedMaxLines, isFalse, reason: p.text.toPlainText());
          }
          expect(tester.takeException(), isNull);
        });
      }
    }
  });

  group('4-7. the members search field', () {
    testWidgets('4. more than 15 characters says so; a dot keeps the '
        'general hint', (tester) async {
      final rig = CommunitiesTabletRig();
      await rig.pump(
        tester,
        location: _membersPath,
        width: 360,
        flags: _searchFlags,
      );
      await _typeMembers(tester, 'abcdefghijklmnop');
      expect(
        find.text(
          'Search by handle: up to 15 letters, numbers or underscores.',
        ),
        findsOneWidget,
      );
      await _typeMembers(tester, 'a.b');
      expect(
        find.text('Search by handle: letters, numbers and underscores.'),
        findsOneWidget,
      );
      expect(rig.server.count('search:'), 0);
    });

    testWidgets('5. the hint names the handle; the spoken name stays '
        '"Search members"; one character shows the helper', (tester) async {
      final handle = tester.ensureSemantics();
      final rig = CommunitiesTabletRig();
      await rig.pump(
        tester,
        location: _membersPath,
        width: 360,
        flags: _searchFlags,
      );
      expect(_field(_membersHint), findsOneWidget);
      expect(
        tester.getSemantics(_field(_membersHint)).label,
        startsWith('Search members'),
      );
      await _typeMembers(tester, 'm');
      expect(find.text('Type at least 2 characters.'), findsOneWidget);
      expect(find.text('Member 1'), findsOneWidget);
      await _typeMembers(tester, 'me');
      expect(find.text('Type at least 2 characters.'), findsNothing);
      handle.dispose();
    });

    testWidgets('6. no result names the tab: Moderators and Banned', (
      tester,
    ) async {
      final rig = CommunitiesTabletRig();
      rig.server.viewerRole = pb.CommunityRole.COMMUNITY_ROLE_MODERATOR;
      await rig.pump(
        tester,
        location: _membersPath,
        width: 360,
        flags: _searchFlags,
      );
      await tapCommunityTab(tester, 'Banned');
      await _typeMembers(tester, 'zz');
      expect(
        find.text('No banned people found for that handle.'),
        findsOneWidget,
      );
      await tapCommunityTab(tester, 'Moderators');
      expect(find.text('No moderators found for that handle.'), findsOneWidget);
    });

    testWidgets('7. the Moderators tab filters its loaded list by handle '
        'prefix, with no call', (tester) async {
      final rig = CommunitiesTabletRig();
      rig.server.viewerRole = pb.CommunityRole.COMMUNITY_ROLE_MODERATOR;
      await rig.pump(
        tester,
        location: _membersPath,
        width: 360,
        flags: _searchFlags,
      );
      await tapCommunityTab(tester, 'Moderators');
      await _typeMembers(tester, 'mo');
      expect(find.text('Mo'), findsOneWidget);
      expect(find.text('Olivia'), findsNothing);
      await _typeMembers(tester, '@OL');
      expect(find.text('Olivia'), findsOneWidget);
      expect(find.text('Mo'), findsNothing);
      expect(rig.server.count('search:'), 0);
      expect(
        rig.server.count(
          'members:$kRigCommunityId:COMMUNITY_MEMBER_FILTER_MODERATORS',
        ),
        1,
      );
    });
  });

  group('8. no skeleton flash; a polite count line', () {
    testWidgets('members: the last results stay while the next search '
        'loads, under "N members match @x"', (tester) async {
      final handle = tester.ensureSemantics();
      final rig = CommunitiesTabletRig();
      await rig.pump(
        tester,
        location: _membersPath,
        width: 360,
        flags: _searchFlags,
      );
      await _typeMembers(tester, 'mem');
      final line = find.text('3 members match @mem');
      expect(line, findsOneWidget);
      expect(tester.getSemantics(line).flagsCollection.isLiveRegion, isTrue);

      final hold = rig.server.holdSearch = Completer<void>();
      await tester.enterText(_field(_membersHint), 'member1');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      expect(find.text('Member 2'), findsOneWidget);
      expect(find.bySemanticsLabel('Searching members'), findsNothing);
      hold.complete();
      await tester.pumpAndSettle();
      expect(find.text('1 member matches @member1'), findsOneWidget);
      expect(find.text('Member 2'), findsNothing);
      handle.dispose();
    });

    testWidgets('Communities: "N Communities match" over a filtered list, '
        'live', (tester) async {
      final handle = tester.ensureSemantics();
      final rig = CommunitiesTabletRig();
      await rig.pump(tester, width: 360);
      await showExploreTab(tester);
      await tester.enterText(_field(_communitiesHint), 'club');
      await tester.pumpAndSettle();
      final line = find.text('2 Communities match "club"');
      expect(line, findsOneWidget);
      expect(tester.getSemantics(line).flagsCollection.isLiveRegion, isTrue);
      await tester.enterText(_field(_communitiesHint), 'book');
      await tester.pumpAndSettle();
      expect(find.text('1 Community matches "book"'), findsOneWidget);
      handle.dispose();
    });
  });

  group('9. a match in the other tab', () {
    testWidgets('360: none in My communities, one in Explore: "See 1 in '
        'Explore" (48 dp) switches tabs', (tester) async {
      final rig = CommunitiesTabletRig();
      await rig.pump(tester, width: 360);
      await tester.enterText(_field(_communitiesHint), 'book');
      await tester.pumpAndSettle();
      final see = find.text('See 1 in Explore');
      expect(see, findsOneWidget);
      expect(
        tester
            .getSize(find.ancestor(of: see, matching: find.byType(TextButton)))
            .height,
        greaterThanOrEqualTo(AppSpacing.minTapTarget),
      );
      await tester.tap(see);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('explore-78')), findsOneWidget);
    });

    testWidgets('no button when the other tab has none either', (tester) async {
      final rig = CommunitiesTabletRig();
      await rig.pump(tester, width: 360);
      await tester.enterText(_field(_communitiesHint), 'zzz');
      await tester.pumpAndSettle();
      expect(find.textContaining('See '), findsNothing);
    });
  });

  group('10. one empty-My-communities sentence in every layout', () {
    for (final w in <double>[360, 744, 1024, 1200]) {
      testWidgets('$w', (tester) async {
        final rig = CommunitiesTabletRig();
        rig.server.directory = _directoryOf(2);
        await rig.pump(tester, width: w);
        expect(
          inCommunitiesPage(
            find.text(
              "You haven't joined any Communities yet. Join one from "
              'Explore to see its posts.',
            ),
          ),
          findsOneWidget,
        );
      });
    }
  });

  group('11. the description in the Community header', () {
    for (final w in <double>[360, 744, 1024, 1440]) {
      testWidgets('$w: in the header, 2 lines at most; there is no pane', (
        tester,
      ) async {
        final rig = CommunitiesTabletRig();
        await rig.pump(tester, location: _communityPath, width: w);
        final text = find.descendant(
          of: find.byType(CommunityHeader),
          matching: find.text('Openings, endgames and puzzles'),
        );
        expect(text, findsOneWidget);
        final widget = tester.widget<Text>(text);
        expect(widget.maxLines, 2);
        expect(widget.overflow, TextOverflow.ellipsis);
        expect(find.text('About this Community'), findsNothing);
        expect(findContextPane(), findsNothing);
        expect(find.text('Openings, endgames and puzzles'), findsOneWidget);
      });
    }

    testWidgets('an empty description draws nothing in the header', (
      tester,
    ) async {
      final rig = CommunitiesTabletRig();
      rig.server.description = '';
      await rig.pump(tester, location: _communityPath, width: 360);
      final before = tester.getSize(find.byType(CommunityHeader)).height;
      final blank = find.descendant(
        of: find.byType(CommunityHeader),
        matching: find.byWidgetPredicate((w) => w is Text && w.data == ''),
      );
      expect(blank, findsNothing);
      final rig2 = CommunitiesTabletRig();
      rig2.server.description = 'Openings';
      await rig2.pump(tester, location: _communityPath, width: 360);
      expect(
        tester.getSize(find.byType(CommunityHeader)).height,
        greaterThan(before),
      );
    });
  });

  group('12-14. nice-to-have', () {
    testWidgets('12. the members header keeps its height when the name '
        'arrives (x1.3)', (tester) async {
      final rig = CommunitiesTabletRig();
      final hold = rig.server.holdGet = Completer<void>();
      await rig.pump(
        tester,
        location: _membersPath,
        width: 360,
        textScale: 1.3,
        settle: false,
      );
      final title = find.text('Members').first;
      final before = tester.getRect(title).top;
      final listTop = tester.getRect(find.text('Member 1')).top;
      hold.complete();
      await tester.pumpAndSettle();
      expect(tester.getRect(find.text('Members').first).top, before);
      expect(tester.getRect(find.text('Member 1')).top, listTop);
      expect(inCommunitiesPage(find.text('Chess club')), findsOneWidget);
    });

    testWidgets('13. band B: when the server turns member search off, the '
        'inline field goes and the page stays whole, with no pane', (
      tester,
    ) async {
      final rig = CommunitiesTabletRig();
      rig.server.searchError = const FeatureDisabledException(
        'off',
        feature: kFeatureCommunityMemberSearch,
      );
      await rig.pump(
        tester,
        location: _membersPath,
        width: 1024,
        flags: _searchFlags,
      );
      expect(findContextPane(), findsNothing);
      await tester.enterText(inCommunitiesPage(_field(_membersHint)), 'mem');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(_field(_membersHint), findsNothing);
      expect(findContextPane(), findsNothing);
      expect(inCommunitiesPage(find.text('Member 1')), findsOneWidget);
    });

    testWidgets('14. at 320 x1.0 a row whose name would get under 140 dp '
        'stacks its pill under the name', (tester) async {
      final rig = CommunitiesTabletRig();
      await rig.pump(tester, width: 320);
      await showExploreTab(tester);
      final row = find.byKey(const ValueKey('explore-78'));
      final name = tester.getRect(
        find.descendant(of: row, matching: find.text('Book club')),
      );
      final join = tester.getRect(
        find.descendant(of: row, matching: find.byType(CommunityJoinControl)),
      );
      expect(join.top, greaterThanOrEqualTo(name.bottom));
      expect(tester.takeException(), isNull);
    });

    testWidgets('14. at 744 x1.0 the pill stays beside a wide name', (
      tester,
    ) async {
      final rig = CommunitiesTabletRig();
      await rig.pump(tester, width: 744);
      await showExploreTab(tester);
      final row = find.byKey(const ValueKey('explore-78'));
      final name = tester.getRect(
        find.descendant(of: row, matching: find.text('Book club')),
      );
      final join = tester.getRect(
        find.descendant(of: row, matching: find.byType(CommunityJoinControl)),
      );
      expect(join.left, greaterThan(name.right));
    });
  });
}
