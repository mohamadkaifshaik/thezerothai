import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/posts/presentation/bloc/post_detail_cubit.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../../support/posts_fixtures.dart';
import '../../../../support/timeline_fixtures.dart';

void main() {
  late MockPostsRepository repo;
  late PostDetailCubit cubit;

  setUp(() {
    repo = MockPostsRepository();
    cubit = PostDetailCubit(postsRepository: repo, postId: postId(1));
  });

  tearDown(() => cubit.close());

  test('loads the post', () async {
    when(() => repo.getPost(postId(1))).thenAnswer((_) async => postView(1));

    await cubit.load();

    expect(cubit.state.status, PostDetailStatus.ready);
    expect(cubit.state.view!.post.postId, postId(1));
    verify(() => repo.getPost(postId(1))).called(1);
  });

  test('NOT_FOUND is a final state, not an error', () async {
    when(
      () => repo.getPost(postId(1)),
    ).thenAnswer((_) async => throw const NotFoundException('gone'));

    await cubit.load();

    expect(cubit.state.status, PostDetailStatus.notFound);
    expect(cubit.state.error, isNull);
  });

  test('a malformed id is treated as not found', () async {
    when(
      () => repo.getPost(postId(1)),
    ).thenAnswer((_) async => throw const ValidationException('bad id'));

    await cubit.load();

    expect(cubit.state.status, PostDetailStatus.notFound);
  });

  test('other failures are errors that load() can retry', () async {
    when(
      () => repo.getPost(postId(1)),
    ).thenAnswer((_) async => throw const NetworkException('offline'));
    await cubit.load();
    expect(cubit.state.status, PostDetailStatus.error);
    expect(cubit.state.error, isA<NetworkException>());

    when(() => repo.getPost(postId(1))).thenAnswer((_) async => postView(1));
    await cubit.load();
    expect(cubit.state.status, PostDetailStatus.ready);
  });

  test('delete success leaves the screen; a failed delete retries with the '
      'same key', () async {
    var calls = 0;
    when(
      () => repo.deletePost(
        postId: postId(1),
        idempotencyKey: any(named: 'idempotencyKey'),
      ),
    ).thenAnswer((_) async {
      calls++;
      if (calls == 1) throw const NetworkException('offline');
    });

    await expectLater(cubit.deletePost(), throwsA(isA<NetworkException>()));
    expect(cubit.state.status, isNot(PostDetailStatus.deleted));

    await cubit.deletePost();

    expect(cubit.state.status, PostDetailStatus.deleted);
    final keys = verify(
      () => repo.deletePost(
        postId: postId(1),
        idempotencyKey: captureAny(named: 'idempotencyKey'),
      ),
    ).captured;
    expect(keys, hasLength(2));
    expect(keys[0], keys[1]);
  });
}
