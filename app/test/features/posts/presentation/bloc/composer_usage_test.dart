import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/telemetry/usage_reporter.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/features/posts/presentation/bloc/composer_cubit.dart';
import 'package:dzeroth/features/posts/presentation/bloc/pending_posts_cubit.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pbenum.dart'
    show ReplyPolicy;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../../support/posts_fixtures.dart';
import '../../../../support/recording_usage_analytics.dart';
import '../../../../support/scheduled_fixtures.dart';

class _MockPostsRepository extends Mock implements PostsRepository {}

/// The composer reports `post_created` on the success path only.
void main() {
  setUpAll(() {
    registerFallbackValue(ReplyPolicy.REPLY_POLICY_UNSPECIFIED);
    registerFallbackValue(DateTime.fromMillisecondsSinceEpoch(0));
  });

  late _MockPostsRepository repo;
  late PendingPostsCubit pending;
  late RecordingUsageAnalytics analytics;

  setUp(() {
    repo = _MockPostsRepository();
    pending = PendingPostsCubit();
    analytics = RecordingUsageAnalytics();
    when(() => repo.subFeatureEnabled(any())).thenReturn(true);
  });

  tearDown(() => pending.close());

  ComposerCubit root({String quote = ''}) {
    final c = ComposerCubit(
      postsRepository: repo,
      pending: pending,
      author: common.AuthorSnapshot(userId: 'me', handle: 'me'),
      quoteOfPostId: quote,
      scheduleEnabled: true,
      usage: UsageReporter.analytics(analytics),
    );
    addTearDown(c.close);
    return c;
  }

  void stubCreate(Future<dynamic> Function() answer) => when(
    () => repo.createPost(
      idempotencyKey: any(named: 'idempotencyKey'),
      text: any(named: 'text'),
      replyToPostId: any(named: 'replyToPostId'),
      quoteOfPostId: any(named: 'quoteOfPostId'),
      mediaIds: any(named: 'mediaIds'),
      mediaAltTexts: any(named: 'mediaAltTexts'),
      replyPolicy: any(named: 'replyPolicy'),
      poll: any(named: 'poll'),
    ),
  ).thenAnswer((_) async => await answer());

  test('a post, a quote and a reply each log one post_created', () async {
    stubCreate(() async => postView(1));

    final post = root()..textChanged('hello');
    await post.submit();
    final quote = root(quote: postId(5))..textChanged('my take');
    await quote.submit();
    final reply = ComposerCubit.reply(
      postsRepository: repo,
      replyToPostId: postId(6),
      usage: UsageReporter.analytics(analytics),
    )..textChanged('re');
    addTearDown(reply.close);
    await reply.submit();
    await Future<void>.value();

    expect(analytics.wire, [
      'post_created{kind=post,media=none,poll=false,scheduled=false}',
      'post_created{kind=quote,media=none,poll=false,scheduled=false}',
      'post_created{kind=reply,media=none,poll=false,scheduled=false}',
    ]);
  });

  test('a failed post logs nothing; the retry that works logs once', () async {
    var fail = true;
    stubCreate(() async {
      if (fail) throw const NetworkException('offline');
      return postView(1);
    });
    final c = root()..textChanged('hello');

    await c.submit();
    await Future<void>.value();
    expect(c.state.status, ComposerStatus.editing);
    expect(analytics.events, isEmpty);

    fail = false;
    await c.submit();
    await Future<void>.value();
    expect(analytics.wire, [
      'post_created{kind=post,media=none,poll=false,scheduled=false}',
    ]);
  });

  test(
    'a scheduled post logs scheduled=true; a refused one logs nothing',
    () async {
      var refuse = true;
      when(
        () => repo.schedulePost(
          idempotencyKey: any(named: 'idempotencyKey'),
          text: any(named: 'text'),
          publishAt: any(named: 'publishAt'),
          mediaIds: any(named: 'mediaIds'),
          mediaAltTexts: any(named: 'mediaAltTexts'),
          replyPolicy: any(named: 'replyPolicy'),
        ),
      ).thenAnswer((_) async {
        if (refuse) throw const NetworkException('offline');
        return scheduledPost(1);
      });
      final c = root()..textChanged('later');
      c.scheduleChanged(scheduledBase().add(const Duration(days: 3)));

      await c.submit();
      await Future<void>.value();
      expect(analytics.events, isEmpty);

      refuse = false;
      await c.submit();
      await Future<void>.value();
      expect(analytics.wire, [
        'post_created{kind=post,media=none,poll=false,scheduled=true}',
      ]);
    },
  );
}
