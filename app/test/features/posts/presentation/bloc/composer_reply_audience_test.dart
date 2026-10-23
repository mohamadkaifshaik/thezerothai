import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/features/posts/domain/reply_audience.dart';
import 'package:dzeroth/features/posts/presentation/bloc/composer_cubit.dart';
import 'package:dzeroth/features/posts/presentation/bloc/pending_posts_cubit.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pbenum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../../support/posts_fixtures.dart';

class _MockPostsRepository extends Mock implements PostsRepository {}

/// ADR-0021 D2 / L-1: the audience the composer sends and the echo check.
void main() {
  late _MockPostsRepository repo;
  late PendingPostsCubit pending;

  setUpAll(() {
    registerFallbackValue(ReplyPolicy.REPLY_POLICY_UNSPECIFIED);
  });

  setUp(() {
    repo = _MockPostsRepository();
    pending = PendingPostsCubit();
    when(() => repo.subFeatureEnabled(any())).thenReturn(true);
  });

  tearDown(() => pending.close());

  ComposerCubit make({bool enabled = true, String quote = ''}) {
    final cubit = ComposerCubit(
      postsRepository: repo,
      pending: pending,
      author: common.AuthorSnapshot(userId: 'me', handle: 'me'),
      quoteOfPostId: quote,
      replyAudienceEnabled: enabled,
    );
    addTearDown(cubit.close);
    return cubit;
  }

  /// Answers every create with a post echoing [echo], or throws [error].
  void stubCreate({
    ReplyPolicy echo = ReplyPolicy.REPLY_POLICY_UNSPECIFIED,
    Object? error,
  }) {
    when(
      () => repo.createPost(
        idempotencyKey: any(named: 'idempotencyKey'),
        text: any(named: 'text'),
        replyToPostId: any(named: 'replyToPostId'),
        quoteOfPostId: any(named: 'quoteOfPostId'),
        mediaIds: any(named: 'mediaIds'),
        mediaAltTexts: any(named: 'mediaAltTexts'),
        replyPolicy: any(named: 'replyPolicy'),
      ),
    ).thenAnswer((_) async {
      if (error != null) throw error;
      final view = postView(1);
      view.post.replyPolicy = echo;
      return view;
    });
  }

  /// The policy of the one CreatePost since the last [clearInteractions].
  ReplyPolicy sent() {
    final captured = verify(
      () => repo.createPost(
        idempotencyKey: any(named: 'idempotencyKey'),
        text: any(named: 'text'),
        replyToPostId: any(named: 'replyToPostId'),
        quoteOfPostId: any(named: 'quoteOfPostId'),
        mediaIds: any(named: 'mediaIds'),
        mediaAltTexts: any(named: 'mediaAltTexts'),
        replyPolicy: captureAny(named: 'replyPolicy'),
      ),
    ).captured;
    clearInteractions(repo);
    return captured.single as ReplyPolicy;
  }

  test('default sends UNSPECIFIED and the echo check stays quiet', () async {
    stubCreate();
    final cubit = make()..textChanged('hello');
    expect(cubit.state.replyAudience, ReplyAudience.everyone);
    await cubit.submit();

    expect(sent(), ReplyPolicy.REPLY_POLICY_UNSPECIFIED);
    expect(cubit.state.status, ComposerStatus.posted);
    expect(cubit.state.replyPolicyNotApplied, isFalse);
  });

  test('an explicit Everyone is still sent as UNSPECIFIED', () async {
    stubCreate(echo: ReplyPolicy.REPLY_POLICY_EVERYONE);
    final cubit = make()
      ..replyAudienceChanged(ReplyAudience.following)
      ..replyAudienceChanged(ReplyAudience.everyone)
      ..textChanged('hello');
    await cubit.submit();

    expect(sent(), ReplyPolicy.REPLY_POLICY_UNSPECIFIED);
    // The server may echo EVERYONE for UNSPECIFIED: equivalent, no notice.
    expect(cubit.state.replyPolicyNotApplied, isFalse);
  });

  test('FOLLOWING and MENTIONED_ONLY are sent and survive typing', () async {
    for (final (audience, wire) in [
      (ReplyAudience.following, ReplyPolicy.REPLY_POLICY_FOLLOWING),
      (ReplyAudience.mentionedOnly, ReplyPolicy.REPLY_POLICY_MENTIONED_ONLY),
    ]) {
      stubCreate(echo: wire);
      final cubit = make()
        ..replyAudienceChanged(audience)
        ..textChanged('hello')
        ..textChanged('hello again');
      expect(cubit.state.replyAudience, audience);
      await cubit.submit();

      expect(sent(), wire);
      expect(cubit.state.replyPolicyNotApplied, isFalse);
    }
  });

  test('a quote may choose an audience', () async {
    stubCreate(echo: ReplyPolicy.REPLY_POLICY_FOLLOWING);
    final cubit = make(quote: postId(5))
      ..replyAudienceChanged(ReplyAudience.following)
      ..textChanged('quote');
    await cubit.submit();
    expect(sent(), ReplyPolicy.REPLY_POLICY_FOLLOWING);
  });

  test('feature off or a reply: choice ignored, UNSPECIFIED sent', () async {
    stubCreate();
    final off = make(enabled: false)
      ..replyAudienceChanged(ReplyAudience.following)
      ..textChanged('hello');
    expect(off.canChooseReplyAudience, isFalse);
    expect(off.state.replyAudience, ReplyAudience.everyone);
    await off.submit();
    expect(sent(), ReplyPolicy.REPLY_POLICY_UNSPECIFIED);

    final reply = ComposerCubit.reply(
      postsRepository: repo,
      replyToPostId: postId(9),
    );
    addTearDown(reply.close);
    reply
      ..replyAudienceChanged(ReplyAudience.mentionedOnly)
      ..textChanged('hi');
    expect(reply.canChooseReplyAudience, isFalse);
    await reply.submit();
    expect(sent(), ReplyPolicy.REPLY_POLICY_UNSPECIFIED);
  });

  test('hidden once the gate learned the feature is disabled', () {
    final cubit = make();
    expect(cubit.canChooseReplyAudience, isTrue);
    when(() => repo.subFeatureEnabled(kFeatureReplyAudience)).thenReturn(false);
    expect(cubit.canChooseReplyAudience, isFalse);
  });

  test('echo mismatch: an old revision dropped the field', () async {
    stubCreate();
    final cubit = make()
      ..replyAudienceChanged(ReplyAudience.mentionedOnly)
      ..textChanged('hello');
    await cubit.submit();

    expect(cubit.state.status, ComposerStatus.posted);
    expect(cubit.state.error, isNull);
    expect(cubit.state.replyPolicyNotApplied, isTrue);
  });

  test('the next edit clears the notice flag', () async {
    stubCreate();
    final cubit = make()
      ..replyAudienceChanged(ReplyAudience.following)
      ..textChanged('hello');
    await cubit.submit();
    expect(cubit.state.replyPolicyNotApplied, isTrue);
    cubit.textChanged('');
    expect(cubit.state.replyPolicyNotApplied, isFalse);
  });

  test('a different audience is a different request: its own key', () async {
    stubCreate(error: const NetworkException('offline'));
    final cubit = make()..textChanged('hello');
    await cubit.submit();
    final first = cubit.currentKey;
    expect(first, isNotNull);
    cubit.replyAudienceChanged(ReplyAudience.following);
    await cubit.submit();
    expect(cubit.currentKey, isNot(first));
    // Back to the first audience: the first key again (edit and revert).
    cubit.replyAudienceChanged(ReplyAudience.everyone);
    await cubit.submit();
    expect(cubit.currentKey, first);
  });

  test('FEATURE_DISABLED for the audience falls back to Everyone', () async {
    stubCreate(
      error: const FeatureDisabledException(
        'off',
        feature: kFeatureReplyAudience,
      ),
    );
    final cubit = make()
      ..replyAudienceChanged(ReplyAudience.following)
      ..textChanged('hello');
    await cubit.submit();

    expect(cubit.state.status, ComposerStatus.editing);
    expect(cubit.state.error, isA<FeatureDisabledException>());
    expect(cubit.state.replyAudience, ReplyAudience.everyone);
  });
}
