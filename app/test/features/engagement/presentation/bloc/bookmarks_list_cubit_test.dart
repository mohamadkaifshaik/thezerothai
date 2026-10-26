import 'dart:async';

import 'package:connectrpc/connect.dart' as connect;
import 'package:dzeroth/core/feature_flags/service_feature_gate.dart';
import 'package:dzeroth/core/network/api_client.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/network/rate_limit_hold.dart';
import 'package:dzeroth/core/storage/session_epoch.dart';
import 'package:dzeroth/features/engagement/data/bookmarks_repository.dart';
import 'package:dzeroth/features/engagement/presentation/bloc/bookmarks_cubit.dart';
import 'package:dzeroth/features/engagement/presentation/bloc/bookmarks_list_cubit.dart';
import 'package:dzeroth/features/engagement/presentation/bloc/bookmarks_list_state.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/engagement/v1/engagement.pb.dart' as eng;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:flutter_test/flutter_test.dart';

import '../../../../support/bookmarks_fixtures.dart';
import '../../../../support/fake_transport.dart';
import '../../../../support/posts_fixtures.dart';

void main() {
  late FakeBookmarksServer server;
  late SessionEpoch epoch;
  late BookmarksRepository repo;
  late BookmarksListCubit cubit;
  late BookmarksCubit overlay;
  var gateOn = true;
  var unexpected = 0;

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  setUp(() {
    server = FakeBookmarksServer();
    epoch = SessionEpoch();
    gateOn = true;
    unexpected = 0;
    repo = BookmarksRepository(
      apiClient: ApiClient.withTransport(FakeTransport(server.handle)),
      gate: ServiceFeatureGate(isEnabled: () => gateOn),
      epoch: epoch,
      onUnexpectedError: (_, _) => unexpected++,
    );
    cubit = BookmarksListCubit(repository: repo);
    overlay = BookmarksCubit(repository: repo);
  });

  tearDown(() async {
    await cubit.close();
    await overlay.close();
    await repo.dispose();
  });

  List<String> ids(BookmarksListState s) => [
    for (final v in s.visibleItems) v.post.postId,
  ];

  group('load', () {
    test('page 1 replaces the rows, lands in the local set first', () async {
      server.pages[''] = () => bookmarksPage([3, 2, 1], 'p2');
      final states = <BookmarksListState>[];
      cubit.stream.listen(states.add);

      await cubit.load();

      expect(server.listTokens, ['']);
      expect(cubit.state.status, BookmarksListStatus.ready);
      expect(ids(cubit.state), [postId(3), postId(2), postId(1)]);
      expect(cubit.state.nextPageToken, 'p2');
      // Every row is bookmarked before the rows are shown.
      for (final n in [1, 2, 3]) {
        expect(repo.isBookmarked(postId(n)), isTrue);
      }
      expect(cubit.state.hidden, isEmpty);
      // Skeleton -> rows, never an empty list in between.
      expect(
        states.where((s) => s.status == BookmarksListStatus.ready),
        everyElement(predicate<BookmarksListState>((s) => s.items.isNotEmpty)),
      );
    });

    test('rows without the viewer flag (no hydration for this caller) still '
        'show', () async {
      server.pages[''] = () => bookmarksPageOf([postView(1), postView(2)]);

      await cubit.load();

      expect(ids(cubit.state), [postId(1), postId(2)]);
      expect(repo.isBookmarked(postId(1)), isTrue);
    });

    test('each open asks again and replaces, no merge', () async {
      server.pages[''] = () => bookmarksPage([2, 1]);
      await cubit.load();
      server.pages[''] = () => bookmarksPage([5]);
      await cubit.load();

      expect(server.listTokens, ['', '']);
      expect(ids(cubit.state), [postId(5)]);
    });

    test('empty: ready with no rows and no token', () async {
      await cubit.load();

      expect(cubit.state.status, BookmarksListStatus.ready);
      expect(cubit.state.items, isEmpty);
      expect(cubit.state.hasMore, isFalse);
    });

    test('follows the token through empty pages until a row shows', () async {
      server.pages[''] = () => bookmarksPage(const [], 't1');
      server.pages['t1'] = () => bookmarksPage(const [], 't2');
      server.pages['t2'] = () => bookmarksPage([7], 't3');
      final states = <BookmarksListState>[];
      cubit.stream.listen(states.add);

      await cubit.load();

      expect(server.listTokens, ['', 't1', 't2']);
      expect(ids(cubit.state), [postId(7)]);
      expect(cubit.state.nextPageToken, 't3');
      // The empty state was never claimed while a token existed.
      expect(
        states.where(
          (s) =>
              s.status == BookmarksListStatus.ready &&
              s.visibleItems.isEmpty &&
              s.hasMore,
        ),
        isEmpty,
      );
    });

    test('an empty page with a token that does not advance stops', () async {
      server.pages[''] = () => bookmarksPage(const [], 't1');
      server.pages['t1'] = () => bookmarksPage(const [], 't1');

      await cubit.load();

      expect(server.listTokens, ['', 't1']);
      expect(cubit.state.status, BookmarksListStatus.ready);
      expect(cubit.state.items, isEmpty);
    });

    test('a row without a usable target is skipped', () async {
      server.pages[''] = () => eng.ListBookmarksResponse(
        bookmarks: [
          eng.Bookmark(
            post: pb.PostView(
              post: pb.Post(
                postId: postId(9),
                kind: pb.PostKind.POST_KIND_REPOST,
              ),
            ),
          ),
          eng.Bookmark(post: postView(2)),
        ],
      );

      await cubit.load();

      expect(ids(cubit.state), [postId(2)]);
    });
  });

  group('errors', () {
    test('FEATURE_DISABLED: the not-available error, RPC was sent even with '
        'the bookmarks gate off, and Remove is not blocked', () async {
      gateOn = false;
      server.pages[''] = () => throw serverError(
        connect.Code.failedPrecondition,
        common.ErrorReason.ERROR_REASON_FEATURE_DISABLED,
        metadata: {'feature': 'bookmarks'},
      );

      await cubit.load();

      expect(server.listTokens, ['']);
      expect(cubit.state.status, BookmarksListStatus.error);
      expect(cubit.state.error, isA<FeatureDisabledException>());
      // The gate does not remember a List answer: Remove still goes out.
      await repo.setBookmarked(postId(1), saved: false, server: true);
      expect(server.toggles.single, isA<eng.RemoveBookmarkRequest>());
    });

    test('a first-page failure is an error with nothing to show', () async {
      server.pages[''] = () => throw serverError(
        connect.Code.unavailable,
        common.ErrorReason.ERROR_REASON_UNSPECIFIED,
      );

      await cubit.load();

      expect(cubit.state.status, BookmarksListStatus.error);
      expect(cubit.state.error, isA<NetworkException>());
    });

    test('a failed refresh keeps the rows under a notice', () async {
      server.pages[''] = () => bookmarksPage([1]);
      await cubit.load();
      server.pages[''] = () => throw serverError(
        connect.Code.unavailable,
        common.ErrorReason.ERROR_REASON_UNSPECIFIED,
      );

      await cubit.refresh();

      expect(cubit.state.status, BookmarksListStatus.ready);
      expect(ids(cubit.state), [postId(1)]);
      expect(cubit.state.notice, isA<NetworkException>());
      expect(cubit.noticeFromPaging, isFalse);
    });

    test('a failed next page halts paging until retry', () async {
      server.pages[''] = () => bookmarksPage([2], 't1');
      await cubit.load();
      server.pages['t1'] = () => throw serverError(
        connect.Code.unavailable,
        common.ErrorReason.ERROR_REASON_UNSPECIFIED,
      );

      await cubit.loadMore();
      expect(cubit.state.notice, isA<NetworkException>());
      expect(cubit.noticeFromPaging, isTrue);
      expect(ids(cubit.state), [postId(2)]);

      // The scroll listener calls again on every tick: nothing is sent.
      await cubit.loadMore();
      await cubit.loadMore();
      expect(server.listTokens, ['', 't1']);

      server.pages['t1'] = () => bookmarksPage([1]);
      await cubit.retry();
      expect(server.listTokens, ['', 't1', 't1']);
      expect(ids(cubit.state), [postId(2), postId(1)]);
      expect(cubit.state.notice, isNull);
    });

    test(
      'a RATE_LIMITED answer is held: the next call sends nothing',
      () async {
        final hold = RateLimitHold();
        final held = BookmarksRepository(
          apiClient: ApiClient.withTransport(FakeTransport(server.handle)),
          gate: ServiceFeatureGate(isEnabled: () => true),
          epoch: epoch,
          rateLimitHold: hold,
        );
        addTearDown(held.dispose);
        server.pages[''] = () => throw serverError(
          connect.Code.resourceExhausted,
          common.ErrorReason.ERROR_REASON_RATE_LIMITED,
          metadata: {'limit': 'reads_daily'},
        );
        final own = BookmarksListCubit(repository: held);
        addTearDown(own.close);

        await own.load();
        await own.load();

        expect(own.state.error, isA<RateLimitedException>());
        expect(server.listTokens, [''], reason: 'the second open was held');
      },
    );

    test('an unexpected failure is reported and shown as a failure', () async {
      server.pages[''] = () => throw serverError(
        connect.Code.internal,
        common.ErrorReason.ERROR_REASON_UNSPECIFIED,
      );

      await cubit.load();

      expect(cubit.state.error, isA<UnknownApiException>());
      expect(unexpected, 1);
    });
  });

  group('paging', () {
    test('loadMore appends the next page; the end is an empty token', () async {
      server.pages[''] = () => bookmarksPage([5, 4], 't1');
      server.pages['t1'] = () => bookmarksPage([3], 't2');
      server.pages['t2'] = () => bookmarksPage([2, 1]);
      await cubit.load();

      await cubit.loadMore();
      expect(ids(cubit.state), [postId(5), postId(4), postId(3)]);
      expect(cubit.state.hasMore, isTrue);

      await cubit.loadMore();
      expect(ids(cubit.state).length, 5);
      expect(cubit.state.hasMore, isFalse);

      await cubit.loadMore();
      expect(server.listTokens, ['', 't1', 't2'], reason: 'nothing after');
    });

    test('a short page with a token is not the end', () async {
      server.pages[''] = () => bookmarksPage([3], 't1');
      server.pages['t1'] = () => bookmarksPage([2], 't2');
      server.pages['t2'] = () => bookmarksPage([1]);
      await cubit.load();
      expect(cubit.state.hasMore, isTrue);

      await cubit.loadMore();
      await cubit.loadMore();

      expect(ids(cubit.state), [postId(3), postId(2), postId(1)]);
      expect(cubit.state.hasMore, isFalse);
    });

    test('a page of nothing new is followed in the same call', () async {
      server.pages[''] = () => bookmarksPage([2], 't1');
      // Already on screen (the user's list moved between pages), then a hole.
      server.pages['t1'] = () => bookmarksPage([2], 't2');
      server.pages['t2'] = () => bookmarksPage([1]);
      await cubit.load();

      await cubit.loadMore();

      expect(server.listTokens, ['', 't1', 't2']);
      expect(ids(cubit.state), [postId(2), postId(1)]);
    });

    test('concurrent loadMore calls send one request', () async {
      final gate = Completer<void>();
      server.pages[''] = () => bookmarksPage([2], 't1');
      server.pages['t1'] = () async {
        await gate.future;
        return bookmarksPage([1]);
      };
      await cubit.load();

      final a = cubit.loadMore();
      final b = cubit.loadMore();
      gate.complete();
      await Future.wait([a, b]);

      expect(server.listTokens, ['', 't1']);
    });
  });

  group('un-bookmark', () {
    setUp(() async {
      server.pages[''] = () => bookmarksPage([3, 2, 1]);
      await cubit.load();
    });

    test('the row leaves at once with a one-shot removal', () async {
      server.toggleGate = Completer<void>();
      final future = repo.setBookmarked(postId(2), saved: false, server: true);
      await settle();

      expect(ids(cubit.state), [postId(3), postId(1)]);
      expect(cubit.state.hidden, {postId(2)});
      expect(cubit.state.removal!.view.post.postId, postId(2));
      expect(cubit.state.items.length, 3, reason: 'kept to restore in place');

      cubit.removalShown();
      expect(cubit.state.removal, isNull);

      server.toggleGate!.complete();
      await future;
      expect(ids(cubit.state), [postId(3), postId(1)]);
    });

    test('a failed removal puts the row back where it was, with the '
        'failure', () async {
      server.toggleError = serverError(
        connect.Code.unavailable,
        common.ErrorReason.ERROR_REASON_UNSPECIFIED,
      );

      await repo.setBookmarked(postId(2), saved: false, server: true);

      expect(ids(cubit.state), [postId(3), postId(2), postId(1)]);
      final failure = cubit.state.failure!;
      expect(failure.postId, postId(2));
      expect(failure.saving, isFalse);
      expect(failure.error, isA<NetworkException>());
      cubit.failureShown();
      expect(cubit.state.failure, isNull);
    });

    test('restore (Undo) re-adds through the repository and the row comes '
        'back in place', () async {
      await repo.setBookmarked(postId(2), saved: false, server: true);
      expect(ids(cubit.state), [postId(3), postId(1)]);

      await cubit.restore(cubit.state.removal!.view);

      expect(server.toggles.last, isA<eng.AddBookmarkRequest>());
      expect(ids(cubit.state), [postId(3), postId(2), postId(1)]);
      expect(cubit.state.hidden, isEmpty);
    });

    test('a failed Undo keeps the row out and reports it', () async {
      await repo.setBookmarked(postId(2), saved: false, server: true);
      server.toggleError = serverError(
        connect.Code.unavailable,
        common.ErrorReason.ERROR_REASON_UNSPECIFIED,
      );

      await cubit.restore(cubit.state.removal!.view);

      expect(ids(cubit.state), [postId(3), postId(1)]);
      expect(cubit.state.failure!.saving, isTrue);
    });

    test('a failure of a post that is not on the list is ignored', () async {
      server.toggleError = serverError(
        connect.Code.unavailable,
        common.ErrorReason.ERROR_REASON_UNSPECIFIED,
      );

      await repo.setBookmarked(postId(99), saved: true);

      expect(cubit.state.failure, isNull);
    });

    test(
      'un-bookmarking through the shared overlay cubit hides the row too',
      () async {
        await overlay.setBookmarked(
          postId(1),
          postView(1)..bookmarkedByViewer = true,
          saved: false,
        );

        expect(ids(cubit.state), [postId(3), postId(2)]);
      },
    );
  });

  group('sign-out', () {
    test('the rows are dropped when the session is cleared', () async {
      server.pages[''] = () => bookmarksPage([2, 1], 't1');
      await cubit.load();
      expect(cubit.state.items, isNotEmpty);

      // What AppWidget does on sign-out.
      overlay.reset();
      epoch.end();

      expect(cubit.state.items, isEmpty);
      expect(cubit.state.hasMore, isFalse);
      expect(cubit.state.status, BookmarksListStatus.loading);
      expect(repo.snapshot(), isEmpty);
    });

    test('a page that lands after sign-out is dropped and records '
        'nothing', () async {
      final gate = Completer<void>();
      server.pages[''] = () async {
        await gate.future;
        return bookmarksPage([2, 1]);
      };
      final loading = cubit.load();
      await settle();

      overlay.reset();
      epoch.end();
      gate.complete();
      await loading;

      expect(cubit.state.items, isEmpty);
      expect(cubit.state.status, BookmarksListStatus.loading);
      expect(repo.snapshot(), isEmpty, reason: 'old ids never enter the set');
    });

    test('a next page that lands after sign-out is dropped', () async {
      final gate = Completer<void>();
      server.pages[''] = () => bookmarksPage([2], 't1');
      server.pages['t1'] = () async {
        await gate.future;
        return bookmarksPage([1]);
      };
      await cubit.load();
      final more = cubit.loadMore();
      await settle();

      overlay.reset();
      epoch.end();
      gate.complete();
      await more;

      expect(cubit.state.items, isEmpty);
      expect(repo.snapshot(), isEmpty);
    });

    test('a list started by the next user works', () async {
      server.pages[''] = () => bookmarksPage([2]);
      await cubit.load();
      overlay.reset();
      epoch.end();

      server.pages[''] = () => bookmarksPage([8]);
      await cubit.load();

      expect(ids(cubit.state), [postId(8)]);
      expect(repo.isBookmarked(postId(2)), isFalse);
    });
  });

  test('closing mid-load does not emit', () async {
    final gate = Completer<void>();
    server.pages[''] = () async {
      await gate.future;
      return bookmarksPage([1]);
    };
    final loading = cubit.load();
    await settle();
    await cubit.close();
    gate.complete();
    await loading;
    expect(cubit.isClosed, isTrue);
  });
}
