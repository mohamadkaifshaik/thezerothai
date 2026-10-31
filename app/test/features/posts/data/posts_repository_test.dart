import 'dart:async';

import 'package:connectrpc/connect.dart' as connect;
import 'package:drift/native.dart';
import 'package:dzeroth/core/network/api_client.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/network/rate_limit_hold.dart';
import 'package:dzeroth/core/storage/app_database.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/features/posts/domain/composer_attachment_rules.dart';
import 'package:dzeroth/features/posts/domain/composer_draft.dart';
import 'package:dzeroth/features/posts/domain/posts_feature_flag.dart';
import 'package:dzeroth/features/posts/domain/reply_audience.dart';
import 'package:dzeroth/features/timeline/data/timeline_repository.dart';
import 'package:dzeroth/features/timeline/data/timeline_store.dart';
import 'package:dzeroth/features/timeline/domain/feed_key.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pbenum.dart'
    show ReplyPolicy;
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_transport.dart';
import '../../../support/posts_fixtures.dart';

const _create = '/dzeroth.posts.v1.PostService/CreatePost';
const _get = '/dzeroth.posts.v1.PostService/GetPost';

void main() {
  late AppDatabase db;
  late TimelineStore store;
  late FakeTransport transport;
  late PostsRepository repo;
  late PostsFeatureGate gate;
  late List<Object> requests;
  late Object Function(String procedure) answer;
  var postsOn = true;

  setUp(() {
    postsOn = true;
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
    gate = PostsFeatureGate(isPostsEnabled: () => postsOn);
    repo = PostsRepository(
      apiClient: ApiClient.withTransport(transport),
      store: store,
      gate: gate,
    );
  });

  tearDown(() => db.close());

  Future<void> seed(FeedKey feed, List<int> ids) async {
    await store.applyColdOpen(
      feed,
      posts: [for (final i in ids) postView(i)],
      sinceToken: 's',
      nextPageToken: '',
      session: store.session,
    );
  }

  List<String> cachedIds(TimelineSnapshot s) => [
    for (final p in s.posts) p.post.postId,
  ];

  test(
    'createPost sends the request and prepends to loaded feeds only',
    () async {
      await seed(const FeedKey.home(), [5, 4]);
      // The author's Posts tab was never opened: it must stay empty.
      answer = (_) => pb.CreatePostResponse(post: postView(9, authorId: 'me'));

      final view = await repo.createPost(idempotencyKey: 'k1', text: 'hello');

      expect(view.post.postId, postId(9));
      final sent = requests.single as pb.CreatePostRequest;
      expect(sent.idempotencyKey, 'k1');
      expect(sent.text, 'hello');
      expect(cachedIds(await store.read(const FeedKey.home())), [
        postId(9),
        postId(5),
        postId(4),
      ]);
      expect((await store.read(FeedKey.user('me'))).entries, isEmpty);
    },
  );

  test('a post created while the session ends is not written back', () async {
    await seed(const FeedKey.home(), [5]);
    final release = Completer<void>();
    final slow = PostsRepository(
      apiClient: ApiClient.withTransport(
        FakeTransport((_, _) async {
          await release.future;
          return pb.CreatePostResponse(post: postView(9, authorId: 'me'));
        }),
      ),
      store: store,
      gate: gate,
    );

    final pending = slow.createPost(idempotencyKey: 'k', text: 't');
    await Future<void>.delayed(Duration.zero);
    store.endSession();
    release.complete();
    await pending;

    expect(cachedIds(await store.read(const FeedKey.home())), [postId(5)]);
  });

  test('a created reply is not inserted into Home or Posts feeds', () async {
    await seed(const FeedKey.home(), [5]);
    answer = (_) => pb.CreatePostResponse(
      post: pb.PostView(
        post: pb.Post(
          postId: postId(9),
          replyToPostId: postId(5),
          author: common.AuthorSnapshot(userId: 'me'),
        ),
      ),
    );

    await repo.createPost(
      idempotencyKey: 'k',
      text: 'r',
      replyToPostId: postId(5),
    );

    expect(cachedIds(await store.read(const FeedKey.home())), [postId(5)]);
  });

  group('reply_policy (ADR-0021)', () {
    pb.CreatePostRequest lastRequest() =>
        requests.whereType<pb.CreatePostRequest>().last;

    test('is UNSPECIFIED unless a policy is passed', () async {
      answer = (_) => pb.CreatePostResponse(post: postView(1));
      await repo.createPost(idempotencyKey: 'k', text: 't');
      expect(lastRequest().replyPolicy, ReplyPolicy.REPLY_POLICY_UNSPECIFIED);
    });

    test('a chosen policy goes on the wire', () async {
      answer = (_) => pb.CreatePostResponse(post: postView(1));
      await repo.createPost(
        idempotencyKey: 'k',
        text: 't',
        replyPolicy: ReplyPolicy.REPLY_POLICY_FOLLOWING,
      );
      expect(lastRequest().replyPolicy, ReplyPolicy.REPLY_POLICY_FOLLOWING);
    });

    test('FEATURE_DISABLED feature=reply_audience stops later sends of a '
        'policy, but not plain posts', () async {
      answer = (_) => serverError(
        connect.Code.failedPrecondition,
        common.ErrorReason.ERROR_REASON_FEATURE_DISABLED,
        metadata: {'feature': kFeatureReplyAudience},
      );
      await expectLater(
        repo.createPost(
          idempotencyKey: 'k',
          text: 't',
          replyPolicy: ReplyPolicy.REPLY_POLICY_MENTIONED_ONLY,
        ),
        throwsA(isA<FeatureDisabledException>()),
      );
      expect(gate.postsEnabled, isTrue);
      expect(gate.subFeatureEnabled(kFeatureReplyAudience), isFalse);

      transport.calledProcedures.clear();
      await expectLater(
        repo.createPost(
          idempotencyKey: 'k2',
          text: 't',
          replyPolicy: ReplyPolicy.REPLY_POLICY_FOLLOWING,
        ),
        throwsA(isA<FeatureDisabledException>()),
      );
      expect(transport.calledProcedures, isEmpty);

      answer = (_) => pb.CreatePostResponse(post: postView(1));
      await repo.createPost(idempotencyKey: 'k3', text: 'plain');
      expect(transport.calledProcedures, [_create]);
    });
  });

  group('poll (ADR-0029)', () {
    pb.CreatePostRequest lastRequest() =>
        requests.whereType<pb.CreatePostRequest>().last;

    test('goes on the wire as a PollDraft; no poll sends none', () async {
      answer = (_) => pb.CreatePostResponse(post: postView(1));
      await repo.createPost(
        idempotencyKey: 'k',
        text: 'Best colour?',
        poll: const DraftPoll(choices: ['Red', 'Blue'], durationMinutes: 90),
      );
      expect(lastRequest().poll.choices, ['Red', 'Blue']);
      expect(lastRequest().poll.durationMinutes, 90);
      await repo.createPost(idempotencyKey: 'k2', text: 'plain');
      expect(lastRequest().hasPoll(), isFalse);
    });

    test(
      'FEATURE_DISABLED feature=polls stops later polls, not plain posts',
      () async {
        answer = (_) => serverError(
          connect.Code.failedPrecondition,
          common.ErrorReason.ERROR_REASON_FEATURE_DISABLED,
          metadata: {'feature': kFeaturePolls},
        );
        const poll = DraftPoll(choices: ['a', 'b'], durationMinutes: 60);
        await expectLater(
          repo.createPost(idempotencyKey: 'k', text: 't', poll: poll),
          throwsA(isA<FeatureDisabledException>()),
        );
        expect(gate.postsEnabled, isTrue);
        expect(gate.subFeatureEnabled(kFeaturePolls), isFalse);

        transport.calledProcedures.clear();
        await expectLater(
          repo.createPost(idempotencyKey: 'k2', text: 't', poll: poll),
          throwsA(isA<FeatureDisabledException>()),
        );
        expect(transport.calledProcedures, isEmpty);

        answer = (_) => pb.CreatePostResponse(post: postView(1));
        await repo.createPost(idempotencyKey: 'k3', text: 'plain');
        expect(transport.calledProcedures, [_create]);
      },
    );
  });

  group('getThread (FEATURE_REPLIES)', () {
    const getThread = '/dzeroth.posts.v1.PostService/GetThread';

    test(
      'sends the post id, token and page size and returns the page',
      () async {
        answer = (_) => pb.GetThreadResponse(
          focal: postView(1),
          parentUnavailable: true,
          nextPageToken: 'n2',
        );

        final r = await repo.getThread(
          postId(1),
          pageToken: 'n1',
          pageSize: 10,
        );

        final sent = requests.single as pb.GetThreadRequest;
        expect(sent.postId, postId(1));
        expect(sent.pageToken, 'n1');
        expect(sent.pageSize, 10);
        expect(transport.calledProcedures, [getThread]);
        expect(r.parentUnavailable, isTrue);
        expect(r.nextPageToken, 'n2');
      },
    );

    test(
      'FEATURE_DISABLED hides only replies and sends nothing after',
      () async {
        answer = (_) => serverError(
          connect.Code.failedPrecondition,
          common.ErrorReason.ERROR_REASON_FEATURE_DISABLED,
          metadata: {'feature': 'replies'},
        );
        await expectLater(
          repo.getThread(postId(1)),
          throwsA(isA<FeatureDisabledException>()),
        );
        expect(gate.subFeatureEnabled(kPostsSubFeatureReplies), isFalse);
        expect(gate.postsEnabled, isTrue);

        requests.clear();
        await expectLater(
          repo.getThread(postId(1)),
          throwsA(isA<FeatureDisabledException>()),
        );
        expect(requests, isEmpty);
      },
    );

    test('NOT_FOUND prunes the focal post from cached feeds', () async {
      await seed(const FeedKey.home(), [1, 2]);
      answer = (_) =>
          connect.ConnectException(connect.Code.notFound, 'post not found');

      await expectLater(
        repo.getThread(postId(1)),
        throwsA(isA<NotFoundException>()),
      );

      expect(cachedIds(await store.read(const FeedKey.home())), [postId(2)]);
    });
  });

  group('RATE_LIMITED hold shared across reads (ADR-0010 D5)', () {
    const getThread = '/dzeroth.posts.v1.PostService/GetThread';
    const getHome = '/dzeroth.timeline.v1.TimelineService/GetHomeTimeline';
    var clock = Duration.zero;
    late RateLimitHold hold;
    late PostsRepository posts;
    late TimelineRepository timeline;

    Object daily() => serverError(
      connect.Code.resourceExhausted,
      common.ErrorReason.ERROR_REASON_RATE_LIMITED,
      metadata: {'limit': 'read_budget_daily'},
    );

    setUp(() {
      clock = Duration.zero;
      hold = RateLimitHold(monotonic: () => clock);
      final api = ApiClient.withTransport(transport);
      posts = PostsRepository(
        apiClient: api,
        store: store,
        gate: gate,
        rateLimitHold: hold,
      );
      timeline = TimelineRepository(
        apiClient: api,
        store: store,
        gate: gate,
        rateLimitHold: hold,
      );
    });

    test('a held thread load or refresh sends nothing', () async {
      answer = (_) => daily();
      await expectLater(
        posts.getThread(postId(1)),
        throwsA(isA<RateLimitedException>()),
      );
      expect(transport.calledProcedures, [getThread]);

      clock = const Duration(minutes: 1);
      await expectLater(
        posts.getThread(postId(1)),
        throwsA(
          isA<RateLimitedException>().having(
            (e) => e.retryAfter,
            'retryAfter',
            const Duration(minutes: 4),
          ),
        ),
      );
      await expectLater(
        posts.getThread(postId(1), pageToken: 't'),
        throwsA(isA<RateLimitedException>()),
      );
      expect(transport.calledProcedures, [getThread]); // still one RPC

      clock = const Duration(minutes: 6);
      answer = (_) => pb.GetThreadResponse(focal: postView(1));
      await posts.getThread(postId(1));
      expect(transport.calledProcedures, [getThread, getThread]);
    });

    test('a thread RATE_LIMITED holds a Home refresh and vice versa', () async {
      answer = (_) => daily();
      await expectLater(
        posts.getThread(postId(1)),
        throwsA(isA<RateLimitedException>()),
      );
      expect(timeline.rateLimitedFor(), isNotNull);
      await expectLater(
        timeline.refresh(const FeedKey.home()),
        throwsA(isA<RateLimitedException>()),
      );
      expect(transport.calledProcedures, [getThread]);

      hold.clear();
      await expectLater(
        timeline.refresh(const FeedKey.home()),
        throwsA(isA<RateLimitedException>()),
      );
      expect(transport.calledProcedures, [getThread, getHome]);
      await expectLater(
        posts.getThread(postId(1)),
        throwsA(isA<RateLimitedException>()),
      );
      expect(transport.calledProcedures, [getThread, getHome]);
    });

    test(
      'writes still send while reads are held (create and delete)',
      () async {
        answer = (_) => daily();
        await expectLater(
          posts.getThread(postId(1)),
          throwsA(isA<RateLimitedException>()),
        );
        expect(hold.check(), isNotNull);

        answer = (p) => p == _create
            ? pb.CreatePostResponse(post: postView(9, authorId: 'me'))
            : pb.DeletePostResponse();
        await posts.createPost(idempotencyKey: 'k1', text: 'hello');
        await posts.deletePost(postId: postId(9), idempotencyKey: 'k2');

        expect(transport.calledProcedures, [
          getThread,
          _create,
          '/dzeroth.posts.v1.PostService/DeletePost',
        ]);
        // The write neither released nor extended the read hold.
        expect(hold.check()?.retryAfter, const Duration(minutes: 5));
      },
    );

    test('a read_budget_inflight answer leaves the hold empty', () async {
      answer = (_) => serverError(
        connect.Code.resourceExhausted,
        common.ErrorReason.ERROR_REASON_RATE_LIMITED,
        metadata: {'limit': 'read_budget_inflight'},
      );
      await expectLater(
        posts.getThread(postId(1)),
        throwsA(isA<RateLimitedException>()),
      );
      expect(hold.check(), isNull);
      expect(timeline.rateLimitedFor(), isNull);

      // Nothing is held back: the next read is sent.
      answer = (_) => pb.GetThreadResponse(focal: postView(1));
      await posts.getThread(postId(1));
      expect(transport.calledProcedures, [getThread, getThread]);
    });

    test('clearSession releases the hold for every repository', () async {
      answer = (_) => daily();
      await expectLater(
        posts.getThread(postId(1)),
        throwsA(isA<RateLimitedException>()),
      );

      timeline.clearSession();

      expect(hold.check(), isNull);
    });
  });

  test('deletePost removes the post from every cached feed', () async {
    await seed(const FeedKey.home(), [5, 4]);
    await seed(FeedKey.user('u1'), [5, 3]);
    answer = (_) => pb.DeletePostResponse();

    await repo.deletePost(postId: postId(5), idempotencyKey: 'k');

    expect(cachedIds(await store.read(const FeedKey.home())), [postId(4)]);
    expect(cachedIds(await store.read(FeedKey.user('u1'))), [postId(3)]);
  });

  test('getPost NOT_FOUND prunes the post from every cached feed', () async {
    await seed(const FeedKey.home(), [5, 4]);
    await seed(FeedKey.user('u1'), [5]);
    answer = (_) =>
        connect.ConnectException(connect.Code.notFound, 'post not found');

    await expectLater(
      repo.getPost(postId(5)),
      throwsA(isA<NotFoundException>()),
    );

    expect(cachedIds(await store.read(const FeedKey.home())), [postId(4)]);
    expect((await store.read(FeedKey.user('u1'))).entries, isEmpty);
  });

  test('removedPosts announces a deleted post and a NOT_FOUND post', () async {
    final seen = <String>[];
    final sub = repo.removedPosts.listen(seen.add);
    answer = (_) => pb.DeletePostResponse();
    await repo.deletePost(postId: postId(5), idempotencyKey: 'k');
    answer = (_) =>
        connect.ConnectException(connect.Code.notFound, 'post not found');
    await expectLater(
      repo.getPost(postId(6)),
      throwsA(isA<NotFoundException>()),
    );
    await Future<void>.delayed(Duration.zero);

    expect(seen, [postId(5), postId(6)]);
    await sub.cancel();
  });

  test('getPost returns the post and leaves caches alone', () async {
    await seed(const FeedKey.home(), [5]);
    answer = (p) {
      expect(p, _get);
      return pb.GetPostResponse(post: postView(5));
    };
    final view = await repo.getPost(postId(5));
    expect(view.post.postId, postId(5));
    expect(cachedIds(await store.read(const FeedKey.home())), [postId(5)]);
  });

  group('flag plumbing', () {
    test('flag off: no posts RPC is ever sent', () async {
      postsOn = false;
      await expectLater(
        repo.createPost(idempotencyKey: 'k', text: 't'),
        throwsA(isA<FeatureDisabledException>()),
      );
      await expectLater(
        repo.getPost(postId(1)),
        throwsA(isA<FeatureDisabledException>()),
      );
      await expectLater(
        repo.deletePost(postId: postId(1), idempotencyKey: 'k'),
        throwsA(isA<FeatureDisabledException>()),
      );
      expect(transport.calledProcedures, isEmpty);
    });

    test('FEATURE_DISABLED feature=media hides only media; posts stay '
        'enabled', () async {
      answer = (p) => serverError(
        connect.Code.failedPrecondition,
        common.ErrorReason.ERROR_REASON_FEATURE_DISABLED,
        metadata: {'feature': 'media'},
      );

      await expectLater(
        repo.createPost(idempotencyKey: 'k', text: 't', mediaIds: ['m1']),
        throwsA(
          isA<FeatureDisabledException>().having(
            (e) => e.feature,
            'feature',
            'media',
          ),
        ),
      );

      expect(gate.postsEnabled, isTrue);
      expect(gate.subFeatureEnabled(kPostsSubFeatureMedia), isFalse);
      expect(gate.subFeatureEnabled(kPostsSubFeatureReplies), isTrue);
      expect(gate.subFeatureEnabled(kPostsSubFeatureQuotes), isTrue);

      // Another media post is not even sent...
      transport.calledProcedures.clear();
      await expectLater(
        repo.createPost(idempotencyKey: 'k2', text: 't', mediaIds: ['m1']),
        throwsA(isA<FeatureDisabledException>()),
      );
      expect(transport.calledProcedures, isEmpty);

      // ...but a plain post and other posts RPCs still are.
      answer = (p) => p == _create
          ? pb.CreatePostResponse(post: postView(1))
          : pb.GetPostResponse(post: postView(1));
      await repo.createPost(idempotencyKey: 'k3', text: 'plain');
      await repo.getPost(postId(1));
      expect(transport.calledProcedures, [_create, _get]);
    });

    test('FEATURE_DISABLED feature=replies and quotes are tracked '
        'independently', () async {
      answer = (_) => serverError(
        connect.Code.failedPrecondition,
        common.ErrorReason.ERROR_REASON_FEATURE_DISABLED,
        metadata: {'feature': 'replies'},
      );
      await expectLater(
        repo.createPost(
          idempotencyKey: 'k',
          text: 't',
          replyToPostId: postId(1),
        ),
        throwsA(isA<FeatureDisabledException>()),
      );
      expect(gate.subFeatureEnabled(kPostsSubFeatureReplies), isFalse);
      expect(gate.subFeatureEnabled(kPostsSubFeatureQuotes), isTrue);
      expect(gate.postsEnabled, isTrue);
    });

    test(
      'FEATURE_DISABLED without feature hides all of posts until reset',
      () async {
        answer = (_) => serverError(
          connect.Code.failedPrecondition,
          common.ErrorReason.ERROR_REASON_FEATURE_DISABLED,
        );
        await expectLater(
          repo.createPost(idempotencyKey: 'k', text: 't'),
          throwsA(isA<FeatureDisabledException>()),
        );
        expect(gate.postsEnabled, isFalse);

        gate.reset();
        expect(gate.postsEnabled, isTrue);
      },
    );

    test('an unexpected error is reported once (Crashlytics hook)', () async {
      final reported = <Object>[];
      gate = PostsFeatureGate(
        isPostsEnabled: () => true,
        onUnexpectedError: (e, _) => reported.add(e),
      );
      repo = PostsRepository(
        apiClient: ApiClient.withTransport(transport),
        store: store,
        gate: gate,
      );
      answer = (_) => connect.ConnectException(connect.Code.internal, 'boom');

      await expectLater(
        repo.getPost(postId(1)),
        throwsA(isA<UnknownApiException>()),
      );
      expect(reported, hasLength(1));
    });
  });
}
