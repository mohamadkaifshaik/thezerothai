import 'dart:async';

import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/features/posts/presentation/bloc/composer_cubit.dart';
import 'package:dzeroth/features/posts/presentation/bloc/pending_posts_cubit.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../../support/posts_fixtures.dart';

class MockPostsRepository extends Mock implements PostsRepository {}

void main() {
  late MockPostsRepository repo;
  late PendingPostsCubit pending;
  late ComposerCubit cubit;

  setUp(() {
    repo = MockPostsRepository();
    pending = PendingPostsCubit();
    cubit = ComposerCubit(
      postsRepository: repo,
      pending: pending,
      author: common.AuthorSnapshot(userId: 'me', handle: 'me'),
      clock: () => DateTime.utc(2026, 1, 1),
    );
  });

  tearDown(() async {
    await cubit.close();
    await pending.close();
  });

  void stubCreate(Future<pb.PostView> Function() answer) {
    when(
      () => repo.createPost(
        idempotencyKey: any(named: 'idempotencyKey'),
        text: any(named: 'text'),
      ),
    ).thenAnswer((_) => answer());
  }

  test('starts empty with Post disabled', () {
    expect(cubit.state.canSubmit, isFalse);
    expect(cubit.state.draft.remaining, 280);
  });

  test('success: optimistic item appears while sending, then is removed', () async {
    final done = Completer<pb.PostView>();
    stubCreate(() => done.future);
    cubit.textChanged('  hello  ');
    final future = cubit.submit();

    expect(cubit.state.isSubmitting, isTrue);
    expect(pending.state, hasLength(1));
    expect(pending.state.single.text, 'hello');
    expect(pending.state.single.author.userId, 'me');

    done.complete(postView(1));
    await future;

    expect(pending.state, isEmpty);
    expect(cubit.state.status, ComposerStatus.posted);
    verify(
      () => repo.createPost(
        idempotencyKey: any(named: 'idempotencyKey'),
        text: 'hello',
      ),
    ).called(1);
  });

  test('QUOTA_EXCEEDED rolls back the optimistic item and keeps the draft',
      () async {
    stubCreate(() async => throw const QuotaExceededException('quota'));
    cubit.textChanged('hello');
    await cubit.submit();

    expect(pending.state, isEmpty);
    expect(cubit.state.error, isA<QuotaExceededException>());
    expect(cubit.state.status, ComposerStatus.editing);
    expect(cubit.state.draft.text, 'hello');
    expect(cubit.state.canSubmit, isTrue);
  });

  test('a network error then a retry sends the same idempotency key, once',
      () async {
    var calls = 0;
    stubCreate(() async {
      calls++;
      if (calls == 1) throw const NetworkException('offline');
      return postView(1);
    });
    cubit.textChanged('hello');
    await cubit.submit();
    expect(cubit.state.error, isA<NetworkException>());
    expect(pending.state, isEmpty);

    await cubit.submit();
    expect(pending.state, isEmpty);
    expect(cubit.state.status, ComposerStatus.posted);

    final keys = verify(
      () => repo.createPost(
        idempotencyKey: captureAny(named: 'idempotencyKey'),
        text: 'hello',
      ),
    ).captured;
    expect(keys, hasLength(2));
    expect(keys.first, isNotEmpty);
    expect(keys[0], keys[1]);
  });

  test('editing the text after a failure starts a new intent (new key)',
      () async {
    stubCreate(() async => throw const NetworkException('offline'));
    cubit.textChanged('hello');
    await cubit.submit();
    cubit.textChanged('hello world');
    await cubit.submit();

    final keys = verify(
      () => repo.createPost(
        idempotencyKey: captureAny(named: 'idempotencyKey'),
        text: any(named: 'text'),
      ),
    ).captured;
    expect(keys, hasLength(2));
    expect(keys[0], isNot(keys[1]));
  });

  test('a successful post clears the key so the next post gets a new one',
      () async {
    stubCreate(() async => postView(1));
    cubit.textChanged('one');
    await cubit.submit();
    expect(cubit.currentKey, isNull);
  });

  test('DEGRADED_MODE is surfaced and never retried automatically', () async {
    stubCreate(() async => throw const DegradedModeException('degraded'));
    cubit.textChanged('hello');
    await cubit.submit();
    expect(cubit.state.error, isA<DegradedModeException>());
    verify(
      () => repo.createPost(
        idempotencyKey: any(named: 'idempotencyKey'),
        text: any(named: 'text'),
      ),
    ).called(1);
  });

  test('submit is a no-op while Post is disabled or already sending', () async {
    cubit.textChanged('a' * 281);
    await cubit.submit();
    verifyNever(
      () => repo.createPost(
        idempotencyKey: any(named: 'idempotencyKey'),
        text: any(named: 'text'),
      ),
    );
    expect(pending.state, isEmpty);
  });

  test('an unexpected error rolls back too', () async {
    stubCreate(() async => throw StateError('drift'));
    cubit.textChanged('hello');
    await cubit.submit();
    expect(pending.state, isEmpty);
    expect(cubit.state.error, isA<UnknownApiException>());
    expect(cubit.state.status, ComposerStatus.editing);
  });
}
