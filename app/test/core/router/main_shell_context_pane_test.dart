import 'package:dzeroth/core/feature_flags/ui_shell_feature_flag.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/core/widgets/app_bottom_bar.dart';
import 'package:dzeroth/core/widgets/app_nav_rail.dart';
import 'package:dzeroth/core/widgets/app_top_bar.dart';
import 'package:dzeroth/core/widgets/context_pane.dart';
import 'package:dzeroth/core/widgets/shell_geometry.dart';
import 'package:dzeroth/features/graph/presentation/widgets/user_list_row.dart';
import 'package:dzeroth/features/graph/presentation/widgets/who_to_follow_card.dart';
import 'package:dzeroth/features/search/data/search_repository.dart';
import 'package:dzeroth/features/search/presentation/widgets/app_search_field.dart';
import 'package:dzeroth/features/search/presentation/widgets/whats_happening_card.dart';
import 'package:dzeroth/gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import 'package:dzeroth/shared/widgets/primitives/app_side_column.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/context_pane_rig.dart';
import '../../support/fake_search_repository.dart';
import '../../support/geometry.dart';
import '../../support/search_field_rig.dart';
import '../../support/suggestions_fixtures.dart';
import '../../support/theme_harness.dart';

/// A suggestions repository whose call failed. The real one never throws
/// to the cubit: a failure (a limit, an error, FEATURE_DISABLED) is an empty
/// answer, and the card never explains itself.
class _FailedSuggestions extends FakeSuggestionsRepository {
  _FailedSuggestions() : super(const []);

  @override
  Future<List<graph.UserListItem>> suggestionsFor(String uid) async {
    calls++;
    return const [];
  }
}

/// Tablet plan T3: band B's context pane in the real `MainShell` (section 3
/// code P, section 4.1 per-route lists, section 5.1 `contextSectionsFor`).
void main() {
  /// The sections the pane shows, top to bottom.
  List<String> paneOrder(WidgetTester tester) {
    final found = <(double, String)>[];
    void add(Finder f, String name) {
      final inPane = inContextPane(f);
      if (inPane.evaluate().isNotEmpty &&
          tester.getSize(inPane.first).height > 0) {
        found.add((tester.getTopLeft(inPane.first).dy, name));
      }
    }

    add(find.byType(AppSearchField), 'search');
    add(find.byType(AppSideProfileCard), 'profile');
    add(find.text("What's happening"), 'trends');
    add(find.text('Who to follow'), 'Who to follow');
    add(find.text('You might like'), 'You might like');
    add(find.byType(AppSideLinks), 'links');
    found.sort((a, b) => a.$1.compareTo(b.$1));
    return [for (final f in found) f.$2];
  }

  /// The primary pane's header (the stub page's top bar spans the pane).
  Rect primaryRect(WidgetTester tester) =>
      tester.getRect(find.byType(AppTopBar));

  group('geometry: primary | 1 dp hairline | pane (plan section 3)', () {
    // W -> (primary, pane), the plan's check table.
    final table = <double, (double, double)>{
      840: (439, 320),
      1024: (623, 320),
      1133: (680, 372),
      1180: (680, 419),
      1194: (680, 433),
      1199: (680, 438),
    };
    for (final MapEntry(key: width, value: (primary, pane)) in table.entries) {
      testWidgets('${width.toInt()} dp: ${primary.toInt()} / '
          '${pane.toInt()}, no dead strip', (tester) async {
        final rig = ContextPaneRig();
        await rig.pump(tester, width: width, height: 834);

        final rail = tester.getRect(find.byType(AppNavRail));
        final header = primaryRect(tester);
        final paneRect = tester.getRect(findContextPane());
        expect(rail, Rect.fromLTWH(0, 0, AppSize.railCompact, 834));
        expect(header.left, AppSize.railCompact);
        expect(header.width, primary);
        // The hairline is the 1 dp between the two panes.
        expect(paneRect.left, header.right + 1);
        expect(paneRect, Rect.fromLTWH(80 + primary + 1, 0, pane, 834));
        expect(rail.width + header.width + 1 + paneRect.width, width);
        // Dialogs and snack bars still centre on both panes together.
        final geometry = ShellGeometry.maybeOf(
          tester.element(find.byType(AppTopBar)),
        )!;
        expect(geometry.content, Rect.fromLTWH(80, 0, width - 80, 834));
        expectNoOverflow(tester);
      });
    }

    testWidgets('the hairline is the theme hairline on the pane\'s start '
        'edge, light and dark', (tester) async {
      for (final brightness in Brightness.values) {
        final rig = ContextPaneRig();
        await rig.pump(tester, brightness: brightness);
        final box = tester.widget<DecoratedBox>(
          find
              .descendant(
                of: find.byKey(const ValueKey('tablet-context-pane')),
                matching: find.byType(DecoratedBox),
              )
              .first,
        );
        final border =
            (box.decoration as BoxDecoration).border! as BorderDirectional;
        final theme = buildAppTheme(brightness: brightness);
        expect(border.start.color, theme.extension<AppColors>()!.hairline);
        expect(border.start.width, 1);
        expect(border.end, BorderSide.none);
      }
    });

    testWidgets('safe areas (932 x 430, insets 44 / 24 / 30 / 20): the pane '
        'ends at the trailing inset and pads its content by the top and '
        'bottom ones', (tester) async {
      final rig = ContextPaneRig();
      await rig.pump(
        tester,
        width: 932,
        height: 430,
        padding: const EdgeInsets.fromLTRB(44, 24, 30, 20),
      );

      // Rail 80 + 44; C = 932 - 124 - 30 = 778; pane 320; primary 457.
      final paneRect = tester.getRect(findContextPane());
      expect(paneRect, const Rect.fromLTWH(124 + 457 + 1, 0, 320, 430));
      expect(primaryRect(tester).left, 124);
      expect(primaryRect(tester).width, 457);
      expect(
        tester.getRect(find.byKey(const ValueKey('tablet-trailing-inset'))),
        const Rect.fromLTWH(902, 0, 30, 430),
      );
      // The first section sits below the top inset (+16).
      expect(
        tester.getTopLeft(inContextPane(find.byType(AppSearchField))).dy,
        24 + AppSpacing.md,
      );
      // The pane got no side insets of its own.
      final media = MediaQuery.of(
        tester.element(inContextPane(find.byType(AppSideLinks))),
      );
      expect(media.padding.left, 0);
      expect(media.padding.right, 0);
      expectNoOverflow(tester);
    });

    testWidgets('right-to-left: the rail on the right, the pane on the left', (
      tester,
    ) async {
      final rig = ContextPaneRig();
      await rig.pump(tester, textDirection: TextDirection.rtl);

      expect(
        tester.getRect(find.byType(AppNavRail)),
        const Rect.fromLTWH(944, 0, 80, 768),
      );
      expect(
        tester.getRect(findContextPane()),
        const Rect.fromLTWH(0, 0, 320, 768),
      );
      expect(primaryRect(tester), const Rect.fromLTWH(321, 0, 623, 53));
    });
  });

  group('bands with ui_shell + ui_tablet on', () {
    for (final width in [600.0, 744.0, 834.0, 839.0]) {
      testWidgets('band A (${width.toInt()} dp): no pane, nothing fetched for '
          'one; the page keeps the whole content', (tester) async {
        final rig = ContextPaneRig();
        await rig.pump(tester, width: width, height: 1133);

        expect(findContextPane(), findsNothing);
        expect(primaryRect(tester).width, width - 80);
        expect(rig.trendCalls, 0);
        expect(rig.suggestionCalls, 0);
        final scope = tester.widget<ContextPaneScope>(
          find.byType(ContextPaneScope),
        );
        expect(scope.shown, isEmpty);
      });
    }

    for (final width in [840.0, 1024.0, 1199.0]) {
      testWidgets('band B (${width.toInt()} dp): the pane, its sections '
          'published to the page', (tester) async {
        final rig = ContextPaneRig();
        await rig.pump(tester, width: width);

        expect(findContextPane(), findsOneWidget);
        expect(rig.trendCalls, 1);
        expect(rig.suggestionCalls, 1);
        expect(
          tester.widget<ContextPaneScope>(find.byType(ContextPaneScope)).shown,
          {
            ContextSectionKind.search,
            ContextSectionKind.profile,
            ContextSectionKind.trends,
            ContextSectionKind.whoToFollow,
            ContextSectionKind.links,
          },
        );
      });
    }

    for (final width in [1200.0, 1440.0]) {
      testWidgets('desktop (${width.toInt()} dp): no pane, the side column '
          'as before', (tester) async {
        final rig = ContextPaneRig();
        await rig.pump(tester, width: width, height: 900);

        expect(findContextPane(), findsNothing);
        expect(find.byType(ContextPaneScope), findsNothing);
        expect(find.byType(AppSideColumn), findsOneWidget);
        Finder inColumn(Finder f) =>
            find.descendant(of: find.byType(AppSideColumn), matching: f);
        expect(inColumn(find.text('You might like')), findsOneWidget);
        expect(inColumn(find.text('Settings')), findsOneWidget);
        expect(inColumn(find.text('Community rules')), findsNothing);
      });
    }

    testWidgets('crossing 839 <-> 840 adds and removes the pane live', (
      tester,
    ) async {
      final rig = ContextPaneRig();
      await rig.pump(tester, width: 839);
      expect(findContextPane(), findsNothing);

      tester.view.physicalSize = const Size(840, 768);
      await tester.pumpAndSettle();
      expect(findContextPane(), findsOneWidget);
      expect(primaryRect(tester).width, 439);

      tester.view.physicalSize = const Size(839, 768);
      await tester.pumpAndSettle();
      expect(findContextPane(), findsNothing);
      expect(primaryRect(tester).width, 759);
      expectNoOverflow(tester);
    });
  });

  group('flag modes: only ui_shell + ui_tablet draws a pane', () {
    // Both sides of every boundary, plus a phone and the iPad landscape.
    final widths = {360.0, ...kBoundaryWidths, 1024.0}.toList()..sort();
    final base = {...kContextPaneFlags}
      ..removeAll({kFeatureUiShell, kFeatureUiTablet});
    for (final MapEntry(key: mode, value: modeFlags)
        in kTabletFlagModes.entries) {
      final tablet = modeFlags.length == 2;
      for (final width in widths) {
        final bandB =
            width >= AppBreakpoints.expanded && width < AppBreakpoints.tablet;
        final tabletBand =
            width >= AppBreakpoints.mobile && width < AppBreakpoints.tablet;
        testWidgets('$mode at ${width.toInt()} dp: '
            '${tablet && bandB ? 'pane' : 'no pane'}', (tester) async {
          final rig = ContextPaneRig();
          await rig.pump(
            tester,
            width: width,
            height: 900,
            flags: {...base, ...modeFlags},
          );

          expect(
            findContextPane(),
            tablet && bandB ? findsOneWidget : findsNothing,
          );
          // Off the tablet layout the tree around the page is today's: no
          // scope, the legacy NavigationRail, the centred 600 dp column.
          expect(
            find.byType(ContextPaneScope),
            tablet && tabletBand ? findsOneWidget : findsNothing,
          );
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
          }
          expectNoOverflow(tester);
        });
      }
    }
  });

  group('sections per route family (plan section 4.1)', () {
    const global = ['search', 'profile', 'trends', 'Who to follow', 'links'];
    const cases = <String, List<String>>{
      '/home': global,
      '/bookmarks': global,
      '/plans/b1/edit': global,
      '/explore': ['Who to follow', 'links'],
      '/notifications': ['trends', 'links'],
      '/search': ['trends', 'links'],
      '/follow-requests': ['Who to follow', 'links'],
      '/profile/alice/followers': ['Who to follow', 'links'],
      '/profile/alice': ['You might like', 'links'],
      '/u/u1': ['You might like', 'links'],
    };
    for (final MapEntry(key: location, value: order) in cases.entries) {
      testWidgets('$location: ${order.join(', ')}', (tester) async {
        final rig = ContextPaneRig();
        await rig.pump(tester, location: location);

        expect(paneOrder(tester), order);
        // Each section appears once, in the pane only (the stub page has
        // none of its own).
        expect(
          find.byType(WhoToFollowCard),
          order.any((s) => s == 'Who to follow' || s == 'You might like')
              ? findsOneWidget
              : findsNothing,
        );
        expectNoOverflow(tester);
      });
    }

    for (final location in [
      '/settings',
      '/messages',
      '/plans',
      '/plans/b1',
      '/plans/b1/people',
      '/creator-studio',
    ]) {
      testWidgets('$location: no pane (list-detail later, or F in band B); '
          'the page keeps the whole content', (tester) async {
        final rig = ContextPaneRig();
        await rig.pump(tester, location: location);

        expect(findContextPane(), findsNothing);
        expect(primaryRect(tester).width, 1024 - 80);
        expect(rig.trendCalls, 0);
        expect(rig.suggestionCalls, 0);
      });
    }

    testWidgets('navigating swaps the sections; the pane stays', (
      tester,
    ) async {
      final rig = ContextPaneRig();
      await rig.pump(tester);
      expect(paneOrder(tester), global);

      rig.router.go('/notifications');
      await tester.pumpAndSettle();
      expect(paneOrder(tester), ['trends', 'links']);

      rig.router.go('/settings');
      await tester.pumpAndSettle();
      expect(findContextPane(), findsNothing);
      // The list is shared: no second call for any of it.
      expect(rig.trendCalls, 1);
      expect(rig.suggestionCalls, 1);
    });

    testWidgets('the footer is Privacy Policy and Community rules; Settings '
        'stays in the account menu', (tester) async {
      final rig = ContextPaneRig();
      await rig.pump(tester);

      expect(inContextPane(find.text('Privacy Policy')), findsOneWidget);
      expect(inContextPane(find.text('Community rules')), findsOneWidget);
      expect(inContextPane(find.text('Settings')), findsNothing);
      for (final text in ['Terms', 'Help']) {
        expect(find.textContaining(text), findsNothing, reason: text);
      }
    });

    testWidgets('the profile card opens the own profile', (tester) async {
      final rig = ContextPaneRig();
      await rig.pump(tester);

      await tester.tap(inContextPane(find.byType(AppSideProfileCard)));
      await tester.pumpAndSettle();
      expect(find.text('/profile/alice body'), findsOneWidget);
      expect(paneOrder(tester), ['You might like', 'links']);
    });

    testWidgets('What\'s happening: a trend opens its search, Show more '
        'opens Explore', (tester) async {
      final rig = ContextPaneRig();
      await rig.pump(tester);

      expect(
        find.descendant(
          of: inContextPane(find.byType(WhatsHappeningCard)),
          matching: find.textContaining('#tag'),
        ),
        findsNWidgets(kWhatsHappeningRows),
      );
      await tester.tap(inContextPane(find.textContaining('#tag1')).first);
      await tester.pumpAndSettle();
      expect(find.text('/search body'), findsOneWidget);

      rig.router.go('/home');
      await tester.pumpAndSettle();
      await tester.tap(inContextPane(find.text('Show more')).first);
      await tester.pumpAndSettle();
      expect(find.text('/explore body'), findsOneWidget);
    });
  });

  group('each section is gated like its phone counterpart', () {
    testWidgets('search off: no search pill and no trends, nothing asked', (
      tester,
    ) async {
      final rig = ContextPaneRig();
      await rig.pump(tester, flags: {...kContextPaneFlags}..remove('search'));

      expect(paneOrder(tester), ['profile', 'Who to follow', 'links']);
      expect(rig.trendCalls, 0);
    });

    testWidgets('trends off: the pill stays, What\'s happening goes, '
        'nothing asked', (tester) async {
      final rig = ContextPaneRig();
      await rig.pump(tester, flags: {...kContextPaneFlags}..remove('trends'));

      expect(paneOrder(tester), [
        'search',
        'profile',
        'Who to follow',
        'links',
      ]);
      expect(rig.trendCalls, 0);
    });

    for (final missing in ['graph', 'follow_suggestions']) {
      testWidgets('$missing off: no Who to follow, nothing asked, and the '
          'page is not told it is in the pane', (tester) async {
        final rig = ContextPaneRig();
        await rig.pump(tester, flags: {...kContextPaneFlags}..remove(missing));

        expect(paneOrder(tester), ['search', 'profile', 'trends', 'links']);
        expect(rig.suggestionCalls, 0);
        expect(
          tester.widget<ContextPaneScope>(find.byType(ContextPaneScope)).shown,
          isNot(contains(ContextSectionKind.whoToFollow)),
        );
      });
    }

    testWidgets('every section flag off: the pane keeps its footer', (
      tester,
    ) async {
      final rig = ContextPaneRig();
      await rig.pump(tester, flags: const {kFeatureUiShell, kFeatureUiTablet});

      expect(paneOrder(tester), ['profile', 'links']);
      expect(rig.trendCalls, 0);
      expect(rig.suggestionCalls, 0);
    });

    testWidgets('no loaded profile: no profile card (nothing fetched) and no '
        'Who to follow (no viewer)', (tester) async {
      final rig = ContextPaneRig();
      await rig.pump(tester, profile: false);

      expect(paneOrder(tester), ['search', 'trends', 'links']);
      expect(rig.suggestionCalls, 0);
    });
  });

  group('empty and error states', () {
    testWidgets('trends empty: no card and no gap', (tester) async {
      final rig = ContextPaneRig(
        search: FakeSearchRepository()..trendsResult = const TrendsResult(),
      );
      await rig.pump(tester);

      expect(paneOrder(tester), [
        'search',
        'profile',
        'Who to follow',
        'links',
      ]);
      expect(
        tester.getSize(inContextPane(find.byType(WhatsHappeningCard))).height,
        0,
      );
      // The profile card's gap is the only one above Who to follow.
      expect(
        tester.getTopLeft(inContextPane(find.text('Who to follow'))).dy -
            tester
                .getBottomLeft(inContextPane(find.byType(AppSideProfileCard)))
                .dy,
        greaterThan(AppSpacing.md),
      );
    });

    testWidgets('trends unavailable: no card', (tester) async {
      final rig = ContextPaneRig(
        search: FakeSearchRepository()
          ..error = const SearchUnavailableException('trends'),
      );
      await rig.pump(tester);

      expect(paneOrder(tester), [
        'search',
        'profile',
        'Who to follow',
        'links',
      ]);
    });

    testWidgets('trends failed: the notice with a 48 dp Retry that asks '
        'again', (tester) async {
      final search = FakeSearchRepository()..error = Exception('boom');
      final rig = ContextPaneRig(search: search);
      await rig.pump(tester);

      expect(
        inContextPane(find.text("Trends couldn't be loaded right now.")),
        findsOneWidget,
      );
      expect(paneOrder(tester), contains('trends'));
      final retry = inContextPane(find.widgetWithText(TextButton, 'Retry'));
      expectMinTarget(tester, retry);
      expect(rig.trendCalls, 1);

      search.error = null;
      search.trendsResult = TrendsResult(
        trends: [searchTrend('tag1', 100, 1)],
        computedAt: DateTime.now(),
      );
      await tester.tap(retry);
      await tester.pumpAndSettle();
      expect(rig.trendCalls, 2);
      expect(inContextPane(find.textContaining('#tag1')), findsOneWidget);
    });

    testWidgets('Who to follow empty: no card and no gap', (tester) async {
      final rig = ContextPaneRig(suggestions: FakeSuggestionsRepository([]));
      await rig.pump(tester);

      expect(paneOrder(tester), ['search', 'profile', 'trends', 'links']);
      expect(
        tester.getSize(inContextPane(find.byType(WhoToFollowCard))).height,
        0,
      );
    });

    testWidgets('Who to follow failed: no card, asked once, no retry loop', (
      tester,
    ) async {
      final failed = _FailedSuggestions();
      final rig = ContextPaneRig(suggestions: failed);
      await rig.pump(tester);
      await tester.pumpAndSettle();

      expect(paneOrder(tester), ['search', 'profile', 'trends', 'links']);
      expect(failed.calls, 1);
    });

    testWidgets('everything empty: the footer right under the top padding', (
      tester,
    ) async {
      final rig = ContextPaneRig(
        search: FakeSearchRepository()..trendsResult = const TrendsResult(),
        suggestions: FakeSuggestionsRepository([]),
      );
      await rig.pump(
        tester,
        profile: false,
        flags: {...kContextPaneFlags}..remove('search'),
      );

      expect(paneOrder(tester), ['links']);
      expect(
        tester.getTopLeft(inContextPane(find.byType(AppSideLinks))).dy,
        AppSpacing.md,
      );
    });
  });

  group('focus order (plan section 2.1): rail, primary, then the pane', () {
    for (final direction in TextDirection.values) {
      testWidgets('${direction.name}: Tab and Shift+Tab', (tester) async {
        final rig = ContextPaneRig();
        // Without the search field, the pane's first stop is the profile
        // card.
        await rig.pump(
          tester,
          textDirection: direction,
          flags: {...kContextPaneFlags}..remove('search'),
        );
        bool focused(Finder f) => Focus.of(tester.element(f)).hasPrimaryFocus;
        final railHome = find.descendant(
          of: find.byType(AppNavRail),
          matching: find.byIcon(Icons.home),
        );
        final primary = find.text('Primary action');
        final card = inContextPane(find.text('@alice'));

        // The page's route scope holds the focus at first, so the walk
        // starts on the rail's one Tab stop (the selected item).
        Focus.of(tester.element(railHome)).requestFocus();
        await tester.pump();
        expect(focused(railHome), isTrue, reason: 'rail');
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        expect(focused(primary), isTrue, reason: 'then the primary pane');
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        expect(focused(card), isTrue, reason: 'then the context pane');

        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        expect(focused(primary), isTrue, reason: 'Shift+Tab back');
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        expect(focused(railHome), isTrue, reason: 'and to the rail');
      });
    }
  });

  group('the search pill panel inside the pane', () {
    for (final frame in const [Size(840, 1194), Size(932, 430)]) {
      for (final scale in kTabletTextScales) {
        testWidgets('${frame.width.toInt()} x ${frame.height.toInt()} '
            'x$scale: typing opens the suggestions inside the window', (
          tester,
        ) async {
          final rig = ContextPaneRig();
          await rig.pump(
            tester,
            width: frame.width,
            height: frame.height,
            textScale: scale,
          );
          final field = inContextPane(find.byType(TextField));
          await tester.tap(field);
          await tester.pump();
          await tester.enterText(field, 'tag');
          await tester.pump(const Duration(milliseconds: 600));
          await tester.pumpAndSettle();

          final panel = find.byWidgetPredicate(
            (w) => w is Semantics && w.properties.label == 'Search suggestions',
          );
          expect(panel, findsOneWidget);
          final rect = tester.getRect(panel);
          final window = Offset.zero & frame;
          expect(rect.left, greaterThanOrEqualTo(window.left));
          expect(rect.right, lessThanOrEqualTo(window.right));
          expect(rect.top, greaterThanOrEqualTo(window.top));
          expect(rect.bottom, lessThanOrEqualTo(window.bottom + 0.5));
          // Anchored under the pill, in the pane's column.
          final pill = tester.getRect(
            inContextPane(find.byType(AppSearchField)),
          );
          expect(rect.left, closeTo(pill.left, 1));
          expect(rig.search.calls, contains('trends:tag'));
          expectNoOverflow(tester);
        });
      }
    }
  });

  group('text scale 2.0 (plan section 5.5)', () {
    // Band B portrait and landscape frames, and a phone in landscape (R3).
    final frames = <Size>[
      const Size(840, 1194),
      const Size(1024, 1366),
      const Size(1024, 768),
      const Size(1199, 834),
      const Size(932, 430),
    ];
    for (final brightness in Brightness.values) {
      for (final frame in frames) {
        for (final scale in kTabletTextScales) {
          testWidgets('${frame.width.toInt()} x ${frame.height.toInt()} '
              '${brightness.name} x$scale: every section fits the pane, '
              '48 dp targets', (tester) async {
            final rig = ContextPaneRig();
            await rig.pump(
              tester,
              width: frame.width,
              height: frame.height,
              brightness: brightness,
              textScale: scale,
            );

            expectNoOverflow(tester);
            final pane = tester.getRect(findContextPane());
            final c = frame.width - AppSize.railCompact;
            expect(pane.width, ShellGeometry.contextPaneWidthFor(c));
            expect(paneOrder(tester), [
              'search',
              'profile',
              'trends',
              'Who to follow',
              'links',
            ]);
            for (final type in [
              AppSearchField,
              AppSideProfileCard,
              WhatsHappeningCard,
              WhoToFollowCard,
              AppSideLinks,
            ]) {
              final rect = tester.getRect(inContextPane(find.byType(type)));
              expect(
                rect.left,
                greaterThanOrEqualTo(pane.left),
                reason: '$type',
              );
              expect(
                rect.right,
                lessThanOrEqualTo(pane.right + 0.5),
                reason: '$type',
              );
            }
            // No text in the pane is clipped to fewer lines than it needs.
            for (final element in inContextPane(
              find.byType(RichText),
            ).evaluate()) {
              final paragraph = element.renderObject! as RenderParagraph;
              if (paragraph.maxLines == null) {
                expect(
                  paragraph.didExceedMaxLines,
                  isFalse,
                  reason: paragraph.text.toPlainText(),
                );
              }
            }
            expectMinTarget(
              tester,
              inContextPane(find.byType(AppSideProfileCard)),
            );
            for (final label in ['Privacy Policy', 'Community rules']) {
              expectMinTarget(
                tester,
                find.ancestor(
                  of: inContextPane(find.text(label)),
                  matching: find.byType(ListTile),
                ),
                reason: label,
              );
            }
            for (var i = 1; i <= kWhoToFollowCollapsedRows; i++) {
              expectMinTarget(
                tester,
                inContextPane(find.byTooltip('Dismiss @user$i')),
                reason: 'Dismiss @user$i',
              );
            }
            // The pane scrolls to its end without overflow, and Show more
            // opens all five rows there.
            await tester.scrollUntilVisible(
              inContextPane(find.byType(AppSideLinks)),
              200,
              scrollable: inContextPane(find.byType(Scrollable)).first,
            );
            final showMore = find.descendant(
              of: inContextPane(find.byType(WhoToFollowCard)),
              matching: find.widgetWithText(TextButton, 'Show more'),
            );
            await tester.ensureVisible(showMore);
            await tester.pumpAndSettle();
            expectMinTarget(tester, showMore, reason: 'Show more');
            await tester.tap(showMore);
            await tester.pumpAndSettle();
            expect(inContextPane(find.byType(UserListRow)), findsNWidgets(5));
            expectNoOverflow(tester);
          });
        }
      }
    }
  });
}
