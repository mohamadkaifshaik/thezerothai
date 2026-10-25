import 'dart:async';

import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/features/posts/presentation/bloc/scheduled_posts_cubit.dart';
import 'package:dzeroth/features/posts/presentation/bloc/scheduled_posts_state.dart';
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pbenum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../../support/scheduled_fixtures.dart';

class _MockPostsRepository extends Mock implements PostsRepository {}

/// The Scheduled list's logic (CMP-D6): paging, refresh, banner vs error, and
/// the optimistic Cancel / Dismiss with rollback.
void main() {
  late _MockPostsRepository repo;
  late List<String> keys;

  /// The page token of every ListScheduledPosts that was sent, in order.
  late List<String> listedTokens;

  setUp(() {
    repo = _MockPostsRepository();
    keys = [];
    listedTokens = [];
  });

  ScheduledPostsCubit make({int pageSize = 20, List<Object>? reported}) {
    final cubit = ScheduledPostsCubit(
      repository: repo,
      pageSize: pageSize,
      onUnexpectedError: reported == null
          ? null
          : (error, stack) => reported.add(error),
    );
    addTearDown(cubit.close);
    return cubit;
  }

  pb.ListScheduledPostsResponse page(
    List<pb.ScheduledPost> items, [
    String next = '',
  ]) =>
      pb.ListScheduledPostsResponse(scheduledPosts: items, nextPageToken: next);

  void stubList(Object Function(String token) answer) {
    when(
      () => repo.listScheduledPosts(
        pageToken: any(named: 'pageToken'),
        pageSize: any(named: 'pageSize'),
      ),
    ).thenAnswer((invocation) async {
      final token = invocation.namedArguments[#pageToken] as String;
      listedTokens.add(token);
      final r = answer(token);
      if (r is Exception) throw r;
      return r as pb.ListScheduledPostsResponse;
    });
  }

  void stubCancel(Future<pb.ScheduledPost> Function(String id) answer) {
    when(
      () => repo.cancelScheduledPost(
        scheduledId: any(named: 'scheduledId'),
        idempotencyKey: any(named: 'idempotencyKey'),
      ),
    ).thenAnswer((invocation) {
      keys.add(invocation.namedArguments[#idempotencyKey] as String);
      return answer(invocation.namedArguments[#scheduledId] as String);
    });
  }

  group('load', () {
    test(
      'starts loading, then shows PENDING and FAILED in the server order',
      () async {
        stubList((_) => page([scheduledPost(1), failedScheduledPost(2)], 'n'));
        final cubit = make();
        expect(cubit.state.status, ScheduledPostsStatus.loading);

        await cubit.load();

        expect(cubit.state.status, ScheduledPostsStatus.ready);
        expect(cubit.state.items.map((i) => i.scheduledId), [
          scheduledId(1),
          scheduledId(2),
        ]);
        expect(cubit.state.hasMore, isTrue);
        verify(() => repo.listScheduledPosts(pageToken: '', pageSize: 20))
            .called(1);
      },
    );

    test('other statuses are never shown', () async {
      stubList(
        (_) => page([
          scheduledPost(1),
          scheduledPost(
            2,
            status: ScheduledPostStatus.SCHEDULED_POST_STATUS_PUBLISHED,
          ),
          scheduledPost(
            3,
            status: ScheduledPostStatus.SCHEDULED_POST_STATUS_CANCELLED,
          ),
          failedScheduledPost(4),
        ]),
      );
      final cubit = make();
      await cubit.load();
      expect(cubit.state.items.map((i) => i.scheduledId), [
        scheduledId(1),
        scheduledId(4),
      ]);
    });

    test('nothing scheduled: ready with no rows', () async {
      stubList((_) => page([]));
      final cubit = make();
      await cubit.load();
      expect(cubit.state.status, ScheduledPostsStatus.ready);
      expect(cubit.state.items, isEmpty);
      expect(cubit.state.hasMore, isFalse);
    });

    test('a failed first page is an error, with nothing to show', () async {
      stubList((_) => const NetworkException('offline'));
      final cubit = make();
      await cubit.load();
      expect(cubit.state.status, ScheduledPostsStatus.error);
      expect(cubit.state.error, isA<NetworkException>());
      expect(cubit.state.items, isEmpty);
    });

    test('Retry (load again) recovers from the error', () async {
      var fail = true;
      stubList(
        (_) => fail ? const NetworkException('x') : page([scheduledPost(1)]),
      );
      final cubit = make();
      await cubit.load();
      fail = false;
      await cubit.load();
      expect(cubit.state.status, ScheduledPostsStatus.ready);
      expect(cubit.state.items, hasLength(1));
      expect(cubit.state.error, isNull);
    });

    test('an unexpected error is reported and shown as a failure', () async {
      final reported = <Object>[];
      stubList((_) => throw StateError('boom'));
      final cubit = make(reported: reported);
      await cubit.load();
      expect(cubit.state.status, ScheduledPostsStatus.error);
      expect(cubit.state.error, isA<UnknownApiException>());
      expect(reported.single, isA<StateError>());
    });
  });

  group('refresh', () {
    test('replaces the rows and clears the banner', () async {
      var round = 0;
      stubList(
        (_) => page(round++ == 0 ? [scheduledPost(1)] : [scheduledPost(2)]),
      );
      final cubit = make();
      await cubit.load();
      await cubit.refresh();
      expect(cubit.state.items.single.scheduledId, scheduledId(2));
      expect(cubit.state.notice, isNull);
    });

    test('a failed refresh keeps the rows under a banner', () async {
      var round = 0;
      stubList(
        (_) => round++ == 0
            ? page([scheduledPost(1)])
            : const NetworkException('offline'),
      );
      final cubit = make();
      await cubit.load();
      await cubit.refresh();
      expect(cubit.state.status, ScheduledPostsStatus.ready);
      expect(cubit.state.items, hasLength(1));
      expect(cubit.state.notice, isA<NetworkException>());
      expect(cubit.state.error, isNull);
    });

    test('two refreshes at once send one request', () async {
      final gate = Completer<pb.ListScheduledPostsResponse>();
      when(
        () => repo.listScheduledPosts(
          pageToken: any(named: 'pageToken'),
          pageSize: any(named: 'pageSize'),
        ),
      ).thenAnswer((_) => gate.future);
      final cubit = make();
      final first = cubit.refresh();
      final second = cubit.refresh();
      gate.complete(page([]));
      await Future.wait([first, second]);
      verify(
        () => repo.listScheduledPosts(
          pageToken: any(named: 'pageToken'),
          pageSize: any(named: 'pageSize'),
        ),
      ).called(1);
    });
  });

  group('load more', () {
    test(
      'appends the next page with the token, then stops at the end',
      () async {
        stubList(
          (token) => token.isEmpty
              ? page([scheduledPost(1)], 'p2')
              : page([scheduledPost(2)]),
        );
        final cubit = make();
        await cubit.load();
        await cubit.loadMore();
        expect(cubit.state.items.map((i) => i.scheduledId), [
          scheduledId(1),
          scheduledId(2),
        ]);
        expect(cubit.state.hasMore, isFalse);
        await cubit.loadMore();
        verify(() => repo.listScheduledPosts(pageToken: 'p2', pageSize: 20))
            .called(1);
      },
    );

    test(
      'shows loadingMore while the page is on its way, guards a second call',
      () async {
        final gate = Completer<pb.ListScheduledPostsResponse>();
        var calls = 0;
        when(
          () => repo.listScheduledPosts(
            pageToken: any(named: 'pageToken'),
            pageSize: any(named: 'pageSize'),
          ),
        ).thenAnswer((invocation) {
          if (calls++ == 0) return Future.value(page([scheduledPost(1)], 'p2'));
          return gate.future;
        });
        final cubit = make();
        await cubit.load();
        final first = cubit.loadMore();
        expect(cubit.state.status, ScheduledPostsStatus.loadingMore);
        final second = cubit.loadMore();
        gate.complete(page([scheduledPost(2)]));
        await Future.wait([first, second]);
        expect(calls, 2);
        expect(cubit.state.status, ScheduledPostsStatus.ready);
      },
    );

    test(
      'a failed page keeps the rows and the token; Retry asks for it again',
      () async {
        var fail = true;
        stubList((token) {
          if (token.isEmpty) return page([scheduledPost(1)], 'p2');
          return fail ? const NetworkException('x') : page([scheduledPost(2)]);
        });
        final cubit = make();
        await cubit.load();
        await cubit.loadMore();
        expect(cubit.state.status, ScheduledPostsStatus.ready);
        expect(cubit.state.items, hasLength(1));
        expect(cubit.state.notice, isA<NetworkException>());
        expect(cubit.state.nextPageToken, 'p2');

        fail = false;
        await cubit.retry();
        expect(cubit.state.items, hasLength(2));
        expect(cubit.state.notice, isNull);
      },
    );

    test('a row already shown is not added twice', () async {
      stubList(
        (token) => token.isEmpty
            ? page([scheduledPost(1)], 'p2')
            : page([scheduledPost(1), scheduledPost(2)]),
      );
      final cubit = make();
      await cubit.load();
      await cubit.loadMore();
      expect(cubit.state.items, hasLength(2));
    });
  });

  group('remove (Cancel / Dismiss)', () {
    Future<ScheduledPostsCubit> loaded(List<pb.ScheduledPost> items) async {
      stubList((_) => page(items));
      final cubit = make();
      await cubit.load();
      return cubit;
    }

    test(
      'the row leaves at once; a fresh key per tap; done on success',
      () async {
        final gate = Completer<pb.ScheduledPost>();
        stubCancel((_) => gate.future);
        final cubit = await loaded([scheduledPost(1), scheduledPost(2)]);

        final future = cubit.remove(cubit.state.items.first);
        expect(cubit.state.items.single.scheduledId, scheduledId(2));
        gate.complete(
          scheduledPost(
            1,
            status: ScheduledPostStatus.SCHEDULED_POST_STATUS_CANCELLED,
          ),
        );
        final result = await future;

        expect(result.outcome, ScheduledRemovalOutcome.done);
        expect(cubit.state.items.single.scheduledId, scheduledId(2));
        expect(keys.single, matches(RegExp(r'^[A-Za-z0-9_-]{16,64}$')));
      },
    );

    test('keys differ between taps', () async {
      stubCancel(
        (id) async => scheduledPost(
          1,
          status: ScheduledPostStatus.SCHEDULED_POST_STATUS_CANCELLED,
        ),
      );
      final cubit = await loaded([scheduledPost(1), scheduledPost(2)]);
      await cubit.remove(cubit.state.items.first);
      await cubit.remove(cubit.state.items.first);
      expect(keys.toSet(), hasLength(2));
    });

    test('Dismiss on a FAILED item is the same call', () async {
      stubCancel(
        (id) async => scheduledPost(
          2,
          status: ScheduledPostStatus.SCHEDULED_POST_STATUS_CANCELLED,
        ),
      );
      final cubit = await loaded([failedScheduledPost(2)]);
      final result = await cubit.remove(cubit.state.items.single);
      expect(result.outcome, ScheduledRemovalOutcome.done);
      expect(cubit.state.items, isEmpty);
      verify(
        () => repo.cancelScheduledPost(
          scheduledId: scheduledId(2),
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      ).called(1);
    });

    test('an error puts the row back where it was', () async {
      stubCancel((_) async => throw const NetworkException('offline'));
      final cubit = await loaded([
        scheduledPost(1),
        scheduledPost(2),
        scheduledPost(3),
      ]);

      final result = await cubit.remove(cubit.state.items[1]);

      expect(result.outcome, ScheduledRemovalOutcome.failed);
      expect(result.error, isA<NetworkException>());
      expect(cubit.state.items.map((i) => i.scheduledId), [
        scheduledId(1),
        scheduledId(2),
        scheduledId(3),
      ]);
    });

    test('an unexpected error is reported and the row put back', () async {
      final reported = <Object>[];
      stubList((_) => page([scheduledPost(1)]));
      stubCancel((_) async => throw StateError('boom'));
      final cubit = make(reported: reported);
      await cubit.load();
      final result = await cubit.remove(cubit.state.items.single);
      expect(result.outcome, ScheduledRemovalOutcome.failed);
      expect(cubit.state.items, hasLength(1));
      expect(reported.single, isA<StateError>());
    });

    test('already PUBLISHED: too late, the row stays removed', () async {
      stubCancel(
        (_) async => scheduledPost(
          1,
          status: ScheduledPostStatus.SCHEDULED_POST_STATUS_PUBLISHED,
        ),
      );
      final cubit = await loaded([scheduledPost(1), scheduledPost(2)]);
      final result = await cubit.remove(cubit.state.items.first);
      expect(result.outcome, ScheduledRemovalOutcome.tooLate);
      expect(cubit.state.items.single.scheduledId, scheduledId(2));
    });

    test('already CANCELLED: done, the row stays removed', () async {
      stubCancel(
        (_) async => scheduledPost(
          1,
          status: ScheduledPostStatus.SCHEDULED_POST_STATUS_CANCELLED,
        ),
      );
      final cubit = await loaded([scheduledPost(1)]);
      final result = await cubit.remove(cubit.state.items.single);
      expect(result.outcome, ScheduledRemovalOutcome.done);
      expect(cubit.state.items, isEmpty);
    });

    test('NOT_FOUND: it is gone already, done and removed', () async {
      stubCancel((_) async => throw const NotFoundException('gone'));
      final cubit = await loaded([scheduledPost(1)]);
      final result = await cubit.remove(cubit.state.items.single);
      expect(result.outcome, ScheduledRemovalOutcome.done);
      expect(cubit.state.items, isEmpty);
    });

    test('an item no longer in the list is done without a call', () async {
      final cubit = await loaded([scheduledPost(1)]);
      final result = await cubit.remove(scheduledPost(9));
      expect(result.outcome, ScheduledRemovalOutcome.done);
      verifyNever(
        () => repo.cancelScheduledPost(
          scheduledId: any(named: 'scheduledId'),
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      );
    });

    test('removing the last loaded row asks for the next page, not the '
        'empty state', () async {
      stubList(
        (token) => token.isEmpty
            ? page([scheduledPost(1)], 'p2')
            : page([scheduledPost(2)]),
      );
      stubCancel(
        (_) async => scheduledPost(
          1,
          status: ScheduledPostStatus.SCHEDULED_POST_STATUS_CANCELLED,
        ),
      );
      final cubit = make();
      await cubit.load();
      await cubit.remove(cubit.state.items.single);
      await Future<void>.delayed(Duration.zero);
      expect(cubit.state.items.single.scheduledId, scheduledId(2));
    });
  });

  group('a failed page halts automatic paging', () {
    // The scroll listener calls loadMore on every tick; each try costs
    // 1 + page reads and a degraded answer must never be retried on its own.
    for (final error in <AppException>[
      const NetworkException('offline'),
      const DegradedModeException('limited'),
      const UnknownApiException('boom'),
    ]) {
      test('${error.runtimeType}: more loadMore calls send nothing, retry '
          'sends one', () async {
        var failPage = true;
        stubList((token) {
          if (token.isEmpty) return page([scheduledPost(1)], 'p2');
          return failPage ? error : page([scheduledPost(2)]);
        });
        final cubit = make();
        await cubit.load();
        await cubit.loadMore();
        expect(cubit.state.notice, isNotNull);
        // The first page, then the page that failed.
        expect(listedTokens, ['', 'p2']);

        for (var tick = 0; tick < 5; tick++) {
          await cubit.loadMore();
        }
        // Nothing more was sent by the five scroll ticks.
        expect(listedTokens, ['', 'p2']);
        expect(cubit.state.items, hasLength(1));

        failPage = false;
        await cubit.retry();
        expect(listedTokens, ['', 'p2', 'p2']);
        expect(cubit.state.items.map((i) => i.scheduledId), [
          scheduledId(1),
          scheduledId(2),
        ]);
        expect(cubit.state.notice, isNull);
      });
    }

    test('a successful refresh lets paging resume', () async {
      var failPage = true;
      stubList((token) {
        if (token.isEmpty) return page([scheduledPost(1)], 'p2');
        return failPage
            ? const NetworkException('x')
            : page([scheduledPost(2)]);
      });
      final cubit = make();
      await cubit.load();
      await cubit.loadMore();
      await cubit.loadMore();
      expect(listedTokens, ['', 'p2']);

      failPage = false;
      await cubit.refresh();
      await cubit.loadMore();
      expect(listedTokens, ['', 'p2', '', 'p2']);
      expect(cubit.state.items, hasLength(2));
    });

    test('a failed refresh does not resume paging', () async {
      var round = 0;
      stubList((token) {
        if (token.isEmpty) {
          return round++ == 1
              ? const NetworkException('x')
              : page([scheduledPost(1)], 'p2');
        }
        return const NetworkException('x');
      });
      final cubit = make();
      await cubit.load();
      await cubit.loadMore();
      await cubit.refresh();
      await cubit.loadMore();
      // The failed refresh ('') did not lift the halt: no second 'p2'.
      expect(listedTokens, ['', 'p2', '']);
    });

    test('load (the error view Retry) starts paging afresh', () async {
      var failPage = true;
      stubList((token) {
        if (token.isEmpty) return page([scheduledPost(1)], 'p2');
        return failPage
            ? const NetworkException('x')
            : page([scheduledPost(2)]);
      });
      final cubit = make();
      await cubit.load();
      await cubit.loadMore();
      failPage = false;
      await cubit.load();
      await cubit.loadMore();
      expect(cubit.state.items, hasLength(2));
    });
  });

  group('FEATURE_DISABLED: scheduling is off for everyone', () {
    const off = FeatureDisabledException('x', feature: 'scheduled_posts');

    test('the first page: the error status carries it', () async {
      stubList((_) => off);
      final cubit = make();
      await cubit.load();
      expect(cubit.state.status, ScheduledPostsStatus.error);
      expect(cubit.state.error, isA<FeatureDisabledException>());
    });

    test('a refresh: the rows give way to it, no banner', () async {
      var round = 0;
      stubList((_) => round++ == 0 ? page([scheduledPost(1)]) : off);
      final cubit = make();
      await cubit.load();
      await cubit.refresh();
      expect(cubit.state.status, ScheduledPostsStatus.error);
      expect(cubit.state.error, isA<FeatureDisabledException>());
      expect(cubit.state.items, isEmpty);
      expect(cubit.state.notice, isNull);
    });

    test('a next page', () async {
      stubList((token) => token.isEmpty ? page([scheduledPost(1)], 'p2') : off);
      final cubit = make();
      await cubit.load();
      await cubit.loadMore();
      expect(cubit.state.status, ScheduledPostsStatus.error);
      expect(cubit.state.error, isA<FeatureDisabledException>());
    });

    test('a Cancel: reported as failed, and the list is unavailable', () async {
      stubList((_) => page([scheduledPost(1)]));
      stubCancel((_) async => throw off);
      final cubit = make();
      await cubit.load();
      final result = await cubit.remove(cubit.state.items.single);
      expect(result.outcome, ScheduledRemovalOutcome.failed);
      expect(result.error, isA<FeatureDisabledException>());
      expect(cubit.state.status, ScheduledPostsStatus.error);
    });

    test('a later refresh that works brings the rows back', () async {
      var on = false;
      stubList((_) => on ? page([scheduledPost(1)]) : off);
      final cubit = make();
      await cubit.load();
      expect(cubit.state.status, ScheduledPostsStatus.error);
      on = true;
      await cubit.refresh();
      expect(cubit.state.status, ScheduledPostsStatus.ready);
      expect(cubit.state.items, hasLength(1));
    });
  });

  group('a removal in flight', () {
    pb.ScheduledPost cancelled(int n) => scheduledPost(
      n,
      status: ScheduledPostStatus.SCHEDULED_POST_STATUS_CANCELLED,
    );

    test(
      'a refresh that lands meanwhile does not bring the row back',
      () async {
        // The server has not applied the cancel yet: it still lists row 1.
        stubList((_) => page([scheduledPost(1), scheduledPost(2)]));
        final gate = Completer<pb.ScheduledPost>();
        stubCancel((_) => gate.future);
        final cubit = make();
        await cubit.load();

        final removal = cubit.remove(cubit.state.items.first);
        expect(cubit.state.items.map((i) => i.scheduledId), [scheduledId(2)]);
        await cubit.refresh();
        expect(cubit.state.items.map((i) => i.scheduledId), [scheduledId(2)]);

        gate.complete(cancelled(1));
        await removal;
        expect(cubit.state.items.map((i) => i.scheduledId), [scheduledId(2)]);
      },
    );

    test('a page that lands meanwhile does not bring the row back', () async {
      // Page 2 still lists row 1 (the cancel is not applied yet).
      stubList(
        (token) => token.isEmpty
            ? page([scheduledPost(1), scheduledPost(2)], 'p2')
            : page([scheduledPost(1), scheduledPost(3)]),
      );
      final gate = Completer<pb.ScheduledPost>();
      stubCancel((_) => gate.future);
      final cubit = make();
      await cubit.load();

      final removal = cubit.remove(cubit.state.items.first);
      await cubit.loadMore();
      expect(cubit.state.items.map((i) => i.scheduledId), [
        scheduledId(2),
        scheduledId(3),
      ]);

      gate.complete(cancelled(1));
      await removal;
      expect(cubit.state.items.map((i) => i.scheduledId), [
        scheduledId(2),
        scheduledId(3),
      ]);
    });

    test('a failure after a refresh puts the row back', () async {
      stubList((_) => page([scheduledPost(1), scheduledPost(2)]));
      final gate = Completer<pb.ScheduledPost>();
      stubCancel((_) => gate.future);
      final cubit = make();
      await cubit.load();

      final removal = cubit.remove(cubit.state.items.first);
      await cubit.refresh();
      gate.completeError(const NetworkException('offline'));
      final result = await removal;

      expect(result.outcome, ScheduledRemovalOutcome.failed);
      expect(cubit.state.items.map((i) => i.scheduledId), [
        scheduledId(1),
        scheduledId(2),
      ]);
      // Settled: the next refresh shows the row again.
      await cubit.refresh();
      expect(cubit.state.items, hasLength(2));
    });

    test('once it succeeded, a refresh shows what the server says', () async {
      var listed = [scheduledPost(1), scheduledPost(2)];
      stubList((_) => page(listed));
      stubCancel((_) async => cancelled(1));
      final cubit = make();
      await cubit.load();
      await cubit.remove(cubit.state.items.first);
      listed = [scheduledPost(2)];
      await cubit.refresh();
      expect(cubit.state.items.map((i) => i.scheduledId), [scheduledId(2)]);
    });

    test('a second remove of the same row shares the first call: one request, '
        'no early "cancelled"', () async {
      stubList((_) => page([scheduledPost(1), scheduledPost(2)]));
      final gate = Completer<pb.ScheduledPost>();
      stubCancel((_) => gate.future);
      final cubit = make();
      await cubit.load();
      final item = cubit.state.items.first;

      final first = cubit.remove(item);
      final second = cubit.remove(item);
      var secondDone = false;
      unawaited(second.then((_) => secondDone = true));
      await Future<void>.delayed(Duration.zero);
      expect(secondDone, isFalse, reason: 'the first call has not finished');

      gate.complete(cancelled(1));
      expect((await first).outcome, ScheduledRemovalOutcome.done);
      expect((await second).outcome, ScheduledRemovalOutcome.done);
      verify(
        () => repo.cancelScheduledPost(
          scheduledId: scheduledId(1),
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      ).called(1);
    });

    test(
      'a second remove shares a failure too, and the row comes back once',
      () async {
        stubList((_) => page([scheduledPost(1)]));
        final gate = Completer<pb.ScheduledPost>();
        stubCancel((_) => gate.future);
        final cubit = make();
        await cubit.load();
        final item = cubit.state.items.single;

        final first = cubit.remove(item);
        final second = cubit.remove(item);
        gate.completeError(const NetworkException('offline'));

        expect((await first).outcome, ScheduledRemovalOutcome.failed);
        expect((await second).outcome, ScheduledRemovalOutcome.failed);
        expect(cubit.state.items, hasLength(1));
      },
    );

    test('after it finished, the same row can be removed again', () async {
      var fail = true;
      stubList((_) => page([scheduledPost(1)]));
      stubCancel(
        (_) async => fail ? throw const NetworkException('x') : cancelled(1),
      );
      final cubit = make();
      await cubit.load();
      expect(
        (await cubit.remove(cubit.state.items.single)).outcome,
        ScheduledRemovalOutcome.failed,
      );
      fail = false;
      expect(
        (await cubit.remove(cubit.state.items.single)).outcome,
        ScheduledRemovalOutcome.done,
      );
      expect(cubit.state.items, isEmpty);
    });
  });
}
