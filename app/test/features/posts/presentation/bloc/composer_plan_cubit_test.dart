import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/beacons/domain/beacons_feature_flag.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/features/posts/domain/composer_attachment_rules.dart';
import 'package:dzeroth/features/posts/presentation/bloc/composer_cubit.dart';
import 'package:dzeroth/features/posts/presentation/bloc/pending_posts_cubit.dart';
import 'package:dzeroth/features/posts/presentation/post_error_messages.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../../support/posts_fixtures.dart';

class MockPostsRepository extends Mock implements PostsRepository {}

const _plan = '1234567890123456789';

void main() {
  late MockPostsRepository repo;
  late PendingPostsCubit pending;
  final open = <ComposerCubit>[];

  setUp(() {
    repo = MockPostsRepository();
    pending = PendingPostsCubit();
    when(() => repo.subFeatureEnabled(any())).thenReturn(true);
  });

  tearDown(() async {
    for (final c in open) {
      await c.close();
    }
    open.clear();
    await pending.close();
  });

  ComposerCubit make({
    String beaconId = _plan,
    String quote = '',
    bool polls = true,
    bool schedule = true,
  }) {
    final c = ComposerCubit(
      postsRepository: repo,
      pending: pending,
      author: common.AuthorSnapshot(userId: 'me', handle: 'me'),
      beaconId: beaconId,
      quoteOfPostId: quote,
      pollsFlag: polls,
      engagementOn: polls,
      scheduleEnabled: schedule,
    );
    open.add(c);
    return c;
  }

  When<Future<pb.PostView>> stubCreate() => when(
    () => repo.createPost(
      idempotencyKey: any(named: 'idempotencyKey'),
      text: any(named: 'text'),
      replyToPostId: any(named: 'replyToPostId'),
      quoteOfPostId: any(named: 'quoteOfPostId'),
      mediaIds: any(named: 'mediaIds'),
      mediaAltTexts: any(named: 'mediaAltTexts'),
      beaconId: any(named: 'beaconId'),
    ),
  );

  List<String> sentBeaconIds() => verify(
    () => repo.createPost(
      idempotencyKey: any(named: 'idempotencyKey'),
      text: any(named: 'text'),
      replyToPostId: any(named: 'replyToPostId'),
      quoteOfPostId: any(named: 'quoteOfPostId'),
      mediaIds: any(named: 'mediaIds'),
      mediaAltTexts: any(named: 'mediaAltTexts'),
      beaconId: captureAny(named: 'beaconId'),
    ),
  ).captured.cast<String>();

  group('an attached plan', () {
    test('is sent as beacon_id', () async {
      stubCreate().thenAnswer((_) async => postView(9));
      final cubit = make()..textChanged('come along');
      expect(cubit.state.hasPlan, isTrue);

      await cubit.submit();

      expect(sentBeaconIds(), [_plan]);
      expect(cubit.state.status, ComposerStatus.posted);
    });

    test('removed, it is not sent and the request gets its own key', () async {
      final keys = <String>[];
      stubCreate().thenAnswer((i) async {
        keys.add(i.namedArguments[#idempotencyKey] as String);
        throw const NetworkException('offline');
      });
      final cubit = make()..textChanged('come along');
      await cubit.submit();

      cubit.removePlan();
      expect(cubit.state.hasPlan, isFalse);
      await cubit.submit();

      expect(keys, hasLength(2));
      expect(keys[0], isNot(keys[1]));
      expect(sentBeaconIds(), [_plan, '']);
    });

    test('a retry with the plan still attached reuses the key', () async {
      final keys = <String>[];
      var fail = true;
      stubCreate().thenAnswer((i) async {
        keys.add(i.namedArguments[#idempotencyKey] as String);
        if (fail) throw const NetworkException('offline');
        return postView(9);
      });
      final cubit = make()..textChanged('come along');
      await cubit.submit();
      fail = false;
      await cubit.submit();

      expect(keys[0], keys[1]);
    });

    test('a plain composer sends no beacon_id', () async {
      stubCreate().thenAnswer((_) async => postView(9));
      final cubit = make(beaconId: '')..textChanged('hi');

      await cubit.submit();

      expect(sentBeaconIds(), ['']);
    });

    test('is dropped for a quote', () {
      final cubit = make(quote: postId(5));
      expect(cubit.state.hasPlan, isFalse);
    });

    test('blocks the poll button with its reason, and scheduling', () {
      final cubit = make();
      final rules = cubit.rules;

      expect(rules.showPoll, isTrue);
      expect(rules.poll, ComposerBlock.hasPlan);
      expect(rules.poll.pollTooltip, "Polls can't go with a plan");
      expect(cubit.canSchedule, isFalse);
      expect(rules.schedule, ComposerBlock.hasPlan);
    });

    test('with it removed, the poll and scheduling are open again', () {
      final cubit = make()..removePlan();

      expect(cubit.rules.poll, ComposerBlock.none);
      expect(cubit.canSchedule, isTrue);
    });

    test('FEATURE_DISABLED post_beacon_embed drops the plan, keeps the '
        'text', () async {
      stubCreate().thenAnswer(
        (_) async => throw const FeatureDisabledException(
          'off',
          feature: kFeaturePostBeaconEmbed,
        ),
      );
      final cubit = make()..textChanged('come along');

      await cubit.submit();

      expect(cubit.state.hasPlan, isFalse);
      expect(cubit.state.draft.text, 'come along');
      expect(cubit.state.error, isA<FeatureDisabledException>());
      expect(
        createPostErrorMessage(cubit.state.error!),
        contains("Plans can't be shared"),
      );
    });

    test(
      'a plan that is gone stays on screen for the user to remove',
      () async {
        stubCreate().thenAnswer(
          (_) async => throw const NotFoundException('beacon not found'),
        );
        final cubit = make()..textChanged('come along');

        await cubit.submit();

        expect(cubit.state.hasPlan, isTrue);
        expect(cubit.state.error, isA<NotFoundException>());
      },
    );
  });

  group('plan error copy', () {
    test('VALIDATION beacon_id has its own message', () {
      expect(
        createPostErrorMessage(
          const ValidationException('bad', field: 'beacon_id'),
        ),
        contains("This plan can't be shared in this post"),
      );
    });

    test('NOT_FOUND, ended and cancelled read as the plan', () {
      expect(
        planPostErrorMessage(const NotFoundException('beacon not found')),
        "This plan isn't available any more.",
      );
      expect(
        planPostErrorMessage(const StateConflictException('ended')),
        contains('already ended'),
      );
      expect(
        planPostErrorMessage(const StateConflictException('cancelled')),
        contains('cancelled'),
      );
    });

    test('anything else is the shared post copy', () {
      const e = NetworkException('offline');
      expect(planPostErrorMessage(e), createPostErrorMessage(e));
    });
  });
}
