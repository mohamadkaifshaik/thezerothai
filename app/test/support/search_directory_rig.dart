import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/app/session_wiring.dart' show UnexpectedErrorReporter;
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/lists/data/lists_repository.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/search/data/recent_searches_store.dart';
import 'package:dzeroth/features/search/data/search_repository.dart';
import 'package:dzeroth/features/search/domain/search_results_tab.dart';
import 'package:dzeroth/features/search/presentation/search_results_screen.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/communities/v1/communities.pb.dart'
    as communities;
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:dzeroth/gen/dzeroth/lists/v1/lists.pb.dart' as lists_pb;
import 'package:dzeroth/shared/widgets/primitives/app_tab_bar.dart';
import 'package:fixnum/fixnum.dart' show Int64;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import 'fake_search_repository.dart';
import 'search_field_rig.dart' show FakeRecentSearchesStore;

class _MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

class _MockGraph extends Mock implements GraphRepository {}

class MockListsRepository extends Mock implements ListsRepository {}

/// Flags of the search bundle with everything on.
const kSearchBundleFlags = <String>{
  'search',
  'posts',
  'lists',
  'communities',
  'list_follows',
  'search_lists',
  'search_filters',
};

lists_pb.ListInfo searchList(
  String id, {
  String name = 'Coffee lovers',
  String owner = 'u-olivia',
  bool following = false,
  bool isPrivate = false,
}) => lists_pb.ListInfo(
  listId: id,
  name: name,
  isPrivate: isPrivate,
  memberCount: 3,
  followerCount: 7,
  followedByViewer: following,
  owner: common.AuthorSnapshot(
    userId: owner,
    handle: 'olivia',
    displayName: 'Olivia',
  ),
);

communities.Community searchCommunity(
  String id, {
  String name = 'Coffee club',
}) => communities.Community(
  communityId: id,
  name: name,
  description: 'Beans and brews',
  memberCount: Int64(412),
);

/// `/search` over a [FakeSearchRepository] and a mocked [ListsRepository],
/// signed in as `u-me`.
class SearchDirectoryRig {
  SearchDirectoryRig({FakeSearchRepository? search})
    : search = search ?? FakeSearchRepository(),
      lists = MockListsRepository();

  final FakeSearchRepository search;
  final MockListsRepository lists;
  late GoRouter router;

  Future<void> pump(
    WidgetTester tester, {
    String query = 'coffee',
    SearchResultsTab tab = SearchResultsTab.top,
    Set<String> flags = kSearchBundleFlags,
    Size size = const Size(390, 844),
    Brightness brightness = Brightness.light,
    double textScale = 1,
  }) async {
    final onboarding = _MockOnboardingBloc();
    whenListen(
      onboarding,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        status: OnboardingStatus.ready,
        enabledFeatures: flags,
        profile: identity.Profile(userId: 'u-me', handle: 'me'),
      ),
    );
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Widget stub(String label) => Scaffold(body: Text(label));
    router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(path: '/', builder: (context, state) => stub('came from')),
        GoRoute(
          path: '/search',
          builder: (context, state) => SearchResultsScreen(
            query: state.uri.queryParameters['q'] ?? query,
            initialTab: tab,
          ),
        ),
        GoRoute(
          path: '/lists/:id',
          builder: (context, state) =>
              stub('list page ${state.pathParameters['id']}'),
        ),
        GoRoute(
          path: '/communities/:id',
          builder: (context, state) =>
              stub('community page ${state.pathParameters['id']}'),
        ),
        GoRoute(path: '/home', builder: (context, state) => stub('home')),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<SearchRepository>.value(value: search),
          RepositoryProvider<ListsRepository>.value(value: lists),
          RepositoryProvider<RecentSearchesStore>.value(
            value: FakeRecentSearchesStore(),
          ),
          RepositoryProvider<GraphRepository>.value(value: _MockGraph()),
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
    await tester.pumpAndSettle();
  }

  Future<void> tapTab(WidgetTester tester, String label) async {
    final tab = find.descendant(
      of: find.byType(AppTabBar),
      matching: find.text(label),
    );
    await tester.ensureVisible(tab);
    await tester.pumpAndSettle();
    await tester.tap(tab);
    await tester.pumpAndSettle();
  }
}
