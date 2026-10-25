
import 'package:connectrpc/connect.dart' as connect;
import 'package:drift/native.dart';
import 'package:dzeroth/core/network/api_client.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/storage/app_database.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/features/posts/domain/posts_feature_flag.dart';
import 'package:dzeroth/features/posts/domain/reply_audience.dart';
import 'package:dzeroth/features/timeline/data/timeline_store.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pbenum.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_transport.dart';
import '../../../support/posts_fixtures.dart';
import '../../../support/scheduled_fixtures.dart';

const _schedule = '/dzeroth.posts.v1.PostService/SchedulePost';
const _list = '/dzeroth.posts.v1.PostService/ListScheduledPosts';
const _cancel = '/dzeroth.posts.v1.PostService/CancelScheduledPost';

/// SchedulePost, ListScheduledPosts and CancelScheduledPost through the real
/// `PostServiceClient` and a fake transport (CMP-D6, ADR-0021 D4).
void main() {
  late AppDatabase db;
  late FakeTransport transport;
  late PostsRepository repo;
  late PostsFeatureGate gate;
  late List<Object> requests;
  late Object Function(String procedure) answer;
  var postsOn = true;

  setUp(() {
    postsOn = true;
    db = AppDatabase.forTesting(NativeDatabase.memory());
    requests = [];
    answer = (_) => throw StateError('unscripted');
    transport = FakeTransport((procedure, input) async {
      requests.add(input);
      final r = answer(procedure);
      if (r is Exception) throw r;
      return r;
    });
    gate = PostsFeatureGate(isPostsEnabled: () => postsOn);
    repo = PostsRepository(
      apiClient: ApiClient.withTransport(transport),
      store: TimelineStore(db),
      gate: gate,
    );
  });

  tearDown(() => db.close());

  final at = scheduledBase().add(const Duration(days: 2));

  group('schedulePost', () {
    test(
      'sends the request with a UTC timestamp and no reply fields',
      () async {
        answer = (_) =>
            pb.SchedulePostResponse(scheduledPost: scheduledPost(1));

        final item = await repo.schedulePost(
          idempotencyKey: 'key-0123456789abcdef',
          text: 'later',
          publishAt: at,
        );

        expect(transport.calledProcedures, [_schedule]);
        final sent = requests.single as pb.SchedulePostRequest;
        expect(sent.idempotencyKey, 'key-0123456789abcdef');
        expect(sent.text, 'later');
        expect(sent.publishAt.toDateTime(toLocal: false), at.toUtc());
        expect(sent.replyPolicy, ReplyPolicy.REPLY_POLICY_UNSPECIFIED);
        expect(sent.mediaIds, isEmpty);
        expect(sent.paidPartnership, isFalse);
        expect(sent.madeWithAi, isFalse);
        expect(item.scheduledId, scheduledId(1));
      },
    );

    test('media ids, alt texts and the audience go along', () async {
      answer = (_) => pb.SchedulePostResponse(scheduledPost: scheduledPost(1));

      await repo.schedulePost(
        idempotencyKey: 'key-0123456789abcdef',
        text: 'look',
        publishAt: at,
        mediaIds: const ['m1', 'm2'],
        mediaAltTexts: const ['a', ''],
        replyPolicy: ReplyAudience.following.wire,
      );

      final sent = requests.single as pb.SchedulePostRequest;
      expect(sent.mediaIds, ['m1', 'm2']);
      expect(sent.mediaAltTexts, ['a', '']);
      expect(sent.replyPolicy, ReplyPolicy.REPLY_POLICY_FOLLOWING);
    });

    test('the returned item carries the time the server stored', () async {
      final stored = at.add(const Duration(minutes: 1));
      answer = (_) => pb.SchedulePostResponse(
        scheduledPost: scheduledPost(1, publishAt: stored),
      );
      final item = await repo.schedulePost(
        idempotencyKey: 'key-0123456789abcdef',
        text: 'later',
        publishAt: at,
      );
      expect(item.publishAt.toDateTime(toLocal: false), stored.toUtc());
    });

    test('posts flag off: nothing is sent', () async {
      postsOn = false;
      await expectLater(
        repo.schedulePost(
          idempotencyKey: 'key-0123456789abcdef',
          text: 'later',
          publishAt: at,
        ),
        throwsA(isA<FeatureDisabledException>()),
      );
      expect(requests, isEmpty);
    });

    test(
      'FEATURE_DISABLED feature=scheduled_posts hides it and stops sends',
      () async {
        answer = (_) => serverError(
          connect.Code.failedPrecondition,
          common.ErrorReason.ERROR_REASON_FEATURE_DISABLED,
          metadata: {'feature': kFeatureScheduledPosts},
        );
        await expectLater(
          repo.schedulePost(
            idempotencyKey: 'key-0123456789abcdef',
            text: 'later',
            publishAt: at,
          ),
          throwsA(
            isA<FeatureDisabledException>().having(
              (e) => e.feature,
              'feature',
              kFeatureScheduledPosts,
            ),
          ),
        );
        expect(gate.subFeatureEnabled(kFeatureScheduledPosts), isFalse);
        expect(repo.subFeatureEnabled(kFeatureScheduledPosts), isFalse);
        // Posting itself is unaffected.
        expect(gate.subFeatureEnabled(kPostsSubFeatureMedia), isTrue);

        requests.clear();
        await expectLater(
          repo.schedulePost(
            idempotencyKey: 'key-0123456789abcdef',
            text: 'later',
            publishAt: at,
          ),
          throwsA(isA<FeatureDisabledException>()),
        );
        expect(requests, isEmpty, reason: 'not sent while known to be off');
      },
    );

    test('media sub-feature off: a schedule with photos is not sent', () async {
      answer = (_) => serverError(
        connect.Code.failedPrecondition,
        common.ErrorReason.ERROR_REASON_FEATURE_DISABLED,
        metadata: {'feature': kPostsSubFeatureMedia},
      );
      await expectLater(
        repo.schedulePost(
          idempotencyKey: 'key-0123456789abcdef',
          text: 'look',
          publishAt: at,
          mediaIds: const ['m1'],
        ),
        throwsA(isA<FeatureDisabledException>()),
      );
      requests.clear();
      await expectLater(
        repo.schedulePost(
          idempotencyKey: 'key-0123456789abcdef',
          text: 'look',
          publishAt: at,
          mediaIds: const ['m1'],
        ),
        throwsA(isA<FeatureDisabledException>()),
      );
      expect(requests, isEmpty);
    });

    test(
      'cap errors map to LimitReached / QuotaExceeded with the name',
      () async {
        answer = (_) => serverError(
          connect.Code.resourceExhausted,
          common.ErrorReason.ERROR_REASON_LIMIT_REACHED,
          metadata: {'limit': 'scheduled_window'},
        );
        await expectLater(
          repo.schedulePost(
            idempotencyKey: 'key-0123456789abcdef',
            text: 'later',
            publishAt: at,
          ),
          throwsA(
            isA<LimitReachedException>().having(
              (e) => e.quota,
              'quota',
              'scheduled_window',
            ),
          ),
        );
        answer = (_) => serverError(
          connect.Code.resourceExhausted,
          common.ErrorReason.ERROR_REASON_QUOTA_EXCEEDED,
          metadata: {'quota': 'schedules'},
        );
        await expectLater(
          repo.schedulePost(
            idempotencyKey: 'key-0123456789abcdef',
            text: 'later',
            publishAt: at,
          ),
          throwsA(
            isA<QuotaExceededException>().having(
              (e) => e.quota,
              'quota',
              'schedules',
            ),
          ),
        );
      },
    );

    test('VALIDATION on publish_at carries the field', () async {
      answer = (_) => rejectedToken('publish_at');
      await expectLater(
        repo.schedulePost(
          idempotencyKey: 'key-0123456789abcdef',
          text: 'later',
          publishAt: at,
        ),
        throwsA(
          isA<ValidationException>().having(
            (e) => e.field,
            'field',
            'publish_at',
          ),
        ),
      );
    });
  });

  group('listScheduledPosts', () {
    test('asks for 20 by default and passes the token', () async {
      answer = (_) => pb.ListScheduledPostsResponse(
        scheduledPosts: [scheduledPost(1), failedScheduledPost(2)],
        nextPageToken: 'next',
      );

      final page = await repo.listScheduledPosts(pageToken: 'tok');

      final sent = requests.single as pb.ListScheduledPostsRequest;
      expect(sent.pageSize, 20);
      expect(sent.pageToken, 'tok');
      expect(page.scheduledPosts, hasLength(2));
      expect(page.nextPageToken, 'next');
    });

    test('is not blocked by the scheduling sub-feature being off', () async {
      // A SchedulePost answer makes the gate remember the sub-feature as off.
      answer = (_) => serverError(
        connect.Code.failedPrecondition,
        common.ErrorReason.ERROR_REASON_FEATURE_DISABLED,
        metadata: {'feature': kFeatureScheduledPosts},
      );
      await expectLater(
        repo.schedulePost(
          idempotencyKey: 'key-0123456789abcdef',
          text: 'later',
          publishAt: at,
        ),
        throwsA(isA<FeatureDisabledException>()),
      );
      expect(repo.subFeatureEnabled(kFeatureScheduledPosts), isFalse);

      // Listing (and cancelling) what was scheduled still works: the server
      // lets a caller outside the rollout do both.
      answer = (_) => pb.ListScheduledPostsResponse();
      await repo.listScheduledPosts();
      expect(transport.calledProcedures.last, _list);
    });

    test('posts flag off: nothing is sent', () async {
      postsOn = false;
      await expectLater(
        repo.listScheduledPosts(),
        throwsA(isA<FeatureDisabledException>()),
      );
      expect(requests, isEmpty);
    });

    test('a rate limit is held: the next read is not sent', () async {
      answer = (_) => serverError(
        connect.Code.resourceExhausted,
        common.ErrorReason.ERROR_REASON_RATE_LIMITED,
      );
      await expectLater(
        repo.listScheduledPosts(),
        throwsA(isA<RateLimitedException>()),
      );
      requests.clear();
      await expectLater(
        repo.listScheduledPosts(),
        throwsA(isA<RateLimitedException>()),
      );
      expect(requests, isEmpty);
    });
  });

  group('cancelScheduledPost', () {
    test('sends the id and the key and returns the current state', () async {
      answer = (_) => pb.CancelScheduledPostResponse(
        scheduledPost: scheduledPost(
          3,
          status: ScheduledPostStatus.SCHEDULED_POST_STATUS_CANCELLED,
        ),
      );

      final item = await repo.cancelScheduledPost(
        scheduledId: scheduledId(3),
        idempotencyKey: 'cancel-key-0123456789',
      );

      expect(transport.calledProcedures, [_cancel]);
      final sent = requests.single as pb.CancelScheduledPostRequest;
      expect(sent.scheduledId, scheduledId(3));
      expect(sent.idempotencyKey, 'cancel-key-0123456789');
      expect(item.status, ScheduledPostStatus.SCHEDULED_POST_STATUS_CANCELLED);
    });

    test('NOT_FOUND surfaces as NotFoundException', () async {
      answer = (_) => connect.ConnectException(connect.Code.notFound, 'gone');
      await expectLater(
        repo.cancelScheduledPost(
          scheduledId: scheduledId(3),
          idempotencyKey: 'cancel-key-0123456789',
        ),
        throwsA(isA<NotFoundException>()),
      );
    });
  });
}
