import 'dart:async';

import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/posts/presentation/bloc/thread_cubit.dart';
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../../support/posts_fixtures.dart';
import '../../../../support/timeline_fixtures.dart';

pb.GetThreadResponse thread({
  int focal = 1,
  List<int> replies = const [],
  String next = '',
  pb.PostView? parent,
  pb.PostView? root,
  bool parentUnavailable = false,
  bool rootUnavailable = false,
}) => pb.GetThreadResponse(
  focal: postView(focal),
  parent: parent,
  root: root,
  replies: [for (final n in replies) postView(n)],
  nextPageToken: next,
  parentUnavailable: parentUnavailable,
  rootUnavailable: rootUnavailable,
);

void main() {
  late MockPostsRepository repo;
  late ThreadCubit cubit;

  setUp(() {
    repo = MockPostsRepository();
    cubit = ThreadCubit(postsRepository: repo, postId: postId(1));
  });

  tearDown(() => cubit.close());

  void stub(Future<pb.GetThreadResponse> Function(String token) answer) {
    when(
      () => repo.getThread(
        postId(1),
        pageToken: any(named: 'pageToken'),
        pageSize: any(named: 'pageSize'),
      ),
    ).thenAnswer((i) => answer(i.namedArguments[#pageToken] as String));
  }

  test('loads the focal post, context flags and first page', () async {
    stub(
      (_) async => thread(
        replies: [2, 3],
        next: 'n1',
        parentUnavailable: true,
        rootUnavailable: true,
      ),
    );

    await cubit.load();

    final s = cubit.state;
    expect(s.status, ThreadStatus.ready);
    expect(s.focal!.post.postId, postId(1));
    expect(s.parentUnavailable, isTrue);
    expect(s.rootUnavailable, isTrue);
    expect(s.parent, isNull);
    expect(s.replies.map((r) => r.post.postId), [postId(2), postId(3)]);
    expect(s.hasMore, isTrue);
  });

  test(
    'loadMore follows the token, dedupes and drops the focal post',
    () async {
      stub(
        (token) async => token.isEmpty
            ? thread(replies: [2], next: 'n1')
            : thread(replies: [2, 3, 1], next: ''),
      );
      await cubit.load();

      await cubit.loadMore();

      expect(cubit.state.replies.map((r) => r.post.postId), [
        postId(2),
        postId(3),
      ]);
      expect(cubit.state.hasMore, isFalse);
      // Exhausted: no further request.
      await cubit.loadMore();
      verify(
        () => repo.getThread(
          postId(1),
          pageToken: any(named: 'pageToken'),
          pageSize: any(named: 'pageSize'),
        ),
      ).called(2);
    },
  );

  test('concurrent loadMore calls send one request', () async {
    final page = Completer<pb.GetThreadResponse>();
    stub(
      (token) => token.isEmpty
          ? Future.value(thread(replies: [2], next: 'n1'))
          : page.future,
    );
    await cubit.load();

    final a = cubit.loadMore();
    final b = cubit.loadMore();
    page.complete(thread(replies: [3]));
    await Future.wait([a, b]);

    verify(
      () => repo.getThread(
        postId(1),
        pageToken: 'n1',
        pageSize: any(named: 'pageSize'),
      ),
    ).called(1);
    expect(cubit.state.replies, hasLength(2));
  });

  test('a failed page keeps the replies and offers a retry', () async {
    var fail = true;
    stub((token) async {
      if (token.isEmpty) return thread(replies: [2], next: 'n1');
      if (fail) throw const NetworkException('offline');
      return thread(replies: [3]);
    });
    await cubit.load();

    await cubit.loadMore();
    expect(cubit.state.loadMoreError, isA<NetworkException>());
    expect(cubit.state.replies, hasLength(1));
    expect(cubit.state.loadingMore, isFalse);

    fail = false;
    await cubit.loadMore();
    expect(cubit.state.loadMoreError, isNull);
    expect(cubit.state.replies, hasLength(2));
  });

  test('a rejected page token restarts the thread once', () async {
    var calls = 0;
    stub((token) async {
      calls++;
      if (token == 'old') throw const ValidationException('page_token');
      return thread(
        replies: [2],
        next: token.isEmpty && calls == 1 ? 'old' : '',
      );
    });
    await cubit.load();
    expect(cubit.state.nextPageToken, 'old');

    await cubit.loadMore();

    expect(cubit.state.status, ThreadStatus.ready);
    expect(cubit.state.replies, hasLength(1));
    expect(cubit.state.hasMore, isFalse);
  });

  test('NOT_FOUND is final; FEATURE_DISABLED degrades; others retry', () async {
    stub((_) async => throw const NotFoundException('gone'));
    await cubit.load();
    expect(cubit.state.status, ThreadStatus.notFound);

    stub((_) async => throw const FeatureDisabledException('off'));
    await cubit.load();
    expect(cubit.state.status, ThreadStatus.disabled);

    stub((_) async => throw const NetworkException('offline'));
    await cubit.load();
    expect(cubit.state.status, ThreadStatus.error);

    stub((_) async => thread());
    await cubit.load();
    expect(cubit.state.status, ThreadStatus.ready);
  });

  test('refresh keeps the thread on a failed refetch', () async {
    stub((_) async => thread(replies: [2]));
    await cubit.load();

    stub((_) async => throw const NetworkException('offline'));
    await cubit.refresh();

    expect(cubit.state.status, ThreadStatus.ready);
    expect(cubit.state.replies, hasLength(1));
  });

  test('replyPosted appends once; blocked authors are hidden', () async {
    stub((_) async => thread(replies: [2]));
    await cubit.load();

    cubit.replyPosted(postView(9, authorId: 'me'));
    cubit.replyPosted(postView(9, authorId: 'me'));
    expect(cubit.state.replies.map((r) => r.post.postId), [
      postId(2),
      postId(9),
    ]);

    cubit.setAuthorHidden('me', hidden: true);
    expect(cubit.state.visibleReplies.map((r) => r.post.postId), [postId(2)]);
    cubit.setAuthorHidden('me', hidden: false);
    expect(cubit.state.visibleReplies, hasLength(2));
  });

  test('deleting a reply removes it; deleting the focal post leaves', () async {
    stub((_) async => thread(replies: [2, 3]));
    when(
      () => repo.deletePost(
        postId: any(named: 'postId'),
        idempotencyKey: any(named: 'idempotencyKey'),
      ),
    ).thenAnswer((_) async {});
    await cubit.load();

    await cubit.deletePost(postId(2));
    expect(cubit.state.replies.map((r) => r.post.postId), [postId(3)]);
    expect(cubit.state.status, ThreadStatus.ready);

    await cubit.deletePost(postId(1));
    expect(cubit.state.status, ThreadStatus.deleted);
  });

  test('a failed delete is rethrown and its retry reuses the key', () async {
    stub((_) async => thread(replies: [2]));
    final keys = <String>[];
    var fail = true;
    when(
      () => repo.deletePost(
        postId: any(named: 'postId'),
        idempotencyKey: any(named: 'idempotencyKey'),
      ),
    ).thenAnswer((i) async {
      keys.add(i.namedArguments[#idempotencyKey] as String);
      if (fail) throw const NetworkException('offline');
    });
    await cubit.load();

    await expectLater(
      cubit.deletePost(postId(2)),
      throwsA(isA<NetworkException>()),
    );
    fail = false;
    await cubit.deletePost(postId(2));

    expect(keys, hasLength(2));
    expect(keys[0], keys[1]);
    expect(cubit.state.replies, isEmpty);
  });
}
