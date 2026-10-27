import 'dart:async';

import 'package:dzeroth/features/timeline/data/timeline_store.dart';
import 'package:dzeroth/features/timeline/domain/feed_key.dart';
import 'package:dzeroth/features/timeline/presentation/bloc/timeline_cubit.dart';
import 'package:dzeroth/features/timeline/presentation/bloc/timeline_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../../support/posts_fixtures.dart';
import '../../../../support/timeline_fixtures.dart';

/// W3-17: the profile's Posts tab leaves out the post its Pinned row shows
/// (a filter on the visible rows, like removed and blocked authors).
void main() {
  final feed = FeedKey.user('u1');
  late MockTimelineRepository timeline;
  late MockPostsRepository posts;
  late StreamController<String> removed;
  late TimelineCubit cubit;

  List<String> ids(TimelineState s) => [
    for (final e in s.entries) e.isGap ? 'gap' : e.postView!.post.postId,
  ];
  List<String> idsOf(List<int> n) => [for (final i in n) postId(i)];

  void stubFeed(TimelineSnapshot snapshot) {
    when(() => timeline.cached(feed)).thenAnswer((_) async => snapshot);
    when(() => timeline.refresh(feed)).thenAnswer((_) async => snapshot);
  }

  setUp(() {
    timeline = MockTimelineRepository();
    posts = MockPostsRepository();
    removed = StreamController<String>.broadcast();
    when(() => posts.removedPosts).thenAnswer((_) => removed.stream);
    when(() => timeline.sinceRefresh(feed)).thenReturn(null);
    when(() => timeline.sinceRefreshAttempt(feed)).thenReturn(null);
    when(() => timeline.rateLimitedFor()).thenReturn(null);
    cubit = TimelineCubit(feed: feed, timeline: timeline, posts: posts);
  });

  tearDown(() async {
    await cubit.close();
    await removed.close();
  });

  test('the excluded post is not among the rows from the first load', () async {
    stubFeed(snapshotOf([3, 2, 1]));
    cubit.setExcludedPostId(postId(2));

    await cubit.load();

    expect(ids(cubit.state), idsOf([3, 1]));
  });

  test('excluding later removes the row, clearing brings it back', () async {
    stubFeed(snapshotOf([3, 2, 1]));
    await cubit.load();
    expect(ids(cubit.state), idsOf([3, 2, 1]));

    cubit.setExcludedPostId(postId(3));
    expect(ids(cubit.state), idsOf([2, 1]));

    // Moving the pin: the old one returns, the new one leaves.
    cubit.setExcludedPostId(postId(1));
    expect(ids(cubit.state), idsOf([3, 2]));

    cubit.setExcludedPostId(null);
    expect(ids(cubit.state), idsOf([3, 2, 1]));
    cubit.setExcludedPostId('');
    expect(ids(cubit.state), idsOf([3, 2, 1]));
  });

  test('the same exclusion twice emits nothing new', () async {
    stubFeed(snapshotOf([3, 2, 1]));
    await cubit.load();
    cubit.setExcludedPostId(postId(2));
    final emitted = <TimelineState>[];
    final sub = cubit.stream.listen(emitted.add);

    cubit.setExcludedPostId(postId(2));
    await Future<void>.delayed(Duration.zero);

    expect(emitted, isEmpty);
    await sub.cancel();
  });

  test('a refresh keeps the exclusion and never counts it as new', () async {
    stubFeed(snapshotOf([2, 1]));
    cubit.setExcludedPostId(postId(2));
    await cubit.load();
    expect(ids(cubit.state), idsOf([1]));

    when(() => timeline.refresh(feed))
        .thenAnswer((_) async => snapshotOf([3, 2, 1], since: 's2'));
    await cubit.refresh();

    expect(ids(cubit.state), idsOf([3, 1]));
    expect(cubit.state.newPosts, 0);
  });

  test('a gap row under only excluded posts does not lead the list', () async {
    stubFeed(
      TimelineSnapshot(
        entries: [postEntry(2), gapEntry(2), postEntry(1)],
        sinceToken: 's',
        olderPageToken: '',
      ),
    );
    cubit.setExcludedPostId(postId(2));

    await cubit.load();

    expect(ids(cubit.state), idsOf([1]));
  });
}
