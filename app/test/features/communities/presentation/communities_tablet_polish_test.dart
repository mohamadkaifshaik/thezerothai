import 'dart:async';

import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/core/widgets/context_pane.dart';
import 'package:dzeroth/core/widgets/context_pane_slots.dart';
import 'package:dzeroth/features/communities/presentation/widgets/community_about.dart';
import 'package:dzeroth/features/communities/presentation/widgets/community_preview.dart';
import 'package:dzeroth/features/communities/presentation/widgets/explore_communities_pane.dart';
import 'package:dzeroth/features/communities/presentation/widgets/moderation_log_about.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/communities/v1/communities.pb.dart' as pb;
import 'package:dzeroth/shared/widgets/primitives/app_pill_button.dart';
import 'package:dzeroth/shared/widgets/user/user_list_skeleton.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protobuf/well_known_types/google/protobuf/timestamp.pb.dart'
    as ts;

import '../../../support/communities_tablet_rig.dart';
import '../../../support/context_pane_rig.dart'
    show findContextPane, inContextPane;

/// T8a polish: the fixes of the T8a UX review (items 1-8 and the log's
/// copy). Every item is tablet-only; phones and desktop keep T8a's tests.

final _communityPath = AppRouter.communityPath(kRigCommunityId);
final _logPath = AppRouter.communityModerationLogPath(kRigCommunityId);

// R10 (F23): Explore is a tab outside band B, so "below" became "from
// Explore"; band B names the pane's card, now sentence case.
const _emptyMineOld =
    "You haven't joined any Communities yet. Join one from Explore to see its "
    'posts.';
const _emptyMineBandB =
    "You haven't joined any Communities yet. Join one from Explore "
    'communities to see its posts.';

/// The pane's own scroll view (R10: its search field has a Scrollable too).
Finder _paneScrollable() => find
    .descendant(of: findContextPane(), matching: find.byType(Scrollable))
    .first;

/// The pane's directory rows (their keys are `explore-<id>`).
int _paneExploreRows(WidgetTester tester) => inContextPane(
  find.byWidgetPredicate(
    (w) =>
        w.key is ValueKey<String> &&
        (w.key! as ValueKey<String>).value.startsWith('explore-'),
  ),
).evaluate().length;

List<pb.Community> _directoryOf(int n) => [
  for (var i = 0; i < n; i++)
    pb.Community(
      communityId: '${100 + i}',
      name: 'Club $i',
      memberCount: Int64(2),
      viewerRole: pb.CommunityRole.COMMUNITY_ROLE_NONE,
    ),
];

List<pb.ModerationLogEntry> _bans(int n) => [
  for (var i = 1; i <= n; i++)
    pb.ModerationLogEntry(
        seq: Int64(i),
        action: pb.ModerationLogAction.MODERATION_LOG_ACTION_BAN,
        actor: common.AuthorSnapshot(userId: 'm1', handle: 'mo'),
        target: common.AuthorSnapshot(userId: 'p$i', handle: 'member$i'),
      )
      ..at = ts.Timestamp.fromDateTime(
        kRigNow.subtract(Duration(hours: i)).toUtc(),
      ),
];

Future<void> _fillRule(
  WidgetTester tester, {
  String title = '',
  String details = '',
}) async {
  await tester.tap(find.text('Add a rule'));
  await tester.pumpAndSettle();
  if (title.isNotEmpty) {
    await tester.enterText(createFormField('Rule 1 title'), title);
  }
  if (details.isNotEmpty) {
    await tester.enterText(createFormField('Rule 1 details'), details);
  }
  await tester.pumpAndSettle();
}

void main() {
  group('1. empty My Communities points at Explore', () {
    for (final w in <double>[360, 744, 1024, 1200]) {
      testWidgets('at $w', (tester) async {
        final rig = CommunitiesTabletRig();
        rig.server.directory = _directoryOf(3);
        await rig.pump(tester, width: w);
        // R10 review item 10: one sentence in every layout ("Explore" is
        // the tab, or band B's Explore communities card).
        expect(inCommunitiesPage(find.text(_emptyMineOld)), findsOneWidget);
        expect(find.text(_emptyMineBandB), findsNothing);
      });
    }
  });

  group('2. the description (R10 review item 11: in the header)', () {
    testWidgets('band B: the description is in the page header, and the '
        'pane starts with Rules (no description card)', (tester) async {
      final rig = CommunitiesTabletRig();
      await rig.pump(tester, location: _communityPath, width: 1024);
      expect(find.text('About this Community'), findsNothing);
      expect(
        inContextPane(find.text('Openings, endgames and puzzles')),
        findsNothing,
      );
      expect(
        inCommunitiesPage(find.text('Openings, endgames and puzzles')),
        findsOneWidget,
      );
      expect(inContextPane(find.text('Rules')), findsOneWidget);
    });

    testWidgets('band B: no description, no card', (tester) async {
      final rig = CommunitiesTabletRig();
      rig.server.description = '';
      await rig.pump(tester, location: _communityPath, width: 1024);
      expect(find.text('About this Community'), findsNothing);
      expect(inContextPane(find.text('Rules')), findsOneWidget);
    });

    testWidgets('band A: no pane, the description stays in the page only', (
      tester,
    ) async {
      final rig = CommunitiesTabletRig();
      await rig.pump(tester, location: _communityPath, width: 744);
      expect(findContextPane(), findsNothing);
      expect(find.text('About this Community'), findsNothing);
    });
  });

  group('3. the pane is never blank while a page is pushed', () {
    testWidgets('a community pushed over Home: the Rules card on the first '
        'frame', (tester) async {
      final rig = CommunitiesTabletRig();
      await rig.pump(tester, location: AppRouter.homePath, width: 1024);
      unawaited(rig.router.push(_communityPath));
      await tester.pump();
      expect(inContextPane(find.text('Rules')), findsOneWidget);
      await tester.pumpAndSettle();
      expect(inContextPane(find.text('Be kind')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('/communities pushed over Home: the Explore Communities card '
        'on the first frame', (tester) async {
      final rig = CommunitiesTabletRig();
      await rig.pump(tester, location: AppRouter.homePath, width: 1024);
      unawaited(rig.router.push(AppRouter.communitiesPath));
      await tester.pump();
      expect(inContextPane(find.text('Explore communities')), findsOneWidget);
      await tester.pumpAndSettle();
      expect(
        inContextPane(find.byKey(const ValueKey('explore-78'))),
        findsOneWidget,
      );
    });

    testWidgets('Create pushed from /communities: the empty Preview on the '
        'first frame', (tester) async {
      final rig = CommunitiesTabletRig();
      await rig.pump(tester, width: 1024);
      unawaited(rig.router.push(AppRouter.communityNewPath));
      await tester.pump();
      expect(inContextPane(find.text('Preview')), findsOneWidget);
      expect(
        inContextPane(find.text(kCommunityPreviewUnnamed)),
        findsOneWidget,
      );
      await tester.pumpAndSettle();
      expect(inContextPane(find.text('Preview')), findsOneWidget);
    });

    for (final (location, kind, placeholder) in [
      (
        AppRouter.communitiesPath,
        ContextSectionKind.exploreCommunities,
        ExploreCommunitiesPanePlaceholder,
      ),
      (
        _communityPath,
        ContextSectionKind.communityAbout,
        CommunityAboutPanePlaceholder,
      ),
      (
        AppRouter.communityNewPath,
        ContextSectionKind.communityPreview,
        CommunityPreviewCard,
      ),
      (
        _logPath,
        ContextSectionKind.moderationLogAbout,
        ModerationLogAboutPlaceholder,
      ),
    ]) {
      testWidgets('$location: the lent slot waits with $placeholder', (
        tester,
      ) async {
        final rig = CommunitiesTabletRig();
        await rig.pump(tester, location: location, width: 1024);
        final section = tester
            .widget<ContextPane>(findContextPane())
            .sections
            .firstWhere((s) => s.kind == kind);
        final slot = section.child as ContextPaneSlot;
        expect(slot.placeholder.runtimeType, placeholder);
      });
    }

    for (final (placeholder, title) in [
      (const ExploreCommunitiesPanePlaceholder(), 'Explore communities'),
      (const CommunityAboutPanePlaceholder(), 'Rules'),
      (const CommunityPreviewCard(), 'Preview'),
      (const ModerationLogAboutPlaceholder(), kModerationLogAboutTitle),
    ]) {
      testWidgets('${placeholder.runtimeType} is the "$title" card', (
        tester,
      ) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(brightness: Brightness.light),
            home: Scaffold(body: SingleChildScrollView(child: placeholder)),
          ),
        );
        expect(
          find.descendant(
            of: find.byType(ContextPaneCard),
            matching: find.text(title),
          ),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('the Community pane while GetCommunity is in flight: the same '
        'Rules card over a skeleton', (tester) async {
      final rig = CommunitiesTabletRig();
      final hold = rig.server.holdGet = Completer<void>();
      await rig.pump(
        tester,
        location: _communityPath,
        width: 1024,
        settle: false,
      );
      expect(inContextPane(find.text('Rules')), findsOneWidget);
      expect(inContextPane(find.byType(UserListSkeleton)), findsOneWidget);

      hold.complete();
      await tester.pumpAndSettle();
      expect(inContextPane(find.text('Be kind')), findsOneWidget);
      expect(inContextPane(find.byType(UserListSkeleton)), findsNothing);
    });
  });

  group('4. the band A log banner: loaded entries only, in the list', () {
    testWidgets('loaded: the first item of the log, and it scrolls with it', (
      tester,
    ) async {
      final rig = CommunitiesTabletRig();
      rig.server.viewerRole = pb.CommunityRole.COMMUNITY_ROLE_MODERATOR;
      rig.server.logEntries = _bans(12);
      await rig.pump(tester, location: _logPath, width: 744, height: 600);
      final banner = find.byType(ModerationLogAbout);
      expect(banner, findsOneWidget);
      expect(
        find.ancestor(of: banner, matching: find.byType(ListView)),
        findsOneWidget,
      );
      final before = tester.getRect(banner).top;
      await tester.drag(find.byType(ListView), const Offset(0, -80));
      await tester.pumpAndSettle();
      expect(tester.getRect(banner).top, closeTo(before - 80, 1));
    });

    testWidgets('loading: no banner', (tester) async {
      final rig = CommunitiesTabletRig();
      rig.server.viewerRole = pb.CommunityRole.COMMUNITY_ROLE_MODERATOR;
      final hold = rig.server.holdLog = Completer<void>();
      await rig.pump(tester, location: _logPath, width: 744, settle: false);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byType(ModerationLogAbout), findsNothing);
      hold.complete();
      await tester.pumpAndSettle();
      expect(find.byType(ModerationLogAbout), findsOneWidget);
    });

    testWidgets('empty: no banner', (tester) async {
      final rig = CommunitiesTabletRig();
      rig.server.viewerRole = pb.CommunityRole.COMMUNITY_ROLE_MODERATOR;
      rig.server.logEntries = [];
      await rig.pump(tester, location: _logPath, width: 744);
      expect(find.text('Nothing here yet'), findsOneWidget);
      expect(find.byType(ModerationLogAbout), findsNothing);
    });

    testWidgets('locked (not a moderator): no banner', (tester) async {
      final rig = CommunitiesTabletRig();
      rig.server.logError = CommunityForbiddenException(
        CommunityForbiddenReason.notModerator,
      );
      await rig.pump(tester, location: _logPath, width: 744);
      expect(find.text('Only moderators can do that.'), findsOneWidget);
      expect(find.byType(ModerationLogAbout), findsNothing);
    });

    testWidgets('not found: no banner', (tester) async {
      final rig = CommunitiesTabletRig();
      rig.server.logError = const NotFoundException('gone');
      await rig.pump(tester, location: _logPath, width: 744);
      expect(find.byType(ModerationLogAbout), findsNothing);
    });
  });

  group('band B: About this log in the pane only for a loaded log (the '
      'band A rule)', () {
    Finder restoreCopy() => find.textContaining('You can restore');

    for (final (name, error) in <(String, AppException?)>[
      (
        'locked',
        CommunityForbiddenException(CommunityForbiddenReason.notModerator),
      ),
      ('not found', const NotFoundException('gone')),
      ('failed', const UnknownApiException('down')),
    ]) {
      testWidgets('$name: no card and no restore copy in the pane', (
        tester,
      ) async {
        final rig = CommunitiesTabletRig();
        rig.server.logError = error;
        await rig.pump(tester, location: _logPath, width: 1024);
        expect(findContextPane(), findsOneWidget);
        expect(restoreCopy(), findsNothing);
        expect(find.text(kModerationLogAboutTitle), findsNothing);
      });
    }

    testWidgets('a moderator\'s empty log: no card (as band A)', (
      tester,
    ) async {
      final rig = CommunitiesTabletRig();
      rig.server.viewerRole = pb.CommunityRole.COMMUNITY_ROLE_MODERATOR;
      rig.server.logEntries = [];
      await rig.pump(tester, location: _logPath, width: 1024);
      expect(find.text('Nothing here yet'), findsOneWidget);
      expect(find.text(kModerationLogAboutTitle), findsNothing);
    });

    testWidgets('a moderator: the placeholder while the log loads, then the '
        'card', (tester) async {
      final rig = CommunitiesTabletRig();
      rig.server.viewerRole = pb.CommunityRole.COMMUNITY_ROLE_MODERATOR;
      final hold = rig.server.holdLog = Completer<void>();
      await rig.pump(tester, location: _logPath, width: 1024, settle: false);
      expect(
        inContextPane(find.text(kModerationLogAboutTitle)),
        findsOneWidget,
      );
      expect(restoreCopy(), findsNothing);

      hold.complete();
      await tester.pumpAndSettle();
      expect(inContextPane(find.text(kModerationLogAboutText)), findsOneWidget);
      expect(rig.server.count('log:'), 1);
    });

    testWidgets('pushed from the community pane: one pump shows the '
        'placeholder, not a blank pane or the copy', (tester) async {
      final rig = CommunitiesTabletRig();
      rig.server.viewerRole = pb.CommunityRole.COMMUNITY_ROLE_MODERATOR;
      await rig.pump(tester, location: _communityPath, width: 1024);
      final hold = rig.server.holdLog = Completer<void>();
      unawaited(rig.router.push(_logPath));
      await tester.pump();
      expect(
        inContextPane(find.text(kModerationLogAboutTitle)),
        findsOneWidget,
      );
      expect(restoreCopy(), findsNothing);

      hold.complete();
      await tester.pumpAndSettle();
      expect(inContextPane(find.text(kModerationLogAboutText)), findsOneWidget);
    });
  });

  group('the log copy (ruling 6, reviewed)', () {
    test('names edits and speaks to the moderator', () {
      expect(
        kModerationLogAboutText,
        'Removed posts, bans, role changes and edits in this Community, '
        'newest first. Only the owner and moderators can see this log. You '
        'can restore a removed post from its entry.',
      );
    });
  });

  group('5. the Explore pane: 8 rows, then Show more', () {
    testWidgets('12 rows: 8 and Show more (48 dp); Show more adds the rest '
        'in place', (tester) async {
      final rig = CommunitiesTabletRig();
      rig.server.directory = _directoryOf(12);
      await rig.pump(tester, width: 1024, height: 1100);
      expect(_paneExploreRows(tester), 8);
      final more = inContextPane(find.text('Show more'));
      expect(more, findsOneWidget);
      await tester.scrollUntilVisible(more, 100, scrollable: _paneScrollable());
      expect(
        tester
            .getSize(find.ancestor(of: more, matching: find.byType(TextButton)))
            .height,
        greaterThanOrEqualTo(AppSpacing.minTapTarget),
      );
      await tester.tap(more);
      await tester.pumpAndSettle();
      expect(_paneExploreRows(tester), 12);
      expect(find.text('Show more'), findsNothing);
      expect(rig.server.count('directory'), 1);

      // Kept across a resize through band A and back (the page's state).
      await rig.resize(tester, 744);
      await rig.resize(tester, 1024);
      expect(_paneExploreRows(tester), 12);
    });

    testWidgets('8 rows: all of them, no Show more', (tester) async {
      final rig = CommunitiesTabletRig();
      rig.server.directory = _directoryOf(8);
      await rig.pump(tester, width: 1024, height: 1100);
      expect(_paneExploreRows(tester), 8);
      expect(find.text('Show more'), findsNothing);
    });

    testWidgets('band A: the inline directory has no Show more', (
      tester,
    ) async {
      final rig = CommunitiesTabletRig();
      rig.server.directory = _directoryOf(12);
      await rig.pump(tester, width: 744, height: 1100);
      // R10 (F23): the inline directory is the Explore tab.
      await showExploreTab(tester);
      await tester.scrollUntilVisible(
        inCommunitiesPage(find.byKey(const ValueKey('explore-111'))),
        100,
        scrollable: find
            .descendant(
              of: findCommunitiesPage(),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(find.text('Show more'), findsNothing);
    });
  });

  group('6. the preview reads like the real header', () {
    testWidgets('band B: the name is w800, Rules a titleSmall heading, '
        '"Owner · 1 member"', (tester) async {
      final rig = CommunitiesTabletRig();
      await rig.pump(tester, location: AppRouter.communityNewPath, width: 1024);
      final preview = find.byType(CommunityPreview);
      final theme = Theme.of(tester.element(preview));
      final name = tester.widget<Text>(
        find.descendant(
          of: preview,
          matching: find.text(kCommunityPreviewUnnamed),
        ),
      );
      expect(name.style?.fontWeight, FontWeight.w800);
      final rules = tester.widget<Text>(
        find.descendant(of: preview, matching: find.text('Rules')),
      );
      expect(rules.style?.fontSize, theme.textTheme.titleSmall?.fontSize);
      expect(
        find.ancestor(
          of: find.descendant(of: preview, matching: find.text('Rules')),
          matching: find.byWidgetPredicate(
            (w) => w is Semantics && (w.properties.header ?? false),
          ),
        ),
        findsWidgets,
      );
      expect(
        find.descendant(of: preview, matching: find.text('Owner · 1 member')),
        findsOneWidget,
      );
    });

    testWidgets('band A dialog: the preview lines up with the dialog title', (
      tester,
    ) async {
      final rig = CommunitiesTabletRig();
      await rig.pump(
        tester,
        location: AppRouter.communityNewPath,
        width: 744,
        height: 1100,
      );
      await _fillRule(tester, title: 'No spam', details: 'Ask first.');
      await tester.tap(find.widgetWithText(TextButton, 'Preview'));
      await tester.pumpAndSettle();
      final dialog = find.byType(Dialog);
      Finder inDialog(Finder f) => find.descendant(of: dialog, matching: f);
      final title = tester.getRect(inDialog(find.text('Preview'))).left;
      expect(
        tester.getRect(inDialog(find.text(kCommunityPreviewUnnamed))).left,
        closeTo(title, 0.5),
      );
      expect(
        tester.getRect(inDialog(find.text('Rules'))).left,
        closeTo(title, 0.5),
      );
      expect(
        tester.getRect(inDialog(find.text('1.'))).left,
        closeTo(title, 0.5),
      );
    });

    testWidgets('band B pane: the preview lines up with the card title', (
      tester,
    ) async {
      final rig = CommunitiesTabletRig();
      await rig.pump(tester, location: AppRouter.communityNewPath, width: 1024);
      final card = tester.getRect(inContextPane(find.text('Preview'))).left;
      expect(
        tester.getRect(inContextPane(find.text(kCommunityPreviewUnnamed))).left,
        closeTo(card, 0.5),
      );
      expect(
        tester.getRect(inContextPane(find.text(kCommunityNoRulesText))).left,
        closeTo(card, 0.5),
      );
    });
  });

  group('7. one label for the moderation log, the pane link first', () {
    for (final role in [
      pb.CommunityRole.COMMUNITY_ROLE_MODERATOR,
      pb.CommunityRole.COMMUNITY_ROLE_OWNER,
    ]) {
      testWidgets('band B, ${role.name}', (tester) async {
        final rig = CommunitiesTabletRig();
        rig.server.viewerRole = role;
        await rig.pump(tester, location: _communityPath, width: 1024);
        expect(find.text('View moderation log'), findsNothing);
        final link = inContextPane(find.text('Moderation log'));
        expect(link, findsOneWidget);
        // The header's button has the same label.
        expect(inCommunitiesPage(find.text('Moderation log')), findsOneWidget);
        // First in the pane: above the rules (the description card is gone,
        // R10 review item 11).
        final top = tester.getRect(link).top;
        expect(
          top,
          lessThan(tester.getRect(inContextPane(find.text('Rules'))).top),
        );
      });
    }
  });

  group('the Join pill in the pane takes a tap anywhere in its 48 dp box', () {
    for (final dy in <double>[-5, 5]) {
      testWidgets('band B, ${dy < 0 ? 'above' : 'below'} the 36 dp pill', (
        tester,
      ) async {
        final rig = CommunitiesTabletRig();
        await rig.pump(tester, width: 1024, height: 1100);
        final pill = inContextPane(
          find.descendant(
            of: find.byKey(const ValueKey('explore-78')),
            matching: find.byType(AppPillButton),
          ),
        );
        final ink = tester.getRect(
          find.descendant(of: pill, matching: find.byType(InkWell)),
        );
        expect(tester.getSize(pill).height, AppSpacing.minTapTarget);
        // One spoken button, as before (the wider target is not announced).
        expect(find.bySemanticsLabel('Join Book club'), findsOneWidget);
        await tester.tapAt(
          Offset(ink.center.dx, dy < 0 ? ink.top + dy : ink.bottom + dy),
        );
        await tester.pumpAndSettle();
        expect(rig.server.count('join:78'), 1);
      });
    }
  });

  group('8. a rule with no title', () {
    testWidgets('band B preview: no blank title line, spoken without it', (
      tester,
    ) async {
      final rig = CommunitiesTabletRig();
      await rig.pump(
        tester,
        location: AppRouter.communityNewPath,
        width: 1024,
        height: 1100,
      );
      await _fillRule(tester, details: 'Links only when asked.');
      final row = inContextPane(find.byType(CommunityRuleRow));
      expect(row, findsOneWidget);
      expect(
        find.descendant(
          of: row,
          matching: find.byWidgetPredicate((w) => w is Text && w.data == ''),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: row,
          matching: find.byWidgetPredicate(
            (w) =>
                w is Semantics &&
                w.properties.label == 'Rule 1: Links only when asked.',
          ),
        ),
        findsOneWidget,
      );
    });
  });
}
