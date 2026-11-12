import 'package:dzeroth/core/feature_flags/ui_shell_feature_flag.dart';
import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/core/widgets/shell_geometry.dart';
import 'package:dzeroth/features/communities/presentation/communities_screen.dart';
import 'package:dzeroth/features/communities/presentation/community_moderation_log_screen.dart';
import 'package:dzeroth/features/communities/presentation/community_screen.dart';
import 'package:dzeroth/features/communities/presentation/create_community_screen.dart';
import 'package:dzeroth/features/communities/presentation/widgets/community_join_control.dart';
import 'package:dzeroth/features/communities/presentation/widgets/community_preview.dart';
import 'package:dzeroth/features/communities/presentation/widgets/moderation_log_about.dart';
import 'package:dzeroth/gen/dzeroth/communities/v1/communities.pb.dart' as pb;
import 'package:dzeroth/shared/widgets/primitives/app_side_column.dart';
import 'package:dzeroth/shared/widgets/primitives/app_tab_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/communities_tablet_rig.dart';
import '../../../support/context_pane_rig.dart'
    show expectTabletPanes, findContextPane, inContextPane;
import '../../../support/tablet_modal_harness.dart' show openDialogRect;
import '../../../support/theme_harness.dart';

const _widths = <double>[360, 599, 600, 839, 840, 1024, 1199, 1200];

bool _tabletFlags(Set<String> flags) =>
    flags.contains(kFeatureUiShell) && flags.contains(kFeatureUiTablet);

/// The tablet layout has no side context pane at any width (the owner's
/// ruling: no tablet mock has one), so a page never lends a section into one:
/// every communities page draws its own copy inline. Desktop's side column
/// (>= 1200, R-1) is a different widget and is not covered here.
Finder _tabletContextPane() =>
    find.byKey(const ValueKey('tablet-context-pane'));

/// A text field whose label or hint is [text] (F36 / F37 search fields).
Finder _fieldNamed(String text) => find.byWidgetPredicate(
  (w) =>
      w is TextField &&
      (w.decoration?.hintText == text || w.decoration?.labelText == text),
);

String _communityPath = AppRouter.communityPath(kRigCommunityId);
String _membersPath = AppRouter.communityMembersPath(kRigCommunityId);
String _logPath = AppRouter.communityModerationLogPath(kRigCommunityId);

void main() {
  group('Communities (/communities)', () {
    for (final MapEntry(key: mode, value: flags)
        in kCommunitiesFlagModes.entries) {
      for (final w in _widths) {
        testWidgets('$mode at $w: Explore Communities inline, no context '
            'pane', (tester) async {
          final rig = CommunitiesTabletRig();
          await rig.pump(tester, width: w, flags: flags);
          expect(tester.takeException(), isNull);

          expect(
            inCommunitiesPage(find.text('My communities')),
            findsOneWidget,
          );
          // R10 (F37): "Search communities" in exactly one place, above the
          // tabs, at every width (band B draws what band A draws).
          expect(_fieldNamed('Search communities'), findsOneWidget);
          expect(
            inCommunitiesPage(_fieldNamed('Search communities')),
            findsOneWidget,
          );
          expect(findContextPane(), findsNothing);
          expect(_tabletContextPane(), findsNothing);
          // R10 (F23): Explore is the second tab of the page.
          final tabs = tester.widget<AppTabBar>(find.byType(AppTabBar));
          expect(
            [for (final t in tabs.tabs) t.label],
            ['My communities', 'Explore'],
          );
          expect(find.text('Explore communities'), findsNothing);
          expect(
            inCommunitiesPage(find.byKey(const ValueKey('explore-78'))),
            findsNothing,
          );
          await showExploreTab(tester);
          expect(
            inCommunitiesPage(find.byKey(const ValueKey('explore-78'))),
            findsOneWidget,
          );
          expect(rig.server.count('mine'), 1);
          expect(rig.server.count('directory'), 1);
          // Desktop keeps its side column (R-1).
          expect(
            find.byType(AppSideColumn),
            w >= AppBreakpoints.tablet ? findsOneWidget : findsNothing,
          );
        });
      }
    }

    testWidgets('band B: Join in the Explore tab is the page Join (one '
        'call, the row and My Communities follow)', (tester) async {
      final rig = CommunitiesTabletRig();
      await rig.pump(tester, width: 1024);
      expect(findContextPane(), findsNothing);
      await showExploreTab(tester);
      await tester.tap(
        inCommunitiesPage(find.bySemanticsLabel('Join Book club')),
      );
      await tester.pumpAndSettle();

      expect(rig.server.count('join:78'), 1);
      expect(
        find.descendant(
          of: inCommunitiesPage(find.byKey(const ValueKey('explore-78'))),
          matching: find.text('Joined'),
        ),
        findsOneWidget,
      );
      // The page's own list took the joined community.
      await tapCommunityTab(tester, 'My communities');
      expect(inCommunitiesPage(find.text('Book club')), findsOneWidget);
      expect(rig.server.count('mine'), 1);
      expect(rig.server.count('directory'), 1);
    });

    for (final w in <double>[839, 1024]) {
      testWidgets('at $w the Join pill sits after the name (inline, the same '
          'in both tablet bands)', (tester) async {
        final rig = CommunitiesTabletRig();
        await rig.pump(tester, width: w);
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
    }

    testWidgets('band B: an Explore row opens the community (pushed), with no '
        'pane', (tester) async {
      final rig = CommunitiesTabletRig();
      await rig.pump(tester, width: 1024);
      await showExploreTab(tester);
      await tester.tap(
        inCommunitiesPage(find.bySemanticsLabel(RegExp('^Chess club'))),
      );
      await tester.pumpAndSettle();

      expect(rig.uri.path, _communityPath);
      expect(findContextPane(), findsNothing);
      expect(find.text('Explore communities'), findsNothing);

      rig.router.pop();
      await tester.pumpAndSettle();
      expect(rig.uri.path, AppRouter.communitiesPath);
      expect(findContextPane(), findsNothing);
    });

    testWidgets('band B: the Explore tab follows the directory states '
        '(empty)', (tester) async {
      final rig = CommunitiesTabletRig();
      rig.server.directory = [];
      await rig.pump(tester, width: 1024);
      expect(findContextPane(), findsNothing);
      await showExploreTab(tester);
      expect(
        inCommunitiesPage(find.text('No Communities to explore yet.')),
        findsOneWidget,
      );
    });

    testWidgets('state across 839, 840, 1024, 1199, 1200 and 599: the same '
        'page and cubit, no new call, a Join kept', (tester) async {
      final rig = CommunitiesTabletRig();
      await rig.pump(tester, width: 1024);
      final state = tester.state(find.byType(CommunitiesScreen));
      await showExploreTab(tester);
      await tester.tap(
        inCommunitiesPage(find.bySemanticsLabel('Join Book club')),
      );
      await tester.pumpAndSettle();

      for (final w in <double>[839, 840, 1024, 1199, 1200, 599, 600, 1024]) {
        await rig.resize(tester, w);
        expect(tester.takeException(), isNull, reason: '$w');
        expect(
          tester.state(find.byType(CommunitiesScreen)),
          same(state),
          reason: '$w',
        );
        final row = find.byKey(const ValueKey('explore-78'));
        // R10 (F23): Explore is a tab at every width (kept once chosen).
        if (row.evaluate().isEmpty) await showExploreTab(tester);
        await tester.scrollUntilVisible(
          row,
          100,
          scrollable: find
              .descendant(
                of: findCommunitiesPage(),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        expect(
          find.descendant(of: row, matching: find.text('Joined')),
          findsOneWidget,
          reason: '$w',
        );
        expect(findContextPane(), findsNothing, reason: '$w');
      }
      expect(rig.server.count('mine'), 1);
      expect(rig.server.count('directory'), 1);
      expect(rig.server.count('join:'), 1);
    });
  });

  group('Community (/communities/:id)', () {
    for (final MapEntry(key: mode, value: flags)
        in kCommunitiesFlagModes.entries) {
      for (final w in _widths) {
        testWidgets('$mode at $w: rules and moderators in the About tab '
            'only, no context pane', (tester) async {
          final rig = CommunitiesTabletRig();
          await rig.pump(
            tester,
            location: _communityPath,
            width: w,
            flags: flags,
          );
          expect(tester.takeException(), isNull);

          // Posts / About at every width (R-inline).
          final tabs = tester.widget<AppTabBar>(find.byType(AppTabBar));
          expect([for (final t in tabs.tabs) t.label], ['Posts', 'About']);
          expect(findContextPane(), findsNothing);
          expect(_tabletContextPane(), findsNothing);
          // A member does not moderate: no log entry anywhere.
          expect(find.text('Moderation log'), findsNothing);
          // The Posts tab is open: the rules are not in the page.
          expect(inCommunitiesPage(find.text('Be kind')), findsNothing);
          expect(rig.server.count('get:'), 1);
          expect(rig.feedRefreshes, 1);
        });
      }
    }

    testWidgets('band B: the About tab shows the rules and moderators in the '
        'page, and there is no pane', (tester) async {
      final rig = CommunitiesTabletRig();
      await rig.pump(tester, location: _communityPath, width: 1024);
      expect(findContextPane(), findsNothing);
      await tester.tap(find.text('About'));
      await tester.pumpAndSettle();
      expect(findContextPane(), findsNothing);
      expect(inCommunitiesPage(find.text('Rules')), findsOneWidget);
      expect(inCommunitiesPage(find.text('Be kind')), findsOneWidget);
      expect(inCommunitiesPage(find.text('Stay on topic')), findsOneWidget);
      expect(inCommunitiesPage(find.text('Moderators')), findsOneWidget);
      expect(inCommunitiesPage(find.text('Olivia')), findsOneWidget);
      expect(inCommunitiesPage(find.text('Mo')), findsOneWidget);
    });

    testWidgets('band B: no rules says so in the About tab', (tester) async {
      final rig = CommunitiesTabletRig();
      rig.server.rules = [];
      await rig.pump(tester, location: _communityPath, width: 1024);
      await tester.tap(find.text('About'));
      await tester.pumpAndSettle();
      expect(findContextPane(), findsNothing);
      expect(
        inCommunitiesPage(
          find.text("This Community hasn't set any rules yet."),
        ),
        findsOneWidget,
      );
    });

    for (final role in [
      pb.CommunityRole.COMMUNITY_ROLE_MODERATOR,
      pb.CommunityRole.COMMUNITY_ROLE_OWNER,
    ]) {
      testWidgets('band B, ${role.name}: the header "Moderation log" '
          'opens the log, which has no pane', (tester) async {
        final rig = CommunitiesTabletRig();
        rig.server.viewerRole = role;
        await rig.pump(tester, location: _communityPath, width: 1024);
        expect(findContextPane(), findsNothing);
        final link = inCommunitiesPage(find.text('Moderation log'));
        expect(link, findsOneWidget);
        expect(tester.getSize(link.hitTestable()).height, greaterThan(0));
        expect(
          tester
              .getSize(
                find.ancestor(of: link, matching: find.byType(OutlinedButton)),
              )
              .height,
          greaterThanOrEqualTo(AppSpacing.minTapTarget),
        );
        await tester.tap(link);
        await tester.pumpAndSettle();
        expect(rig.uri.path, _logPath);
        expect(findContextPane(), findsNothing);
        expect(rig.server.count('log:'), 1);
      });
    }

    testWidgets('band A, moderator: the header keeps its Moderation log, no '
        'pane', (tester) async {
      final rig = CommunitiesTabletRig();
      rig.server.viewerRole = pb.CommunityRole.COMMUNITY_ROLE_MODERATOR;
      await rig.pump(tester, location: _communityPath, width: 834);
      expect(findContextPane(), findsNothing);
      expect(find.text('Moderation log'), findsOneWidget);
      expect(inCommunitiesPage(find.text('Moderation log')), findsOneWidget);
    });

    testWidgets('pushed over Home (a post community label): no pane at '
        'band B, before or after', (tester) async {
      final rig = CommunitiesTabletRig();
      await rig.pump(tester, location: AppRouter.homePath, width: 1024);
      expect(findContextPane(), findsNothing);

      rig.router.push(_communityPath);
      await tester.pumpAndSettle();
      expect(findContextPane(), findsNothing);
      expect(find.text('Be kind'), findsNothing);

      rig.router.pop();
      await tester.pumpAndSettle();
      expect(findContextPane(), findsNothing);
    });

    testWidgets('state across 839, 840, 1199, 1200, 599 and back: the About '
        'tab stays open, one GetCommunity, one feed open', (tester) async {
      final rig = CommunitiesTabletRig();
      await rig.pump(tester, location: _communityPath, width: 1024);
      final state = tester.state(find.byType(CommunityScreen));
      await tester.tap(find.text('About'));
      await tester.pumpAndSettle();

      for (final w in <double>[839, 840, 1199, 1200, 599, 600, 1024]) {
        await rig.resize(tester, w);
        expect(tester.takeException(), isNull, reason: '$w');
        expect(tester.state(find.byType(CommunityScreen)), same(state));
        expect(
          inCommunitiesPage(find.text('Be kind')),
          findsOneWidget,
          reason: '$w: About is still the open tab',
        );
        expect(findContextPane(), findsNothing, reason: '$w');
      }
      expect(rig.server.count('get:'), 1);
      expect(rig.feedRefreshes, 1);
    });

    testWidgets('band B in RTL: no pane, the page takes the content beside '
        'the rail on the right', (tester) async {
      final rig = CommunitiesTabletRig();
      await rig.pump(
        tester,
        location: _communityPath,
        width: 1024,
        textDirection: TextDirection.rtl,
      );
      expect(tester.takeException(), isNull);
      expect(findContextPane(), findsNothing);
      final page = tester.getRect(findCommunitiesPage());
      final rail = tester.getRect(find.byKey(const ValueKey('tablet-rail')));
      expect(page.left, 0);
      expect(page.right, rail.left);
      expect(rail.right, 1024);
    });

    for (final w in <double>[834, 1024]) {
      testWidgets('at $w "Community options" stays an anchored menu (section '
          '4.2)', (tester) async {
        final rig = CommunitiesTabletRig();
        await rig.pump(
          tester,
          location: _communityPath,
          width: w,
          flags: {...kCommunitiesTabletFlags, 'reports'},
        );
        final button = find.byTooltip('Community options');
        await tester.tap(button);
        await tester.pumpAndSettle();
        final item = find.text('Report Community');
        expect(item, findsOneWidget);
        expect(find.byType(Dialog), findsNothing);
        expect(find.byType(BottomSheet), findsNothing);
        // Anchored at the button, inside the page.
        final itemRect = tester.getRect(item);
        final page = tester.getRect(findCommunitiesPage());
        expect(
          (itemRect.center - tester.getCenter(button)).distance,
          lessThan(300),
        );
        expect(itemRect.right, lessThanOrEqualTo(page.right));
        await tester.tapAt(const Offset(200, 600));
        await tester.pumpAndSettle();
      });
    }

    for (final w in <double>[700, 1024]) {
      testWidgets('at $w the Leave confirm is a D 280-400 on the content '
          'area', (tester) async {
        final rig = CommunitiesTabletRig();
        await rig.pump(tester, location: _communityPath, width: w);
        await tester.tap(inCommunitiesPage(find.text('Joined')));
        await tester.pumpAndSettle();
        final dialog = find.byType(AlertDialog);
        expect(dialog, findsOneWidget);
        expect(find.text('Leave Chess club?'), findsOneWidget);
        final rect = openDialogRect(tester);
        expect(rect.width, inInclusiveRange(280, 400));
        final content = w - AppSize.railCompact;
        expect(rect.center.dx, closeTo(AppSize.railCompact + content / 2, 1));
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(rig.server.count('leave:'), 0);
      });
    }
  });

  group('CommunityMembers (/communities/:id/members)', () {
    for (final MapEntry(key: mode, value: flags)
        in kCommunitiesFlagModes.entries) {
      for (final w in _widths) {
        testWidgets('$mode at $w: members alone, no pane; no "Search '
            'members" (its flag off), the Moderators tab', (tester) async {
          final rig = CommunitiesTabletRig();
          rig.server.viewerRole = pb.CommunityRole.COMMUNITY_ROLE_MODERATOR;
          await rig.pump(
            tester,
            location: _membersPath,
            width: w,
            flags: flags,
          );
          expect(tester.takeException(), isNull);

          expect(findContextPane(), findsNothing);
          expect(inCommunitiesPage(find.text('Member 1')), findsOneWidget);
          // F36 stays hidden with `community_member_search` off (these
          // modes); F24's Moderators tab shows to a moderator (R10).
          expect(find.textContaining('Search members'), findsNothing);
          expect(_fieldNamed('Search members'), findsNothing);
          final tabs = tester.widget<AppTabBar>(find.byType(AppTabBar));
          expect(
            [for (final t in tabs.tabs) t.label],
            ['Members', 'Moderators', 'Banned'],
          );
          expect(rig.server.count('members:'), 1);
        });
      }
    }

    testWidgets('a member (no moderation) gets no tab bar at all, in band B '
        'too', (tester) async {
      final rig = CommunitiesTabletRig();
      await rig.pump(tester, location: _membersPath, width: 1024);
      expect(find.byType(AppTabBar), findsNothing);
      expect(findContextPane(), findsNothing);
    });

    testWidgets('pushed from the community member count: no pane, and none '
        'after back', (tester) async {
      final rig = CommunitiesTabletRig();
      await rig.pump(tester, location: _communityPath, width: 1024);
      await tester.tap(find.bySemanticsLabel('5 members, see members'));
      await tester.pumpAndSettle();
      expect(rig.uri.path, _membersPath);
      expect(findContextPane(), findsNothing);
      rig.router.pop();
      await tester.pumpAndSettle();
      expect(rig.uri.path, _communityPath);
      expect(findContextPane(), findsNothing);
    });

    for (final w in <double>[700, 1024]) {
      testWidgets('at $w the Ban confirm is a D 280-400 on the content area', (
        tester,
      ) async {
        final rig = CommunitiesTabletRig();
        rig.server.viewerRole = pb.CommunityRole.COMMUNITY_ROLE_MODERATOR;
        await rig.pump(tester, location: _membersPath, width: w);
        await tester.tap(find.byTooltip('Moderate @member1'));
        await tester.pumpAndSettle();
        await tester.tap(find.textContaining('Ban').last);
        await tester.pumpAndSettle();
        final dialog = find.byType(AlertDialog);
        expect(dialog, findsOneWidget);
        final rect = openDialogRect(tester);
        expect(rect.width, inInclusiveRange(280, 400));
        final content = w - AppSize.railCompact;
        expect(rect.center.dx, closeTo(AppSize.railCompact + content / 2, 1));
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(rig.server.count('role:'), 0);
      });
    }
  });

  group('ModLog (/communities/:id/moderation-log)', () {
    for (final MapEntry(key: mode, value: flags)
        in kCommunitiesFlagModes.entries) {
      for (final w in _widths) {
        final tablet = _tabletFlags(flags) && w >= 600 && w < 1200;
        testWidgets('$mode at $w: About this log '
            '${tablet ? 'inline' : 'not shown'}, no context pane', (
          tester,
        ) async {
          final rig = CommunitiesTabletRig();
          rig.server.viewerRole = pb.CommunityRole.COMMUNITY_ROLE_MODERATOR;
          await rig.pump(tester, location: _logPath, width: w, flags: flags);
          expect(tester.takeException(), isNull);

          expect(
            find.text(kModerationLogAboutTitle),
            tablet ? findsOneWidget : findsNothing,
          );
          expect(
            inCommunitiesPage(find.text(kModerationLogAboutText)),
            tablet ? findsOneWidget : findsNothing,
          );
          expect(findContextPane(), findsNothing);
          // The log itself is unchanged: three entries, one call.
          expect(find.textContaining('@member1'), findsWidgets);
          expect(rig.server.count('log:'), 1);
        });
      }
    }

    for (final w in <double>[744, 1024]) {
      testWidgets('at $w the banner sits between the header and the log', (
        tester,
      ) async {
        final rig = CommunitiesTabletRig();
        rig.server.viewerRole = pb.CommunityRole.COMMUNITY_ROLE_MODERATOR;
        await rig.pump(tester, location: _logPath, width: w);
        final banner = tester.getRect(find.byType(ModerationLogAbout));
        final header = tester.getRect(find.text('Moderation log'));
        final firstEntry = tester.getRect(
          find.textContaining('@member1').first,
        );
        expect(banner.top, greaterThan(header.bottom));
        expect(banner.bottom, lessThanOrEqualTo(firstEntry.top));
        expect(findContextPane(), findsNothing);
      });
    }

    testWidgets('state across 839, 840 and back: the same log, one call', (
      tester,
    ) async {
      final rig = CommunitiesTabletRig();
      rig.server.viewerRole = pb.CommunityRole.COMMUNITY_ROLE_MODERATOR;
      await rig.pump(tester, location: _logPath, width: 839);
      final state = tester.state(find.byType(CommunityModerationLogScreen));
      for (final w in <double>[840, 839, 1199, 1200, 599, 839]) {
        await rig.resize(tester, w);
        expect(tester.takeException(), isNull, reason: '$w');
        expect(
          tester.state(find.byType(CommunityModerationLogScreen)),
          same(state),
        );
        expect(find.textContaining('@member1'), findsWidgets);
      }
      expect(rig.server.count('log:'), 1);
    });
  });

  group('CreateCommunity (/communities/new)', () {
    for (final MapEntry(key: mode, value: flags)
        in kCommunitiesFlagModes.entries) {
      for (final w in _widths) {
        final tablet = _tabletFlags(flags) && w >= 600 && w < 1200;
        testWidgets('$mode at $w: preview '
            '${tablet ? 'behind the header action' : 'not shown'}, no context '
            'pane', (tester) async {
          final rig = CommunitiesTabletRig();
          await rig.pump(
            tester,
            location: AppRouter.communityNewPath,
            width: w,
            flags: flags,
          );
          expect(tester.takeException(), isNull);

          expect(
            find.widgetWithText(TextButton, 'Preview'),
            tablet ? findsOneWidget : findsNothing,
          );
          expect(findContextPane(), findsNothing);
          expect(find.byType(CommunityPreview), findsNothing);
          // The form is the same everywhere.
          expect(find.text('Create a community'), findsOneWidget);
          expect(rig.server.calls, isEmpty);
        });
      }
    }

    Future<void> fill(WidgetTester tester) async {
      await tester.enterText(createFormField('Name'), '  Go club ');
      await tester.enterText(createFormField('Description'), 'Weekly games');
      await tester.tap(find.text('Add a rule'));
      await tester.pumpAndSettle();
      await tester.enterText(createFormField('Rule 1 title'), 'No spam');
      await tester.enterText(
        createFormField('Rule 1 details'),
        'Links only when asked.',
      );
      await tester.pumpAndSettle();
    }

    for (final w in <double>[600, 744, 839, 840, 1024, 1199]) {
      testWidgets('tablet at $w: Preview opens a D 560 dialog on the content '
          'area with the form as typed', (tester) async {
        final rig = CommunitiesTabletRig();
        await rig.pump(
          tester,
          location: AppRouter.communityNewPath,
          width: w,
          height: 1100,
        );
        await fill(tester);
        await tester.tap(find.widgetWithText(TextButton, 'Preview'));
        await tester.pumpAndSettle();

        final dialog = find.byType(Dialog);
        expect(dialog, findsOneWidget);
        final preview = find.descendant(
          of: dialog,
          matching: find.byType(CommunityPreview),
        );
        expect(preview, findsOneWidget);
        Finder inPreview(Finder f) => find.descendant(of: preview, matching: f);
        expect(inPreview(find.text('Go club')), findsOneWidget);
        expect(inPreview(find.text('Weekly games')), findsOneWidget);
        expect(inPreview(find.text('No spam')), findsOneWidget);
        expect(inPreview(find.text('Links only when asked.')), findsOneWidget);
        expect(inPreview(find.text('1.')), findsOneWidget);

        final content = w - AppSize.railCompact;
        final rect = openDialogRect(tester);
        expect(
          rect.width,
          lessThanOrEqualTo(
            content - 48 < AppSize.dialogMax ? content - 48 : AppSize.dialogMax,
          ),
        );
        expect(rect.center.dx, closeTo(AppSize.railCompact + content / 2, 1));

        await tester.tap(find.text('Close'));
        await tester.pumpAndSettle();
        expect(find.byType(Dialog), findsNothing);
        expect(find.text('Go club'), findsNothing);
        expect(rig.server.calls, isEmpty);
      });
    }

    testWidgets('state across 839, 840, 1024, 1199, 1200, 599 and back: the '
        'typed form survives and the preview stays behind the header action '
        '(no pane at any width)', (tester) async {
      final rig = CommunitiesTabletRig();
      await rig.pump(
        tester,
        location: AppRouter.communityNewPath,
        width: 839,
        height: 1100,
      );
      await fill(tester);
      final state = tester.state(find.byType(CreateCommunityScreen));
      final field = tester.state<EditableTextState>(
        find.descendant(
          of: createFormField('Name'),
          matching: find.byType(EditableText),
        ),
      );

      for (final w in <double>[840, 1024, 1199, 1200, 599, 600, 839]) {
        await rig.resize(tester, w);
        expect(tester.takeException(), isNull, reason: '$w');
        expect(
          tester.state(find.byType(CreateCommunityScreen)),
          same(state),
          reason: '$w',
        );
        expect(
          tester.state<EditableTextState>(
            find.descendant(
              of: createFormField('Name'),
              matching: find.byType(EditableText),
            ),
          ),
          same(field),
          reason: '$w',
        );
        expect(field.textEditingValue.text, '  Go club ');
        expect(findContextPane(), findsNothing, reason: '$w');
        expect(
          find.widgetWithText(TextButton, 'Preview'),
          w >= 600 && w < 1200 ? findsOneWidget : findsNothing,
          reason: '$w',
        );
      }
      // Back at 839, the dialog shows the typed form.
      await tester.tap(find.widgetWithText(TextButton, 'Preview'));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(Dialog),
          matching: find.text('No spam'),
        ),
        findsOneWidget,
      );
      expect(rig.server.calls, isEmpty);
    });
  });

  group('communities off (the router sends these routes Home; should one '
      'show anyway)', () {
    final off = {...kCommunitiesTabletFlags}..remove('communities');

    testWidgets('/communities at 1024: no pane, and Explore Communities '
        'stays inline', (tester) async {
      final rig = CommunitiesTabletRig();
      await rig.pump(tester, width: 1024, flags: off);
      expect(tester.takeException(), isNull);
      expect(findContextPane(), findsNothing);
      // R10 (F23): inline, Explore is the second tab of the page.
      expect(find.byType(AppTabBar), findsOneWidget);
      await showExploreTab(tester);
      expect(
        inCommunitiesPage(find.byKey(const ValueKey('explore-78'))),
        findsOneWidget,
      );
    });

    for (final (name, location) in [
      ('Community', _communityPath),
      ('ModLog', _logPath),
      ('CreateCommunity', AppRouter.communityNewPath),
    ]) {
      testWidgets('$name at 1024: no pane, none of the communities '
          'sections in it', (tester) async {
        final rig = CommunitiesTabletRig();
        rig.server.viewerRole = pb.CommunityRole.COMMUNITY_ROLE_MODERATOR;
        await rig.pump(tester, location: location, width: 1024, flags: off);
        expect(tester.takeException(), isNull);
        expect(findContextPane(), findsNothing);
        expect(_tabletContextPane(), findsNothing);
        expect(inContextPane(find.text('Be kind')), findsNothing);
        expect(
          inContextPane(find.text(kModerationLogAboutTitle)),
          findsNothing,
        );
        expect(inContextPane(find.byType(CommunityPreview)), findsNothing);
      });
    }
  });

  group('tablet matrix (plan section 5.5)', () {
    final screens = <String, String>{
      'Communities': AppRouter.communitiesPath,
      'Community': _communityPath,
      'CommunityMembers': _membersPath,
      'ModLog': _logPath,
      'CreateCommunity': AppRouter.communityNewPath,
    };
    for (final MapEntry(key: name, value: location) in screens.entries) {
      forEachThemeAndWidth(
        '$name: no overflow, the rail pinned at 0, no pane',
        (tester, env) async {
          final rig = CommunitiesTabletRig();
          rig.server.viewerRole = pb.CommunityRole.COMMUNITY_ROLE_MODERATOR;
          await rig.pump(
            tester,
            location: location,
            width: env.size.width,
            height: env.size.height,
            textScale: env.textScale,
            brightness: env.brightness,
          );
          expect(tester.takeException(), isNull);
          expect(
            tester.getRect(find.byKey(const ValueKey('tablet-rail'))).left,
            0,
          );
          // No side context pane at any tablet width: the page takes the
          // whole content beside the rail.
          expectTabletPanes(
            tester,
            findCommunitiesPage(),
            env.size.width,
            hasPane: false,
          );
          expect(findContextPane(), findsNothing);
          // The page geometry is the shell's.
          final geometry = ShellGeometry.maybeOf(
            tester.element(findCommunitiesPage()),
          );
          expect(geometry?.tablet, isTrue);
        },
        widths: kTabletMatrixWidths,
        textScales: kTabletTextScales,
        heights: kTabletHeights,
      );
    }
  });

  group('text scale 2.0 at 840 x 1194 (no pane: the page is inline)', () {
    for (final brightness in Brightness.values) {
      testWidgets('Communities, ${brightness.name}: the directory rows and '
          'Join fit; rows >= 48 dp', (tester) async {
        final rig = CommunitiesTabletRig();
        await rig.pump(
          tester,
          width: 840,
          height: 1194,
          textScale: 2,
          brightness: brightness,
        );
        expect(tester.takeException(), isNull);
        expect(findContextPane(), findsNothing);
        await showExploreTab(tester);
        for (final (id, _) in kRigDirectory) {
          final row = inCommunitiesPage(find.byKey(ValueKey('explore-$id')));
          await tester.scrollUntilVisible(
            row,
            100,
            scrollable: find
                .descendant(
                  of: findCommunitiesPage(),
                  matching: find.byType(Scrollable),
                )
                .first,
          );
          expect(
            tester.getSize(row).height,
            greaterThanOrEqualTo(AppSpacing.minTapTarget),
          );
        }
      });

      testWidgets('Community (moderator), ${brightness.name}: the header '
          'and its log link fit', (tester) async {
        final rig = CommunitiesTabletRig();
        rig.server.viewerRole = pb.CommunityRole.COMMUNITY_ROLE_MODERATOR;
        await rig.pump(
          tester,
          location: _communityPath,
          width: 840,
          height: 1194,
          textScale: 2,
          brightness: brightness,
        );
        expect(tester.takeException(), isNull);
        expect(findContextPane(), findsNothing);
        final link = inCommunitiesPage(find.text('Moderation log'));
        await tester.scrollUntilVisible(
          link,
          100,
          scrollable: find
              .descendant(
                of: findCommunitiesPage(),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        expect(tester.takeException(), isNull);
      });
    }
  });
}
