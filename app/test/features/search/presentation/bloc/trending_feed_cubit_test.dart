import 'dart:async';

import 'package:dzeroth/features/search/data/search_repository.dart';
import 'package:dzeroth/features/search/presentation/bloc/trending_feed_cubit.dart';
import 'package:dzeroth/features/search/presentation/bloc/trending_paged_cubit.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pbenum.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../support/fake_search_repository.dart';

pb.PostView _post(String id, {String author = 'u1'}) => pb.PostView(
  post: pb.Post(
    postId: id,
    kind: PostKind.POST_KIND_POST,
    author: common.AuthorSnapshot(userId: author),
  ),
);

SearchPostsPage _page(List<pb.PostView> posts, String? token) =>
    SearchPostsPage(posts: posts, nextPageToken: token);

List<String> _ids(TrendingFeedCubit c) => [
  for (final v in c.state.rows) v.post.postId,
];

void main() {
  group('TrendingFeedCubit', () {
    test('the first page is ready with a next page', () async {
      final repo = FakeSearchRepository()
        ..explorePostsResult = _page([_post('a'), _post('b')], 'n');
      final cubit = TrendingFeedCubit(repository: repo);
      await cubit.start();
      await cubit.start();
      expect(cubit.state.status, PagedStatus.ready);
      expect(_ids(cubit), ['a', 'b']);
      expect(cubit.state.hasMore, isTrue);
      expect(repo.explorePostsTokens, [null]);
      await cubit.close();
    });

    test('empty pages with a token are followed up to 3 calls, then the '
        'list is stalled and nothing asks by itself', () async {
      final repo = FakeSearchRepository()
        ..explorePostsHandler = (_) => _page(const [], 'n');
      final cubit = TrendingFeedCubit(repository: repo);
      await cubit.start();
      expect(repo.explorePostsTokens, [null, 'n', 'n']);
      expect(cubit.state.stalled, isTrue);
      expect(cubit.state.rows, isEmpty);
      await cubit.loadMore();
      await cubit.loadMore();
      expect(repo.explorePostsTokens, hasLength(3));
      await cubit.close();
    });

    test('continueAfterStall runs one bounded round', () async {
      var round = 0;
      final repo = FakeSearchRepository()
        ..explorePostsHandler = (_) =>
            ++round <= 3 ? _page(const [], 'n') : _page([_post('a')], null);
      final cubit = TrendingFeedCubit(repository: repo);
      await cubit.start();
      expect(cubit.state.stalled, isTrue);
      await cubit.continueAfterStall();
      expect(repo.explorePostsTokens, hasLength(4));
      expect(_ids(cubit), ['a']);
      expect(cubit.state.stalled, isFalse);
      expect(cubit.state.hasMore, isFalse);
      await cubit.close();
    });

    test('a round that finds rows is not stalled; loadMore stops at 10 new '
        'rows', () async {
      final repo = FakeSearchRepository()
        ..explorePostsHandler = (t) => t == null
            ? _page([_post('a')], 'p2')
            : _page([for (var i = 0; i < 10; i++) _post('b$i')], 'p3');
      final cubit = TrendingFeedCubit(repository: repo);
      await cubit.start();
      await cubit.loadMore();
      expect(repo.explorePostsTokens, [null, 'p2']);
      expect(cubit.state.rows, hasLength(11));
      expect(cubit.state.stalled, isFalse);
      await cubit.close();
    });

    test('a failed later page keeps the rows and pauses automatic paging; '
        'retryMore answers it', () async {
      final repo = FakeSearchRepository()
        ..explorePostsHandler = (t) =>
            t == null ? _page([_post('a')], 'p2') : throw Exception('x');
      final cubit = TrendingFeedCubit(repository: repo);
      await cubit.start();
      await cubit.loadMore();
      expect(cubit.state.pagingFailed, isTrue);
      expect(_ids(cubit), ['a']);
      await cubit.loadMore();
      expect(repo.explorePostsTokens, [null, 'p2']);
      repo.explorePostsHandler = (_) => _page([_post('b')], null);
      await cubit.retryMore();
      expect(_ids(cubit), ['a', 'b']);
      expect(cubit.state.pagingFailed, isFalse);
      await cubit.close();
    });

    test('a rate limit on a later page holds automatic paging', () async {
      final repo = FakeSearchRepository()
        ..explorePostsHandler = (t) => t == null
            ? _page([_post('a')], 'p2')
            : throw const SearchRateLimitedException();
      final cubit = TrendingFeedCubit(repository: repo);
      await cubit.start();
      await cubit.loadMore();
      expect(cubit.state.error, isA<SearchRateLimitedException>());
      expect(cubit.state.pagingFailed, isTrue);
      await cubit.loadMore();
      expect(repo.explorePostsTokens, hasLength(2));
      await cubit.close();
    });

    test('an expired token restarts from page one without an error', () async {
      var expired = true;
      final repo = FakeSearchRepository()
        ..explorePostsHandler = (t) {
          if (t == null) return _page([_post('a')], 'old');
          if (expired) {
            expired = false;
            throw const SearchInvalidQueryException(field: 'page_token');
          }
          return _page(const [], null);
        };
      final cubit = TrendingFeedCubit(repository: repo);
      await cubit.start();
      final serial = cubit.state.resetSerial;
      await cubit.loadMore();
      expect(repo.explorePostsTokens, [null, 'old', null, 'old']);
      expect(cubit.state.pagingFailed, isFalse);
      expect(cubit.state.error, isNull);
      expect(cubit.state.resetSerial, serial + 1);
      expect(_ids(cubit), ['a']);
      await cubit.close();
    });

    test('a query validation error is a failure, not a restart', () async {
      final repo = FakeSearchRepository()
        ..explorePostsHandler = (t) => t == null
            ? _page([_post('a')], 'p2')
            : throw const SearchInvalidQueryException(field: 'query');
      final cubit = TrendingFeedCubit(repository: repo);
      await cubit.start();
      await cubit.loadMore();
      expect(cubit.state.pagingFailed, isTrue);
      expect(repo.explorePostsTokens, [null, 'p2']);
      await cubit.close();
    });

    test('refresh replaces the rows and keeps them when it fails', () async {
      final repo = FakeSearchRepository()
        ..explorePostsResult = _page([_post('a')], null);
      final cubit = TrendingFeedCubit(repository: repo);
      await cubit.start();
      repo.explorePostsResult = _page([_post('n'), _post('a')], null);
      await cubit.refresh();
      expect(_ids(cubit), ['n', 'a']);
      repo.error = Exception('down');
      await cubit.refresh();
      expect(_ids(cubit), ['n', 'a']);
      expect(cubit.state.notice, isNotNull);
      expect(cubit.state.refreshing, isFalse);
      repo.error = null;
      await cubit.refresh();
      expect(cubit.state.notice, isNull);
      await cubit.close();
    });

    test('a late page after a refresh is dropped', () async {
      final repo = FakeSearchRepository()
        ..explorePostsHandler = (t) => t == null
            ? _page([_post('a')], 'p2')
            : _page([_post('late')], null);
      final cubit = TrendingFeedCubit(repository: repo);
      await cubit.start();
      repo.explorePostsGate = Completer<void>();
      final more = cubit.loadMore();
      await Future<void>.delayed(Duration.zero);
      final gate = repo.explorePostsGate!;
      repo.explorePostsGate = null;
      final refresh = cubit.refresh();
      gate.complete();
      await Future.wait([more, refresh]);
      expect(_ids(cubit), ['a']);
      await cubit.close();
    });

    test(
      'hideAuthor, restoreAuthor and removePost change the rows at once',
      () async {
        final repo = FakeSearchRepository()
          ..explorePostsResult = _page([
            _post('a'),
            _post('b', author: 'u2'),
            _post('c'),
          ], null);
        final cubit = TrendingFeedCubit(repository: repo);
        await cubit.start();
        cubit.hideAuthor('u1');
        expect(_ids(cubit), ['b']);
        cubit.restoreAuthor('u1');
        expect(_ids(cubit), ['a', 'b', 'c']);
        cubit.removePost('b');
        expect(_ids(cubit), ['a', 'c']);
        expect(repo.explorePostsTokens, [null]);
        await cubit.close();
      },
    );

    test('a tag asks SearchPosts LATEST for #tag, not ExplorePosts', () async {
      final repo = FakeSearchRepository()
        ..postsResult = _page([_post('a')], null);
      final cubit = TrendingFeedCubit(repository: repo, tag: 'go');
      await cubit.start();
      expect(repo.calls, ['posts:#go:SEARCH_TAB_LATEST']);
      expect(repo.explorePostsTokens, isEmpty);
      await cubit.close();
    });

    test('FEATURE_DISABLED is unavailable and is not retried', () async {
      final repo = FakeSearchRepository()
        ..error = const SearchUnavailableException('trending_posts');
      final cubit = TrendingFeedCubit(repository: repo);
      await cubit.start();
      expect(cubit.state.status, PagedStatus.unavailable);
      await cubit.retry();
      await cubit.refresh();
      expect(repo.calls, hasLength(1));
      await cubit.close();
    });

    test('a failed first page is failed; retry asks again', () async {
      final repo = FakeSearchRepository()..error = Exception('boom');
      final cubit = TrendingFeedCubit(repository: repo);
      await cubit.start();
      expect(cubit.state.status, PagedStatus.failed);
      repo.error = null;
      repo.explorePostsResult = _page([_post('a')], null);
      await cubit.retry();
      expect(_ids(cubit), ['a']);
      await cubit.close();
    });
  });
}
