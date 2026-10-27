import 'dart:async';

import 'package:connectrpc/connect.dart' as connect;
import 'package:dzeroth/core/feature_flags/service_feature_gate.dart';
import 'package:dzeroth/core/network/api_client.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/storage/session_epoch.dart';
import 'package:dzeroth/features/engagement/data/engagement_repository.dart';
import 'package:dzeroth/features/engagement/data/likes_repository.dart';
import 'package:dzeroth/features/engagement/domain/engagement_entry.dart';
import 'package:dzeroth/features/engagement/presentation/bloc/engagement_cubit.dart';
import 'package:dzeroth/features/engagement/presentation/bloc/engagement_state.dart';
import 'package:dzeroth/features/engagement/presentation/bloc/likes_list_cubit.dart';
import 'package:dzeroth/features/engagement/presentation/bloc/likes_list_state.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/engagement/v1/engagement.pb.dart' as eng;
import 'package:flutter_test/flutter_test.dart';

import '../../../../support/fake_transport.dart';
import '../../../../support/likes_fixtures.dart';
import '../../../../support/posts_fixtures.dart';

void main() {
  late FakeLikesServer server;
  late SessionEpoch epoch;
  late LikesRepository repo;
  late EngagementCubit engagement;
  late LikesListCubit cubit;
  var gateOn = true;
  var unexpected = 0;

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  setUp(() {
    server = FakeLikesServer();
    epoch = SessionEpoch();
    gateOn = true;
    unexpected = 0;
    final client = ApiClient.withTransport(FakeTransport(server.handle));
    repo = LikesRepository(
      apiClient: client,
      gate: ServiceFeatureGate(isEnabled: () => gateOn),
      epoch: epoch,
      onUnexpectedError: (_, _) => unexpected++,
    );
    engagement = EngagementCubit(
      repository: EngagementRepository(
        apiClient: client,
        gate: ServiceFeatureGate(isEnabled: () => true),
      ),
    );
    cubit = LikesListCubit(
      repository: repo,
      engagement: engagement,
      onUnexpectedError: (_, _) => unexpected++,
    );
  });

  tearDown(() async {
    await cubit.close();
    await engagement.close();
    await repo.dispose();
  });

  List<String> ids(LikesListState s) => [
    for (final v in s.visibleItems) v.post.postId,
  ];

  /// What the card of liked post [n] does when its heart is tapped.
  Future<void> unlike(int n, {bool liked = true}) => engagement.setLiked(
    postId(n),
    liked: false,
    shown: EngagementEntry.fromView(likedView(n, liked: liked)),
  );

  group('load', () {
    test('page 1 replaces the rows: nothing is merged across opens', () async {
      server.pages[''] = () => likesPage([3, 2, 1], 'p2');
      await cubit.load();
      expect(cubit.state.status, LikesListStatus.ready);
      expect(ids(cubit.state), [postId(3), postId(2), postId(1)]);
      expect(cubit.state.nextPageToken, 'p2');

      server.pages[''] = () => likesPage([9]);
      await cubit.load();

      expect(server.listTokens, ['', '']);
      expect(ids(cubit.state), [postId(9)]);
      expect(cubit.state.hasMore, isFalse);
    });

    test(
      'the skeleton first, then rows, never an empty list in between',
      () async {
        server.pages[''] = () => likesPage([2, 1]);
        final states = <LikesListState>[];
        cubit.stream.listen(states.add);

        await cubit.load();

        expect(states.first.status, LikesListStatus.loading);
        expect(
          states.where((s) => s.status == LikesListStatus.ready),
          everyElement(predicate<LikesListState>((s) => s.items.isNotEmpty)),
        );
      },
    );

    test('no likes: ready, empty, no token', () async {
      await cubit.load();

      expect(cubit.state.status, LikesListStatus.ready);
      expect(cubit.state.visibleItems, isEmpty);
      expect(cubit.state.hasMore, isFalse);
    });

    test(
      'pages with a token and no row are followed, not reported as empty',
      () async {
        server.pages[''] = () => likesPage(const [], 't1');
        server.pages['t1'] = () => likesPage(const [], 't2');
        server.pages['t2'] = () => likesPage([2, 1]);

        await cubit.load();

        expect(server.listTokens, ['', 't1', 't2']);
        expect(ids(cubit.state), [postId(2), postId(1)]);
        expect(cubit.state.hasMore, isFalse);
      },
    );

    test('rows whose liked_by_viewer is false (engagement off for the caller) '
        'still list: the flag is never read', () async {
      server.pages[''] = () =>
          likesPageOf([likedView(2, liked: false), likedView(1, liked: false)]);

      await cubit.load();

      expect(ids(cubit.state), [postId(2), postId(1)]);
      expect(cubit.state.hidden, isEmpty);
    });
  });

  group('loadMore', () {
    test('appends the next page and drops rows already shown', () async {
      server.pages[''] = () => likesPage([4, 3], 't1');
      server.pages['t1'] = () => likesPage([3, 2, 1]);
      await cubit.load();

      await cubit.loadMore();

      expect(server.listTokens, ['', 't1']);
      expect(ids(cubit.state), [postId(4), postId(3), postId(2), postId(1)]);
      expect(cubit.state.hasMore, isFalse);
    });

    test(
      'short pages are followed through, with rows from a later one',
      () async {
        server.pages[''] = () => likesPage([6], 't1');
        server.pages['t1'] = () => likesPage(const [], 't2');
        server.pages['t2'] = () => likesPage([5, 4], 't3');
        await cubit.load();

        await cubit.loadMore();

        expect(server.listTokens, ['', 't1', 't2']);
        expect(ids(cubit.state), [postId(6), postId(5), postId(4)]);
        expect(cubit.state.nextPageToken, 't3');
      },
    );

    test(
      'the end sends nothing more: an exact fit has no trailing empty page',
      () async {
        server.pages[''] = () => likesPage([2, 1]);
        await cubit.load();

        await cubit.loadMore();
        await cubit.loadMore();

        expect(server.listTokens, ['']);
      },
    );

    test('concurrent asks send one request', () async {
      final gate = Completer<void>();
      server.pages[''] = () => likesPage([2, 1], 't1');
      server.pages['t1'] = () async {
        await gate.future;
        return likesPage([0]);
      };
      await cubit.load();

      final first = cubit.loadMore();
      final second = cubit.loadMore();
      await settle();
      expect(cubit.state.status, LikesListStatus.loadingMore);
      gate.complete();
      await Future.wait([first, second]);

      expect(server.listTokens, ['', 't1']);
    });

    test('an expired token (VALIDATION page_token) drops the token and loads '
        'page 1 again', () async {
      server.pages[''] = () => likesPage([3, 2], 'old');
      await cubit.load();
      server.pages['old'] = () => throw rejectedToken('page_token');
      server.pages[''] = () => likesPage([9, 8], 'fresh');

      await cubit.loadMore();

      expect(server.listTokens, ['', 'old', '']);
      expect(cubit.state.status, LikesListStatus.ready);
      expect(ids(cubit.state), [postId(9), postId(8)]);
      expect(cubit.state.nextPageToken, 'fresh');
      expect(cubit.state.notice, isNull);
    });

    test('another VALIDATION answer is a failed page, not a reload', () async {
      server.pages[''] = () => likesPage([3, 2], 't1');
      await cubit.load();
      server.pages['t1'] = () => throw rejectedToken('page_size');

      await cubit.loadMore();

      expect(server.listTokens, ['', 't1']);
      expect(cubit.state.notice, isA<ValidationException>());
      expect(cubit.noticeFromPaging, isTrue);
    });
  });

  group('failures', () {
    test(
      'a failed first page is the error status, Retry (load) asks again',
      () async {
        server.pages[''] = () => throw serverError(
          connect.Code.unavailable,
          common.ErrorReason.ERROR_REASON_UNSPECIFIED,
        );

        await cubit.load();

        expect(cubit.state.status, LikesListStatus.error);
        expect(cubit.state.error, isA<NetworkException>());

        server.pages[''] = () => likesPage([1]);
        await cubit.load();
        expect(ids(cubit.state), [postId(1)]);
      },
    );

    test('FEATURE_DISABLED is the error status with that exception', () async {
      server.pages[''] = () => throw serverError(
        connect.Code.failedPrecondition,
        common.ErrorReason.ERROR_REASON_FEATURE_DISABLED,
        metadata: {'feature': 'likes_list'},
      );

      await cubit.load();

      expect(cubit.state.status, LikesListStatus.error);
      expect(cubit.state.error, isA<FeatureDisabledException>());
    });

    test(
      'UNIMPLEMENTED reads as disabled, once: no report, no call storm',
      () async {
        server.pages[''] = () => throw connect.ConnectException(
          connect.Code.unimplemented,
          'ListLikedPosts is not implemented yet',
        );

        await cubit.load();
        await cubit.load();
        await cubit.refresh();

        expect(cubit.state.error, isA<FeatureDisabledException>());
        expect(server.listCalls, 1);
        expect(unexpected, 0);
      },
    );

    test('a failed refresh keeps the rows under a banner', () async {
      server.pages[''] = () => likesPage([2, 1]);
      await cubit.load();
      server.pages[''] = () => throw serverError(
        connect.Code.unavailable,
        common.ErrorReason.ERROR_REASON_UNSPECIFIED,
      );

      await cubit.refresh();

      expect(cubit.state.status, LikesListStatus.ready);
      expect(ids(cubit.state), [postId(2), postId(1)]);
      expect(cubit.state.notice, isA<NetworkException>());
      expect(cubit.noticeFromPaging, isFalse);
    });

    test('a failed next page keeps the rows, halts paging, and Retry asks '
        'for that page again', () async {
      server.pages[''] = () => likesPage([2, 1], 't1');
      await cubit.load();
      server.pages['t1'] = () => throw serverError(
        connect.Code.unavailable,
        common.ErrorReason.ERROR_REASON_UNSPECIFIED,
      );

      await cubit.loadMore();
      expect(cubit.state.notice, isA<NetworkException>());
      expect(cubit.noticeFromPaging, isTrue);
      expect(cubit.state.status, LikesListStatus.ready);

      // Halted: scrolling sends nothing.
      await cubit.loadMore();
      expect(server.listTokens, ['', 't1']);

      server.pages['t1'] = () => likesPage([0]);
      await cubit.retry();
      expect(server.listTokens, ['', 't1', 't1']);
      expect(ids(cubit.state), [postId(2), postId(1), postId(0)]);
      expect(cubit.state.notice, isNull);
    });

    test('a rate limit is a banner, and the hold stops the next ask', () async {
      server.pages[''] = () => likesPage([2, 1], 't1');
      await cubit.load();
      server.pages['t1'] = () => throw serverError(
        connect.Code.resourceExhausted,
        common.ErrorReason.ERROR_REASON_RATE_LIMITED,
      );

      await cubit.loadMore();
      expect(cubit.state.notice, isA<RateLimitedException>());

      await cubit.retry();
      expect(server.listTokens, ['', 't1'], reason: 'held: nothing was sent');
    });

    test(
      'an unexpected failure is reported and shown as a generic one',
      () async {
        server.pages[''] = () =>
            throw connect.ConnectException(connect.Code.internal, 'boom');

        await cubit.load();

        expect(cubit.state.status, LikesListStatus.error);
        expect(cubit.state.error, isA<UnknownApiException>());
        expect(unexpected, 1);
      },
    );
  });

  group('un-liking', () {
    test(
      'the row leaves at once, before the server answers, and stays out',
      () async {
        server.toggleGate = Completer<void>();
        server.pages[''] = () => likesPage([3, 2, 1]);
        await cubit.load();

        final done = unlike(2);
        await settle();

        expect(ids(cubit.state), [postId(3), postId(1)]);
        expect(cubit.state.items, hasLength(3), reason: 'kept for a rollback');
        expect(cubit.state.hidden, {postId(2)});

        server.toggleGate!.complete();
        await done;
        await settle();
        expect(ids(cubit.state), [postId(3), postId(1)]);
        expect(
          (server.toggles.single as eng.UnlikePostRequest).postId,
          postId(2),
        );
      },
    );

    test(
      'a failed unlike puts the row back at its place and reports once',
      () async {
        server.pages[''] = () => likesPage([3, 2, 1]);
        await cubit.load();
        server.toggleError = serverError(
          connect.Code.unavailable,
          common.ErrorReason.ERROR_REASON_UNSPECIFIED,
        );

        await unlike(2);
        await settle();

        expect(ids(cubit.state), [postId(3), postId(2), postId(1)]);
        expect(engagement.state.failure?.action, EngagementAction.unlike);
        expect(engagement.state.failure?.postId, postId(2));
        expect(cubit.holds(postId(2)), isTrue);
      },
    );

    test(
      'a heart tapped elsewhere (Home, a post) removes the row as well',
      () async {
        server.pages[''] = () => likesPage([2, 1]);
        await cubit.load();

        await unlike(1);
        await settle();

        expect(ids(cubit.state), [postId(2)]);
      },
    );

    test('liking the post again (from Home, while History is mounted '
        'underneath) brings the row back at its place', () async {
      server.pages[''] = () => likesPage([3, 2, 1]);
      await cubit.load();
      await unlike(2);
      await settle();
      expect(ids(cubit.state), [postId(3), postId(1)]);

      // The card on Home shows the post unliked now, and is tapped.
      await engagement.setLiked(
        postId(2),
        liked: true,
        shown: EngagementEntry.fromView(likedView(2, liked: false)),
      );
      await settle();

      expect(ids(cubit.state), [postId(3), postId(2), postId(1)]);
    });

    test('a like the overlay confirms keeps the row', () async {
      server.pages[''] = () => likesPage([2, 1]);
      await cubit.load();

      // Liked while not liked on the row it was made on: an unrelated entry.
      await engagement.setLiked(
        postId(7),
        liked: true,
        shown: EngagementEntry.fromView(likedView(7, liked: false)),
      );
      await settle();

      expect(ids(cubit.state), [postId(2), postId(1)]);
    });

    test(
      'a page opened after the unlike does not bring the row back',
      () async {
        server.pages[''] = () => likesPage([3, 2, 1]);
        await cubit.load();
        await unlike(2);
        await settle();

        // The server may still list it for a minute (an instance's cache).
        await cubit.load();

        expect(ids(cubit.state), [postId(3), postId(1)]);
      },
    );

    test('holds says which posts the loaded pages have', () async {
      server.pages[''] = () => likesPage([2, 1]);
      await cubit.load();

      expect(cubit.holds(postId(2)), isTrue);
      expect(cubit.holds(postId(9)), isFalse);
    });
  });

  group('sign-out', () {
    test('the rows are dropped, and a page landing after is ignored', () async {
      final gate = Completer<void>();
      server.pages[''] = () => likesPage([2, 1], 't1');
      server.pages['t1'] = () async {
        await gate.future;
        return likesPage([0]);
      };
      await cubit.load();
      final pending = cubit.loadMore();
      await settle();

      repo.clearSession();
      expect(cubit.state.items, isEmpty);
      expect(cubit.state.status, LikesListStatus.loading);

      gate.complete();
      await pending;
      expect(cubit.state.items, isEmpty);
      expect(cubit.state.status, LikesListStatus.loading);
    });

    test('an ended epoch drops the rows when the overlay resets', () async {
      server.pages[''] = () => likesPage([2, 1]);
      await cubit.load();

      // What sign-out does: the epoch ends, then the overlay resets.
      epoch.end();
      engagement.reset();
      await settle();

      expect(cubit.state.items, isEmpty);
    });

    test('an answer that comes back to a closed cubit is ignored', () async {
      final gate = Completer<void>();
      server.pages[''] = () async {
        await gate.future;
        return likesPage([1]);
      };
      final loading = cubit.load();
      await settle();

      await cubit.close();
      gate.complete();
      await loading;

      expect(cubit.isClosed, isTrue);
    });
  });
}
