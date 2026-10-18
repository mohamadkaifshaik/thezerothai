import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/engagement/data/engagement_repository.dart';
import 'package:dzeroth/features/engagement/domain/engagement_entry.dart';
import 'package:dzeroth/features/engagement/presentation/bloc/engagement_cubit.dart';
import 'package:dzeroth/features/engagement/presentation/bloc/engagement_state.dart';
import 'package:dzeroth/gen/dzeroth/engagement/v1/engagement.pb.dart' as pb;
import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../../support/posts_fixtures.dart';

class MockEngagementRepository extends Mock implements EngagementRepository {}

pb.PostEngagement _answer({
  bool liked = false,
  bool reposted = false,
  int likes = 0,
  int reposts = 0,
}) => pb.PostEngagement(
  postId: postId(1),
  likedByViewer: liked,
  repostedByViewer: reposted,
  likeCount: Int64(likes),
  repostCount: Int64(reposts),
);

void main() {
  late MockEngagementRepository repo;
  final target = postId(1);
  const row = EngagementEntry(
    liked: false,
    reposted: false,
    likeCount: 4,
    repostCount: 2,
  );

  setUp(() {
    repo = MockEngagementRepository();
  });

  EngagementCubit build() => EngagementCubit(repository: repo);

  When<Future<pb.PostEngagement>> like() => when(
    () => repo.like(
      postId: any(named: 'postId'),
      idempotencyKey: any(named: 'idempotencyKey'),
    ),
  );
  When<Future<pb.PostEngagement>> unlike() => when(
    () => repo.unlike(
      postId: any(named: 'postId'),
      idempotencyKey: any(named: 'idempotencyKey'),
    ),
  );
  When<Future<pb.PostEngagement>> repost() => when(
    () => repo.repost(
      postId: any(named: 'postId'),
      idempotencyKey: any(named: 'idempotencyKey'),
    ),
  );
  When<Future<pb.PostEngagement>> undo() => when(
    () => repo.undoRepost(
      postId: any(named: 'postId'),
      idempotencyKey: any(named: 'idempotencyKey'),
    ),
  );

  group('like', () {
    blocTest<EngagementCubit, EngagementState>(
      'shows the like at once, then the server counts',
      build: () {
        like().thenAnswer((_) async => _answer(liked: true, likes: 9));
        return build();
      },
      act: (cubit) => cubit.setLiked(target, liked: true, shown: row),
      expect: () => [
        isA<EngagementState>().having(
          (s) => s.entries[target],
          'optimistic',
          isA<EngagementEntry>()
              .having((e) => e.liked, 'liked', true)
              .having((e) => e.likeCount, 'count + 1', 5)
              .having((e) => e.likeBusy, 'busy', true),
        ),
        isA<EngagementState>().having(
          (s) => s.entries[target],
          'confirmed',
          isA<EngagementEntry>()
              .having((e) => e.liked, 'liked', true)
              .having((e) => e.likeCount, 'server count', 9)
              .having((e) => e.likeBusy, 'busy', false)
              .having((e) => e.repostCount, 'other count kept', 2),
        ),
      ],
      verify: (_) {
        verify(
          () => repo.like(
            postId: target,
            idempotencyKey: any(named: 'idempotencyKey'),
          ),
        ).called(1);
      },
    );

    blocTest<EngagementCubit, EngagementState>(
      'rolls back and reports one typed failure when the call fails',
      build: () {
        like().thenAnswer(
          (_) async => throw const QuotaExceededException('no', quota: 'likes'),
        );
        return build();
      },
      act: (cubit) => cubit.setLiked(target, liked: true, shown: row),
      expect: () => [
        isA<EngagementState>().having(
          (s) => s.entries[target]!.liked,
          'optimistic',
          true,
        ),
        isA<EngagementState>()
            .having((s) => s.entries[target]!.liked, 'rolled back', false)
            .having((s) => s.entries[target]!.likeCount, 'count back', 4)
            .having((s) => s.entries[target]!.likeBusy, 'idle', false)
            .having(
              (s) => s.failure,
              'failure',
              isA<EngagementFailure>()
                  .having((f) => f.postId, 'postId', target)
                  .having((f) => f.action, 'action', EngagementAction.like)
                  .having(
                    (f) => f.error,
                    'error',
                    isA<QuotaExceededException>(),
                  ),
            ),
      ],
    );

    test(
      'a retry after a failure reuses the key; a new intent gets a new one',
      () async {
        final keys = <String>[];
        var fail = true;
        like().thenAnswer((invocation) async {
          keys.add(invocation.namedArguments[#idempotencyKey] as String);
          if (fail) throw const NetworkException('offline');
          return _answer(liked: true, likes: 5);
        });
        unlike().thenAnswer((invocation) async {
          keys.add(invocation.namedArguments[#idempotencyKey] as String);
          return _answer(likes: 4);
        });
        final cubit = build();

        await cubit.setLiked(target, liked: true, shown: row);
        fail = false;
        await cubit.setLiked(target, liked: true, shown: row);
        expect(keys[0], keys[1], reason: 'same intent, same key');

        await cubit.setLiked(target, liked: false, shown: row);
        await cubit.setLiked(target, liked: true, shown: row);
        expect(
          keys.toSet().length,
          3,
          reason: 'a different request, a new key',
        );
        await cubit.close();
      },
    );

    test('never retries on its own, not even after degraded mode', () async {
      like().thenAnswer(
        (_) async => throw const DegradedModeException('limited'),
      );
      final cubit = build();

      await cubit.setLiked(target, liked: true, shown: row);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      verify(
        () => repo.like(
          postId: any(named: 'postId'),
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      ).called(1);
      expect(cubit.state.failure!.error, isA<DegradedModeException>());
      await cubit.close();
    });

    test('liking what is already liked sends nothing', () async {
      final cubit = build();

      await cubit.setLiked(
        target,
        liked: true,
        shown: const EngagementEntry(liked: true, reposted: false),
      );

      verifyZeroInteractions(repo);
      await cubit.close();
    });
  });

  group('latest intent wins, one request at a time', () {
    test(
      'like then unlike while the like is in flight: like, then unlike',
      () async {
        final firstCall = Completer<pb.PostEngagement>();
        var calls = 0;
        like().thenAnswer((_) {
          calls++;
          return firstCall.future;
        });
        unlike().thenAnswer((_) async => _answer(likes: 4));
        final cubit = build();

        final done = cubit.setLiked(target, liked: true, shown: row);
        await Future<void>.delayed(Duration.zero);
        // Second tap while in flight: the display flips back at once.
        unawaited(cubit.setLiked(target, liked: false, shown: row));
        expect(cubit.state.entries[target]!.liked, isFalse);
        expect(calls, 1);

        firstCall.complete(_answer(liked: true, likes: 5));
        await done;

        verify(
          () => repo.unlike(
            postId: target,
            idempotencyKey: any(named: 'idempotencyKey'),
          ),
        ).called(1);
        expect(cubit.state.entries[target]!.liked, isFalse);
        expect(cubit.state.entries[target]!.likeBusy, isFalse);
        expect(cubit.state.entries[target]!.likeCount, 4);
        await cubit.close();
      },
    );

    test(
      'like, unlike, like while in flight sends only the first like',
      () async {
        final firstCall = Completer<pb.PostEngagement>();
        like().thenAnswer((_) => firstCall.future);
        final cubit = build();

        final done = cubit.setLiked(target, liked: true, shown: row);
        await Future<void>.delayed(Duration.zero);
        unawaited(cubit.setLiked(target, liked: false, shown: row));
        unawaited(cubit.setLiked(target, liked: true, shown: row));
        firstCall.complete(_answer(liked: true, likes: 5));
        await done;

        verify(
          () => repo.like(
            postId: any(named: 'postId'),
            idempotencyKey: any(named: 'idempotencyKey'),
          ),
        ).called(1);
        verifyNever(
          () => repo.unlike(
            postId: any(named: 'postId'),
            idempotencyKey: any(named: 'idempotencyKey'),
          ),
        );
        expect(cubit.state.entries[target]!.liked, isTrue);
        await cubit.close();
      },
    );

    test('like and repost are independent lanes', () async {
      final likeCall = Completer<pb.PostEngagement>();
      like().thenAnswer((_) => likeCall.future);
      repost().thenAnswer((_) async => _answer(reposted: true, reposts: 3));
      final cubit = build();

      final likeDone = cubit.setLiked(target, liked: true, shown: row);
      await Future<void>.delayed(Duration.zero);
      await cubit.setReposted(target, reposted: true, shown: row);

      expect(cubit.state.entries[target]!.reposted, isTrue);
      expect(cubit.state.entries[target]!.repostCount, 3);
      expect(cubit.state.entries[target]!.likeBusy, isTrue);

      likeCall.complete(_answer(liked: true, likes: 5));
      await likeDone;
      expect(cubit.state.entries[target]!.liked, isTrue);
      expect(cubit.state.entries[target]!.reposted, isTrue);
      await cubit.close();
    });
  });

  group('repost', () {
    test('repost then undo use their own RPCs and counts', () async {
      repost().thenAnswer((_) async => _answer(reposted: true, reposts: 3));
      undo().thenAnswer((_) async => _answer(reposts: 2));
      final cubit = build();

      await cubit.setReposted(target, reposted: true, shown: row);
      expect(cubit.state.entries[target]!.reposted, isTrue);
      expect(cubit.state.entries[target]!.repostCount, 3);

      await cubit.setReposted(target, reposted: false, shown: row);
      expect(cubit.state.entries[target]!.reposted, isFalse);
      expect(cubit.state.entries[target]!.repostCount, 2);
      await cubit.close();
    });

    test('a failed repost rolls back and names the repost action', () async {
      repost().thenAnswer((_) async => throw const NotFoundException('gone'));
      final cubit = build();

      await cubit.setReposted(target, reposted: true, shown: row);

      expect(cubit.state.entries[target]!.reposted, isFalse);
      expect(cubit.state.failure!.action, EngagementAction.repost);
      cubit.failureShown();
      expect(cubit.state.failure, isNull);
      await cubit.close();
    });

    test(
      'unknown counts (REPOST row) stay unknown until the server answers',
      () async {
        final completer = Completer<pb.PostEngagement>();
        like().thenAnswer((_) => completer.future);
        final cubit = build();
        const repostRow = EngagementEntry(liked: false, reposted: false);

        final done = cubit.setLiked(target, liked: true, shown: repostRow);
        await Future<void>.delayed(Duration.zero);
        expect(cubit.state.entries[target]!.liked, isTrue);
        expect(cubit.state.entries[target]!.likeCount, isNull);

        completer.complete(_answer(liked: true, likes: 12));
        await done;
        expect(cubit.state.entries[target]!.likeCount, 12);
        await cubit.close();
      },
    );
  });

  group('rows and sessions', () {
    test(
      'a refreshed row (different server data) starts again from it',
      () async {
        like().thenAnswer((_) async => _answer(liked: true, likes: 5));
        unlike().thenAnswer((_) async => _answer(likes: 20));
        final cubit = build();

        await cubit.setLiked(target, liked: true, shown: row);
        // The feed refreshed: the server says 21 likes and liked.
        const fresh = EngagementEntry(
          liked: true,
          reposted: false,
          likeCount: 21,
          repostCount: 2,
        );
        await cubit.setLiked(target, liked: false, shown: fresh);

        verify(
          () => repo.unlike(
            postId: target,
            idempotencyKey: any(named: 'idempotencyKey'),
          ),
        ).called(1);
        expect(cubit.state.entries[target]!.liked, isFalse);
        expect(cubit.state.entries[target]!.likeCount, 20);
        await cubit.close();
      },
    );

    test(
      'reset forgets entries and ignores a request still in flight',
      () async {
        final completer = Completer<pb.PostEngagement>();
        like().thenAnswer((_) => completer.future);
        final cubit = build();

        final done = cubit.setLiked(target, liked: true, shown: row);
        await Future<void>.delayed(Duration.zero);
        cubit.reset();
        expect(cubit.state.entries, isEmpty);

        completer.complete(_answer(liked: true, likes: 5));
        await done;
        expect(cubit.state.entries, isEmpty);
        await cubit.close();
      },
    );

    test('an unexpected error is reported and rolled back', () async {
      like().thenAnswer((_) async => throw StateError('boom'));
      Object? reported;
      final cubit = EngagementCubit(
        repository: repo,
        onUnexpectedError: (e, _) => reported = e,
      );

      await cubit.setLiked(target, liked: true, shown: row);

      expect(reported, isA<StateError>());
      expect(cubit.state.entries[target]!.liked, isFalse);
      expect(cubit.state.failure!.error, isA<UnknownApiException>());
      await cubit.close();
    });
  });
}
