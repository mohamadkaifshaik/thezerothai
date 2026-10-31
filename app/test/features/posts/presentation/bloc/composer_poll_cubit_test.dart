import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/features/posts/domain/composer_attachment_rules.dart';
import 'package:dzeroth/features/posts/domain/composer_draft.dart';
import 'package:dzeroth/features/posts/domain/poll_rules.dart';
import 'package:dzeroth/features/posts/presentation/bloc/composer_cubit.dart';
import 'package:dzeroth/features/posts/presentation/bloc/pending_posts_cubit.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pbenum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../../support/posts_fixtures.dart';

class _MockPostsRepository extends Mock implements PostsRepository {}

/// The poll path of the composer cubit (W6-12, ADR-0029): the builder's
/// edits, the rules that gate Post, the idempotency key, the exclusions with
/// photos and a schedule, FEATURE_DISABLED and the echo check.
void main() {
  setUpAll(() {
    registerFallbackValue(ReplyPolicy.REPLY_POLICY_UNSPECIFIED);
    registerFallbackValue(newDraftPoll());
  });

  late _MockPostsRepository repo;
  late PendingPostsCubit pending;
  late List<_Sent> sent;

  setUp(() {
    repo = _MockPostsRepository();
    pending = PendingPostsCubit();
    sent = [];
    when(() => repo.subFeatureEnabled(any())).thenReturn(true);
  });

  tearDown(() => pending.close());

  ComposerCubit make({
    bool polls = true,
    bool engagement = true,
    bool schedule = true,
    String quote = '',
  }) {
    final cubit = ComposerCubit(
      postsRepository: repo,
      pending: pending,
      author: common.AuthorSnapshot(userId: 'me', handle: 'me'),
      quoteOfPostId: quote,
      scheduleEnabled: schedule,
      pollsFlag: polls,
      engagementOn: engagement,
    );
    addTearDown(cubit.close);
    return cubit;
  }

  /// Answers each CreatePost with the next of [answers] (a view, or an
  /// exception to throw); the last repeats.
  void stubCreate(List<Object> answers) {
    var call = 0;
    when(
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
    ).thenAnswer((i) async {
      sent.add(
        _Sent(
          i.namedArguments[#idempotencyKey] as String,
          i.namedArguments[#text] as String,
          i.namedArguments[#poll] as DraftPoll?,
        ),
      );
      final answer = answers[call < answers.length ? call : answers.length - 1];
      call++;
      if (answer is Exception || answer is Error) throw answer;
      return answer as pb.PostView;
    });
  }

  ComposerCubit ready({
    String text = 'Best colour?',
    List<String> choices = const ['Red', 'Blue'],
  }) {
    final cubit = make();
    cubit.textChanged(text);
    cubit.pollAdded();
    for (var i = 0; i < choices.length; i++) {
      if (i >= cubit.state.poll!.choices.length) cubit.pollChoiceAdded();
      cubit.pollChoiceChanged(i, choices[i]);
    }
    return cubit;
  }

  pb.PostView withPoll() {
    final view = postView(1, text: 'Best colour?');
    view.post.poll = pb.Poll();
    return view;
  }

  group('adding and removing', () {
    test('Poll opens two empty choices and a one day length', () {
      final cubit = make();
      cubit.pollAdded();
      expect(cubit.state.hasPoll, isTrue);
      expect(cubit.state.poll!.choices, ['', '']);
      expect(cubit.state.poll!.durationMinutes, kPollDefaultMinutes);
    });

    test('is refused without the flag, without engagement and for a quote', () {
      final noFlag = make(polls: false)..pollAdded();
      expect(noFlag.state.hasPoll, isFalse);
      final noEngagement = make(engagement: false)..pollAdded();
      expect(noEngagement.state.hasPoll, isFalse);
      final quote = make(quote: postId(5))..pollAdded();
      expect(quote.state.hasPoll, isFalse);
    });

    test('is refused once the gate learned polls are disabled', () {
      final cubit = make();
      when(() => repo.subFeatureEnabled(kFeaturePolls)).thenReturn(false);
      cubit.pollAdded();
      expect(cubit.state.hasPoll, isFalse);
    });

    test('Remove poll goes back to a plain post and keeps the text', () {
      final cubit = ready();
      cubit.pollRemoved();
      expect(cubit.state.hasPoll, isFalse);
      expect(cubit.state.draft.text, 'Best colour?');
      expect(cubit.state.canSubmit, isTrue);
    });

    test('the poll survives typing in the question', () {
      final cubit = make();
      cubit.pollAdded();
      cubit.pollChoiceChanged(0, 'Red');
      cubit.pollDurationChanged(30);
      cubit.textChanged('Best');
      cubit.textChanged('Best colour?');
      expect(cubit.state.poll!.choices, ['Red', '']);
      expect(cubit.state.poll!.durationMinutes, 30);
    });
  });

  group('choices', () {
    test('Add a choice stops at four; remove keeps two', () {
      final cubit = make()..pollAdded();
      cubit.pollChoiceAdded();
      cubit.pollChoiceAdded();
      cubit.pollChoiceAdded();
      expect(cubit.state.poll!.choices, hasLength(4));
      cubit.pollChoiceRemoved(3);
      cubit.pollChoiceRemoved(2);
      cubit.pollChoiceRemoved(1);
      expect(cubit.state.poll!.choices, hasLength(2));
    });

    test('removing choice 3 of 4 moves choice 4 up', () {
      final cubit = ready(choices: ['a', 'b', 'c', 'd']);
      cubit.pollChoiceRemoved(2);
      expect(cubit.state.poll!.choices, ['a', 'b', 'd']);
    });
  });

  group('the length', () {
    test('under 5 minutes is raised to 5 with the hint flag', () {
      final cubit = make()..pollAdded();
      cubit.pollDurationChanged(3);
      expect(cubit.state.poll!.durationMinutes, 5);
      expect(cubit.state.pollDurationClamped, isTrue);
      cubit.pollDurationChanged(90);
      expect(cubit.state.pollDurationClamped, isFalse);
    });

    test('over 7 days is cut to 7 days', () {
      final cubit = make()..pollAdded();
      cubit.pollDurationChanged(7 * 1440 + 60);
      expect(cubit.state.poll!.durationMinutes, kPollMaxMinutes);
    });
  });

  group('Post is enabled only when the rules hold', () {
    test('2 filled choices and text: enabled', () {
      expect(ready().state.canSubmit, isTrue);
    });

    test('a 26th code point disables Post', () {
      final cubit = ready(choices: ['a' * 26, 'b']);
      expect(cubit.state.canSubmit, isFalse);
    });

    test('duplicate choices disable Post', () {
      expect(ready(choices: ['Yes', 'YES']).state.canSubmit, isFalse);
    });

    test('an empty choice or an empty question disables Post', () {
      expect(ready(choices: ['Red', '']).state.canSubmit, isFalse);
      expect(ready(text: '  ').state.canSubmit, isFalse);
    });
  });

  group('exclusions use the rules object', () {
    test('a schedule refuses the poll', () {
      final cubit = make();
      cubit.scheduleChanged(DateTime.now().add(const Duration(days: 1)));
      cubit.pollAdded();
      expect(cubit.state.hasPoll, isFalse);
      expect(cubit.rules.poll, ComposerBlock.scheduled);
    });

    test('a poll refuses the schedule, and Schedule is still offered', () {
      final cubit = make()..pollAdded();
      cubit.scheduleChanged(DateTime.now().add(const Duration(days: 1)));
      expect(cubit.state.scheduledAt, isNull);
      expect(cubit.rules.schedule, ComposerBlock.hasPoll);
      // The button stays (disabled with its reason), it does not vanish.
      expect(cubit.canSchedule, isTrue);
    });

    test('with a poll the rules switch photos and GIF off', () {
      final cubit = make()..pollAdded();
      expect(cubit.rules.photo, ComposerBlock.hasPoll);
      expect(cubit.rules.gif, ComposerBlock.hasPoll);
    });
  });

  group('submit', () {
    test('sends the normalised choices and the length, once', () async {
      stubCreate([withPoll()]);
      final cubit = ready(choices: ['  Red ', 'Blue']);
      cubit.pollDurationChanged(90);
      await cubit.submit();
      expect(sent, hasLength(1));
      expect(sent.single.poll!.choices, ['Red', 'Blue']);
      expect(sent.single.poll!.durationMinutes, 90);
      expect(cubit.state.status, ComposerStatus.posted);
      expect(cubit.state.pollNotAdded, isFalse);
    });

    test(
      'a retry of the same poll reuses its key, also after a respace',
      () async {
        stubCreate([const NetworkException('offline'), withPoll()]);
        final cubit = ready();
        await cubit.submit();
        expect(cubit.state.error, isA<NetworkException>());
        // Only spacing changed: the server hashes the normalised labels, so it
        // is the same request and must keep the key.
        cubit.pollChoiceChanged(0, ' Red ');
        await cubit.submit();
        expect(sent, hasLength(2));
        expect(sent[1].key, sent[0].key);
      },
    );

    test('a real change to the poll gets its own key', () async {
      stubCreate([const NetworkException('offline')]);
      final cubit = ready();
      await cubit.submit();
      cubit.pollChoiceChanged(1, 'Green');
      await cubit.submit();
      expect(sent[1].key, isNot(sent[0].key));
    });

    test('a different length is a different key', () async {
      stubCreate([const NetworkException('offline')]);
      final cubit = ready();
      await cubit.submit();
      cubit.pollDurationChanged(30);
      await cubit.submit();
      expect(sent[1].key, isNot(sent[0].key));
    });

    test('a plain post sends no poll', () async {
      stubCreate([postView(1)]);
      final cubit = make()..textChanged('hello');
      await cubit.submit();
      expect(sent.single.poll, isNull);
    });
  });

  group('server answers', () {
    test('FEATURE_DISABLED polls drops the poll and keeps the text', () async {
      stubCreate([const FeatureDisabledException('x', feature: kFeaturePolls)]);
      final cubit = ready();
      await cubit.submit();
      expect(cubit.state.hasPoll, isFalse);
      expect(cubit.state.draft.text, 'Best colour?');
      expect(cubit.state.error, isA<FeatureDisabledException>());
      expect(cubit.state.canSubmit, isTrue);
    });

    test('VALIDATION field=poll keeps the poll for the user to fix', () async {
      stubCreate([const ValidationException('x', field: 'poll')]);
      final cubit = ready();
      await cubit.submit();
      expect(cubit.state.hasPoll, isTrue);
      expect(cubit.state.error, isA<ValidationException>());
    });

    test('an echo without a poll sets pollNotAdded (L-1)', () async {
      stubCreate([postView(1)]);
      final cubit = ready();
      await cubit.submit();
      expect(cubit.state.status, ComposerStatus.posted);
      expect(cubit.state.pollNotAdded, isTrue);
    });
  });
}

class _Sent {
  const _Sent(this.key, this.text, this.poll);

  final String key;
  final String text;
  final DraftPoll? poll;
}
