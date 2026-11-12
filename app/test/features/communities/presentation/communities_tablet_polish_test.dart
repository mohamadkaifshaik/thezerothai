import 'dart:async';

import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/core/widgets/context_pane.dart';
import 'package:dzeroth/features/communities/presentation/widgets/community_about.dart';
import 'package:dzeroth/features/communities/presentation/widgets/community_preview.dart';
import 'package:dzeroth/features/communities/presentation/widgets/explore_communities_pane.dart';
import 'package:dzeroth/features/communities/presentation/widgets/moderation_log_about.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/communities/v1/communities.pb.dart' as pb;
import 'package:dzeroth/shared/widgets/primitives/app_pill_button.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protobuf/well_known_types/google/protobuf/timestamp.pb.dart'
    as ts;

import '../../../support/communities_tablet_rig.dart';
import '../../../support/context_pane_rig.dart' show findContextPane;

/// T8a polish: the fixes of the T8a UX review (items 1-8 and the log's
/// copy). Every item is tablet-only; phones and desktop keep T8a's tests.

final _communityPath = AppRouter.communityPath(kRigCommunityId);
final _logPath = AppRouter.communityModerationLogPath(kRigCommunityId);

// R10 (F23): Explore is a tab at every tablet width (the tablet layout has no
// side pane), so the copy says "from Explore".
const _emptyMineOld =
    "You haven't joined any Communities yet. Join one from Explore to see its "
    'posts.';
const _emptyMineBandB =
    "You haven't joined any Communities yet. Join one from Explore "
    'communities to see its posts.';

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
    testWidgets('band B: the description is in the page header, no card and '
        'no pane', (tester) async {
      final rig = CommunitiesTabletRig();
      await rig.pump(tester, location: _communityPath, width: 1024);
      expect(findContextPane(), findsNothing);
      expect(find.text('About this Community'), findsNothing);
      expect(
        inCommunitiesPage(find.text('Openings, endgames and puzzles')),
        findsOneWidget,
      );
      // Rules are in the About tab only: the Posts tab is open.
      expect(find.text('Rules'), findsNothing);
    });

    testWidgets('band B: no description, no card', (tester) async {
      final rig = CommunitiesTabletRig();
      rig.server.description = '';
      await rig.pump(tester, location: _communityPath, width: 1024);
      expect(findContextPane(), findsNothing);
      expect(find.text('About this Community'), findsNothing);
      await tester.tap(find.text('About'));
      await tester.pumpAndSettle();
      expect(inCommunitiesPage(find.text('Rules')), findsOneWidget);
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

  group('3. pages pushed over Home draw inline, never a pane', () {
    testWidgets('a community pushed over Home: no pane on the first frame or '
        'after, the page is the community', (tester) async {
      final rig = CommunitiesTabletRig();
      await rig.pump(tester, location: AppRouter.homePath, width: 1024);
      unawaited(rig.router.push(_communityPath));
      await tester.pump();
      expect(findContextPane(), findsNothing);
      await tester.pumpAndSettle();
      expect(findContextPane(), findsNothing);
      expect(
        inCommunitiesPage(find.text('Openings, endgames and puzzles')),
        findsOneWidget,
      );
      await tester.tap(find.text('About'));
      await tester.pumpAndSettle();
      expect(inCommunitiesPage(find.text('Be kind')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('/communities pushed over Home: no pane, Explore '
        'communities inline in the Explore tab', (tester) async {
      final rig = CommunitiesTabletRig();
      await rig.pump(tester, location: AppRouter.homePath, width: 1024);
      unawaited(rig.router.push(AppRouter.communitiesPath));
      await tester.pump();
      expect(findContextPane(), findsNothing);
      await tester.pumpAndSettle();
      expect(findContextPane(), findsNothing);
      await showExploreTab(tester);
      expect(
        inCommunitiesPage(find.byKey(const ValueKey('explore-78'))),
        findsOneWidget,
      );
    });

    testWidgets('Create pushed from /communities: no pane, the preview is '
        'behind the header action', (tester) async {
      final rig = CommunitiesTabletRig();
      await rig.pump(tester, width: 1024);
      unawaited(rig.router.push(AppRouter.communityNewPath));
      await tester.pump();
      expect(findContextPane(), findsNothing);
      await tester.pumpAndSettle();
      expect(findContextPane(), findsNothing);
      expect(find.byType(CommunityPreview), findsNothing);
      expect(find.widgetWithText(TextButton, 'Preview'), findsOneWidget);
    });

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

    testWidgets('the Community page while GetCommunity is in flight: no pane '
        'and no Rules card', (tester) async {
      final rig = CommunitiesTabletRig();
      final hold = rig.server.holdGet = Completer<void>();
      await rig.pump(
        tester,
        location: _communityPath,
        width: 1024,
        settle: false,
      );
      expect(findContextPane(), findsNothing);
      expect(find.text('Rules'), findsNothing);

      hold.complete();
      await tester.pumpAndSettle();
      expect(findContextPane(), findsNothing);
      expect(
        inCommunitiesPage(find.text('Openings, endgames and puzzles')),
        findsOneWidget,
      );
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

  group('band B: About this log inline only for a loaded log (the band A '
      'rule), never in a pane', () {
    Finder restoreCopy() => find.textContaining('You can restore');

    for (final (name, error) in <(String, AppException?)>[
      (
        'locked',
        CommunityForbiddenException(CommunityForbiddenReason.notModerator),
      ),
      ('not found', const NotFoundException('gone')),
      ('failed', const UnknownApiException('down')),
    ]) {
      testWidgets('$name: no card and no restore copy', (tester) async {
        final rig = CommunitiesTabletRig();
        rig.server.logError = error;
        await rig.pump(tester, location: _logPath, width: 1024);
        expect(findContextPane(), findsNothing);
        expect(restoreCopy(), findsNothing);
        expect(find.text(kModerationLogAboutTitle), findsNothing);
        expect(find.byType(ModerationLogAbout), findsNothing);
      });
    }

    testWidgets('an empty log of a moderator: no card (as band A)', (
      tester,
    ) async {
      final rig = CommunitiesTabletRig();
      rig.server.viewerRole = pb.CommunityRole.COMMUNITY_ROLE_MODERATOR;
      rig.server.logEntries = [];
      await rig.pump(tester, location: _logPath, width: 1024);
      expect(find.text('Nothing here yet'), findsOneWidget);
      expect(find.text(kModerationLogAboutTitle), findsNothing);
    });

    testWidgets('a moderator: no banner while the log loads, then the banner '
        'inline in the page', (tester) async {
      final rig = CommunitiesTabletRig();
      rig.server.viewerRole = pb.CommunityRole.COMMUNITY_ROLE_MODERATOR;
      final hold = rig.server.holdLog = Completer<void>();
      await rig.pump(tester, location: _logPath, width: 1024, settle: false);
      expect(find.byType(ModerationLogAbout), findsNothing);
      expect(restoreCopy(), findsNothing);
      expect(findContextPane(), findsNothing);

      hold.complete();
      await tester.pumpAndSettle();
      expect(
        inCommunitiesPage(find.text(kModerationLogAboutText)),
        findsOneWidget,
      );
      expect(findContextPane(), findsNothing);
      expect(rig.server.count('log:'), 1);
    });

    testWidgets('pushed from the community page: no pane, no copy while the '
        'log loads, then the banner inline', (tester) async {
      final rig = CommunitiesTabletRig();
      rig.server.viewerRole = pb.CommunityRole.COMMUNITY_ROLE_MODERATOR;
      await rig.pump(tester, location: _communityPath, width: 1024);
      final hold = rig.server.holdLog = Completer<void>();
      unawaited(rig.router.push(_logPath));
      await tester.pump();
      expect(findContextPane(), findsNothing);
      expect(restoreCopy(), findsNothing);

      hold.complete();
      await tester.pumpAndSettle();
      expect(findContextPane(), findsNothing);
      expect(
        inCommunitiesPage(find.text(kModerationLogAboutText)),
        findsOneWidget,
      );
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

  group(
    '5. the Explore directory is the inline tab: all rows, no Show more',
    () {
      for (final w in <double>[744, 1024]) {
        testWidgets('at $w, 12 rows: all reachable, no Show more, no pane', (
          tester,
        ) async {
          final rig = CommunitiesTabletRig();
          rig.server.directory = _directoryOf(12);
          await rig.pump(tester, width: w, height: 1100);
          expect(findContextPane(), findsNothing);
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
          expect(rig.server.count('directory'), 1);
        });
      }
    },
  );

  group('6. the preview reads like the real header', () {
    for (final w in <double>[744, 1024]) {
      testWidgets('at $w the dialog: the name is w800, Rules a titleSmall '
          'heading, "Owner · 1 member"', (tester) async {
        final rig = CommunitiesTabletRig();
        await rig.pump(
          tester,
          location: AppRouter.communityNewPath,
          width: w,
          height: 1100,
        );
        expect(findContextPane(), findsNothing);
        await tester.tap(find.widgetWithText(TextButton, 'Preview'));
        await tester.pumpAndSettle();
        final preview = find.byType(CommunityPreview);
        expect(preview, findsOneWidget);
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

      testWidgets('at $w the dialog: the preview lines up with the dialog '
          'title', (tester) async {
        final rig = CommunitiesTabletRig();
        await rig.pump(
          tester,
          location: AppRouter.communityNewPath,
          width: w,
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
    }
  });

  group('7. one label for the moderation log, in the header', () {
    for (final role in [
      pb.CommunityRole.COMMUNITY_ROLE_MODERATOR,
      pb.CommunityRole.COMMUNITY_ROLE_OWNER,
    ]) {
      testWidgets('band B, ${role.name}', (tester) async {
        final rig = CommunitiesTabletRig();
        rig.server.viewerRole = role;
        await rig.pump(tester, location: _communityPath, width: 1024);
        expect(findContextPane(), findsNothing);
        expect(find.text('View moderation log'), findsNothing);
        // Exactly one entry: the header's button, in the page.
        expect(find.text('Moderation log'), findsOneWidget);
        expect(inCommunitiesPage(find.text('Moderation log')), findsOneWidget);
      });
    }
  });

  group('the Join pill takes a tap anywhere in its 48 dp box', () {
    for (final dy in <double>[-5, 5]) {
      testWidgets('band B, ${dy < 0 ? 'above' : 'below'} the 36 dp pill', (
        tester,
      ) async {
        final rig = CommunitiesTabletRig();
        await rig.pump(tester, width: 1024, height: 1100);
        await showExploreTab(tester);
        final pill = inCommunitiesPage(
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
    testWidgets('band B preview dialog: no blank title line, spoken without '
        'it', (tester) async {
      final rig = CommunitiesTabletRig();
      await rig.pump(
        tester,
        location: AppRouter.communityNewPath,
        width: 1024,
        height: 1100,
      );
      await _fillRule(tester, details: 'Links only when asked.');
      await tester.tap(find.widgetWithText(TextButton, 'Preview'));
      await tester.pumpAndSettle();
      final row = find.descendant(
        of: find.byType(Dialog),
        matching: find.byType(CommunityRuleRow),
      );
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
