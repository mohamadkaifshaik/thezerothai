import 'dart:async';

import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/timeline/data/timeline_store.dart';
import 'package:dzeroth/features/timeline/domain/feed_key.dart';
import 'package:dzeroth/features/timeline/presentation/bloc/timeline_cubit.dart';
import 'package:dzeroth/features/timeline/presentation/bloc/timeline_state.dart';
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../../support/posts_fixtures.dart';
import '../../../../support/timeline_fixtures.dart';

void main() {
  const feed = FeedKey.home();
  late MockTimelineRepository timeline;
  late MockPostsRepository posts;
  late StreamController<String> removed;
  late TimelineCubit cubit;
  final deleted = <pb.PostView>[];

  List<String> ids(TimelineState s) => [
    for (final e in s.entries) e.isGap ? 'gap' : e.postView!.post.postId,
  ];
  List<String> idsOf(List<int> n) => [for (final i in n) postId(i)];

  void stubCached(TimelineSnapshot snapshot) {
    when(() => timeline.cached(feed)).thenAnswer((_) async => snapshot);
  }

  void stubRefresh(TimelineSnapshot snapshot) {
    when(() => timeline.refresh(feed)).thenAnswer((_) async => snapshot);
  }

  TimelineCubit build({String? viewer}) => TimelineCubit(
    feed: feed,
    timeline: timeline,
    posts: posts,
    viewerUserId: viewer,
    onPostDeleted: deleted.add,
  );

  setUp(() {
    deleted.clear();
    timeline = MockTimelineRepository();
    posts = MockPostsRepository();
    removed = StreamController<String>.broadcast();
    when(() => posts.removedPosts).thenAnswer((_) => removed.stream);
    when(() => timeline.sinceRefresh(feed)).thenReturn(null);
    when(() => timeline.sinceRefreshAttempt(feed)).thenReturn(null);
    when(() => timeline.rateLimitedFor()).thenReturn(null);
    cubit = build(viewer: 'me');
  });

  tearDown(() async {
    await cubit.close();
    await removed.close();
  });

  group('load', () {
    test('renders the cache, then holds new posts behind the pill', () async {
      stubCached(snapshotOf([2, 1]));
      stubRefresh(snapshotOf([3, 2, 1], since: 's2'));

      await cubit.load();

      expect(ids(cubit.state), idsOf([2, 1]));
      expect(cubit.state.newPosts, 1);
      expect(cubit.state.status, TimelineStatus.ready);
      verify(() => timeline.cached(feed)).called(1);
      verify(() => timeline.refresh(feed)).called(1);

      cubit.showNewPosts();
      expect(ids(cubit.state), idsOf([3, 2, 1]));
      expect(cubit.state.newPosts, 0);
    });

    test('an empty cache inserts the first page directly', () async {
      stubCached(const TimelineSnapshot());
      stubRefresh(snapshotOf([3, 2, 1]));

      await cubit.load();

      expect(ids(cubit.state), idsOf([3, 2, 1]));
      expect(cubit.state.newPosts, 0);
    });

    test('no RPC when the feed was refreshed moments ago', () async {
      stubCached(snapshotOf([2, 1]));
      when(
        () => timeline.sinceRefresh(feed),
      ).thenReturn(const Duration(seconds: 20));

      await cubit.load();

      verifyNever(() => timeline.refresh(feed));
      expect(ids(cubit.state), idsOf([2, 1]));
    });

    test('a viewer id set after creation still exempts own posts', () async {
      final late = build(); // profile not loaded yet: no viewer id
      addTearDown(late.close);
      stubCached(snapshotOf([2, 1]));
      stubRefresh(
        TimelineSnapshot(
          entries: [postEntry(3, authorId: 'me'), postEntry(2), postEntry(1)],
        ),
      );
      late.viewerUserId = 'me'; // the Home screen sets it when the profile loads

      await late.load();

      expect(ids(late.state), idsOf([3, 2, 1]));
      expect(late.state.newPosts, 0);
    });

    test('a viewer\'s own new post is not held behind the pill', () async {
      stubCached(snapshotOf([2, 1]));
      stubRefresh(
        TimelineSnapshot(
          entries: [postEntry(3, authorId: 'me'), postEntry(2), postEntry(1)],
        ),
      );

      await cubit.load();

      expect(ids(cubit.state), idsOf([3, 2, 1]));
      expect(cubit.state.newPosts, 0);
    });
  });

  group('refreshIfStale', () {
    setUp(() async {
      stubCached(snapshotOf([2, 1]));
      when(
        () => timeline.sinceRefresh(feed),
      ).thenReturn(const Duration(seconds: 5));
      await cubit.load();
      clearInteractions(timeline);
    });

    test('20 s after the last refresh sends nothing, 61 s sends one', () async {
      when(
        () => timeline.sinceRefreshAttempt(feed),
      ).thenReturn(const Duration(seconds: 20));
      await cubit.refreshIfStale();
      verifyNever(() => timeline.refresh(feed));

      when(
        () => timeline.sinceRefreshAttempt(feed),
      ).thenReturn(const Duration(seconds: 61));
      stubRefresh(snapshotOf([2, 1]));
      await cubit.refreshIfStale();
      verify(() => timeline.refresh(feed)).called(1);
    });

    test('two refreshes returning the same new post count it once', () async {
      when(() => timeline.sinceRefreshAttempt(feed)).thenReturn(null);
      stubRefresh(snapshotOf([3, 2, 1]));
      await cubit.refreshIfStale();
      await cubit.refreshIfStale();

      expect(cubit.state.newPosts, 1);
      expect(ids(cubit.state), idsOf([2, 1]));
    });

    test('a pull shows new posts directly and clears the pill', () async {
      when(() => timeline.sinceRefreshAttempt(feed)).thenReturn(null);
      stubRefresh(snapshotOf([3, 2, 1]));
      await cubit.refreshIfStale();
      expect(cubit.state.newPosts, 1);

      stubRefresh(snapshotOf([4, 3, 2, 1]));
      await cubit.refresh();

      expect(ids(cubit.state), idsOf([4, 3, 2, 1]));
      expect(cubit.state.newPosts, 0);
    });

    test('skipped at the retention size (the store would trim the list)',
        () async {
      final big = snapshotOf([for (var i = kTimelineRetention; i >= 1; i--) i]);
      stubCached(big);
      final other = build();
      addTearDown(other.close);
      when(() => timeline.sinceRefreshAttempt(feed)).thenReturn(null);
      stubRefresh(big);
      await other.load();
      clearInteractions(timeline);

      await other.refreshIfStale();

      verifyNever(() => timeline.refresh(feed));
    });
  });

  group('rate limiting', () {
    test('a daily limit keeps the cache under a notice and stops asking',
        () async {
      stubCached(snapshotOf([2, 1], older: 'o1'));
      const daily = RateLimitedException(
        'limited',
        retryAfter: Duration(hours: 2),
        limitName: 'read_budget_daily',
      );
      when(() => timeline.refresh(feed)).thenAnswer((_) async => throw daily);

      await cubit.load();

      expect(cubit.state.status, TimelineStatus.ready);
      expect(ids(cubit.state), idsOf([2, 1]));
      expect(cubit.state.notice, isA<RateLimitedException>());
      expect((cubit.state.notice! as RateLimitedException).isDaily, isTrue);

      // The repository now reports the hold: no RPC is sent before it ends.
      when(() => timeline.rateLimitedFor()).thenReturn(
        const RateLimitedException(
          'limited',
          retryAfter: Duration(hours: 2),
          limitName: 'read_budget_daily',
        ),
      );
      clearInteractions(timeline);
      await cubit.refreshIfStale();
      await cubit.refresh();
      await cubit.loadMore();
      verifyNever(() => timeline.refresh(feed));
      verifyNever(() => timeline.loadOlder(feed));
    });

    test('with nothing cached it is a blocking error', () async {
      stubCached(const TimelineSnapshot());
      when(
        () => timeline.refresh(feed),
      ).thenAnswer((_) async => throw const NetworkException('offline'));

      await cubit.load();

      expect(cubit.state.status, TimelineStatus.error);
      expect(cubit.state.error, isA<NetworkException>());
    });

    test('a later successful refresh clears the notice', () async {
      stubCached(snapshotOf([2, 1]));
      when(
        () => timeline.refresh(feed),
      ).thenAnswer((_) async => throw const NetworkException('offline'));
      await cubit.load();
      expect(cubit.state.notice, isA<NetworkException>());

      stubRefresh(snapshotOf([2, 1]));
      await cubit.refresh();

      expect(cubit.state.notice, isNull);
    });
  });

  group('older pages and gaps', () {
    setUp(() async {
      stubCached(snapshotOf([5, 4], older: 'o1'));
      when(
        () => timeline.sinceRefresh(feed),
      ).thenReturn(const Duration(seconds: 1));
      await cubit.load();
    });

    test('loadMore appends the next page once, even if called twice',
        () async {
      final page = Completer<TimelineSnapshot>();
      when(() => timeline.loadOlder(feed)).thenAnswer((_) => page.future);

      final first = cubit.loadMore();
      final second = cubit.loadMore();
      expect(cubit.state.loadingMore, isTrue);
      page.complete(snapshotOf([5, 4, 3, 2]));
      await Future.wait([first, second]);

      verify(() => timeline.loadOlder(feed)).called(1);
      expect(ids(cubit.state), idsOf([5, 4, 3, 2]));
      expect(cubit.state.hasMore, isFalse);
      expect(cubit.state.loadingMore, isFalse);
    });

    test('a failed page does not retry by itself; Retry does', () async {
      when(
        () => timeline.loadOlder(feed),
      ).thenAnswer((_) async => throw const NetworkException('offline'));
      await cubit.loadMore();
      expect(cubit.state.loadMoreFailed, isTrue);

      await cubit.loadMore();
      verify(() => timeline.loadOlder(feed)).called(1);

      when(
        () => timeline.loadOlder(feed),
      ).thenAnswer((_) async => snapshotOf([5, 4, 3]));
      await cubit.retryLoadMore();
      expect(ids(cubit.state), idsOf([5, 4, 3]));
      expect(cubit.state.loadMoreFailed, isFalse);
    });

    test('fillGap sends one call and the gap row is replaced', () async {
      final gap = gapEntry(4);
      stubCached(snapshotOf([5, 4], gapAfter: {4: gap}));
      final other = build();
      addTearDown(other.close);
      await other.load();
      expect(ids(other.state), [postId(5), postId(4), 'gap']);

      when(
        () => timeline.fillGap(feed, gap.itemKey),
      ).thenAnswer((_) async => snapshotOf([5, 4, 3, 2]));
      await other.fillGap(gap.itemKey);

      verify(() => timeline.fillGap(feed, gap.itemKey)).called(1);
      expect(ids(other.state), idsOf([5, 4, 3, 2]));
      expect(other.state.loadingGapKey, isNull);
    });
  });

  group('local changes', () {
    setUp(() async {
      stubCached(
        TimelineSnapshot(
          entries: [postEntry(3, authorId: 'a'), postEntry(2), postEntry(1)],
        ),
      );
      when(
        () => timeline.sinceRefresh(feed),
      ).thenReturn(const Duration(seconds: 1));
      await cubit.load();
    });

    test('hideAuthor and restoreAuthor (D6) work without a refetch', () {
      cubit.hideAuthor('a');
      expect(ids(cubit.state), idsOf([2, 1]));

      cubit.restoreAuthor('a');
      expect(ids(cubit.state), idsOf([3, 2, 1]));
      verifyNever(() => timeline.refresh(feed));
    });

    test('a post removed elsewhere leaves the list', () async {
      removed.add(postId(2));
      await Future<void>.delayed(Duration.zero);
      expect(ids(cubit.state), idsOf([3, 1]));
    });

    test('delete is optimistic, then final and reported', () async {
      final done = Completer<void>();
      when(
        () => posts.deletePost(
          postId: postId(2),
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      ).thenAnswer((_) => done.future);

      final future = cubit.deletePost(postId(2));
      expect(ids(cubit.state), idsOf([3, 1]));
      done.complete();
      await future;

      expect(ids(cubit.state), idsOf([3, 1]));
      expect(deleted.single.post.postId, postId(2));
    });

    test('a failed delete restores the post and a retry reuses the key',
        () async {
      var calls = 0;
      when(
        () => posts.deletePost(
          postId: postId(2),
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      ).thenAnswer((_) async {
        calls++;
        if (calls == 1) throw const NetworkException('offline');
      });

      await expectLater(
        cubit.deletePost(postId(2)),
        throwsA(isA<NetworkException>()),
      );
      expect(ids(cubit.state), idsOf([3, 2, 1]));
      expect(deleted, isEmpty);

      await cubit.deletePost(postId(2));
      final keys = verify(
        () => posts.deletePost(
          postId: postId(2),
          idempotencyKey: captureAny(named: 'idempotencyKey'),
        ),
      ).captured;
      expect(keys, hasLength(2));
      expect(keys[0], keys[1]);
    });
  });
}
