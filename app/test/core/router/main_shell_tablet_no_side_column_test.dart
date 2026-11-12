import 'package:dzeroth/core/feature_flags/ui_shell_feature_flag.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/core/widgets/app_bottom_bar.dart';
import 'package:dzeroth/core/widgets/app_nav_rail.dart';
import 'package:dzeroth/core/widgets/app_top_bar.dart';
import 'package:dzeroth/core/widgets/shell_geometry.dart';
import 'package:dzeroth/features/settings/presentation/settings_screen.dart';
import 'package:dzeroth/shared/widgets/primitives/app_side_column.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/context_pane_rig.dart';
import '../../support/geometry.dart';
import '../../support/theme_harness.dart';

/// The tablet layout has no side column: none of the tablet designs has one.
/// Band B (840-1199 dp) draws exactly what band A (600-839 dp) draws, in the
/// real `MainShell`: the rail and the page across the whole content, so every
/// page keeps its inline sections. List-detail pages keep their list pane in
/// band B; desktop (>= 1200 dp) keeps its side column.
void main() {
  /// The page's header (the stub page's top bar spans the page).
  Rect primaryRect(WidgetTester tester) =>
      tester.getRect(find.byType(AppTopBar));

  /// Nothing of a side pane is drawn or fetched.
  void expectNoPane(WidgetTester tester, ContextPaneRig rig) {
    expect(find.byKey(const ValueKey('tablet-context-pane')), findsNothing);
    expect(rig.trendCalls, 0);
    expect(rig.suggestionCalls, 0);
  }

  group('geometry: rail | page, no pane in band B', () {
    for (final width in [840.0, 1024.0, 1133.0, 1180.0, 1194.0, 1199.0]) {
      testWidgets('${width.toInt()} dp: the page keeps the whole content', (
        tester,
      ) async {
        final rig = ContextPaneRig();
        await rig.pump(tester, width: width, height: 834);

        final rail = tester.getRect(find.byType(AppNavRail));
        final header = primaryRect(tester);
        expect(rail, Rect.fromLTWH(0, 0, AppSize.railCompact, 834));
        expect(header.left, AppSize.railCompact);
        expect(header.width, width - AppSize.railCompact);
        expect(rail.width + header.width, width);
        expectNoPane(tester, rig);
        final geometry = ShellGeometry.maybeOf(
          tester.element(find.byType(AppTopBar)),
        )!;
        expect(geometry.content, Rect.fromLTWH(80, 0, width - 80, 834));
        expectNoOverflow(tester);
      });
    }

    testWidgets('safe areas (932 x 430, insets 44 / 24 / 30 / 20): the page '
        'ends at the trailing inset', (tester) async {
      final rig = ContextPaneRig();
      await rig.pump(
        tester,
        width: 932,
        height: 430,
        padding: const EdgeInsets.fromLTRB(44, 24, 30, 20),
      );

      // Rail 80 + 44; the page takes 932 - 124 - 30 = 778.
      expect(primaryRect(tester).left, 124);
      expect(primaryRect(tester).width, 778);
      expect(
        tester.getRect(find.byKey(const ValueKey('tablet-trailing-inset'))),
        const Rect.fromLTWH(902, 0, 30, 430),
      );
      expectNoPane(tester, rig);
      expectNoOverflow(tester);
    });

    testWidgets('right-to-left: the rail on the right, the page on the left', (
      tester,
    ) async {
      final rig = ContextPaneRig();
      await rig.pump(tester, textDirection: TextDirection.rtl);

      expect(
        tester.getRect(find.byType(AppNavRail)),
        const Rect.fromLTWH(944, 0, 80, 768),
      );
      expect(primaryRect(tester), const Rect.fromLTWH(0, 0, 944, 53));
      expectNoPane(tester, rig);
    });
  });

  group('bands with ui_shell + ui_tablet on', () {
    for (final width in [600.0, 744.0, 834.0, 839.0, 840.0, 1024.0, 1199.0]) {
      testWidgets('${width.toInt()} dp: no pane, nothing fetched for one; '
          'the page keeps the whole content', (tester) async {
        final rig = ContextPaneRig();
        await rig.pump(tester, width: width, height: 1133);

        expectNoPane(tester, rig);
        expect(primaryRect(tester).width, width - 80);
        expect(find.byType(AppSideColumn), findsNothing);
      });
    }

    for (final width in [1200.0, 1440.0]) {
      testWidgets('desktop (${width.toInt()} dp): no pane, the side column '
          'as before', (tester) async {
        final rig = ContextPaneRig();
        await rig.pump(tester, width: width, height: 900);

        expect(find.byType(AppSideColumn), findsOneWidget);
        Finder inColumn(Finder f) =>
            find.descendant(of: find.byType(AppSideColumn), matching: f);
        expect(inColumn(find.text('You might like')), findsOneWidget);
        expect(inColumn(find.text('Settings')), findsOneWidget);
        expect(inColumn(find.text('Community rules')), findsNothing);
      });
    }

    testWidgets('crossing 839 <-> 840 changes nothing around the page', (
      tester,
    ) async {
      final rig = ContextPaneRig();
      await rig.pump(tester, width: 839);
      expectNoPane(tester, rig);
      expect(primaryRect(tester).width, 759);

      tester.view.physicalSize = const Size(840, 768);
      await tester.pumpAndSettle();
      expectNoPane(tester, rig);
      expect(primaryRect(tester).width, 760);

      tester.view.physicalSize = const Size(839, 768);
      await tester.pumpAndSettle();
      expectNoPane(tester, rig);
      expect(primaryRect(tester).width, 759);
      expectNoOverflow(tester);
    });
  });

  group('flag modes: no flag mode draws a pane', () {
    // Both sides of every boundary, plus a phone and the iPad landscape.
    final widths = {360.0, ...kBoundaryWidths, 1024.0}.toList()..sort();
    final base = {...kContextPaneFlags}
      ..removeAll({kFeatureUiShell, kFeatureUiTablet});
    for (final MapEntry(key: mode, value: modeFlags)
        in kTabletFlagModes.entries) {
      final tablet = modeFlags.length == 2;
      for (final width in widths) {
        final tabletBand =
            width >= AppBreakpoints.mobile && width < AppBreakpoints.tablet;
        testWidgets('$mode at ${width.toInt()} dp: no pane', (tester) async {
          final rig = ContextPaneRig();
          await rig.pump(
            tester,
            width: width,
            height: 900,
            flags: {...base, ...modeFlags},
          );

          // Off the tablet layout the tree around the page is today's: the
          // legacy NavigationRail, the centred 600 dp column.
          if (width < AppBreakpoints.mobile) {
            // Phones: the bar, no rail of either kind, nothing fetched.
            expect(find.byType(AppBottomBar), findsOneWidget);
            expect(find.byType(NavigationRail), findsNothing);
            expect(find.byType(AppNavRail), findsNothing);
            expect(find.byType(AppSideColumn), findsNothing);
            expect(rig.trendCalls, 0);
            expect(rig.suggestionCalls, 0);
          } else if (!(tablet && tabletBand)) {
            expect(find.byType(NavigationRail), findsOneWidget);
            expect(find.byType(AppNavRail), findsNothing);
            if (width < AppBreakpoints.tablet) {
              // No side column below 1200, and nothing fetched for one.
              expect(find.byType(AppSideColumn), findsNothing);
              expect(rig.trendCalls, 0);
              expect(rig.suggestionCalls, 0);
              expect(
                primaryRect(tester).width,
                lessThanOrEqualTo(AppSize.contentMax),
              );
            }
          } else {
            // The tablet layout: the page keeps the whole content.
            expect(primaryRect(tester).width, width - 80);
            expect(rig.trendCalls, 0);
            expect(rig.suggestionCalls, 0);
          }
          expectNoOverflow(tester);
        });
      }
    }
  });

  group('every route: no pane in band B, the page keeps the content', () {
    for (final location in [
      '/home',
      '/bookmarks',
      '/plans/b1/edit',
      '/explore',
      '/notifications',
      '/search',
      '/follow-requests',
      '/profile/alice/followers',
      '/profile/alice',
      '/u/u1',
      '/messages',
      '/plans',
      '/plans/b1',
      '/plans/b1/people',
      '/creator-studio',
    ]) {
      testWidgets('$location: no pane, nothing fetched for one', (
        tester,
      ) async {
        final rig = ContextPaneRig();
        await rig.pump(tester, location: location);

        expectNoPane(tester, rig);
        expect(primaryRect(tester).width, 1024 - 80);
        expectNoOverflow(tester);
      });
    }

    // Settings is list-detail in band B: its list pane (not a context pane)
    // sits before the detail (plan section 3, code LD).
    testWidgets('/settings: no context pane; the Settings list pane instead', (
      tester,
    ) async {
      final rig = ContextPaneRig();
      await rig.pump(tester, location: '/settings');

      expect(find.byType(SettingsCategoriesPane), findsOneWidget);
      final list = ShellGeometry.listPaneWidthFor(1024 - 80);
      expect(primaryRect(tester).width, 1024 - 80 - list - 1);
      expect(rig.trendCalls, 0);
      expect(rig.suggestionCalls, 0);
    });

    testWidgets('navigating keeps the page whole and asks for nothing', (
      tester,
    ) async {
      final rig = ContextPaneRig();
      await rig.pump(tester);
      expectNoPane(tester, rig);

      rig.router.go('/notifications');
      await tester.pumpAndSettle();
      expectNoPane(tester, rig);
      expect(primaryRect(tester).width, 1024 - 80);

      rig.router.go('/settings');
      await tester.pumpAndSettle();
      expect(find.byType(SettingsCategoriesPane), findsOneWidget);
      expect(rig.trendCalls, 0);
      expect(rig.suggestionCalls, 0);
    });
  });

  group('section flags do not bring the pane back', () {
    final modes = <String, Set<String>>{
      'every section flag on': kContextPaneFlags,
      'search off': {...kContextPaneFlags}..remove('search'),
      'trends off': {...kContextPaneFlags}..remove('trends'),
      'graph off': {...kContextPaneFlags}..remove('graph'),
      'follow_suggestions off': {...kContextPaneFlags}
        ..remove('follow_suggestions'),
      'every section flag off': const {kFeatureUiShell, kFeatureUiTablet},
    };
    for (final entry in modes.entries) {
      for (final profile in [true, false]) {
        testWidgets('${entry.key}, ${profile ? 'with' : 'without'} a profile: '
            'no pane, nothing asked', (tester) async {
          final rig = ContextPaneRig();
          await rig.pump(tester, flags: entry.value, profile: profile);

          expectNoPane(tester, rig);
        });
      }
    }
  });
}
