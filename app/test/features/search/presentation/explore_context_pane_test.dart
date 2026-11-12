import 'package:dzeroth/core/feature_flags/ui_shell_feature_flag.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/core/widgets/app_top_bar.dart';
import 'package:dzeroth/core/widgets/context_pane.dart';
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

/// Explore on the tablet layout, which has no side context pane: "Who to
/// follow" is inline in Explore (after the trends) at every width and flag
/// mode, in band B (840-1199 dp) exactly as in band A, and nowhere else.
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

  // Band A (600, 834) and band B (840, 1024, 1199) draw the same thing.
  for (final width in [600.0, 834.0, 840.0, 1024.0, 1199.0]) {
    final band = width >= AppBreakpoints.expanded ? 'band B' : 'band A';
    testWidgets('$band (${width.toInt()} dp): no pane, Who to follow inline '
        'after the trends', (tester) async {
      final rig = ContextPaneRig();
      await rig.pump(
        tester,
        location: '/explore',
        width: width,
        height: 2400,
        page: page,
      );

      expect(findContextPane(), findsNothing);
      expect(find.byKey(const ValueKey('tablet-context-pane')), findsNothing);
      expect(
        tester.widget<ContextPaneScope>(find.byType(ContextPaneScope)).shown,
        isEmpty,
      );
      expect(inExplore(find.byType(ExploreTrendsSection)), findsOneWidget);
      expect(find.byType(WhoToFollowCard), findsOneWidget);
      expect(inExplore(find.byType(WhoToFollowCard)), findsOneWidget);
      expect(inExplore(find.byType(UserListRow)), findsNWidgets(3));
      expect(
        tester.getTopLeft(inExplore(find.text('Who to follow'))).dy,
        greaterThan(
          tester.getTopLeft(inExplore(find.text('Trending today'))).dy,
        ),
      );
      expect(rig.suggestionCalls, 1);
      expectNoOverflow(tester);
    });
  }

  final base = {...kContextPaneFlags}
    ..removeAll({kFeatureUiShell, kFeatureUiTablet});
  // Explore needs `ui_shell`; with only `ui_tablet` the route redirects
  // Home in the app, but the screen itself is what is under test here.
  for (final MapEntry(key: mode, value: modeFlags)
      in kTabletFlagModes.entries) {
    // Every mode on a phone (599), and every mode but the tablet one at
    // 1024: the inline card, as today.
    for (final width in [599.0, 1024.0]) {
      if (modeFlags.length == 2 && width == 1024) continue;
      testWidgets('$mode at ${width.toInt()} dp: inline, as today', (
        tester,
      ) async {
        final rig = ContextPaneRig();
        await rig.pump(
          tester,
          location: '/explore',
          width: width,
          height: 2400,
          flags: {...base, ...modeFlags},
          page: page,
        );

        expect(findContextPane(), findsNothing);
        expect(find.byType(ContextPaneScope), findsNothing);
        expect(inExplore(find.byType(WhoToFollowCard)), findsOneWidget);
      });
    }
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

  testWidgets('band B without follow suggestions: no card, nothing asked, '
      'no pane', (tester) async {
    final rig = ContextPaneRig();
    await rig.pump(
      tester,
      location: '/explore',
      flags: {...kContextPaneFlags}..remove('follow_suggestions'),
      page: page,
    );

    expect(find.byType(WhoToFollowCard), findsNothing);
    expect(rig.suggestionCalls, 0);
    expect(findContextPane(), findsNothing);
  });

  testWidgets('a resize across 840 changes nothing: the card stays inline '
      'with the same rows, no pane', (tester) async {
    final rig = ContextPaneRig();
    await rig.pump(
      tester,
      location: '/explore',
      width: 834,
      height: 2400,
      page: page,
    );

    for (final width in [834.0, 840.0, 1024.0, 839.0]) {
      tester.view.physicalSize = Size(width, 2400);
      await tester.pumpAndSettle();
      expect(findContextPane(), findsNothing, reason: '$width');
      expect(
        inExplore(find.byType(WhoToFollowCard)),
        findsOneWidget,
        reason: '$width',
      );
      expect(
        inExplore(find.byType(UserListRow)),
        findsNWidgets(3),
        reason: '$width',
      );
      expectNoOverflow(tester);
    }
    // Trends are one call per five minutes.
    expect(rig.trendCalls, 1);
  });

  // The tablet matrix (plan section 5.5): 5 widths x 2 scales x 2 themes,
  // plus 840, the first band B width.
  forEachThemeAndWidth(
    'tablet matrix: Explore fills the content, the card inline, no pane',
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
      expectTabletPanes(
        tester,
        find.byType(ExploreScreen),
        env.size.width,
        hasPane: false,
      );
      // Inline at the end of the page: build it (a lazy list).
      await tester.scrollUntilVisible(
        inExplore(find.byType(WhoToFollowCard)),
        300,
        scrollable: inExplore(find.byType(Scrollable)).first,
      );
      await tester.pumpAndSettle();
      expectNoOverflow(tester);
      expect(find.byType(WhoToFollowCard), findsOneWidget);
      expect(inExplore(find.byType(WhoToFollowCard)), findsOneWidget);
    },
    widths: [...kTabletMatrixWidths, 840],
    textScales: kTabletTextScales,
    heights: {...kTabletHeights, 840: 1194},
  );
}
