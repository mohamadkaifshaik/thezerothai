import 'dart:async';

import 'package:connectrpc/connect.dart' as connect;
import 'package:dzeroth/core/feature_flags/service_feature_gate.dart';
import 'package:dzeroth/core/network/api_client.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/network/rate_limit_hold.dart';
import 'package:dzeroth/core/storage/session_epoch.dart';
import 'package:dzeroth/features/engagement/data/likes_repository.dart';
import 'package:dzeroth/features/engagement/domain/likes_list_feature_flag.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_transport.dart';
import '../../../support/likes_fixtures.dart';
import '../../../support/posts_fixtures.dart';

void main() {
  late FakeLikesServer server;
  late SessionEpoch epoch;
  late RateLimitHold shared;
  late LikesRepository repo;
  var gateOn = true;
  var refreshAsked = 0;
  var unexpected = 0;
  final base = DateTime.now();
  var now = base;

  setUp(() {
    server = FakeLikesServer();
    epoch = SessionEpoch();
    shared = RateLimitHold();
    gateOn = true;
    refreshAsked = 0;
    unexpected = 0;
    now = base;
    repo = LikesRepository(
      apiClient: ApiClient.withTransport(FakeTransport(server.handle)),
      gate: ServiceFeatureGate(
        isEnabled: () => gateOn,
        onDisabledByServer: () => refreshAsked++,
      ),
      epoch: epoch,
      onUnexpectedError: (_, _) => unexpected++,
      rateLimitHold: shared,
      now: () => now,
    );
  });

  tearDown(() => repo.dispose());

  List<String> ids(LikesPage? page) => [
    for (final v in page!.posts) v.post.postId,
  ];

  group('fetchPage', () {
    test(
      'asks for 20 by default, returns the live rows and the token',
      () async {
        server.pages[''] = () => likesPage([3, 2, 1], 'p2');

        final page = await repo.fetchPage();

        expect(server.listTokens, ['']);
        expect(server.listSizes, [20]);
        expect(ids(page), [postId(3), postId(2), postId(1)]);
        expect(page!.nextPageToken, 'p2');
        expect(page.hasMore, isTrue);
      },
    );

    test('an empty token ends the list; a user with no likes gets an empty '
        'page and no token', () async {
      final page = await repo.fetchPage();

      expect(page!.posts, isEmpty);
      expect(page.hasMore, isFalse);
      expect(server.listTokens, ['']);
    });

    test('passes the token it is given, and the page size', () async {
      server.pages['t1'] = () => likesPage([5]);

      final page = await repo.fetchPage(after: 't1', pageSize: 50);

      expect(server.listTokens, ['t1']);
      expect(server.listSizes, [50]);
      expect(ids(page), [postId(5)]);
    });

    test('follows the token through empty and known-only pages until a row '
        'comes, and stops there', () async {
      server.pages[''] = () => likesPage(const [], 't1');
      server.pages['t1'] = () => likesPage([1], 't2');
      server.pages['t2'] = () => likesPage([4, 3], 't3');
      server.pages['t3'] = () => likesPage([2]);

      final page = await repo.fetchPage(known: {postId(1)});

      expect(server.listTokens, ['', 't1', 't2']);
      expect(ids(page), [postId(4), postId(3)]);
      expect(page!.nextPageToken, 't3');
    });

    test(
      'drops rows the caller already has and repeats inside a page',
      () async {
        server.pages['t1'] = () => likesPageOf([
          likedView(1),
          likedView(2),
          likedView(2, text: 'again'),
          likedView(3),
        ]);

        final page = await repo.fetchPage(after: 't1', known: {postId(1)});

        expect(ids(page), [postId(2), postId(3)]);
      },
    );

    test(
      'a token that did not advance ends the list instead of looping',
      () async {
        server.pages['t1'] = () => likesPage(const [], 't1');

        final page = await repo.fetchPage(after: 't1');

        expect(server.listTokens, ['t1']);
        expect(page!.posts, isEmpty);
        expect(page.hasMore, isFalse);
      },
    );

    test('one ask spends at most $kLikesMaxCallsPerFetch calls and hands '
        'back the token to go on from', () async {
      for (var i = 0; i < 12; i++) {
        server.pages[i == 0 ? '' : 't$i'] = () =>
            likesPage(const [], 't${i + 1}');
      }

      final page = await repo.fetchPage();

      expect(server.listTokens, ['', 't1', 't2', 't3', 't4']);
      expect(page!.posts, isEmpty);
      expect(page.nextPageToken, 't5');
    });

    test('a row without an id is skipped', () async {
      server.pages[''] = () =>
          likesPageOf([likedView(1)..post.postId = '', likedView(2)]);

      expect(ids(await repo.fetchPage()), [postId(2)]);
    });
  });

  group('flag', () {
    test(
      'off for the caller: no RPC, FEATURE_DISABLED, not available',
      () async {
        gateOn = false;

        expect(repo.available, isFalse);
        await expectLater(
          repo.fetchPage(),
          throwsA(isA<FeatureDisabledException>()),
        );
        expect(server.listCalls, 0);
      },
    );

    test('FEATURE_DISABLED from the server is remembered, asks one GetMe '
        'refresh and sends nothing more', () async {
      server.pages[''] = () => throw serverError(
        connect.Code.failedPrecondition,
        common.ErrorReason.ERROR_REASON_FEATURE_DISABLED,
        metadata: {'feature': kFeatureLikesList},
      );
      expect(repo.available, isTrue);

      await expectLater(
        repo.fetchPage(),
        throwsA(
          isA<FeatureDisabledException>().having(
            (e) => e.feature,
            'feature',
            kFeatureLikesList,
          ),
        ),
      );

      expect(refreshAsked, 1);
      expect(repo.available, isFalse);
      await expectLater(
        repo.fetchPage(),
        throwsA(isA<FeatureDisabledException>()),
      );
      expect(server.listCalls, 1);
    });

    test('UNIMPLEMENTED reads as disabled: not reported, no GetMe refresh, '
        'no call for ten minutes, then one more try', () async {
      server.pages[''] = () => throw connect.ConnectException(
        connect.Code.unimplemented,
        'ListLikedPosts is not implemented yet',
      );

      await expectLater(
        repo.fetchPage(),
        throwsA(
          isA<FeatureDisabledException>().having(
            (e) => e.feature,
            'feature',
            kFeatureLikesList,
          ),
        ),
      );
      expect(unexpected, 0);
      expect(refreshAsked, 0);
      expect(repo.available, isFalse);

      // The storm the backoff prevents: every open would call again.
      for (var i = 0; i < 3; i++) {
        await expectLater(
          repo.fetchPage(),
          throwsA(isA<FeatureDisabledException>()),
        );
      }
      expect(server.listCalls, 1);

      now = base.add(kLikesUnavailableBackoff + const Duration(seconds: 1));
      expect(repo.available, isTrue);
      server.pages[''] = () => likesPage([1]);
      expect(ids(await repo.fetchPage()), [postId(1)]);
      expect(server.listCalls, 2);
    });

    test(
      'an unexpected failure is reported once and thrown as it is',
      () async {
        server.pages[''] = () =>
            throw connect.ConnectException(connect.Code.internal, 'boom');

        await expectLater(
          repo.fetchPage(),
          throwsA(isA<UnknownApiException>()),
        );

        expect(unexpected, 1);
      },
    );
  });

  group('errors', () {
    test('an expired or foreign token is VALIDATION field=page_token, thrown '
        'as is', () async {
      server.pages['old'] = () => throw rejectedToken('page_token');

      await expectLater(
        repo.fetchPage(after: 'old'),
        throwsA(
          isA<ValidationException>().having(
            (e) => e.field,
            'field',
            'page_token',
          ),
        ),
      );
      expect(unexpected, 0);
    });

    test(
      'the per-minute bucket of this RPC holds only this repository',
      () async {
        server.pages[''] = () => throw serverError(
          connect.Code.resourceExhausted,
          common.ErrorReason.ERROR_REASON_RATE_LIMITED,
        );

        await expectLater(
          repo.fetchPage(),
          throwsA(isA<RateLimitedException>()),
        );
        // Held: the next ask is answered without a call...
        await expectLater(
          repo.fetchPage(),
          throwsA(isA<RateLimitedException>()),
        );
        expect(server.listCalls, 1);
        // ...and Home / Bookmarks are not frozen with it.
        expect(shared.check(), isNull);
      },
    );

    test('the daily read budget is the shared hold: it freezes every read '
        'screen', () async {
      server.pages[''] = () => throw serverError(
        connect.Code.resourceExhausted,
        common.ErrorReason.ERROR_REASON_RATE_LIMITED,
        metadata: {'limit': 'read_budget_daily'},
      );

      await expectLater(repo.fetchPage(), throwsA(isA<RateLimitedException>()));

      expect(shared.check(), isNotNull);
      await expectLater(repo.fetchPage(), throwsA(isA<RateLimitedException>()));
      expect(server.listCalls, 1);
    });

    test(
      'a hold the shared budget already has stops the call before it',
      () async {
        shared.record(
          const RateLimitedException(
            'slow down',
            retryAfter: Duration(minutes: 10),
            limitName: 'read_budget_daily',
          ),
        );

        await expectLater(
          repo.fetchPage(),
          throwsA(isA<RateLimitedException>()),
        );
        expect(server.listCalls, 0);
      },
    );
  });

  group('session', () {
    test('a page that lands after the session ended is ignored', () async {
      final gate = Completer<void>();
      server.pages[''] = () async {
        await gate.future;
        return likesPage([1]);
      };

      final pending = repo.fetchPage();
      await Future<void>.delayed(Duration.zero);
      epoch.end();
      gate.complete();

      expect(await pending, isNull);
    });

    test(
      'clearSession tells the open list and ignores a request in flight',
      () async {
        final ended = <void>[];
        final sub = repo.sessionEnds.listen(ended.add);
        addTearDown(sub.cancel);
        final generation = repo.sessionGeneration;
        final gate = Completer<void>();
        server.pages[''] = () async {
          await gate.future;
          return likesPage([1]);
        };

        final pending = repo.fetchPage();
        await Future<void>.delayed(Duration.zero);
        repo.clearSession();
        gate.complete();

        expect(ended, hasLength(1));
        expect(repo.sessionGeneration, generation + 1);
        expect(await pending, isNull);
      },
    );

    test('an ended epoch is noticed on the next look, with no event lost '
        'to the list', () async {
      final generation = repo.sessionGeneration;
      epoch.end();

      expect(repo.sessionGeneration, generation + 1);
    });

    test('sign-out forgets the UNIMPLEMENTED backoff', () async {
      server.pages[''] = () =>
          throw connect.ConnectException(connect.Code.unimplemented, 'not yet');
      await expectLater(
        repo.fetchPage(),
        throwsA(isA<FeatureDisabledException>()),
      );
      expect(repo.available, isFalse);

      repo.clearSession();

      expect(repo.available, isTrue);
    });
  });
}
