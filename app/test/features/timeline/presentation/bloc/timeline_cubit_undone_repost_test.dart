import 'dart:async';

import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/engagement/data/engagement_repository.dart';
import 'package:dzeroth/features/engagement/domain/engagement_entry.dart';
import 'package:dzeroth/features/engagement/presentation/bloc/engagement_cubit.dart';
import 'package:dzeroth/features/timeline/data/timeline_store.dart';
import 'package:dzeroth/features/timeline/domain/feed_key.dart';
import 'package:dzeroth/features/timeline/presentation/bloc/timeline_cubit.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/engagement/v1/engagement.pb.dart' as eng;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pbenum.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../../support/posts_fixtures.dart';
import '../../../../support/timeline_fixtures.dart';

class _MockEngagementRepository extends Mock implements EngagementRepository {}

/// W3-41c: an undone REPOST row leaves the own profile tab locally.
void main() {
  final feed = FeedKey.user('me');
  late MockTimelineRepository timeline;
  late MockPostsRepository posts;
  late _MockEngagementRepository repo;
  late StreamController<String> removed;
  late EngagementCubit engagement;
  late TimelineCubit cubit;

  // The REPOST row (id 7) of the original (id 1), written by `me`.
  TimelineEntry repostEntry({String author = 'me'}) {
    final view = pb.PostView(
      repostedByViewer: true,
      post: pb.Post(
        postId: postId(7),
        kind: PostKind.POST_KIND_REPOST,
        author: common.AuthorSnapshot(userId: author, handle: 'hme'),
        embedded: pb.EmbeddedPost(
          postId: postId(1),
          author: common.AuthorSnapshot(userId: 'u1'),
        ),
      ),
    );
    return TimelineEntry.post(postId(7), postId(7), view);
  }

  const shown = EngagementEntry(liked: false, reposted: true);

  When<Future<eng.PostEngagement>> undo() => when(
    () => repo.undoRepost(
      postId: any(named: 'postId'),
      idempotencyKey: any(named: 'idempotencyKey'),
    ),
  );

  setUp(() async {
    timeline = MockTimelineRepository();
    posts = MockPostsRepository();
    repo = _MockEngagementRepository();
    removed = StreamController<String>.broadcast();
    when(() => posts.removedPosts).thenAnswer((_) => removed.stream);
    when(() => posts.forgetPostLocally(any())).thenAnswer((_) async {});
    when(() => timeline.sinceRefresh(feed))
        .thenReturn(const Duration(seconds: 5));
    when(() => timeline.cached(feed)).thenAnswer(
      (_) async => TimelineSnapshot(entries: [repostEntry()], sinceToken: 's'),
    );
    engagement = EngagementCubit(repository: repo);
    cubit = TimelineCubit(
      feed: feed,
      timeline: timeline,
      posts: posts,
      viewerUserId: 'me',
      engagement: engagement,
    );
    await cubit.load();
  });

  tearDown(() async {
    await cubit.close();
    await engagement.close();
    await removed.close();
  });

  test(
    'a confirmed undo removes the row, locally, with no extra RPC',
    () async {
      undo().thenAnswer(
        (_) async => eng.PostEngagement(
          postId: postId(1),
          repostedByViewer: false,
          repostCount: Int64(0),
        ),
      );
      expect(cubit.state.entries, hasLength(1));

      await engagement.setReposted(postId(1), reposted: false, shown: shown);
      await Future<void>.delayed(Duration.zero);

      expect(cubit.state.entries, isEmpty);
      verify(() => posts.forgetPostLocally(postId(7))).called(1);
      verify(
        () => repo.undoRepost(
          postId: postId(1),
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      ).called(1);
    },
  );

  test(
    'while the undo runs the row stays in the list state (no removal)',
    () async {
      final done = Completer<eng.PostEngagement>();
      undo().thenAnswer((_) => done.future);

      unawaited(
        engagement.setReposted(postId(1), reposted: false, shown: shown),
      );
      await Future<void>.delayed(Duration.zero);

      expect(cubit.state.entries, hasLength(1));
      verifyNever(() => posts.forgetPostLocally(any()));
      done.complete(eng.PostEngagement(postId: postId(1)));
      await Future<void>.delayed(Duration.zero);
    },
  );

  test('a failed undo keeps the row and removes nothing', () async {
    undo().thenThrow(NetworkException('offline'));

    await engagement.setReposted(postId(1), reposted: false, shown: shown);
    await Future<void>.delayed(Duration.zero);

    expect(cubit.state.entries, hasLength(1));
    verifyNever(() => posts.forgetPostLocally(any()));
  });

  test('a REPOST by someone else is left alone', () async {
    when(() => timeline.cached(feed)).thenAnswer(
      (_) async => TimelineSnapshot(
        entries: [repostEntry(author: 'other')],
        sinceToken: 's',
      ),
    );
    await cubit.load();
    undo().thenAnswer(
      (_) async =>
          eng.PostEngagement(postId: postId(1), repostedByViewer: false),
    );

    await engagement.setReposted(postId(1), reposted: false, shown: shown);
    await Future<void>.delayed(Duration.zero);

    expect(cubit.state.entries, hasLength(1));
    verifyNever(() => posts.forgetPostLocally(any()));
  });
}
