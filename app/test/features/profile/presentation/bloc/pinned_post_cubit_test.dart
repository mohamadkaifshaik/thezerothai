import 'dart:async';

import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/profile/presentation/bloc/pinned_post_cubit.dart';
import 'package:dzeroth/features/profile/presentation/bloc/pinned_post_state.dart';
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../../support/posts_fixtures.dart';
import '../../../../support/timeline_fixtures.dart';

/// W3-17: the one cubit that owns the Pinned row's `GetPost` and the rule for
/// what a failure means.
void main() {
  late MockPostsRepository posts;
  late StreamController<String> removed;
  late int deleted;
  late PinnedPostCubit cubit;

  final id = postId(7);

  setUp(() {
    posts = MockPostsRepository();
    removed = StreamController<String>.broadcast();
    deleted = 0;
    when(() => posts.removedPosts).thenAnswer((_) => removed.stream);
    cubit = PinnedPostCubit(posts: posts, onDeleted: () => deleted++);
  });

  tearDown(() async {
    await cubit.close();
    await removed.close();
  });

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  test('starts with no pin and asks for nothing', () {
    expect(cubit.state.status, PinnedPostStatus.none);
    expect(cubit.state.coveredPostId, isNull);
    verifyNever(() => posts.getPost(any()));
  });

  test('null and "" mean no pin: no GetPost, row cleared', () async {
    when(() => posts.getPost(id)).thenAnswer((_) async => postView(7));
    cubit.pinChanged(id);
    await settle();
    expect(cubit.state.status, PinnedPostStatus.ready);

    cubit.pinChanged('');
    expect(cubit.state.status, PinnedPostStatus.none);
    cubit.pinChanged(null);
    expect(cubit.state.status, PinnedPostStatus.none);
    verify(() => posts.getPost(id)).called(1);
  });

  test('a pin loads once: loading, then the post', () async {
    final completer = Completer<pb.PostView>();
    when(() => posts.getPost(id)).thenAnswer((_) => completer.future);
    final seen = <PinnedPostStatus>[];
    final sub = cubit.stream.listen((s) => seen.add(s.status));

    cubit.pinChanged(id);
    await settle();
    expect(cubit.state.status, PinnedPostStatus.loading);
    // The feed below already leaves the post out while it loads.
    expect(cubit.state.coveredPostId, id);

    completer.complete(postView(7));
    await settle();
    expect(cubit.state.status, PinnedPostStatus.ready);
    expect(cubit.state.view!.post.postId, id);
    expect(cubit.state.coveredPostId, id);
    expect(seen, [PinnedPostStatus.loading, PinnedPostStatus.ready]);

    // The same pin again (a profile rebuild) costs nothing.
    cubit.pinChanged(id);
    await settle();
    verify(() => posts.getPost(id)).called(1);
    await sub.cancel();
  });

  test('NOT_FOUND hides the row silently and frees the feed', () async {
    when(() => posts.getPost(id))
        .thenAnswer((_) async => throw const NotFoundException('gone'));

    cubit.pinChanged(id);
    await settle();

    expect(cubit.state.status, PinnedPostStatus.hidden);
    expect(cubit.state.error, isNull);
    expect(cubit.state.coveredPostId, isNull);
    // The same id is not asked again.
    cubit.pinChanged(id);
    await settle();
    verify(() => posts.getPost(id)).called(1);
  });

  test(
    'another failure is shown with Retry and keeps the feed whole',
    () async {
      var calls = 0;
      when(() => posts.getPost(id)).thenAnswer((_) async {
        calls++;
        if (calls == 1) throw const NetworkException('offline');
        return postView(7);
      });

      cubit.pinChanged(id);
      await settle();
      expect(cubit.state.status, PinnedPostStatus.failed);
      expect(cubit.state.error, isA<NetworkException>());
      expect(cubit.state.coveredPostId, isNull);

      await cubit.retry();
      expect(cubit.state.status, PinnedPostStatus.ready);
      expect(calls, 2);
    },
  );

  test('an unexpected error is a failure too, not a crash', () async {
    when(() => posts.getPost(id))
        .thenAnswer((_) async => throw StateError('boom'));
    cubit.pinChanged(id);
    await settle();
    expect(cubit.state.status, PinnedPostStatus.failed);
    expect(cubit.state.error, isA<UnknownApiException>());
  });

  test('a late answer for an earlier pin is dropped', () async {
    final first = Completer<pb.PostView>();
    final other = postId(8);
    when(() => posts.getPost(id)).thenAnswer((_) => first.future);
    when(() => posts.getPost(other)).thenAnswer((_) async => postView(8));

    cubit.pinChanged(id);
    await settle();
    cubit.pinChanged(other);
    await settle();
    expect(cubit.state.postId, other);
    expect(cubit.state.status, PinnedPostStatus.ready);

    first.complete(postView(7));
    await settle();
    expect(cubit.state.postId, other);
    expect(cubit.state.view!.post.postId, other);
  });

  test('a late answer after the pin was removed is dropped', () async {
    final first = Completer<pb.PostView>();
    when(() => posts.getPost(id)).thenAnswer((_) => first.future);

    cubit.pinChanged(id);
    await settle();
    cubit.pinChanged('');
    first.complete(postView(7));
    await settle();

    expect(cubit.state.status, PinnedPostStatus.none);
  });

  test('a post removed elsewhere hides the row', () async {
    when(() => posts.getPost(id)).thenAnswer((_) async => postView(7));
    cubit.pinChanged(id);
    await settle();

    removed.add(postId(99));
    await settle();
    expect(cubit.state.status, PinnedPostStatus.ready);

    removed.add(id);
    await settle();
    expect(cubit.state.status, PinnedPostStatus.hidden);
    expect(cubit.state.coveredPostId, isNull);
  });

  group('deletePinned', () {
    test('hides at once, reports it once the server confirmed', () async {
      when(() => posts.getPost(id)).thenAnswer((_) async => postView(7));
      when(
        () => posts.deletePost(
          postId: any(named: 'postId'),
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      ).thenAnswer((_) async {});
      cubit.pinChanged(id);
      await settle();

      await cubit.deletePinned(id);

      expect(cubit.state.status, PinnedPostStatus.hidden);
      expect(deleted, 1);
    });

    test('the feed keeps leaving the post out while the delete runs', () async {
      when(() => posts.getPost(id)).thenAnswer((_) async => postView(7));
      final confirm = Completer<void>();
      when(
        () => posts.deletePost(
          postId: any(named: 'postId'),
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      ).thenAnswer((_) => confirm.future);
      cubit.pinChanged(id);
      await settle();

      final done = cubit.deletePinned(id);
      await settle();
      expect(cubit.state.status, PinnedPostStatus.hidden);
      expect(cubit.state.coveredPostId, id, reason: 'no flash below the row');

      confirm.complete();
      await done;
      expect(cubit.state.coveredPostId, isNull);
    });

    test('a failed delete brings the row back and reuses its key', () async {
      when(() => posts.getPost(id)).thenAnswer((_) async => postView(7));
      final keys = <String>[];
      var fail = true;
      when(
        () => posts.deletePost(
          postId: any(named: 'postId'),
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      ).thenAnswer((invocation) async {
        keys.add(invocation.namedArguments[#idempotencyKey] as String);
        if (fail) throw const NetworkException('offline');
      });
      cubit.pinChanged(id);
      await settle();

      await expectLater(
        cubit.deletePinned(id),
        throwsA(isA<NetworkException>()),
      );
      expect(cubit.state.status, PinnedPostStatus.ready);
      expect(deleted, 0);

      fail = false;
      await cubit.deletePinned(id);
      expect(keys, hasLength(2));
      expect(keys[0], keys[1]);
      expect(cubit.state.status, PinnedPostStatus.hidden);
      expect(deleted, 1);
    });
  });
}
