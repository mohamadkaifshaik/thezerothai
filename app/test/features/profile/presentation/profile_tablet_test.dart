import 'dart:async';

import 'package:dzeroth/core/feature_flags/ui_shell_feature_flag.dart';
import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/graph/presentation/graph_list_screen.dart';
import 'package:dzeroth/features/graph/presentation/widgets/who_to_follow_card.dart';
import 'package:dzeroth/features/profile/presentation/profile_screen.dart';
import 'package:dzeroth/features/profile/presentation/widgets/profile_media_strip.dart';
import 'package:dzeroth/features/search/presentation/widgets/app_search_field.dart';
import 'package:dzeroth/shared/widgets/primitives/app_side_column.dart';
import 'package:dzeroth/shared/widgets/primitives/app_tab_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/context_pane_rig.dart'
    show expectTabletPanes, findContextPane;
import '../../../support/profile_tablet_rig.dart';
import '../../../support/theme_harness.dart';

const _widths = <double>[360, 599, 600, 839, 840, 1024, 1199, 1200];

bool _tabletFlags(Set<String> flags) =>
    flags.contains(kFeatureUiShell) && flags.contains(kFeatureUiTablet);

/// The labels of the page's tab bar, and the selected one.
(List<String>, String) _tabs(WidgetTester tester) {
  final bar = tester.widget<AppTabBar>(inProfilePage(find.byType(AppTabBar)));
  final labels = [for (final t in bar.tabs) t.label];
  return (labels, labels[bar.selectedIndex]);
}

const _allTabs = ['Posts', 'Reposts', 'Media', 'Articles'];

/// The tablet layout has no side column, so the profile's media strip (a
/// context-pane section with no inline copy) is not drawn at any width: the
/// page's own Media tab is where the images are.
void main() {
  group('Profile: flag modes x widths', () {
    for (final MapEntry(key: mode, value: flags) in kProfileFlagModes.entries) {
      for (final w in _widths) {
        testWidgets('$mode at $w: tabs in the page, no pane, no Media strip', (
          tester,
        ) async {
          final rig = ProfileTabletRig();
          await rig.pump(tester, width: w, flags: flags);
          expect(tester.takeException(), isNull);

          // The Media tab is the media (F).
          expect(_tabs(tester).$1, _allTabs);
          expect(findContextPane(), findsNothing);
          expect(find.byType(ProfileMediaStrip), findsNothing);
          expect(find.byType(ProfileMediaStripPlaceholder), findsNothing);
          // Nobody opened Media: no call for it.
          expect(rig.count('feed:$kRigOwnId:media'), 0);
          expect(rig.count('feed:$kRigOwnId:posts'), 1);
          expect(rig.count('profile:'), 1);
          expect(
            find.byType(AppSideColumn),
            w >= AppBreakpoints.tablet ? findsOneWidget : findsNothing,
          );
        });
      }
    }
  });

  group('Profile: pushed and the Media tab', () {
    testWidgets('pushed over Home at 1024: no pane, no strip, no Media call; '
        'the same after pop', (tester) async {
      final rig = ProfileTabletRig();
      await rig.pump(tester, location: AppRouter.homePath);
      expect(findContextPane(), findsNothing);

      unawaited(rig.router.push(AppRouter.profileByIdPath(kRigOtherId)));
      await tester.pumpAndSettle();
      expect(find.byType(ProfileScreen), findsOneWidget);
      expect(findContextPane(), findsNothing);
      expect(find.byType(ProfileMediaStrip), findsNothing);
      expect(find.byType(ProfileMediaStripPlaceholder), findsNothing);
      expect(rig.count('feed:$kRigOtherId:media'), 0);

      rig.router.pop();
      await tester.pumpAndSettle();
      expect(findContextPane(), findsNothing);
      expect(find.byType(ProfileMediaStrip), findsNothing);
    });

    for (final w in <double>[744, 1024]) {
      testWidgets('at $w: the Media tab is the only ask for the Media feed', (
        tester,
      ) async {
        final rig = ProfileTabletRig();
        await rig.pump(tester, width: w);
        expect(rig.count('feed:$kRigOwnId:media'), 0);
        await tester.tap(inProfilePage(find.text('Media')));
        await tester.pumpAndSettle();
        expect(_tabs(tester).$2, 'Media');
        expect(rig.count('feed:$kRigOwnId:media'), 1);
        expect(findContextPane(), findsNothing);
        expect(find.byType(ProfileMediaStrip), findsNothing);
      });
    }
  });

  group('Profile: state across resizes', () {
    testWidgets('the same page, its tab and one call per feed across '
        '1024/839/840/1199/1200/599/600/1024', (tester) async {
      final rig = ProfileTabletRig();
      await rig.pump(tester);
      await tester.tap(inProfilePage(find.text('Reposts')));
      await tester.pumpAndSettle();
      final page = tester.state<NestedScrollViewState>(
        find.byType(NestedScrollView),
      );
      for (final w in <double>[839, 840, 1199, 1200, 599, 600, 1024]) {
        await rig.resize(tester, w);
        expect(tester.takeException(), isNull, reason: '$w');
        expect(_tabs(tester).$2, 'Reposts', reason: '$w');
        expect(findContextPane(), findsNothing, reason: '$w');
        expect(find.byType(ProfileMediaStrip), findsNothing, reason: '$w');
      }
      expect(
        tester.state<NestedScrollViewState>(find.byType(NestedScrollView)),
        same(page),
      );
      expect(rig.count('profile:'), 1);
      expect(rig.count('feed:$kRigOwnId:posts'), 1);
      expect(rig.count('feed:$kRigOwnId:reposts'), 1);
      expect(rig.count('feed:$kRigOwnId:media'), 0);
    });
  });

  group('Profile: layout', () {
    forEachThemeAndWidth(
      'tablet matrix (section 5.5): profile',
      (tester, env) async {
        final width = env.size.width;
        final rig = ProfileTabletRig();
        await rig.pump(
          tester,
          width: width,
          height: env.size.height,
          textScale: env.textScale,
          brightness: env.brightness,
        );
        expect(tester.takeException(), isNull);
        // No side column on the tablet layout: the page takes the content.
        expectTabletPanes(
          tester,
          find.byType(ProfileScreen),
          width,
          hasPane: false,
        );
      },
      widths: kTabletMatrixWidths,
      textScales: kTabletTextScales,
      heights: kTabletHeights,
    );

    for (final w in <double>[834, 1024]) {
      testWidgets('the header menu stays anchored at $w (section 4.2)', (
        tester,
      ) async {
        final rig = ProfileTabletRig();
        await rig.pump(
          tester,
          width: w,
          location: AppRouter.profilePath(kRigOtherHandle),
        );
        final more = inProfilePage(find.byType(PopupMenuButton<String>));
        await tester.tap(more.first);
        await tester.pumpAndSettle();
        expect(find.text('Mute'), findsOneWidget);
        expect(find.byType(Dialog), findsNothing);
        final menu = tester.getRect(
          find
              .ancestor(of: find.text('Mute'), matching: find.byType(Material))
              .first,
        );
        final trigger = tester.getRect(more.first);
        // Anchored at its button, inside the primary pane.
        expect((menu.top - trigger.top).abs(), lessThan(trigger.height + 8));
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
      });
    }
  });

  group('GraphList (Followers / Following)', () {
    for (final MapEntry(key: mode, value: flags) in kProfileFlagModes.entries) {
      for (final w in _widths) {
        testWidgets('$mode at $w, pushed from the profile: no pane', (
          tester,
        ) async {
          final rig = ProfileTabletRig();
          await rig.pump(tester, width: w, flags: flags);
          await tester.tap(
            inProfilePage(find.bySemanticsLabel('12 Followers')),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(find.byType(GraphListScreen), findsOneWidget);
          expect(rig.count('followers:$kRigOwnId'), 1);
          expect(findContextPane(), findsNothing);
          expect(find.byType(ProfileMediaStrip), findsNothing);
          if (_tabletFlags(flags) && w >= 600 && w < 1200) {
            // The tablet pushed page carries no Who to follow of its own.
            expect(find.byType(WhoToFollowCard), findsNothing);
            expectTabletPanes(
              tester,
              find.byType(GraphListScreen),
              w,
              hasPane: false,
            );
          }
        });
      }
    }

    testWidgets('band B: back on the profile there is still no pane and no '
        'Media call', (tester) async {
      final rig = ProfileTabletRig();
      await rig.pump(tester);
      await tester.tap(inProfilePage(find.bySemanticsLabel('34 Following')));
      await tester.pumpAndSettle();
      expect(find.byType(GraphListScreen), findsOneWidget);
      rig.router.pop();
      await tester.pumpAndSettle();
      expect(find.byType(ProfileScreen), findsOneWidget);
      expect(findContextPane(), findsNothing);
      expect(rig.count('feed:$kRigOwnId:media'), 0);
    });

    testWidgets('a typed /profile/:h/followers at 1024: no pane, no search '
        'field, no Who to follow', (tester) async {
      final rig = ProfileTabletRig();
      await rig.pump(
        tester,
        location: AppRouter.followersPath(kRigOtherHandle),
      );
      expect(findContextPane(), findsNothing);
      expect(find.byType(AppSearchField), findsNothing);
      expect(find.byType(WhoToFollowCard), findsNothing);
    });
  });
}
