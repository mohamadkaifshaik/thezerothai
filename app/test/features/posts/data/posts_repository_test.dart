import 'package:connectrpc/connect.dart' as connect;
import 'package:drift/native.dart';
import 'package:dzeroth/core/network/api_client.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/storage/app_database.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/features/posts/domain/posts_feature_flag.dart';
import 'package:dzeroth/features/timeline/data/timeline_store.dart';
import 'package:dzeroth/features/timeline/domain/feed_key.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
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
    );
  }

  List<String> cachedIds(TimelineSnapshot s) => [
    for (final p in s.posts) p.post.postId,
  ];

  test('createPost sends the request and prepends to loaded feeds only',
      () async {
    await seed(const FeedKey.home(), [5, 4]);
    // The author's Posts tab was never opened: it must stay empty.
    answer = (_) => pb.CreatePostResponse(post: postView(9, authorId: 'me'));

    final view = await repo.createPost(idempotencyKey: 'k1', text: 'hello');

    expect(view.post.postId, postId(9));
    final sent = requests.single as pb.CreatePostRequest;
    expect(sent.idempotencyKey, 'k1');
    expect(sent.text, 'hello');
    expect(
      cachedIds(await store.read(const FeedKey.home())),
      [postId(9), postId(5), postId(4)],
    );
    expect((await store.read(FeedKey.user('me'))).entries, isEmpty);
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

    test('FEATURE_DISABLED without feature hides all of posts until reset',
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
    });

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
