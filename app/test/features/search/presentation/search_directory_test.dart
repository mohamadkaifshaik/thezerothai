import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/communities/presentation/widgets/community_row.dart';
import 'package:dzeroth/features/lists/presentation/widgets/list_follow_button.dart';
import 'package:dzeroth/features/lists/presentation/widgets/list_row.dart';
import 'package:dzeroth/features/search/data/search_repository.dart';
import 'package:dzeroth/features/search/domain/search_results_tab.dart';
import 'package:dzeroth/features/search/presentation/widgets/search_directory_tabs.dart';
import 'package:dzeroth/shared/widgets/post/post_card.dart';
import 'package:dzeroth/shared/widgets/primitives/app_chip.dart';
import 'package:dzeroth/shared/widgets/primitives/app_pill_button.dart';
import 'package:dzeroth/shared/widgets/primitives/app_tab_bar.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/posts_fixtures.dart';
import '../../../support/search_directory_rig.dart';

Finder _tabLabel(String label) =>
    find.descendant(of: find.byType(AppTabBar), matching: find.text(label));

Finder _pill(String label) => find.widgetWithText(AppFilterPill, label);

void main() {
  late SearchDirectoryRig rig;

  setUpAll(() {
    registerFallbackValue(searchList('x'));
  });

  setUp(() {
    rig = SearchDirectoryRig();
    rig.search.postsResult = SearchPostsPage(
      posts: [postView(1, text: 'tagged')],
      normalizedTag: 'coffee',
    );
  });

  group('flags', () {
    testWidgets('off: no Lists, Communities tabs or filter', (tester) async {
      await rig.pump(tester, flags: const {'search', 'posts'});
      expect(_tabLabel('Lists'), findsNothing);
      expect(_tabLabel('Communities'), findsNothing);
      await rig.tapTab(tester, 'Latest');
      expect(_pill(kSearchFromFollowingLabel), findsNothing);
      expect(rig.search.postsFromFollowing, everyElement(isFalse));
    });

    testWidgets('lists and communities flags gate each tab', (tester) async {
      await rig.pump(tester, flags: const {'search', 'search_lists', 'lists'});
      expect(_tabLabel('Lists'), findsOneWidget);
      expect(_tabLabel('Communities'), findsNothing);
    });

    testWidgets('search_lists off hides both even with lists on', (
      tester,
    ) async {
      await rig.pump(
        tester,
        flags: const {'search', 'lists', 'communities', 'posts'},
      );
      expect(_tabLabel('Lists'), findsNothing);
      expect(_tabLabel('Communities'), findsNothing);
    });

    testWidgets('a link to a tab whose flag is off opens Top', (tester) async {
      await rig.pump(
        tester,
        tab: SearchResultsTab.lists,
        flags: const {'search', 'posts'},
      );
      expect(rig.search.calls.any((c) => c.startsWith('lists:')), isFalse);
      expect(rig.search.calls, contains('posts:#coffee:SEARCH_TAB_TOP'));
    });

    testWidgets('on: both tabs, none asked until opened', (tester) async {
      await rig.pump(tester);
      expect(_tabLabel('Lists'), findsOneWidget);
      expect(_tabLabel('Communities'), findsOneWidget);
      expect(
        rig.search.calls.where(
          (c) => c.startsWith('lists:') || c.startsWith('communities:'),
        ),
        isEmpty,
      );
    });
  });

  group('Lists tab', () {
    testWidgets('rows, Follow beside a public list of someone else', (
      tester,
    ) async {
      rig.search.listsResult = SearchListsPage(
        lists: [
          searchList('L1'),
          searchList('L2', owner: 'u-me', name: 'Mine'),
        ],
      );
      await rig.pump(tester, tab: SearchResultsTab.lists);
      expect(rig.search.calls, contains('lists:coffee'));
      expect(find.byType(ListRow), findsNWidgets(2));
      expect(find.byType(ListFollowButton), findsOneWidget);
    });

    testWidgets('no Follow without list_follows', (tester) async {
      rig.search.listsResult = SearchListsPage(lists: [searchList('L1')]);
      await rig.pump(
        tester,
        tab: SearchResultsTab.lists,
        flags: const {'search', 'lists', 'search_lists'},
      );
      expect(find.byType(ListRow), findsOneWidget);
      expect(find.byType(ListFollowButton), findsNothing);
    });

    testWidgets('Follow toggles through ListService; a row opens the list', (
      tester,
    ) async {
      rig.search.listsResult = SearchListsPage(lists: [searchList('L1')]);
      when(
        () => rig.lists.followList(
          idempotencyKey: any(named: 'idempotencyKey'),
          listId: any(named: 'listId'),
        ),
      ).thenAnswer((_) async => searchList('L1', following: true));
      await rig.pump(tester, tab: SearchResultsTab.lists);
      await tester.tap(find.widgetWithText(AppPillButton, 'Follow'));
      await tester.pumpAndSettle();
      verify(
        () => rig.lists.followList(
          idempotencyKey: any(named: 'idempotencyKey'),
          listId: 'L1',
        ),
      ).called(1);
      expect(find.widgetWithText(AppPillButton, 'Following'), findsOneWidget);
      await tester.tap(find.text('Coffee lovers'));
      await tester.pumpAndSettle();
      expect(find.text('list page L1'), findsOneWidget);
    });

    testWidgets('an empty page with a token is followed; paging goes on', (
      tester,
    ) async {
      rig.search.listsHandler = (q, token) => switch (token) {
        null => const SearchListsPage(nextPageToken: 't1'),
        't1' => SearchListsPage(lists: [searchList('L1')], nextPageToken: 't2'),
        _ => SearchListsPage(lists: [searchList('L2')]),
      };
      await rig.pump(tester, tab: SearchResultsTab.lists);
      expect(find.byType(ListRow), findsNWidgets(2));
      expect(rig.search.calls.where((c) => c == 'lists:coffee'), hasLength(3));
    });

    testWidgets('many empty pages with tokens never stall the tail', (
      tester,
    ) async {
      var n = 0;
      rig.search.listsHandler = (q, token) {
        n++;
        // 7 empty server pages, then one row: more than one client page
        // follows (5), so the tail has to ask again by itself.
        return n < 8
            ? SearchListsPage(nextPageToken: 't$n')
            : SearchListsPage(lists: [searchList('L1')]);
      };
      await rig.pump(tester, tab: SearchResultsTab.lists);
      expect(find.byType(ListRow), findsOneWidget);
      expect(n, 8);
    });

    testWidgets('empty', (tester) async {
      await rig.pump(tester, tab: SearchResultsTab.lists);
      expect(find.text('No Lists found for "coffee"'), findsOneWidget);
    });

    testWidgets('error: Try again asks again', (tester) async {
      rig.search.error = const NetworkException('offline');
      await rig.pump(tester, tab: SearchResultsTab.lists);
      expect(find.byType(ListRow), findsNothing);
      rig.search.error = null;
      rig.search.listsResult = SearchListsPage(lists: [searchList('L1')]);
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.byType(ListRow), findsOneWidget);
    });

    testWidgets('a 31-character query sends nothing', (tester) async {
      await rig.pump(tester, query: 'a' * 31, tab: SearchResultsTab.lists);
      expect(rig.search.calls.any((c) => c.startsWith('lists:')), isFalse);
      expect(find.text("That search isn't valid"), findsOneWidget);
    });
  });

  group('Communities tab', () {
    testWidgets('rows open the community', (tester) async {
      rig.search.communitiesResult = SearchCommunitiesPage(
        communities: [searchCommunity('c1')],
      );
      await rig.pump(tester, tab: SearchResultsTab.communities);
      expect(rig.search.calls, contains('communities:coffee'));
      expect(find.byType(CommunityRow), findsOneWidget);
      expect(find.text('412 members'), findsOneWidget);
      await tester.tap(find.text('Coffee club'));
      await tester.pumpAndSettle();
      expect(find.text('community page c1'), findsOneWidget);
    });

    testWidgets('paging follows the token', (tester) async {
      rig.search.communitiesHandler = (q, token) => token == null
          ? SearchCommunitiesPage(
              communities: [searchCommunity('c1')],
              nextPageToken: 't',
            )
          : SearchCommunitiesPage(
              communities: [searchCommunity('c2', name: 'Cafe crew')],
            );
      await rig.pump(tester, tab: SearchResultsTab.communities);
      expect(find.byType(CommunityRow), findsNWidgets(2));
    });

    testWidgets('empty', (tester) async {
      await rig.pump(tester, tab: SearchResultsTab.communities);
      expect(find.text('No Communities found for "coffee"'), findsOneWidget);
    });

    testWidgets('error shows retry', (tester) async {
      rig.search.error = const NetworkException('offline');
      await rig.pump(tester, tab: SearchResultsTab.communities);
      expect(find.text('Retry'), findsOneWidget);
    });
  });

  group('People you follow filter', () {
    testWidgets('changes the request, resets paging, survives tab changes', (
      tester,
    ) async {
      rig.search.postsHandler = (q, tab, token) => SearchPostsPage(
        posts: [postView(token == null ? 1 : 2, text: 'tagged')],
        nextPageToken: token == null && tab == SearchTab.SEARCH_TAB_LATEST
            ? 'next'
            : null,
        normalizedTag: 'coffee',
      );
      await rig.pump(tester, tab: SearchResultsTab.latest);
      expect(_pill(kSearchFromFollowingLabel), findsOneWidget);
      expect(rig.search.postsFromFollowing.last, isFalse);

      await tester.tap(_pill(kSearchFromFollowingLabel));
      await tester.pumpAndSettle();
      // Page 1 again (no token), filtered.
      expect(rig.search.postsFromFollowing.last, isTrue);
      final afterToggle = rig.search.calls.length;

      // Media was never opened: it asks once, already filtered.
      await rig.tapTab(tester, 'Media');
      expect(rig.search.calls.length, afterToggle + 1);
      expect(rig.search.calls.last, 'posts:#coffee:SEARCH_TAB_MEDIA');
      expect(rig.search.postsFromFollowing.last, isTrue);

      // Back on Latest: nothing re-asked, the choice is still on.
      await rig.tapTab(tester, 'Latest');
      expect(rig.search.calls.length, afterToggle + 1);
      expect(
        tester.widget<AppFilterPill>(_pill(kSearchFromFollowingLabel)).selected,
        isTrue,
      );

      // Off on Media re-asks Media; Latest follows when it returns.
      await rig.tapTab(tester, 'Media');
      await tester.tap(_pill(kSearchFromAnyoneLabel));
      await tester.pumpAndSettle();
      expect(rig.search.postsFromFollowing.last, isFalse);
      await rig.tapTab(tester, 'Latest');
      expect(rig.search.postsFromFollowing.last, isFalse);
    });

    for (final (name, error) in <(String, Object)>[
      ('rate limited', const SearchRateLimitedException()),
      ('feature off', const SearchUnavailableException('search_filters')),
      ('offline', const NetworkException('offline')),
    ]) {
      testWidgets('the filter stays to turn off when the answer is $name', (
        tester,
      ) async {
        await rig.pump(tester, tab: SearchResultsTab.latest);
        rig.search.error = error;
        await tester.tap(_pill(kSearchFromFollowingLabel));
        await tester.pumpAndSettle();
        expect(find.byType(PostCard), findsNothing);
        expect(_pill(kSearchFromFollowingLabel), findsOneWidget);
        rig.search.error = null;
        await tester.tap(_pill(kSearchFromAnyoneLabel));
        await tester.pumpAndSettle();
        expect(find.byType(PostCard), findsOneWidget);
        expect(rig.search.postsFromFollowing.last, isFalse);
      });
    }

    testWidgets('no posts from people you follow: the filter stays', (
      tester,
    ) async {
      await rig.pump(tester, tab: SearchResultsTab.latest);
      rig.search.postsResult = const SearchPostsPage();
      await tester.tap(_pill(kSearchFromFollowingLabel));
      await tester.pumpAndSettle();
      expect(find.byType(PostCard), findsNothing);
      expect(find.textContaining('No results'), findsOneWidget);
      expect(_pill(kSearchFromAnyoneLabel), findsOneWidget);
    });

    testWidgets('Top has no filter', (tester) async {
      await rig.pump(tester);
      expect(_pill(kSearchFromFollowingLabel), findsNothing);
    });
  });
}
