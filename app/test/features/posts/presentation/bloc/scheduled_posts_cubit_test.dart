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

  setUp(() {
    repo = _MockPostsRepository();
    keys = [];
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
      final r = answer(invocation.namedArguments[#pageToken] as String);
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
}
