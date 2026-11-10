import 'package:dzeroth/core/feature_flags/ui_shell_feature_flag.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/core/widgets/app_top_bar.dart';
import 'package:dzeroth/features/graph/presentation/widgets/user_list_row.dart';
import 'package:dzeroth/features/graph/presentation/widgets/who_to_follow_card.dart';
import 'package:dzeroth/features/search/presentation/explore_screen.dart';
import 'package:dzeroth/features/search/presentation/widgets/explore_trends_section.dart';
import 'package:dzeroth/shared/widgets/primitives/app_side_column.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/context_pane_rig.dart';
import '../../../support/geometry.dart';
import '../../../support/theme_harness.dart';

/// Tablet plan T3, Explore (section 4.1: A "F + inl Who to follow", B
/// "P: trends | Who to follow"): one card, one placement. Inline in Explore
/// at every width and flag mode, except in band B of the tablet layout,
/// where it is in the context pane and nowhere else.
void main() {
  Widget page(String path) => path == '/explore'
      ? const ExploreScreen()
      : Scaffold(
          appBar: const AppTopBar(title: 'Page'),
          body: Text('$path body'),
        );

  /// The card inside Explore itself (the primary pane).
  Finder inExplore(Finder f) =>
      find.descendant(of: find.byType(ExploreScreen), matching: f);

  for (final width in [840.0, 1024.0, 1199.0]) {
    testWidgets('band B (${width.toInt()} dp): trends in Explore, Who to '
        'follow in the pane only', (tester) async {
      final rig = ContextPaneRig();
      await rig.pump(tester, location: '/explore', width: width, page: page);

      expect(inExplore(find.byType(ExploreTrendsSection)), findsOneWidget);
      expect(inExplore(find.byType(WhoToFollowCard)), findsNothing);
      expect(find.byType(WhoToFollowCard), findsOneWidget);
      expect(inContextPane(find.text('Who to follow')), findsOneWidget);
      expect(inContextPane(find.byType(UserListRow)), findsNWidgets(3));
      // No search pill and no What's happening beside Explore: the page has
      // its own field and the full trends.
      expect(inContextPane(find.text("What's happening")), findsNothing);
      expect(rig.suggestionCalls, 1);
      expect(rig.trendCalls, 1);
      expectNoOverflow(tester);
    });
  }

  for (final width in [600.0, 834.0]) {
    testWidgets('band A (${width.toInt()} dp): Who to follow inline after '
        'the trends', (tester) async {
      final rig = ContextPaneRig();
      await rig.pump(
        tester,
        location: '/explore',
        width: width,
        height: 2400,
        page: page,
      );

      expect(findContextPane(), findsNothing);
      expect(inExplore(find.byType(WhoToFollowCard)), findsOneWidget);
      expect(
        tester.getTopLeft(inExplore(find.text('Who to follow'))).dy,
        greaterThan(
          tester.getTopLeft(inExplore(find.text('Trending today'))).dy,
        ),
      );
      expect(rig.suggestionCalls, 1);
    });
  }

  final base = {...kContextPaneFlags}
    ..removeAll({kFeatureUiShell, kFeatureUiTablet});
  // Explore needs `ui_shell`; with only `ui_tablet` the route redirects
  // Home in the app, but the screen itself is what is under test here.
  for (final MapEntry(key: mode, value: modeFlags)
      in kTabletFlagModes.entries) {
    if (modeFlags.length == 2) continue;
    testWidgets('$mode at 1024 dp: inline, as today', (tester) async {
      final rig = ContextPaneRig();
      await rig.pump(
        tester,
        location: '/explore',
        height: 2400,
        flags: {...base, ...modeFlags},
        page: page,
      );

      expect(findContextPane(), findsNothing);
      expect(inExplore(find.byType(WhoToFollowCard)), findsOneWidget);
    });
  }

  testWidgets('desktop (1200 dp) with ui_tablet on: inline, and the side '
      'column keeps "You might like" (unchanged)', (tester) async {
    final rig = ContextPaneRig();
    await rig.pump(
      tester,
      location: '/explore',
      width: 1200,
      height: 2400,
      page: page,
    );

    expect(findContextPane(), findsNothing);
    expect(inExplore(find.byType(WhoToFollowCard)), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(AppSideColumn),
        matching: find.text('You might like'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('band B without follow suggestions: no card in either place', (
    tester,
  ) async {
    final rig = ContextPaneRig();
    await rig.pump(
      tester,
      location: '/explore',
      flags: {...kContextPaneFlags}..remove('follow_suggestions'),
      page: page,
    );

    expect(find.byType(WhoToFollowCard), findsNothing);
    expect(rig.suggestionCalls, 0);
    expect(inContextPane(find.text('Privacy Policy')), findsOneWidget);
  });

  testWidgets('a resize across 840 moves the card between the pane and the '
      'page, with the same rows', (tester) async {
    final rig = ContextPaneRig();
    await rig.pump(
      tester,
      location: '/explore',
      width: 1024,
      height: 2400,
      page: page,
    );
    expect(inContextPane(find.byType(WhoToFollowCard)), findsOneWidget);

    tester.view.physicalSize = const Size(834, 2400);
    await tester.pumpAndSettle();
    expect(findContextPane(), findsNothing);
    expect(inExplore(find.byType(WhoToFollowCard)), findsOneWidget);

    tester.view.physicalSize = const Size(1024, 2400);
    await tester.pumpAndSettle();
    expect(inExplore(find.byType(WhoToFollowCard)), findsNothing);
    expect(inContextPane(find.byType(WhoToFollowCard)), findsOneWidget);
    expect(inContextPane(find.byType(UserListRow)), findsNWidgets(3));
    // Each mount asks the shared cubit (the real repository answers a warm
    // call from memory, 0 RPCs); trends are one call per five minutes.
    expect(rig.trendCalls, 1);
  });

  forEachThemeAndWidth(
    'band B: Explore and the pane fit at the narrowest primary',
    (tester, env) async {
      final rig = ContextPaneRig();
      await rig.pump(
        tester,
        location: '/explore',
        width: env.size.width,
        height: env.size.height,
        brightness: env.brightness,
        textScale: env.textScale,
        page: page,
      );

      expectNoOverflow(tester);
      final primary = tester.getRect(find.byType(ExploreScreen));
      expect(primary.left, AppSize.railCompact);
      expect(primary.width, env.size.width == 840 ? 439 : 623);
      expect(inContextPane(find.byType(UserListRow)), findsNWidgets(3));
    },
    widths: const [840, 1024],
    textScales: kTabletTextScales,
    heights: {840: 1194, 1024: 768},
  );
}
