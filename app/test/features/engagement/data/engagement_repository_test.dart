import 'package:connectrpc/connect.dart' as connect;
import 'package:drift/native.dart';
import 'package:dzeroth/core/feature_flags/service_feature_gate.dart';
import 'package:dzeroth/core/network/api_client.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/storage/app_database.dart';
import 'package:dzeroth/features/engagement/data/engagement_repository.dart';
import 'package:dzeroth/features/timeline/data/timeline_store.dart';
import 'package:dzeroth/features/timeline/domain/feed_key.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/engagement/v1/engagement.pb.dart' as pb;
import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_transport.dart';
import '../../../support/posts_fixtures.dart';

const _service = '/dzeroth.engagement.v1.EngagementService/';

void main() {
  late AppDatabase db;
  late TimelineStore store;
  late FakeTransport transport;
  late EngagementRepository repo;
  late List<Object> requests;
  late Object Function(String procedure) answer;
  var enabled = true;
  var refreshAsked = 0;

  pb.PostEngagement result({
    bool liked = false,
    bool reposted = false,
    int likes = 0,
    int reposts = 0,
  }) => pb.PostEngagement(
    postId: postId(1),
    likeCount: Int64(likes),
    repostCount: Int64(reposts),
    likedByViewer: liked,
    repostedByViewer: reposted,
  );

  setUp(() {
    enabled = true;
    refreshAsked = 0;
    db = AppDatabase.forTesting(NativeDatabase.memory());
    store = TimelineStore(db);
    requests = [];
    answer = (_) => throw StateError('unscripted');
    transport = FakeTransport((procedure, input) async {
      requests.add(input);
      final r = answer(procedure);
      if (r is Exception) throw r;
      return r;
    });
    repo = EngagementRepository(
      apiClient: ApiClient.withTransport(transport),
      gate: ServiceFeatureGate(
        isEnabled: () => enabled,
        onDisabledByServer: () => refreshAsked++,
      ),
      store: store,
    );
  });

  tearDown(() => db.close());

  test(
    'like sends the post and the key, and returns the server answer',
    () async {
      answer = (_) =>
          pb.LikePostResponse(engagement: result(liked: true, likes: 3));

      final out = await repo.like(
        postId: postId(1),
        idempotencyKey: 'k-like-1234567890',
      );

      expect(transport.calledProcedures, ['${_service}LikePost']);
      final sent = requests.single as pb.LikePostRequest;
      expect(sent.postId, postId(1));
      expect(sent.idempotencyKey, 'k-like-1234567890');
      expect(out.likedByViewer, isTrue);
      expect(out.likeCount.toInt(), 3);
    },
  );

  test('unlike, repost and undoRepost call their own RPC', () async {
    answer = (procedure) => switch (procedure) {
      '${_service}UnlikePost' => pb.UnlikePostResponse(engagement: result()),
      '${_service}RepostPost' => pb.RepostPostResponse(
        engagement: result(reposted: true, reposts: 1),
        repostPostId: postId(9),
      ),
      '${_service}UndoRepost' => pb.UndoRepostResponse(engagement: result()),
      _ => throw StateError(procedure),
    };

    await repo.unlike(postId: postId(1), idempotencyKey: 'k1');
    final reposted = await repo.repost(postId: postId(1), idempotencyKey: 'k2');
    await repo.undoRepost(postId: postId(1), idempotencyKey: 'k3');

    expect(reposted.repostedByViewer, isTrue);
    expect(transport.calledProcedures, [
      '${_service}UnlikePost',
      '${_service}RepostPost',
      '${_service}UndoRepost',
    ]);
  });

  test('flag off: 0 RPCs and a typed FeatureDisabledException', () async {
    enabled = false;

    await expectLater(
      repo.like(postId: postId(1), idempotencyKey: 'k'),
      throwsA(isA<FeatureDisabledException>()),
    );
    await expectLater(
      repo.repost(postId: postId(1), idempotencyKey: 'k'),
      throwsA(isA<FeatureDisabledException>()),
    );

    expect(transport.calledProcedures, isEmpty);
    expect(repo.enabled, isFalse);
  });

  test(
    'FEATURE_DISABLED from the server is remembered and asks for a GetMe',
    () async {
      answer = (_) => serverError(
        connect.Code.failedPrecondition,
        common.ErrorReason.ERROR_REASON_FEATURE_DISABLED,
      );

      await expectLater(
        repo.like(postId: postId(1), idempotencyKey: 'k'),
        throwsA(isA<FeatureDisabledException>()),
      );
      expect(refreshAsked, 1);
      expect(repo.enabled, isFalse);

      // The next tap sends nothing.
      await expectLater(
        repo.like(postId: postId(1), idempotencyKey: 'k'),
        throwsA(isA<FeatureDisabledException>()),
      );
      expect(transport.calledProcedures, hasLength(1));
    },
  );

  test('quota, not found and degraded mode become typed exceptions', () async {
    answer = (_) => serverError(
      connect.Code.resourceExhausted,
      common.ErrorReason.ERROR_REASON_QUOTA_EXCEEDED,
      metadata: {'quota': 'likes'},
    );
    await expectLater(
      repo.like(postId: postId(1), idempotencyKey: 'k'),
      throwsA(
        isA<QuotaExceededException>().having((e) => e.quota, 'quota', 'likes'),
      ),
    );

    answer = (_) =>
        connect.ConnectException(connect.Code.notFound, 'post not found');
    await expectLater(
      repo.repost(postId: postId(1), idempotencyKey: 'k'),
      throwsA(isA<NotFoundException>()),
    );
  });

  test(
    'a success is written into every cached copy of that post only',
    () async {
      await store.applyColdOpen(
        const FeedKey.home(),
        posts: [postView(2), postView(1)],
        sinceToken: 's',
        nextPageToken: '',
        session: store.session,
      );
      answer = (_) =>
          pb.LikePostResponse(engagement: result(liked: true, likes: 7));

      await repo.like(postId: postId(1), idempotencyKey: 'k');

      final cached = {
        for (final v in (await store.read(const FeedKey.home())).posts)
          v.post.postId: v,
      };
      expect(cached[postId(1)]!.likedByViewer, isTrue);
      expect(cached[postId(1)]!.post.likeCount.toInt(), 7);
      expect(cached[postId(2)]!.likedByViewer, isFalse);
      expect(cached[postId(2)]!.post.likeCount.toInt(), 0);
    },
  );

  test('a like that lands after sign-out does not write the cache', () async {
    await store.applyColdOpen(
      const FeedKey.home(),
      posts: [postView(1)],
      sinceToken: 's',
      nextPageToken: '',
      session: store.session,
    );
    answer = (_) {
      store.endSession();
      return pb.LikePostResponse(engagement: result(liked: true, likes: 1));
    };

    await repo.like(postId: postId(1), idempotencyKey: 'k');

    final cached = (await store.read(const FeedKey.home())).posts.single;
    expect(cached.likedByViewer, isFalse);
  });
}
