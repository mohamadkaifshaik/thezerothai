import 'package:dzeroth/features/search/data/search_repository.dart';
import 'package:dzeroth/features/search/presentation/bloc/explore_media_state.dart';
import 'package:dzeroth/features/search/presentation/bloc/trending_media_cubit.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pbenum.dart';
import 'package:fixnum/fixnum.dart' show Int64;
import 'package:flutter_test/flutter_test.dart';
import 'package:protobuf/well_known_types/google/protobuf/timestamp.pb.dart';

import '../../../../support/fake_search_repository.dart';

pb.PostView _photo(String id, int seconds) => pb.PostView(
  post: pb.Post(
    postId: id,
    kind: PostKind.POST_KIND_POST,
    createdAt: Timestamp(seconds: Int64(seconds)),
    media: [
      common.MediaRef(
        url: 'https://m.test/$id.webp',
        thumbUrl: 'https://m.test/$id-t.webp',
      ),
    ],
  ),
);

SearchPostsPage _page(List<pb.PostView> posts, String? token) =>
    SearchPostsPage(posts: posts, nextPageToken: token);

List<String> _ids(ExploreMediaState s) => [for (final t in s.tiles) t.postId];

void main() {
  group('TrendingMediaCubit', () {
    test('first page is ready, newest first, with a next page', () async {
      final repo = FakeSearchRepository()
        ..exploreMediaHandler = (token) => token == null
            ? _page([_photo('a', 30), _photo('b', 20)], 'next')
            : _page([_photo('c', 10)], null);
      final cubit = TrendingMediaCubit(repository: repo);
      await cubit.start();
      expect(cubit.state.status, ExploreMediaStatus.ready);
      expect(_ids(cubit.state), ['a', 'b']);
      expect(cubit.state.hasMore, isTrue);
      expect(repo.exploreMediaTokens, [null]);
      await cubit.close();
    });

    test('start asks once', () async {
      final repo = FakeSearchRepository()
        ..exploreMediaResult = _page([_photo('a', 1)], null);
      final cubit = TrendingMediaCubit(repository: repo);
      await cubit.start();
      await cubit.start();
      expect(repo.exploreMediaTokens, [null]);
      await cubit.close();
    });

    test('an empty first page with a token follows it', () async {
      final repo = FakeSearchRepository()
        ..exploreMediaHandler = (token) => token == null
            ? _page(const [], 'next')
            : _page([_photo('x', 5)], null);
      final cubit = TrendingMediaCubit(repository: repo);
      await cubit.start();
      expect(_ids(cubit.state), ['x']);
      expect(cubit.state.hasMore, isFalse);
      expect(repo.exploreMediaTokens, [null, 'next']);
      await cubit.close();
    });

    test(
      'feature off for the caller is unavailable and never retried',
      () async {
        final repo = FakeSearchRepository()
          ..error = const SearchUnavailableException('trending_media');
        final cubit = TrendingMediaCubit(repository: repo);
        await cubit.start();
        expect(cubit.state.status, ExploreMediaStatus.unavailable);
        await cubit.retry();
        expect(cubit.state.status, ExploreMediaStatus.unavailable);
        await cubit.close();
      },
    );

    test('a failed first page is failed, and retry asks again', () async {
      final repo = FakeSearchRepository()..error = Exception('boom');
      final cubit = TrendingMediaCubit(repository: repo);
      await cubit.start();
      expect(cubit.state.status, ExploreMediaStatus.failed);
      repo.error = null;
      repo.exploreMediaResult = _page([_photo('a', 1)], null);
      await cubit.retry();
      expect(cubit.state.status, ExploreMediaStatus.ready);
      expect(_ids(cubit.state), ['a']);
      await cubit.close();
    });

    test(
      'loadMore appends the next page and clears the token at the end',
      () async {
        final repo = FakeSearchRepository()
          ..exploreMediaHandler = (token) => token == null
              ? _page([_photo('a', 30)], 'p2')
              : _page([_photo('b', 20)], null);
        final cubit = TrendingMediaCubit(repository: repo);
        await cubit.start();
        await cubit.loadMore();
        expect(_ids(cubit.state), ['a', 'b']);
        expect(cubit.state.hasMore, isFalse);
        expect(cubit.state.loadingMore, isFalse);
        expect(repo.exploreMediaTokens, [null, 'p2']);
        await cubit.close();
      },
    );

    test(
      'a failed later page keeps the tiles; retryMore answers them',
      () async {
        final repo = FakeSearchRepository()
          ..exploreMediaHandler = (token) => token == null
              ? _page([_photo('a', 30)], 'p2')
              : throw Exception('page');
        final cubit = TrendingMediaCubit(repository: repo);
        await cubit.start();
        await cubit.loadMore();
        expect(cubit.state.status, ExploreMediaStatus.ready);
        expect(_ids(cubit.state), ['a']);
        expect(cubit.state.pagingFailed, isTrue);
        repo.exploreMediaHandler = (_) => _page([_photo('b', 20)], null);
        await cubit.retryMore();
        expect(_ids(cubit.state), ['a', 'b']);
        expect(cubit.state.pagingFailed, isFalse);
        await cubit.close();
      },
    );

    test('loadMore does nothing without a next page', () async {
      final repo = FakeSearchRepository()
        ..exploreMediaResult = _page([_photo('a', 1)], null);
      final cubit = TrendingMediaCubit(repository: repo);
      await cubit.start();
      await cubit.loadMore();
      expect(repo.exploreMediaTokens, [null]);
      await cubit.close();
    });
  });
}
