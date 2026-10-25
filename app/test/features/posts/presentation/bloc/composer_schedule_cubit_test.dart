import 'dart:async';

import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/media/data/media_uploader.dart';
import 'package:dzeroth/features/media/presentation/bloc/attachments_cubit.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/features/posts/domain/posts_feature_flag.dart';
import 'package:dzeroth/features/posts/domain/reply_audience.dart';
import 'package:dzeroth/features/posts/presentation/bloc/composer_cubit.dart';
import 'package:dzeroth/features/posts/presentation/bloc/pending_posts_cubit.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pbenum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../../support/media_fixtures.dart';
import '../../../../support/posts_fixtures.dart';
import '../../../../support/scheduled_fixtures.dart';

class _MockPostsRepository extends Mock implements PostsRepository {}

/// The schedule path of the composer cubit (CMP-D6, ADR-0021 D4): gating,
/// what SchedulePost carries, the idempotency key per request, the reset on
/// success and the failure handling.
void main() {
  setUpAll(() {
    registerFallbackValue(ReplyPolicy.REPLY_POLICY_UNSPECIFIED);
    registerFallbackValue(DateTime.fromMillisecondsSinceEpoch(0));
    registerMediaFallbacks();
  });

  late _MockPostsRepository repo;
  late PendingPostsCubit pending;
  late List<_Sent> sent;
  late DateTime at;

  setUp(() {
    repo = _MockPostsRepository();
    pending = PendingPostsCubit();
    sent = [];
    at = scheduledBase().add(const Duration(days: 3));
    when(() => repo.subFeatureEnabled(any())).thenReturn(true);
  });

  tearDown(() => pending.close());

  ComposerCubit make({
    bool enabled = true,
    String quote = '',
    bool audience = false,
    AttachmentsCubit? attachments,
  }) {
    final cubit = ComposerCubit(
      postsRepository: repo,
      pending: pending,
      author: common.AuthorSnapshot(userId: 'me', handle: 'me'),
      quoteOfPostId: quote,
      scheduleEnabled: enabled,
      replyAudienceEnabled: audience,
      attachments: attachments,
    );
    addTearDown(cubit.close);
    return cubit;
  }

  /// Answers each SchedulePost with the next of [answers] (a value, or an
  /// exception to throw); the last one repeats.
  void stubSchedule(List<Object> answers) {
    var call = 0;
    when(
      () => repo.schedulePost(
        idempotencyKey: any(named: 'idempotencyKey'),
        text: any(named: 'text'),
        publishAt: any(named: 'publishAt'),
        mediaIds: any(named: 'mediaIds'),
        mediaAltTexts: any(named: 'mediaAltTexts'),
        replyPolicy: any(named: 'replyPolicy'),
      ),
    ).thenAnswer((invocation) async {
      sent.add(
        _Sent(
          key: invocation.namedArguments[#idempotencyKey] as String,
          text: invocation.namedArguments[#text] as String,
          publishAt: invocation.namedArguments[#publishAt] as DateTime,
          mediaIds: invocation.namedArguments[#mediaIds] as List<String>,
          altTexts: invocation.namedArguments[#mediaAltTexts] as List<String>,
          policy: invocation.namedArguments[#replyPolicy] as ReplyPolicy,
        ),
      );
      final answer = answers[call < answers.length ? call : answers.length - 1];
      call++;
      if (answer is Exception || answer is Error) throw answer;
      return answer as pb.ScheduledPost;
    });
  }

  group('gating', () {
    test('a new root post may be scheduled', () {
      final cubit = make();
      expect(cubit.canSchedule, isTrue);
    });

    test('off without the flags', () {
      final cubit = make(enabled: false);
      expect(cubit.canSchedule, isFalse);
      cubit.scheduleChanged(at);
      expect(cubit.state.scheduledAt, isNull);
    });

    test('a quote cannot be scheduled (the request has no quote field)', () {
      final cubit = make(quote: postId(5));
      expect(cubit.canSchedule, isFalse);
      cubit.scheduleChanged(at);
      expect(cubit.state.scheduledAt, isNull);
    });

    test('a reply cannot be scheduled', () {
      final reply = ComposerCubit.reply(
        postsRepository: repo,
        replyToPostId: postId(7),
      );
      addTearDown(reply.close);
      expect(reply.canSchedule, isFalse);
      reply.scheduleChanged(at);
      expect(reply.state.scheduledAt, isNull);
    });

    test('off once the gate learned scheduling is disabled', () {
      final cubit = make();
      when(() => repo.subFeatureEnabled(kFeatureScheduledPosts))
          .thenReturn(false);
      expect(cubit.canSchedule, isFalse);
    });
  });

  group('the chosen time', () {
    test('is kept as a UTC instant cut to the minute', () {
      final cubit = make();
      cubit.scheduleChanged(at.add(const Duration(seconds: 42)));
      expect(cubit.state.scheduledAt, at.toUtc());
      expect(cubit.state.scheduledAt!.isUtc, isTrue);
      expect(cubit.state.isScheduling, isTrue);
    });

    test('null removes the schedule', () {
      final cubit = make();
      cubit.scheduleChanged(at);
      cubit.scheduleChanged(null);
      expect(cubit.state.scheduledAt, isNull);
      expect(cubit.state.isScheduling, isFalse);
    });

    test('survives typing', () {
      final cubit = make();
      cubit.scheduleChanged(at);
      cubit.textChanged('a');
      cubit.textChanged('ab');
      expect(cubit.state.scheduledAt, at.toUtc());
    });

    test('the reply audience control stays usable with a schedule', () {
      final cubit = make(audience: true);
      cubit.scheduleChanged(at);
      cubit.replyAudienceChanged(ReplyAudience.following);
      expect(cubit.state.replyAudience, ReplyAudience.following);
      expect(cubit.state.scheduledAt, at.toUtc());
    });

    test('cannot change while the post is being sent', () async {
      final done = Completer<pb.ScheduledPost>();
      when(
        () => repo.schedulePost(
          idempotencyKey: any(named: 'idempotencyKey'),
          text: any(named: 'text'),
          publishAt: any(named: 'publishAt'),
          mediaIds: any(named: 'mediaIds'),
          mediaAltTexts: any(named: 'mediaAltTexts'),
          replyPolicy: any(named: 'replyPolicy'),
        ),
      ).thenAnswer((_) => done.future);
      final cubit = make();
      cubit.textChanged('hello');
      cubit.scheduleChanged(at);
      final future = cubit.submit();
      expect(cubit.state.isSubmitting, isTrue);
      cubit.scheduleChanged(null);
      expect(cubit.state.scheduledAt, at.toUtc());
      done.complete(scheduledPost(1));
      await future;
    });
  });

  group('submit', () {
    test('sends SchedulePost, not CreatePost, with the UTC time', () async {
      stubSchedule([scheduledPost(1)]);
      final cubit = make();
      cubit.textChanged('later');
      cubit.scheduleChanged(at);

      await cubit.submit();

      final call = sent.single;
      expect(call.text, 'later');
      expect(call.publishAt.isUtc, isTrue);
      expect(call.publishAt, at.toUtc());
      expect(call.mediaIds, isEmpty);
      expect(call.altTexts, isEmpty);
      expect(call.policy, ReplyPolicy.REPLY_POLICY_UNSPECIFIED);
      verifyNever(
        () => repo.createPost(
          idempotencyKey: any(named: 'idempotencyKey'),
          text: any(named: 'text'),
        ),
      );
    });

    test(
      'no optimistic row on Home: the post exists only once published',
      () async {
        final done = Completer<pb.ScheduledPost>();
        when(
          () => repo.schedulePost(
            idempotencyKey: any(named: 'idempotencyKey'),
            text: any(named: 'text'),
            publishAt: any(named: 'publishAt'),
            mediaIds: any(named: 'mediaIds'),
            mediaAltTexts: any(named: 'mediaAltTexts'),
            replyPolicy: any(named: 'replyPolicy'),
          ),
        ).thenAnswer((_) => done.future);
        final cubit = make();
        cubit.textChanged('later');
        cubit.scheduleChanged(at);
        final future = cubit.submit();
        expect(pending.state, isEmpty);
        done.complete(scheduledPost(1));
        await future;
        expect(pending.state, isEmpty);
      },
    );

    test('a chosen audience goes along; Everyone stays UNSPECIFIED', () async {
      stubSchedule([scheduledPost(1)]);
      final cubit = make(audience: true);
      cubit.textChanged('later');
      cubit.scheduleChanged(at);
      cubit.replyAudienceChanged(ReplyAudience.mentionedOnly);

      await cubit.submit();

      expect(sent.single.policy, ReplyPolicy.REPLY_POLICY_MENTIONED_ONLY);
    });

    test(
      'on success the composer is reset and carries the stored item',
      () async {
        final stored = scheduledPost(
          1,
          publishAt: at.add(const Duration(minutes: 1)),
        );
        stubSchedule([stored]);
        final cubit = make(audience: true);
        cubit.textChanged('later');
        cubit.scheduleChanged(at);
        cubit.replyAudienceChanged(ReplyAudience.following);

        await cubit.submit();

        final state = cubit.state;
        expect(state.scheduledNotice, same(stored));
        expect(state.status, ComposerStatus.editing);
        expect(state.draft.text, '');
        expect(state.canSubmit, isFalse);
        expect(state.scheduledAt, isNull);
        expect(state.isScheduling, isFalse);
        expect(state.replyAudience, ReplyAudience.everyone);
        expect(state.error, isNull);

        cubit.scheduledNoticeShown();
        expect(cubit.state.scheduledNotice, isNull);
      },
    );

    test(
      'a retry of the same request reuses the key (lost response)',
      () async {
        stubSchedule([
          const NetworkException('offline'),
          const NetworkException('offline'),
          scheduledPost(1),
        ]);
        final cubit = make();
        cubit.textChanged('later');
        cubit.scheduleChanged(at);

        await cubit.submit();
        expect(cubit.state.error, isA<NetworkException>());
        expect(cubit.state.isScheduling, isTrue, reason: 'the time is kept');
        expect(cubit.state.draft.text, 'later', reason: 'the text is kept');
        await cubit.submit();
        await cubit.submit();

        expect(sent.map((s) => s.key).toSet(), hasLength(1));
        expect(sent, hasLength(3));
      },
    );

    test('the key is 16 to 64 characters of [A-Za-z0-9_-]', () async {
      stubSchedule([scheduledPost(1)]);
      final cubit = make();
      cubit.textChanged('later');
      cubit.scheduleChanged(at);
      await cubit.submit();
      expect(sent.single.key, matches(RegExp(r'^[A-Za-z0-9_-]{16,64}$')));
    });

    test(
      'a cap error keeps the key: the retry may be a duplicate (m1)',
      () async {
        stubSchedule([
          const LimitReachedException('x', quota: 'scheduled_pending'),
          const QuotaExceededException('x', quota: 'schedules'),
          scheduledPost(1),
        ]);
        final cubit = make();
        cubit.textChanged('later');
        cubit.scheduleChanged(at);

        await cubit.submit();
        expect(cubit.state.error, isA<LimitReachedException>());
        await cubit.submit();
        expect(cubit.state.error, isA<QuotaExceededException>());
        await cubit.submit();

        expect(sent.map((s) => s.key).toSet(), hasLength(1));
      },
    );

    test('a changed time is a new request with a new key', () async {
      stubSchedule([const NetworkException('offline'), scheduledPost(1)]);
      final cubit = make();
      cubit.textChanged('later');
      cubit.scheduleChanged(at);
      await cubit.submit();

      cubit.scheduleChanged(at.add(const Duration(hours: 1)));
      await cubit.submit();

      expect(sent[0].key, isNot(sent[1].key));
      expect(sent[1].publishAt, at.add(const Duration(hours: 1)).toUtc());
    });

    test('changed text is a new request with a new key', () async {
      stubSchedule([const NetworkException('offline'), scheduledPost(1)]);
      final cubit = make();
      cubit.textChanged('later');
      cubit.scheduleChanged(at);
      await cubit.submit();

      cubit.textChanged('later, edited');
      await cubit.submit();

      expect(sent[0].key, isNot(sent[1].key));
      expect(sent[1].text, 'later, edited');
    });

    test(
      'edit and revert reuses the first key (that post may exist)',
      () async {
        stubSchedule([
          const NetworkException('offline'),
          const NetworkException('offline'),
          scheduledPost(1),
        ]);
        final cubit = make();
        cubit.textChanged('later');
        cubit.scheduleChanged(at);
        await cubit.submit();
        cubit.textChanged('other');
        await cubit.submit();
        cubit.textChanged('later');
        await cubit.submit();

        expect(sent[2].key, sent[0].key);
        expect(sent[1].key, isNot(sent[0].key));
      },
    );

    test('a scheduled request and a plain post never share a key', () async {
      stubSchedule([const NetworkException('offline'), scheduledPost(1)]);
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
      ).thenAnswer((_) async => postView(1));
      final cubit = make();
      cubit.textChanged('later');
      cubit.scheduleChanged(at);
      await cubit.submit();
      final scheduleKey = sent.single.key;

      cubit.scheduleChanged(null);
      await cubit.submit();
      final captured = verify(
        () => repo.createPost(
          idempotencyKey: captureAny(named: 'idempotencyKey'),
          text: any(named: 'text'),
          replyToPostId: any(named: 'replyToPostId'),
          quoteOfPostId: any(named: 'quoteOfPostId'),
          mediaIds: any(named: 'mediaIds'),
          mediaAltTexts: any(named: 'mediaAltTexts'),
          replyPolicy: any(named: 'replyPolicy'),
        ),
      ).captured;
      expect(captured.single, isNot(scheduleKey));
    });

    test(
      'a success drops the key: the same text later gets a new one',
      () async {
        stubSchedule([scheduledPost(1), scheduledPost(2)]);
        final cubit = make();
        cubit.textChanged('later');
        cubit.scheduleChanged(at);
        await cubit.submit();
        cubit.textChanged('later');
        cubit.scheduleChanged(at);
        await cubit.submit();
        expect(sent[0].key, isNot(sent[1].key));
      },
    );

    test('a replay of an item that moved on is carried unchanged', () async {
      final published = scheduledPost(
        1,
        status: ScheduledPostStatus.SCHEDULED_POST_STATUS_PUBLISHED,
      );
      stubSchedule([published]);
      final cubit = make();
      cubit.textChanged('later');
      cubit.scheduleChanged(at);
      await cubit.submit();
      expect(cubit.state.scheduledNotice, same(published));
    });
  });

  group('failures', () {
    test('FEATURE_DISABLED for scheduled_posts clears the schedule', () async {
      stubSchedule([
        const FeatureDisabledException('off', feature: kFeatureScheduledPosts),
      ]);
      final cubit = make();
      cubit.textChanged('later');
      cubit.scheduleChanged(at);

      await cubit.submit();

      expect(cubit.state.scheduledAt, isNull);
      expect(cubit.state.draft.text, 'later');
      expect(cubit.state.error, isA<FeatureDisabledException>());
      expect(cubit.state.status, ComposerStatus.editing);
    });

    test('nothing is sent when scheduling went off meanwhile', () async {
      stubSchedule([scheduledPost(1)]);
      final cubit = make();
      cubit.textChanged('later');
      cubit.scheduleChanged(at);
      when(() => repo.subFeatureEnabled(kFeatureScheduledPosts))
          .thenReturn(false);

      await cubit.submit();

      expect(sent, isEmpty);
      expect(cubit.state.scheduledAt, isNull);
      expect(cubit.state.error, isA<FeatureDisabledException>());
    });

    test(
      'a VALIDATION on publish_at keeps text and time for the dialog',
      () async {
        stubSchedule([const ValidationException('x', field: 'publish_at')]);
        final cubit = make();
        cubit.textChanged('later');
        cubit.scheduleChanged(at);
        await cubit.submit();
        expect(cubit.state.error, isA<ValidationException>());
        expect(cubit.state.scheduledAt, at.toUtc());
      },
    );

    test(
      'an unexpected error becomes a generic failure, the key is kept',
      () async {
        stubSchedule([StateError('boom'), scheduledPost(1)]);
        // StateError is not an Exception: it throws as an Error.
        final cubit = make();
        cubit.textChanged('later');
        cubit.scheduleChanged(at);
        await cubit.submit();
        expect(cubit.state.error, isA<UnknownApiException>());
        await cubit.submit();
        expect(sent.map((s) => s.key).toSet(), hasLength(1));
      },
    );
  });

  group('with photos', () {
    test('uploads first and sends the media ids and alt texts', () async {
      final media = MockMediaRepository();
      final picker = FakeImagePicker();
      stubHappyUpload(media);
      final attachments = AttachmentsCubit(
        picker: picker,
        processor: FakeImageProcessor(),
        uploader: MediaUploader(repository: media),
      );
      addTearDown(attachments.close);
      stubSchedule([scheduledPost(1)]);
      final cubit = make(attachments: attachments);
      picker.next = [imageBytes('a'), imageBytes('b')];
      await attachments.pick();
      await Future<void>.delayed(Duration.zero);
      cubit.textChanged('look');
      cubit.scheduleChanged(at);

      await cubit.submit();

      expect(sent.single.mediaIds, ['m1', 'm2']);
      expect(cubit.state.scheduledNotice, isNotNull);
      // The images now belong to the scheduled item: the grid is emptied.
      await Future<void>.delayed(Duration.zero);
      expect(attachments.state.isEmpty, isTrue);
      expect(cubit.state.hasAttachments, isFalse);
    });
  });
}

class _Sent {
  const _Sent({
    required this.key,
    required this.text,
    required this.publishAt,
    required this.mediaIds,
    required this.altTexts,
    required this.policy,
  });

  final String key;
  final String text;
  final DateTime publishAt;
  final List<String> mediaIds;
  final List<String> altTexts;
  final ReplyPolicy policy;
}
