import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/app/session_wiring.dart' show UnexpectedErrorReporter;
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/search/data/recent_searches_store.dart';
import 'package:dzeroth/features/search/data/search_repository.dart';
import 'package:dzeroth/features/search/domain/search_results_tab.dart';
import 'package:dzeroth/features/search/presentation/search_results_screen.dart';
import 'package:dzeroth/gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:dzeroth/shared/widgets/app_tab_bar.dart';
import 'package:dzeroth/shared/widgets/post_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/fake_people_source.dart' show person;
import '../../../support/fake_search_repository.dart';
import '../../../support/search_field_rig.dart' show FakeRecentSearchesStore;
import '../../../support/posts_fixtures.dart';
import '../../../support/theme_harness.dart';

class _MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

class _MockGraphRepository extends Mock implements GraphRepository {}

/// `/search` (W4-15, ADR-0028): the four tabs over a scripted
/// [FakeSearchRepository]; no transport, no router beyond the one the screen
/// pops with.
void main() {
  late FakeSearchRepository search;
  late _MockOnboardingBloc onboarding;
  late GoRouter router;

  setUp(() {
    search = FakeSearchRepository();
    onboarding = _MockOnboardingBloc();
  });

  Future<void> open(
    WidgetTester tester, {
    String query = '#go',
    SearchResultsTab tab = SearchResultsTab.top,
    Set<String> flags = const {'search', 'posts'},
    Size size = const Size(390, 844),
    Brightness brightness = Brightness.light,
    double textScale = 1,
    bool settle = true,
  }) async {
    whenListen(
      onboarding,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        status: OnboardingStatus.ready,
        enabledFeatures: flags,
        profile: identity.Profile(userId: 'me', handle: 'me'),
      ),
    );
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => const Scaffold(body: Text('came from')),
        ),
        GoRoute(
          path: '/search',
          builder: (context, state) => SearchResultsScreen(
            query: state.uri.queryParameters['q'] ?? query,
            initialTab: tab,
          ),
        ),
        GoRoute(
          path: '/post/:id',
          builder: (context, state) =>
              Scaffold(body: Text('post page ${state.pathParameters['id']}')),
        ),
      ],
    );
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<SearchRepository>.value(value: search),
          RepositoryProvider<RecentSearchesStore>.value(
            value: FakeRecentSearchesStore(),
          ),
          RepositoryProvider<GraphRepository>.value(
            value: _MockGraphRepository(),
          ),
          RepositoryProvider<UnexpectedErrorReporter>.value(
            value: (error, stack) {},
          ),
        ],
        child: BlocProvider<OnboardingBloc>.value(
          value: onboarding,
          child: MaterialApp.router(
            routerConfig: router,
            theme: buildAppTheme(brightness: brightness),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(textScale)),
              child: child!,
            ),
          ),
        ),
      ),
    );
    unawaited(router.push('/search?q=${Uri.encodeQueryComponent(query)}'));
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
    }
  }

  Future<void> tapTab(WidgetTester tester, String label) async {
    final tab = find.descendant(
      of: find.byType(AppTabBar),
      matching: find.text(label),
    );
    // The row scrolls sideways when the labels are wide (large text).
    await tester.ensureVisible(tab);
    await tester.pumpAndSettle();
    await tester.tap(tab);
    await tester.pumpAndSettle();
  }

  SearchPostsPage page(
    List<int> ids, {
    String? token,
    bool unsupported = false,
  }) => SearchPostsPage(
    posts: [for (final n in ids) postView(n, text: 'tagged $n')],
    nextPageToken: token,
    normalizedTag: 'go',
    unsupportedQuery: unsupported,
  );

  group('tabs and the first call', () {
    testWidgets('Top is the default and asks one SearchPosts for #go', (
      tester,
    ) async {
      search.postsResult = page([1, 2]);
      await open(tester);

      expect(search.calls, ['posts:#go:SEARCH_TAB_TOP']);
      expect(find.byType(PostCard), findsNWidgets(2));
      expect(find.text('Top'), findsOneWidget);
      expect(find.text('Latest'), findsOneWidget);
      expect(find.text('People'), findsOneWidget);
      expect(find.text('Media'), findsOneWidget);
      expect(find.text('#go'), findsOneWidget);
    });

    testWidgets('Top ends with "See latest", which opens Latest', (
      tester,
    ) async {
      search.postsResult = page([1]);
      await open(tester);

      await tester.tap(find.text(kSeeLatestLabel));
      await tester.pumpAndSettle();

      expect(search.calls, [
        'posts:#go:SEARCH_TAB_TOP',
        'posts:#go:SEARCH_TAB_LATEST',
      ]);
    });

    testWidgets('a tab asks only when first selected and keeps its rows', (
      tester,
    ) async {
      search.postsResult = page([1]);
      await open(tester);
      expect(search.calls, hasLength(1));

      await tapTab(tester, 'Latest');
      await tapTab(tester, 'Media');
      await tapTab(tester, 'Top');
      await tapTab(tester, 'Latest');

      expect(search.calls, [
        'posts:#go:SEARCH_TAB_TOP',
        'posts:#go:SEARCH_TAB_LATEST',
        'posts:#go:SEARCH_TAB_MEDIA',
      ]);
    });

    testWidgets('an @handle query opens People and calls SearchPeople', (
      tester,
    ) async {
      search.peopleResult = SearchPeopleResult(users: [person(1)]);
      await open(
        tester,
        query: '@us',
        tab: SearchResultsTab.fromQuery(null, query: '@us'),
      );

      expect(search.calls, ['people:us']);
      expect(find.text('User 1'), findsOneWidget);
      expect(find.text('@user1'), findsOneWidget);
    });
  });

  group('words instead of a call', () {
    testWidgets('a phrase shows "Search posts by #hashtag" and no posts call', (
      tester,
    ) async {
      await open(tester, query: 'hello world');

      expect(search.calls, isEmpty);
      expect(find.text(kSearchPostsHintTitle), findsOneWidget);
      expect(find.byType(PostCard), findsNothing);
    });

    testWidgets('a phrase still has no People call, only the same hint', (
      tester,
    ) async {
      await open(tester, query: 'hello world', tab: SearchResultsTab.people);

      expect(search.calls, isEmpty);
      expect(find.text(kSearchPostsHintTitle), findsOneWidget);
    });

    testWidgets('a one-letter query: People says why, with no call', (
      tester,
    ) async {
      await open(tester, query: 'a', tab: SearchResultsTab.people);

      expect(search.calls, isEmpty);
      expect(find.text(kSearchPeopleTooShortTitle), findsOneWidget);
    });

    testWidgets('a one-letter query still searches the tag on Top', (
      tester,
    ) async {
      search.postsResult = page([1]);
      await open(tester, query: 'a');

      expect(search.calls, ['posts:#a:SEARCH_TAB_TOP']);
      expect(find.byType(PostCard), findsOneWidget);
    });

    testWidgets('a server unsupported_query answer shows the same hint', (
      tester,
    ) async {
      search.postsResult = page([], unsupported: true);
      await open(tester);

      expect(find.text(kSearchPostsHintTitle), findsOneWidget);
    });

    testWidgets('an empty query says it is not valid and calls nothing', (
      tester,
    ) async {
      await open(tester, query: '#');

      expect(search.calls, isEmpty);
      expect(find.text(kSearchInvalidTitle), findsOneWidget);
    });

    testWidgets('@handle on a post tab shows the hashtag hint', (tester) async {
      await open(tester, query: '@bob', tab: SearchResultsTab.latest);

      expect(search.calls, isEmpty);
      expect(find.text(kSearchPostsHintTitle), findsOneWidget);
    });
  });

  group('states', () {
    testWidgets('loading shows a skeleton, not an empty claim', (tester) async {
      search.postsGate = Completer<void>();
      search.postsResult = page([1]);
      await open(tester, settle: false);

      expect(find.bySemanticsLabel('Loading results'), findsOneWidget);
      expect(find.textContaining('No results'), findsNothing);

      search.postsGate!.complete();
      await tester.pumpAndSettle();
      expect(find.byType(PostCard), findsOneWidget);
    });

    testWidgets('no posts: "No results for ..."', (tester) async {
      await open(tester);

      expect(find.text('No results for "#go"'), findsOneWidget);
    });

    testWidgets('no people: "No people found for ..."', (tester) async {
      await open(tester, query: '@zz', tab: SearchResultsTab.people);

      expect(find.text('No people found for "@zz"'), findsOneWidget);
    });

    testWidgets('FEATURE_DISABLED shows "not available" with no Retry', (
      tester,
    ) async {
      search.error = const SearchUnavailableException('search');
      await open(tester);

      expect(find.text(kSearchUnavailableTitle), findsOneWidget);
      expect(find.text('Try again'), findsNothing);
      expect(find.text('Retry'), findsNothing);
    });

    testWidgets('a rate limit says so and Try again repeats the call', (
      tester,
    ) async {
      search.error = const SearchRateLimitedException(
        retryAfter: Duration(seconds: 5),
      );
      await open(tester);
      expect(find.text('Too many searches'), findsOneWidget);

      search
        ..error = null
        ..postsResult = page([1]);
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();

      expect(search.calls, hasLength(2));
      expect(find.byType(PostCard), findsOneWidget);
    });

    testWidgets('a daily rate limit offers no Try again', (tester) async {
      search.error = const SearchRateLimitedException(isDaily: true);
      await open(tester);

      expect(find.text('Too many searches'), findsOneWidget);
      expect(find.text('Try again'), findsNothing);
    });

    testWidgets('a rate limit on People has the same friendly view', (
      tester,
    ) async {
      search.error = const SearchRateLimitedException();
      await open(tester, query: '@bob', tab: SearchResultsTab.people);

      expect(find.text('Too many searches'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
    });

    testWidgets('an unexpected error shows the shared error view with Retry', (
      tester,
    ) async {
      search.error = StateError('boom');
      await open(tester);

      expect(find.text('Try again'), findsNothing);
      expect(find.text('Retry'), findsOneWidget);
    });
  });

  group('paging', () {
    testWidgets('Latest follows next_page_token through short pages', (
      tester,
    ) async {
      search = _PagedSearch([
        page([1], token: 't1'),
        page([2], token: 't2'),
        page([3, 4]),
      ]);
      await open(tester, tab: SearchResultsTab.latest);
      // Short pages that do not fill the screen are followed by themselves,
      // until the token is empty.
      await tester.pumpAndSettle();

      expect(search.postsPageTokens, [null, 't1', 't2']);
      expect(find.byType(PostCard), findsNWidgets(4));
    });

    testWidgets('Latest stops when the token is empty', (tester) async {
      search.postsResult = page([1, 2, 3], token: null);
      await open(tester, tab: SearchResultsTab.latest);

      expect(search.calls, ['posts:#go:SEARCH_TAB_LATEST']);
      expect(find.byType(PostCard), findsNWidgets(3));
    });

    testWidgets('Top never pages even if a token came back', (tester) async {
      search.postsResult = page([1], token: 'ignored');
      await open(tester);
      await tester.pumpAndSettle();

      expect(search.calls, ['posts:#go:SEARCH_TAB_TOP']);
    });

    testWidgets('Media with an empty page and a token keeps following it', (
      tester,
    ) async {
      search = _PagedSearch([
        page([], token: 'm1'),
        page([5]),
      ]);
      await open(tester, tab: SearchResultsTab.media);
      await tester.pumpAndSettle();

      expect(search.postsPageTokens, [null, 'm1']);
      expect(find.textContaining('No results'), findsNothing);
      expect(find.byType(PostCard), findsOneWidget);
    });

    testWidgets('a failed next page keeps the rows under a banner and halts', (
      tester,
    ) async {
      search = _PagedSearch([
        page([1], token: 't1'),
        null, // the second page fails
      ]);
      await open(tester, tab: SearchResultsTab.latest);
      await tester.pumpAndSettle();

      expect(find.byType(PostCard), findsOneWidget);
      expect(find.text("Couldn't refresh the results."), findsOneWidget);
      // Automatic paging stopped: one failed try, not a loop.
      expect(search.postsPageTokens, [null, 't1']);
    });
  });

  group('People', () {
    testWidgets('rows are UserListRows without Follow when graph is off', (
      tester,
    ) async {
      search.peopleResult = SearchPeopleResult(users: [person(1), person(2)]);
      await open(tester, query: '@us', tab: SearchResultsTab.people);

      expect(find.text('User 1'), findsOneWidget);
      expect(find.text('User 2'), findsOneWidget);
      expect(find.text('Follow'), findsNothing);
    });

    testWidgets('with graph on each row shows its Follow button', (
      tester,
    ) async {
      search.peopleResult = SearchPeopleResult(users: [person(1)]);
      await open(
        tester,
        query: '@us',
        tab: SearchResultsTab.people,
        flags: const {'search', 'graph'},
      );

      expect(find.text('Follow'), findsOneWidget);
    });

    testWidgets('rows show Follow, Following and Unblock from relationship', (
      tester,
    ) async {
      graph.UserListItem withRelationship(
        int i, {
        graph.FollowState state = graph.FollowState.FOLLOW_STATE_NONE,
        bool blocking = false,
      }) => person(i)
        ..relationship = graph.Relationship(
          userId: 'u$i',
          followState: state,
          blocking: blocking,
        );
      search.peopleResult = SearchPeopleResult(
        users: [
          withRelationship(1),
          withRelationship(2, state: graph.FollowState.FOLLOW_STATE_FOLLOWING),
          withRelationship(3, blocking: true),
        ],
      );
      await open(
        tester,
        query: '@us',
        tab: SearchResultsTab.people,
        flags: const {'search', 'graph'},
      );

      expect(find.text('Follow'), findsOneWidget);
      expect(find.text('Following'), findsOneWidget);
      expect(find.text('Unblock'), findsOneWidget);
    });

    testWidgets(
      'an unsupported word: People still works, posts show the hint',
      (tester) async {
        // "123" is a handle prefix but not a hashtag body (ADR-0010 D8).
        search.peopleResult = SearchPeopleResult(users: [person(1)]);
        await open(tester, query: '123', tab: SearchResultsTab.people);
        expect(search.calls, ['people:123']);
        expect(find.text('User 1'), findsOneWidget);

        await tapTab(tester, 'Top');
        expect(
          search.calls.where((c) => c.startsWith('posts:')),
          isEmpty,
          reason: 'no posts call',
        );
        expect(find.text(kSearchPostsHintTitle), findsOneWidget);
      },
    );
  });

  group('layout', () {
    testWidgets('Back goes to where the user came from', (tester) async {
      search.postsResult = page([1]);
      await open(tester);

      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();

      expect(find.text('came from'), findsOneWidget);
    });

    testWidgets('a post row opens /post/:id', (tester) async {
      search.postsResult = page([7]);
      await open(tester);

      await tester.tap(find.text('tagged 7'));
      await tester.pumpAndSettle();

      expect(find.textContaining('post page'), findsOneWidget);
    });

    forEachThemeAndWidth(
      'results fit without overflow',
      (tester, env) async {
        search.postsResult = page([1, 2, 3], token: null);
        await open(
          tester,
          size: env.size,
          brightness: env.brightness,
          textScale: env.textScale,
        );

        expect(tester.takeException(), isNull);
        expect(find.byType(PostCard), findsWidgets);
      },
      widths: const [360, 600, 1200],
      textScales: kMatrixTextScalesLarge,
    );

    forEachThemeAndWidth(
      'people and states fit without overflow',
      (tester, env) async {
        search.peopleResult = SearchPeopleResult(users: [person(1), person(2)]);
        await open(
          tester,
          query: '@us',
          tab: SearchResultsTab.people,
          size: env.size,
          brightness: env.brightness,
          textScale: env.textScale,
        );
        expect(tester.takeException(), isNull);
        await tapTab(tester, 'Top');
        expect(tester.takeException(), isNull);
        expect(find.text(kSearchPostsHintTitle), findsOneWidget);
      },
      widths: const [360, 600, 1200],
      textScales: kMatrixTextScalesLarge,
    );

    testWidgets('the header field shows the query and is editable', (
      tester,
    ) async {
      search.postsResult = page([1]);
      await open(tester);
      expect(find.widgetWithText(TextField, '#go'), findsOneWidget);
    });
    testWidgets('a new search replaces the page: one Back leaves the results', (
      tester,
    ) async {
      search.postsResult = page([1]);
      await open(tester);
      await tester.enterText(find.byType(TextField), '#other');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(search.calls, [
        'posts:#go:SEARCH_TAB_TOP',
        'posts:#other:SEARCH_TAB_TOP',
      ]);
      expect(find.widgetWithText(TextField, '#other'), findsOneWidget);
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(find.text('came from'), findsOneWidget);
    });
  });
}

/// Answers `searchPosts` from a queue of pages (a null entry fails that
/// call), so a test can walk `next_page_token` through short pages.
class _PagedSearch extends FakeSearchRepository {
  _PagedSearch(this._pages);

  final List<SearchPostsPage?> _pages;

  @override
  Future<SearchPostsPage> searchPosts(
    String query, {
    required SearchTab tab,
    String? pageToken,
    int pageSize = 20,
  }) async {
    calls.add('posts:$query:${tab.name}');
    postsPageTokens.add(pageToken);
    final next = _pages.isEmpty ? null : _pages.removeAt(0);
    if (next == null) throw StateError('scripted failure');
    return next;
  }
}
