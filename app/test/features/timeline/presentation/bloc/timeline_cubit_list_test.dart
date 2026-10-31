import 'dart:async';

import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/timeline/domain/feed_key.dart';
import 'package:dzeroth/features/timeline/presentation/bloc/timeline_cubit.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../../support/timeline_fixtures.dart';

/// W5-12: a list feed the server answers NOT_FOUND for leaves nothing on screen.
void main() {
  final feed = FeedKey.list('77');
  late MockTimelineRepository timeline;
  late MockPostsRepository posts;
  late TimelineCubit cubit;

  setUp(() {
    timeline = MockTimelineRepository();
    posts = MockPostsRepository();
    when(() => posts.removedPosts).thenAnswer((_) => const Stream.empty());
    when(() => timeline.sinceRefresh(feed)).thenReturn(null);
    when(() => timeline.sinceRefreshAttempt(feed)).thenReturn(null);
    when(() => timeline.rateLimitedFor()).thenReturn(null);
    when(() => timeline.cached(feed))
        .thenAnswer((_) async => snapshotOf([2, 1]));
    cubit = TimelineCubit(feed: feed, timeline: timeline, posts: posts);
  });

  tearDown(() => cubit.close());

  test(
    'NOT_FOUND on refresh clears the cached rows and is unavailable',
    () async {
      when(() => timeline.refresh(feed))
          .thenThrow(const NotFoundException('gone'));

      await cubit.load();

      expect(cubit.state.unavailable, isTrue);
      expect(cubit.state.entries, isEmpty);
      expect(cubit.state.notice, isNull);
      expect(cubit.state.refreshing, isFalse);
    },
  );

  test('NOT_FOUND on an older page is unavailable too', () async {
    when(() => timeline.refresh(feed))
        .thenAnswer((_) async => snapshotOf([2, 1], older: 'o'));
    await cubit.load();
    when(() => timeline.loadOlder(feed))
        .thenThrow(const NotFoundException('gone'));

    await cubit.loadMore();

    expect(cubit.state.unavailable, isTrue);
    expect(cubit.state.entries, isEmpty);
  });

  test('the foreground tick sends nothing while unavailable', () async {
    when(() => timeline.refresh(feed))
        .thenThrow(const NotFoundException('gone'));
    await cubit.load();
    clearInteractions(timeline);

    await cubit.refreshIfStale();

    verifyNever(() => timeline.refresh(feed));
  });

  test('a pull that succeeds brings the feed back', () async {
    when(() => timeline.refresh(feed))
        .thenThrow(const NotFoundException('gone'));
    await cubit.load();
    when(() => timeline.refresh(feed)).thenAnswer((_) async => snapshotOf([3]));

    await cubit.refresh();

    expect(cubit.state.unavailable, isFalse);
    expect(cubit.state.entries, isNotEmpty);
  });

  test('another error keeps the cached rows under a notice', () async {
    when(() => timeline.refresh(feed)).thenThrow(const NetworkException('off'));

    await cubit.load();

    expect(cubit.state.unavailable, isFalse);
    expect(cubit.state.entries, isNotEmpty);
    expect(cubit.state.notice, isA<NetworkException>());
  });

  test('NOT_FOUND on Home is not "unavailable"', () async {
    final home = TimelineCubit(
      feed: const FeedKey.home(),
      timeline: timeline,
      posts: posts,
    );
    when(() => timeline.sinceRefresh(const FeedKey.home())).thenReturn(null);
    when(() => timeline.cached(const FeedKey.home()))
        .thenAnswer((_) async => snapshotOf([1]));
    when(() => timeline.refresh(const FeedKey.home()))
        .thenThrow(const NotFoundException('x'));

    await home.load();

    expect(home.state.unavailable, isFalse);
    await home.close();
  });
}
