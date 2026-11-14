import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/search/data/search_repository.dart';
import 'package:dzeroth/features/search/domain/search_query.dart';
import 'package:dzeroth/features/search/domain/search_results_tab.dart';
import 'package:dzeroth/features/search/presentation/bloc/search_communities_cubit.dart';
import 'package:dzeroth/features/search/presentation/bloc/search_results_cubit.dart';
import 'package:dzeroth/features/search/presentation/bloc/search_results_state.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../support/fake_search_repository.dart';
import '../../../../support/posts_fixtures.dart';
import '../../../../support/search_directory_rig.dart';

void main() {
  group('SearchResultsCubit from_following', () {
    late FakeSearchRepository repo;

    SearchResultsCubit cubit(SearchResultsTab tab) => SearchResultsCubit(
      repository: repo,
      tab: tab,
      query: SearchQuery.parse('#go'),
    );

    setUp(() {
      repo = FakeSearchRepository()
        ..postsHandler = (q, tab, token) => SearchPostsPage(
          posts: [postView(token == null ? 1 : 2, text: 'x')],
          nextPageToken: token == null ? 'next' : null,
        );
    });

    test(
      'setting it reloads from page 1 with the flag; paging keeps it',
      () async {
        final c = cubit(SearchResultsTab.latest);
        await c.load();
        await c.loadMore();
        expect(c.state.posts, hasLength(2));
        expect(repo.postsFromFollowing, [false, false]);

        await c.setFromFollowing(true);
        expect(repo.postsPageTokens.last, isNull);
        expect(c.state.posts, hasLength(1));
        expect(c.state.nextPageToken, 'next');
        await c.loadMore();
        expect(repo.postsFromFollowing, [false, false, true, true]);
        await c.close();
      },
    );

    test('unchanged value and tabs that ignore it ask nothing', () async {
      final latest = cubit(SearchResultsTab.latest);
      await latest.load();
      await latest.setFromFollowing(false);
      final top = cubit(SearchResultsTab.top);
      await top.load();
      await top.setFromFollowing(true);
      expect(repo.calls, hasLength(2));
      expect(top.fromFollowing, isFalse);
      await latest.close();
      await top.close();
    });

    test('a failure with the filter on keeps it for Retry', () async {
      final c = cubit(SearchResultsTab.media);
      await c.load();
      repo.error = const NetworkException('offline');
      await c.setFromFollowing(true);
      expect(c.state.status, SearchResultsStatus.error);
      repo.error = null;
      await c.load();
      expect(repo.postsFromFollowing.last, isTrue);
      await c.close();
    });
  });

  group('SearchCommunitiesCubit', () {
    late FakeSearchRepository repo;
    setUp(() => repo = FakeSearchRepository());

    SearchCommunitiesCubit make() =>
        SearchCommunitiesCubit(repository: repo, query: 'co');

    blocTest<SearchCommunitiesCubit, SearchCommunitiesState>(
      'load then page, no duplicates, the last page ends it',
      build: () {
        repo.communitiesHandler = (q, token) => token == null
            ? SearchCommunitiesPage(
                communities: [searchCommunity('1')],
                nextPageToken: 't',
              )
            : SearchCommunitiesPage(
                communities: [searchCommunity('1'), searchCommunity('2')],
              );
        return make();
      },
      act: (c) async {
        await c.load();
        await c.loadMore();
        await c.loadMore();
      },
      verify: (c) {
        expect(c.state.communities.map((x) => x.communityId), ['1', '2']);
        expect(c.state.hasMore, isFalse);
        expect(repo.calls, ['communities:co', 'communities:co']);
      },
    );

    test(
      'first page failure is an error; a next page failure keeps rows',
      () async {
        repo.error = const SearchRateLimitedException();
        final c = make();
        await c.load();
        expect(c.state.status, SearchCommunitiesStatus.error);
        expect(c.state.error, isA<RateLimitedException>());

        repo.error = null;
        repo.communitiesHandler = (q, token) => SearchCommunitiesPage(
          communities: [searchCommunity('1')],
          nextPageToken: 't',
        );
        await c.load();
        repo.error = const NetworkException('offline');
        await c.loadMore();
        expect(c.state.communities, hasLength(1));
        expect(c.state.loadMoreFailed, isTrue);
        expect(c.state.hasMore, isTrue);
        await c.close();
      },
    );
  });
}
