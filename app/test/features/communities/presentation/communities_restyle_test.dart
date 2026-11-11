import 'dart:async';

import 'package:dzeroth/core/feature_flags/ui_shell_feature_flag.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/core/widgets/app_error_view.dart'
    show rateLimitedMessage;
import 'package:dzeroth/core/widgets/context_pane.dart';
import 'package:dzeroth/features/communities/domain/communities_feature_flag.dart';
import 'package:dzeroth/features/communities/presentation/communities_screen.dart';
import 'package:dzeroth/features/communities/presentation/community_members_screen.dart';
import 'package:dzeroth/features/communities/presentation/widgets/community_header.dart';
import 'package:dzeroth/features/communities/presentation/widgets/community_join_control.dart';
import 'package:dzeroth/features/communities/presentation/widgets/community_preview.dart';
import 'package:dzeroth/features/communities/presentation/widgets/community_row.dart';
import 'package:dzeroth/features/communities/presentation/widgets/community_search_field.dart';
import 'package:dzeroth/features/communities/presentation/widgets/moderation_log_row.dart';
import 'package:dzeroth/gen/dzeroth/communities/v1/communities.pb.dart' as pb;
import 'package:dzeroth/shared/widgets/primitives/app_card.dart';
import 'package:dzeroth/shared/widgets/primitives/app_pill_button.dart';
import 'package:dzeroth/shared/widgets/primitives/app_tab_bar.dart';
import 'package:dzeroth/shared/widgets/primitives/app_tile_icon.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/communities_tablet_rig.dart';
import '../../../support/context_pane_rig.dart'
    show findContextPane, inContextPane;

/// R10: the communities restyle, F23 tabs, F37 "Search communities", F24's
/// Moderators tab, F36 "Search members" and the Joined pill's 48 dp target,
/// at the widths where the layout differs.

const _widths = <double>[360, 599, 600, 839, 840, 1024, 1199, 1200, 1440];

bool _bandB(double w) =>
    w >= AppBreakpoints.expanded && w < AppBreakpoints.tablet;

/// With `community_member_search` (F36) on as well.
final _searchFlags = {
  ...kCommunitiesTabletFlags,
  kFeatureCommunityMemberSearch,
};

final _membersPath = AppRouter.communityMembersPath(kRigCommunityId);
final _communityPath = AppRouter.communityPath(kRigCommunityId);

/// A text field whose hint is [text].
Finder _field(String text) => find.byWidgetPredicate(
  (w) => w is TextField && w.decoration?.hintText == text,
);

List<ContextSectionKind> _paneKinds(WidgetTester tester) {
  final pane = findContextPane();
  if (pane.evaluate().isEmpty) return const [];
  return [for (final s in tester.widget<ContextPane>(pane).sections) s.kind];
}

/// Types [text] in the field named [hint] and lets the 300 ms debounce
/// and the answer through.
Future<void> _type(WidgetTester tester, String hint, String text) async {
  await tester.enterText(_field(hint), text);
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
  group('Communities: F23 tabs and F37 filter, per width', () {
    for (final w in _widths) {
      testWidgets(
        '$w: ${_bandB(w) ? 'no tabs, My communities | the pane\'s '
                  'filter over Explore communities' : 'the filter, then My '
                  'communities / Explore tabs'}',
        (tester) async {
          final rig = CommunitiesTabletRig();
          await rig.pump(tester, width: w);
          expect(tester.takeException(), isNull);
          expect(_field(kSearchCommunitiesHint), findsOneWidget);
          if (_bandB(w)) {
            expect(find.byType(AppTabBar), findsNothing);
            expect(
              inCommunitiesPage(find.text(kMyCommunitiesTitle)),
              findsOneWidget,
            );
            expect(
              inContextPane(_field(kSearchCommunitiesHint)),
              findsOneWidget,
            );
            // The field sits above the Explore communities card.
            expect(
              tester.getRect(inContextPane(_field(kSearchCommunitiesHint))).top,
              lessThan(
                tester
                    .getRect(inContextPane(find.text('Explore communities')))
                    .top,
              ),
            );
          } else {
            expect(findContextPane(), findsNothing);
            final field = inCommunitiesPage(_field(kSearchCommunitiesHint));
            expect(field, findsOneWidget);
            expect(
              tester.getRect(field).bottom,
              lessThanOrEqualTo(tester.getRect(find.byType(AppTabBar)).top),
            );
            // My communities first; Explore shows the directory.
            expect(
              inCommunitiesPage(find.byKey(ValueKey('mine-$kRigCommunityId'))),
              findsOneWidget,
            );
            expect(find.byKey(const ValueKey('explore-78')), findsNothing);
            await showExploreTab(tester);
            expect(
              inCommunitiesPage(find.byKey(const ValueKey('explore-78'))),
              findsOneWidget,
            );
            expect(find.byKey(ValueKey('mine-$kRigCommunityId')), findsNothing);
          }
          // Both lists load on open, once, whichever tab shows.
          expect(rig.server.count('mine'), 1);
          expect(rig.server.count('directory'), 1);
        },
      );
    }

    for (final w in <double>[360, 744, 1200]) {
      testWidgets('$w: the filter narrows both tabs by name, with no call', (
        tester,
      ) async {
        final rig = CommunitiesTabletRig();
        await rig.pump(tester, width: w);
        await tester.enterText(_field(kSearchCommunitiesHint), 'BOOK');
        await tester.pumpAndSettle();
        // My communities holds only Chess club: nothing matches, and the
        // list is whole (one row, no next page).
        expect(
          inCommunitiesPage(find.text(kNoCommunitiesMatch)),
          findsOneWidget,
        );
        await showExploreTab(tester);
        expect(find.byKey(const ValueKey('explore-78')), findsOneWidget);
        expect(find.byKey(const ValueKey('explore-79')), findsNothing);
        expect(find.byKey(ValueKey('explore-$kRigCommunityId')), findsNothing);
        // Clear: every row again.
        await tester.tap(find.byTooltip('Clear search'));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('explore-79')), findsOneWidget);
        expect(rig.server.count('mine'), 1);
        expect(rig.server.count('directory'), 1);
      });
    }

    testWidgets('band B (1024): the pane\'s filter narrows the pane and the '
        'page; the text follows the field to band A and back', (tester) async {
      final rig = CommunitiesTabletRig();
      await rig.pump(tester, width: 1024);
      await tester.enterText(
        inContextPane(_field(kSearchCommunitiesHint)),
        'run',
      );
      await tester.pumpAndSettle();
      expect(inContextPane(find.byKey(const ValueKey('explore-79'))), findsOne);
      expect(
        inContextPane(find.byKey(const ValueKey('explore-78'))),
        findsNothing,
      );
      expect(inCommunitiesPage(find.text(kNoCommunitiesMatch)), findsOneWidget);

      await rig.resize(tester, 744);
      final inline = inCommunitiesPage(_field(kSearchCommunitiesHint));
      expect(tester.widget<TextField>(inline).controller!.text, 'run');
      await rig.resize(tester, 1024);
      expect(
        tester
            .widget<TextField>(inContextPane(_field(kSearchCommunitiesHint)))
            .controller!
            .text,
        'run',
      );
      expect(rig.server.count('directory'), 1);
    });

    testWidgets('band B: the pane placeholder has the field\'s box, so the '
        'lent section does not jump', (tester) async {
      final rig = CommunitiesTabletRig();
      await rig.pump(tester, location: AppRouter.homePath, width: 1024);
      unawaited(rig.router.push(AppRouter.communitiesPath));
      await tester.pump();
      final field = inContextPane(_field(kSearchCommunitiesHint));
      expect(field, findsOneWidget);
      final top = tester.getRect(field).top;
      await tester.pumpAndSettle();
      expect(tester.getRect(field).top, top);
    });

    group('no match over a list that may be cut short (F37 v1)', () {
      for (final searchOn in [true, false]) {
        testWidgets('50 loaded rows, search ${searchOn ? 'on' : 'off'}: the '
            '"shown" note and no Try Search (review item 1)', (tester) async {
          final rig = CommunitiesTabletRig();
          rig.server.directory = _directoryOf(50);
          await rig.pump(
            tester,
            width: 360,
            flags: searchOn
                ? kCommunitiesTabletFlags
                : ({...kCommunitiesTabletFlags}..remove('search')),
          );
          await showExploreTab(tester);
          await tester.enterText(_field(kSearchCommunitiesHint), 'zzz');
          await tester.pumpAndSettle();
          expect(find.text(kNoLoadedCommunitiesMatch), findsOneWidget);
          expect(find.text(kNoCommunitiesMatch), findsNothing);
          // R10 review item 1: global search has no communities.
          expect(find.text('Try Search'), findsNothing);
        });
      }

      testWidgets('49 loaded rows: "No Communities match", no Search', (
        tester,
      ) async {
        final rig = CommunitiesTabletRig();
        rig.server.directory = _directoryOf(49);
        await rig.pump(tester, width: 360);
        await showExploreTab(tester);
        await tester.enterText(_field(kSearchCommunitiesHint), 'zzz');
        await tester.pumpAndSettle();
        expect(find.text(kNoCommunitiesMatch), findsOneWidget);
        expect(find.text('Try Search'), findsNothing);
      });

      testWidgets('band B: the same rule in the pane', (tester) async {
        final rig = CommunitiesTabletRig();
        rig.server.directory = _directoryOf(50);
        await rig.pump(tester, width: 1024);
        await tester.enterText(
          inContextPane(_field(kSearchCommunitiesHint)),
          'zzz',
        );
        await tester.pumpAndSettle();
        expect(inContextPane(find.text(kNoLoadedCommunitiesMatch)), findsOne);
        expect(find.text('Try Search'), findsNothing);
      });
    });

    testWidgets('empty My communities names the Explore tab outside band B', (
      tester,
    ) async {
      final rig = CommunitiesTabletRig();
      rig.server.directory = _directoryOf(2);
      await rig.pump(tester, width: 360);
      expect(find.text(kEmptyMineTabs), findsOneWidget);
    });
  });

  group('Communities: the card rows (R10)', () {
    testWidgets('inline rows are cards with the description; an empty '
        'description draws and says nothing', (tester) async {
      final handle = tester.ensureSemantics();
      final rig = CommunitiesTabletRig();
      rig.server.directory = [
        for (final c in rig.server.directory)
          c.communityId == '78' ? (c.deepCopy()..description = 'Novels') : c,
      ];
      await rig.pump(tester, width: 360);
      await showExploreTab(tester);
      final book = find.byKey(const ValueKey('explore-78'));
      final running = find.byKey(const ValueKey('explore-79'));
      expect(
        find.descendant(of: book, matching: find.byType(AppCard)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: book, matching: find.text('Novels')),
        findsOne,
      );
      expect(find.bySemanticsLabel('Book club, Novels, 2 members'), findsOne);
      expect(find.bySemanticsLabel('Running, 2 members'), findsOneWidget);
      final tile = tester.getSize(
        find.descendant(of: running, matching: find.byType(AppTileIcon)),
      );
      expect(tile, const Size.square(CommunityRow.cardTileSize));
      handle.dispose();
    });

    testWidgets('band B: the pane rows stay plain rows (no card in a card)', (
      tester,
    ) async {
      final rig = CommunitiesTabletRig();
      await rig.pump(tester, width: 1024);
      expect(
        find.descendant(
          of: inContextPane(find.byKey(const ValueKey('explore-78'))),
          matching: find.byType(AppCard),
        ),
        findsNothing,
      );
      // My communities, in the page, is cards.
      expect(
        find.descendant(
          of: find.byKey(ValueKey('mine-$kRigCommunityId')),
          matching: find.byType(AppCard),
        ),
        findsOneWidget,
      );
    });

    testWidgets('text scale 2.0 at 320: the pill goes under the name, the '
        'name keeps its width', (tester) async {
      final rig = CommunitiesTabletRig();
      await rig.pump(tester, width: 320, height: 1194, textScale: 2);
      await showExploreTab(tester);
      expect(tester.takeException(), isNull);
      final row = find.byKey(const ValueKey('explore-78'));
      final name = tester.getRect(
        find.descendant(of: row, matching: find.text('Book club')),
      );
      final join = tester.getRect(
        find.descendant(of: row, matching: find.byType(CommunityJoinControl)),
      );
      expect(join.top, greaterThan(name.bottom));
      expect(join.left, closeTo(name.left, 1));
    });

    testWidgets('text scale 1.3 at 744: the pill stays beside the name', (
      tester,
    ) async {
      // R10 review item 14: at 360 the name would get under 140 dp in the
      // test font, so the pill stacks there; 744 keeps it beside.
      final rig = CommunitiesTabletRig();
      await rig.pump(tester, width: 744, textScale: 1.3);
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

    testWidgets('RTL at 744: the Join pill is at the start side of the card '
        '(left), the name after the tile (right)', (tester) async {
      final rig = CommunitiesTabletRig();
      // R10 review item 14: 744, where the pill sits beside the name (at
      // 360 it stacks in the test font).
      await rig.pump(tester, width: 744, textDirection: TextDirection.rtl);
      await showExploreTab(tester);
      final row = find.byKey(const ValueKey('explore-78'));
      final join = tester.getRect(
        find.descendant(of: row, matching: find.byType(CommunityJoinControl)),
      );
      final name = tester.getRect(
        find.descendant(of: row, matching: find.text('Book club')),
      );
      expect(join.right, lessThan(name.left));
      expect(tester.takeException(), isNull);
    });

    for (final w in <double>[320, 360, 1024]) {
      for (final brightness in Brightness.values) {
        testWidgets('text scale 2.0 at $w, ${brightness.name}: no overflow, '
            'every Join pill whole', (tester) async {
          final rig = CommunitiesTabletRig();
          await rig.pump(
            tester,
            width: w,
            height: 1194,
            textScale: 2,
            brightness: brightness,
          );
          expect(tester.takeException(), isNull);
          if (!_bandB(w)) {
            await showExploreTab(tester);
            expect(tester.takeException(), isNull);
          }
          for (final pill in find.byType(AppPillButton).evaluate()) {
            final text = find.descendant(
              of: find.byWidget(pill.widget),
              matching: find.byType(Text),
            );
            for (final t in text.evaluate()) {
              expect((t.widget as Text).overflow, isNot(TextOverflow.ellipsis));
            }
          }
        });
      }
    }
  });

  group(
    'the Joined pill takes taps across its 48 dp box (plan Notes, R10)',
    () {
      for (final w in <double>[360, 1024, 1440]) {
        for (final dy in <double>[-5, 5]) {
          testWidgets('$w: the strip ${dy < 0 ? 'above' : 'below'} the Joined '
              'pill, inside its 48 dp box, opens Leave', (tester) async {
            final rig = CommunitiesTabletRig();
            await rig.pump(
              tester,
              location: _communityPath,
              width: w,
              height: 1100,
            );
            final joined = find.ancestor(
              of: find.text('Joined'),
              matching: find.byType(AppPillButton),
            );
            final box = tester.getRect(joined);
            expect(box.height, AppSpacing.minTapTarget);
            final pill = tester.getRect(
              find.descendant(of: joined, matching: find.byType(Ink)),
            );
            // The strip of the box above or below the pill, which took no tap
            // while Joined was a shrink-wrapped OutlinedButton.
            expect(pill.top - box.top, greaterThanOrEqualTo(4));
            await tester.tapAt(
              Offset(
                pill.center.dx,
                dy < 0
                    ? (box.top + pill.top) / 2
                    : (pill.bottom + box.bottom) / 2,
              ),
            );
            await tester.pumpAndSettle();
            expect(find.text('Leave Chess club?'), findsOneWidget);
          });
        }
      }

      testWidgets('the owner\'s Joined is inert: a tap in the box opens '
          'nothing and is not a button', (tester) async {
        final handle = tester.ensureSemantics();
        final rig = CommunitiesTabletRig();
        rig.server.viewerRole = pb.CommunityRole.COMMUNITY_ROLE_OWNER;
        await rig.pump(tester, location: _communityPath, width: 360);
        final joined = find.ancestor(
          of: find.text('Joined'),
          matching: find.byType(AppPillButton),
        );
        final pill = tester.getRect(
          find.descendant(of: joined, matching: find.byType(Ink)),
        );
        await tester.tapAt(pill.center);
        await tester.tapAt(Offset(pill.center.dx, pill.top - 5));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        final node = tester.getSemantics(
          find.bySemanticsLabel('Joined Chess club'),
        );
        expect(node.flagsCollection.isButton, isFalse);
        handle.dispose();
      });

      testWidgets('a member\'s Joined is one spoken button, "Joined Chess '
          'club, leave"', (tester) async {
        final handle = tester.ensureSemantics();
        final rig = CommunitiesTabletRig();
        await rig.pump(tester, location: _communityPath, width: 360);
        expect(
          find.bySemanticsLabel('Joined Chess club, leave'),
          findsOneWidget,
        );
        expect(find.bySemanticsLabel('Joined'), findsNothing);
        handle.dispose();
      });
    },
  );

  group('CommunityMembers: F24 Moderators tab', () {
    testWidgets('a moderator: Members, Moderators, Banned; Moderators loads '
        'once when first shown and lists the owner and moderators', (
      tester,
    ) async {
      final rig = CommunitiesTabletRig();
      rig.server.viewerRole = pb.CommunityRole.COMMUNITY_ROLE_MODERATOR;
      await rig.pump(tester, location: _membersPath, width: 360);
      expect(
        rig.server.count(
          'members:$kRigCommunityId:'
          'COMMUNITY_MEMBER_FILTER_MODERATORS',
        ),
        0,
      );
      await tester.tap(find.text('Moderators'));
      await tester.pumpAndSettle();
      expect(
        rig.server.count(
          'members:$kRigCommunityId:'
          'COMMUNITY_MEMBER_FILTER_MODERATORS',
        ),
        1,
      );
      expect(find.text('Olivia'), findsOneWidget);
      expect(find.text('Mo'), findsOneWidget);
      expect(find.text('Member 1'), findsNothing);
      expect(find.text('Owner'), findsOneWidget);
      // Back and forth: no second call.
      Finder tab(String label) => find.descendant(
        of: find.byType(AppTabBar),
        matching: find.text(label),
      );
      await tester.tap(tab('Members'));
      await tester.pumpAndSettle();
      await tester.tap(tab('Moderators'));
      await tester.pumpAndSettle();
      expect(
        rig.server.count(
          'members:$kRigCommunityId:'
          'COMMUNITY_MEMBER_FILTER_MODERATORS',
        ),
        1,
      );
    });

    testWidgets('a member: no tabs and no MODERATORS call', (tester) async {
      final rig = CommunitiesTabletRig();
      await rig.pump(tester, location: _membersPath, width: 360);
      expect(find.byType(AppTabBar), findsNothing);
      expect(find.text('Moderators'), findsNothing);
      expect(rig.server.count('members:'), 1);
    });

    testWidgets('the header names the community under "Members"', (
      tester,
    ) async {
      final rig = CommunitiesTabletRig();
      await rig.pump(tester, location: _membersPath, width: 360);
      final title = tester.getRect(find.text('Members'));
      final name = tester.getRect(inCommunitiesPage(find.text('Chess club')));
      expect(name.top, greaterThanOrEqualTo(title.bottom));
    });
  });

  group('CommunityMembers: F36 Search members', () {
    for (final w in _widths) {
      for (final on in [true, false]) {
        testWidgets('$w, community_member_search ${on ? 'on' : 'off'}: '
            '${!on
                ? 'no field, no search call'
                : _bandB(w)
                ? 'the field in the pane'
                : 'the field above the tabs'}', (tester) async {
          final rig = CommunitiesTabletRig();
          rig.server.viewerRole = pb.CommunityRole.COMMUNITY_ROLE_MODERATOR;
          await rig.pump(
            tester,
            location: _membersPath,
            width: w,
            flags: on ? _searchFlags : kCommunitiesTabletFlags,
          );
          expect(tester.takeException(), isNull);
          if (!on) {
            expect(_field(kSearchMembersHint), findsNothing);
            expect(rig.server.count('search:'), 0);
            return;
          }
          expect(_field(kSearchMembersHint), findsOneWidget);
          if (_bandB(w)) {
            expect(_paneKinds(tester), [
              ContextSectionKind.memberSearch,
              ContextSectionKind.links,
            ]);
            expect(inContextPane(_field(kSearchMembersHint)), findsOneWidget);
          } else {
            expect(findContextPane(), findsNothing);
            final field = inCommunitiesPage(_field(kSearchMembersHint));
            expect(
              tester.getRect(field).bottom,
              lessThanOrEqualTo(tester.getRect(find.byType(AppTabBar)).top),
            );
          }
          // Typing searches the Members tab by handle; results replace it.
          final input = _bandB(w)
              ? inContextPane(_field(kSearchMembersHint))
              : _field(kSearchMembersHint);
          await tester.enterText(input, '@Mem');
          await tester.pump(const Duration(milliseconds: 299));
          expect(rig.server.count('search:'), 0);
          await tester.pump(const Duration(milliseconds: 1));
          await tester.pumpAndSettle();
          expect(rig.server.calls.where((c) => c.startsWith('search:')), [
            'search:$kRigCommunityId:mem:COMMUNITY_MEMBER_FILTER_JOINED',
          ]);
          expect(inCommunitiesPage(find.text('Member 1')), findsOneWidget);
          expect(inCommunitiesPage(find.text('Olivia')), findsNothing);
          expect(tester.takeException(), isNull);
        });
      }
    }

    testWidgets('no match: the honest empty state', (tester) async {
      final rig = CommunitiesTabletRig();
      await rig.pump(
        tester,
        location: _membersPath,
        width: 360,
        flags: _searchFlags,
      );
      await _type(tester, kSearchMembersHint, 'zz');
      expect(find.text(kNoMembersFoundTitle), findsOneWidget);
      expect(find.text(kNoMembersFoundHint), findsOneWidget);
    });

    testWidgets('one character keeps the list; an invalid text shows a hint '
        'and sends nothing; clearing brings the list back', (tester) async {
      final rig = CommunitiesTabletRig();
      await rig.pump(
        tester,
        location: _membersPath,
        width: 360,
        flags: _searchFlags,
      );
      await _type(tester, kSearchMembersHint, 'm');
      expect(find.text('Member 1'), findsOneWidget);
      await _type(tester, kSearchMembersHint, 'sana.n');
      expect(find.text(kMemberSearchInvalidHint), findsOneWidget);
      expect(find.text('Member 1'), findsNothing);
      expect(rig.server.count('search:'), 0);
      await tester.tap(find.byTooltip('Clear search'));
      await tester.pumpAndSettle();
      expect(find.text('Member 1'), findsOneWidget);
      expect(rig.server.count('members:'), 1);
    });

    testWidgets('while it searches: a skeleton of rows, not a blank list', (
      tester,
    ) async {
      final rig = CommunitiesTabletRig();
      final hold = rig.server.holdSearch = Completer<void>();
      await rig.pump(
        tester,
        location: _membersPath,
        width: 360,
        flags: _searchFlags,
      );
      await tester.enterText(_field(kSearchMembersHint), 'mem');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      final handle = tester.ensureSemantics();
      expect(find.bySemanticsLabel('Searching members'), findsOneWidget);
      handle.dispose();
      hold.complete();
      await tester.pumpAndSettle();
      expect(find.text('Member 1'), findsOneWidget);
    });

    testWidgets('the Moderators tab filters its own list with no call '
        '(review item 7); Banned asks BANNED', (tester) async {
      final rig = CommunitiesTabletRig();
      rig.server.viewerRole = pb.CommunityRole.COMMUNITY_ROLE_MODERATOR;
      await rig.pump(
        tester,
        location: _membersPath,
        width: 360,
        flags: _searchFlags,
      );
      await tapCommunityTab(tester, 'Moderators');
      await _type(tester, kSearchMembersHint, 'm');
      // One character: the tab's own list (the owner and Mo).
      expect(find.text('Olivia'), findsOneWidget);
      await _type(tester, kSearchMembersHint, 'mo');
      expect(rig.server.count('search:'), 0);
      expect(find.text('Mo'), findsOneWidget);
      expect(find.text('Olivia'), findsNothing);

      await tapCommunityTab(tester, 'Banned');
      expect(
        rig.server.calls.last,
        'search:$kRigCommunityId:mo:COMMUNITY_MEMBER_FILTER_BANNED',
      );
      expect(find.text(kNoBannedFoundTitle), findsOneWidget);
    });

    for (final (name, error) in <(String, AppException)>[
      (
        'FEATURE_DISABLED community_member_search',
        const FeatureDisabledException(
          'off',
          feature: kFeatureCommunityMemberSearch,
        ),
      ),
    ]) {
      testWidgets('$name: the field goes away and the list comes back; the '
          'members page keeps working', (tester) async {
        final rig = CommunitiesTabletRig();
        rig.server.searchError = error;
        await rig.pump(
          tester,
          location: _membersPath,
          width: 360,
          flags: _searchFlags,
        );
        await _type(tester, kSearchMembersHint, 'mem');
        expect(_field(kSearchMembersHint), findsNothing);
        expect(find.text('Member 1'), findsOneWidget);
        expect(
          find.text("Communities aren't available right now"),
          findsNothing,
        );
      });
    }

    testWidgets('another failure (rate limited): its calm note over the '
        'results, the field kept; typing again asks again', (tester) async {
      final rig = CommunitiesTabletRig();
      const limited = RateLimitedException('slow down');
      rig.server.searchError = limited;
      await rig.pump(
        tester,
        location: _membersPath,
        width: 360,
        flags: _searchFlags,
      );
      await _type(tester, kSearchMembersHint, 'mem');
      expect(_field(kSearchMembersHint), findsOneWidget);
      expect(find.text(rateLimitedMessage(limited)), findsOneWidget);
      rig.server.searchError = null;
      await _type(tester, kSearchMembersHint, 'memb');
      expect(find.text('Member 1'), findsOneWidget);
      expect(rig.server.count('search:'), 2);
    });

    testWidgets('band B: the text follows the field from the pane to band A '
        'and the results stay, with no new call', (tester) async {
      final rig = CommunitiesTabletRig();
      await rig.pump(
        tester,
        location: _membersPath,
        width: 1024,
        flags: _searchFlags,
      );
      await tester.enterText(inContextPane(_field(kSearchMembersHint)), 'mem');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(inCommunitiesPage(find.text('Member 2')), findsOneWidget);
      final state = tester.state(find.byType(CommunityMembersScreen));
      await rig.resize(tester, 744);
      expect(tester.state(find.byType(CommunityMembersScreen)), same(state));
      expect(
        tester
            .widget<TextField>(inCommunitiesPage(_field(kSearchMembersHint)))
            .controller!
            .text,
        'mem',
      );
      expect(find.text('Member 2'), findsOneWidget);
      expect(rig.server.count('search:'), 1);
    });

    testWidgets('RTL at 744 and 1024: no overflow, the field in place', (
      tester,
    ) async {
      for (final w in <double>[744, 1024]) {
        final rig = CommunitiesTabletRig();
        await rig.pump(
          tester,
          location: _membersPath,
          width: w,
          flags: _searchFlags,
          textDirection: TextDirection.rtl,
        );
        expect(tester.takeException(), isNull);
        expect(_field(kSearchMembersHint), findsOneWidget);
      }
    });

    for (final w in <double>[360, 1024]) {
      testWidgets('text scale 2.0 at $w: the field, tabs and results fit', (
        tester,
      ) async {
        final rig = CommunitiesTabletRig();
        rig.server.viewerRole = pb.CommunityRole.COMMUNITY_ROLE_MODERATOR;
        await rig.pump(
          tester,
          location: _membersPath,
          width: w,
          height: 1194,
          textScale: 2,
          flags: _searchFlags,
        );
        expect(tester.takeException(), isNull);
        await tester.enterText(
          _bandB(w)
              ? inContextPane(_field(kSearchMembersHint))
              : _field(kSearchMembersHint),
          'zz',
        );
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text(kNoMembersFoundTitle), findsOneWidget);
      });
    }
  });

  group('ModLog rows (R10)', () {
    testWidgets('each entry has its action tile beside the sentence', (
      tester,
    ) async {
      final rig = CommunitiesTabletRig();
      rig.server.viewerRole = pb.CommunityRole.COMMUNITY_ROLE_MODERATOR;
      await rig.pump(
        tester,
        location: AppRouter.communityModerationLogPath(kRigCommunityId),
        width: 360,
      );
      final rows = find.byType(ModerationLogRow);
      expect(rows, findsNWidgets(3));
      for (final row in rows.evaluate()) {
        final tile = find.descendant(
          of: find.byWidget(row.widget),
          matching: find.byType(AppTileIcon),
        );
        expect(tester.getSize(tile), const Size.square(kModerationLogTileSize));
        expect(tester.widget<AppTileIcon>(tile).icon, Icons.block);
      }
    });
  });

  group('R10 follow-ups', () {
    testWidgets('the Create preview draws the name in the page header\'s '
        'own style (band B pane and band A dialog)', (tester) async {
      final rig = CommunitiesTabletRig();
      rig.server.viewerRole = pb.CommunityRole.COMMUNITY_ROLE_MEMBER;
      await rig.pump(tester, location: _communityPath, width: 1024);
      final header = tester.widget<Text>(
        find.descendant(
          of: find.byType(CommunityHeader),
          matching: find.text('Chess club'),
        ),
      );
      final expected = communityNameStyle(
        Theme.of(tester.element(find.byType(CommunityHeader))),
      )!;
      expect(header.style?.fontSize, expected.fontSize);
      expect(header.style?.height, expected.height);
      expect(header.style?.letterSpacing, expected.letterSpacing);
      expect(header.style?.fontWeight, FontWeight.w800);

      for (final w in <double>[1024, 744]) {
        final create = CommunitiesTabletRig();
        await create.pump(
          tester,
          location: AppRouter.communityNewPath,
          width: w,
        );
        if (w == 744) {
          await tester.tap(find.text('Preview'));
          await tester.pumpAndSettle();
        }
        final name = tester.widget<Text>(
          find.descendant(
            of: find.byType(CommunityPreview),
            matching: find.text(kCommunityPreviewUnnamed),
          ),
        );
        expect(name.style?.fontSize, header.style?.fontSize, reason: '$w');
        expect(name.style?.height, header.style?.height, reason: '$w');
        expect(
          name.style?.letterSpacing,
          header.style?.letterSpacing,
          reason: '$w',
        );
        expect(name.style?.fontWeight, FontWeight.w800, reason: '$w');
      }
    });

    for (final MapEntry(key: mode, value: shell)
        in kCommunitiesFlagModes.entries) {
      if (shell.contains(kFeatureUiShell) && shell.contains(kFeatureUiTablet)) {
        continue;
      }
      testWidgets('community_member_search on, $mode at 1024: the field '
          'inline above the tabs, no pane, one search', (tester) async {
        final rig = CommunitiesTabletRig();
        rig.server.viewerRole = pb.CommunityRole.COMMUNITY_ROLE_MODERATOR;
        await rig.pump(
          tester,
          location: _membersPath,
          width: 1024,
          flags: {...shell, kFeatureCommunityMemberSearch},
        );
        expect(tester.takeException(), isNull);
        expect(findContextPane(), findsNothing);
        final field = inCommunitiesPage(_field(kSearchMembersHint));
        expect(field, findsOneWidget);
        expect(
          tester.getRect(field).bottom,
          lessThanOrEqualTo(tester.getRect(find.byType(AppTabBar)).top),
        );
        await _type(tester, kSearchMembersHint, 'mem');
        expect(rig.server.count('search:'), 1);
        expect(find.text('Member 1'), findsOneWidget);
      });
    }

    testWidgets('the search fields keep their spoken name once there is '
        'text', (tester) async {
      final handle = tester.ensureSemantics();
      final rig = CommunitiesTabletRig();
      await rig.pump(
        tester,
        location: _membersPath,
        width: 360,
        flags: _searchFlags,
      );
      await _type(tester, kSearchMembersHint, 'zz');
      expect(
        tester.getSemantics(_field(kSearchMembersHint)).label,
        contains(kSearchMembersLabel),
      );
      final communities = CommunitiesTabletRig();
      await communities.pump(tester, width: 360);
      await tester.enterText(_field(kSearchCommunitiesHint), 'chess');
      await tester.pumpAndSettle();
      expect(
        tester.getSemantics(_field(kSearchCommunitiesHint)).label,
        contains(kSearchCommunitiesHint),
      );
      handle.dispose();
    });
  });
}
