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
  final quoted = postId(5);

  setUp(() {
    repo = MockPostsRepository();
    pending = PendingPostsCubit();
    cubit = ComposerCubit(
      postsRepository: repo,
      pending: pending,
      author: common.AuthorSnapshot(userId: 'me', handle: 'me'),
      quoteOfPostId: quoted,
      clock: () => DateTime.utc(2026, 1, 1),
    );
  });

  tearDown(() async {
    await cubit.close();
    await pending.close();
  });

  When<Future<pb.PostView>> stubCreate() => when(
    () => repo.createPost(
      idempotencyKey: any(named: 'idempotencyKey'),
      text: any(named: 'text'),
      replyToPostId: any(named: 'replyToPostId'),
      quoteOfPostId: any(named: 'quoteOfPostId'),
      mediaIds: any(named: 'mediaIds'),
      mediaAltTexts: any(named: 'mediaAltTexts'),
    ),
  );

  test('a quote sends quote_of_post_id and keeps the 280 limit', () async {
    stubCreate().thenAnswer((_) async => postView(9));
    cubit.textChanged('a' * 281);
    expect(cubit.state.canSubmit, isFalse);
    expect(cubit.state.draft.remaining, -1);

    cubit.textChanged('my take');
    await cubit.submit();

    final call = verify(
      () => repo.createPost(
        idempotencyKey: any(named: 'idempotencyKey'),
        text: 'my take',
        replyToPostId: '',
        quoteOfPostId: captureAny(named: 'quoteOfPostId'),
        mediaIds: any(named: 'mediaIds'),
        mediaAltTexts: any(named: 'mediaAltTexts'),
      ),
    )..called(1);
    expect(call.captured.single, quoted);
    expect(cubit.state.status, ComposerStatus.posted);
  });

  test('a retry after a failure reuses the key', () async {
    final keys = <String>[];
    var fail = true;
    stubCreate().thenAnswer((invocation) async {
      keys.add(invocation.namedArguments[#idempotencyKey] as String);
      if (fail) throw const NetworkException('offline');
      return postView(9);
    });
    cubit.textChanged('my take');

    await cubit.submit();
    expect(cubit.state.error, isA<NetworkException>());
    fail = false;
    await cubit.submit();

    expect(keys, hasLength(2));
    expect(keys[0], keys[1]);
  });

  test('a plain composer and a reply composer send no quote', () async {
    stubCreate().thenAnswer((_) async => postView(9));
    final plain = ComposerCubit(
      postsRepository: repo,
      pending: pending,
      author: common.AuthorSnapshot(userId: 'me', handle: 'me'),
    );
    final reply = ComposerCubit.reply(
      postsRepository: repo,
      replyToPostId: postId(3),
    );
    plain.textChanged('hi');
    reply.textChanged('hi');

    await plain.submit();
    await reply.submit();

    verify(
      () => repo.createPost(
        idempotencyKey: any(named: 'idempotencyKey'),
        text: 'hi',
        replyToPostId: any(named: 'replyToPostId'),
        quoteOfPostId: '',
        mediaIds: any(named: 'mediaIds'),
        mediaAltTexts: any(named: 'mediaAltTexts'),
      ),
    ).called(2);
    await plain.close();
    await reply.close();
  });
}
