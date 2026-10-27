import 'dart:async';

import 'package:connectrpc/connect.dart' as connect;
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/graph/data/suggestions_repository.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import 'package:flutter_test/flutter_test.dart';

import '../../../support/posts_fixtures.dart' show serverError;
import '../../../support/suggestions_fixtures.dart';

List<String> _ids(List<graph.UserListItem> items) => [
  for (final item in items) item.user.userId,
];

connect.ConnectException _featureDisabled([
  String feature = 'follow_suggestions',
]) => serverError(
  connect.Code.failedPrecondition,
  common.ErrorReason.ERROR_REASON_FEATURE_DISABLED,
  metadata: {'feature': feature},
);

void main() {
  late SuggestionsRig rig;

  setUp(() => rig = SuggestionsRig());
  tearDown(() => rig.database.close());

  group('the 24 h cache', () {
    test('one call asks for 5 and returns them best first', () async {
      final rows = await rig.repository.suggestionsFor('me');

      expect(_ids(rows), ['u1', 'u2', 'u3', 'u4', 'u5']);
      expect(rig.suggestionCalls, 1);
      expect(rig.requestedMax, [kSuggestionsMax]);
    });

    test('a second call in the session costs nothing', () async {
      await rig.repository.suggestionsFor('me');
      await rig.repository.suggestionsFor('me');
      rig.clock = const Duration(hours: 23, minutes: 59);
      await rig.repository.suggestionsFor('me');

      expect(rig.suggestionCalls, 1);
    });

    test('a restart within 24 h reads the disk entry: 0 RPCs', () async {
      await rig.repository.suggestionsFor('me');
      rig.clock = const Duration(hours: 5);

      final restarted = rig.newRepository();
      final rows = await restarted.suggestionsFor('me');

      expect(_ids(rows), ['u1', 'u2', 'u3', 'u4', 'u5']);
      expect(rig.suggestionCalls, 1);
    });

    test('after 24 h the entry is stale and one more call goes out', () async {
      await rig.repository.suggestionsFor('me');
      rig.users = [suggestedUser(9)];
      rig.clock = kSuggestionsTtl + const Duration(minutes: 1);

      expect(_ids(await rig.repository.suggestionsFor('me')), ['u9']);
      expect(rig.suggestionCalls, 2);

      // And the restart path honours the same window.
      rig.clock += const Duration(hours: 25);
      await rig.newRepository().suggestionsFor('me');
      expect(rig.suggestionCalls, 3);
    });

    test('is keyed per account: another uid asks for its own list', () async {
      await rig.repository.suggestionsFor('alice');
      rig.users = [suggestedUser(7)];

      final bob = await rig.repository.suggestionsFor('bob');

      expect(_ids(bob), ['u7']);
      expect(rig.suggestionCalls, 2);
      expect(_ids(await rig.repository.suggestionsFor('alice')), [
        'u1',
        'u2',
        'u3',
        'u4',
        'u5',
      ]);
      expect(rig.suggestionCalls, 2);
      expect(
        await rig.database.readSetting(SuggestionsRepository.key('alice')),
        isNotNull,
      );
      expect(
        await rig.database.readSetting(SuggestionsRepository.key('bob')),
        isNotNull,
      );
    });

    test('an empty answer is cached too, restart included', () async {
      rig.users = const [];

      expect(await rig.repository.suggestionsFor('me'), isEmpty);
      expect(await rig.repository.suggestionsFor('me'), isEmpty);
      expect(await rig.newRepository().suggestionsFor('me'), isEmpty);

      expect(rig.suggestionCalls, 1);
    });

    test('concurrent callers share one call', () async {
      final gate = Completer<graph.ListSuggestedUsersResponse>();
      rig.onSuggestions = () => gate.future;

      final a = rig.repository.suggestionsFor('me');
      final b = rig.repository.suggestionsFor('me');
      await Future<void>.delayed(Duration.zero);
      gate.complete(graph.ListSuggestedUsersResponse(users: rig.users));

      expect(_ids(await a), _ids(await b));
      expect(rig.suggestionCalls, 1);
    });

    test('a corrupt disk entry is a miss, not a crash', () async {
      await rig.database.writeSetting(SuggestionsRepository.key('me'), '{nope');

      expect(_ids(await rig.repository.suggestionsFor('me')).length, 5);
      expect(rig.suggestionCalls, 1);
    });

    test(
      'the disk entry lives under the account prefix, so sign-out wipes it',
      () async {
        await rig.database.writeSetting('appearance', 'dark');
        await rig.repository.suggestionsFor('me');
        expect(
          await rig.database.readSetting(SuggestionsRepository.key('me')),
          isNotNull,
        );

        await rig.database.clearAll();

        expect(
          await rig.database.readSetting(SuggestionsRepository.key('me')),
          isNull,
        );
        expect(await rig.database.readSetting('appearance'), 'dark');
      },
    );
  });

  group('what may be shown', () {
    test('drops the account itself and repeated users', () async {
      rig.users = [
        suggestedUser(1, userId: 'me'),
        suggestedUser(2),
        suggestedUser(2),
        suggestedUser(3),
      ];

      expect(_ids(await rig.repository.suggestionsFor('me')), ['u2', 'u3']);
    });

    test('drops rows the local graph state already knows', () async {
      rig.users = [
        suggestedUser(1),
        suggestedUser(2),
        suggestedUser(3),
        suggestedUser(4),
        suggestedUser(5),
      ];
      await rig.repository.suggestionsFor('me');
      // Known locally after the fetch: followed, requested, blocked, muted.
      rig.graphRepository
        ..primeFromListItem(
          suggestedUser(1, follow: graph.FollowState.FOLLOW_STATE_FOLLOWING),
          rig.database.sessionEpoch.value,
        )
        ..primeFromListItem(
          suggestedUser(2, follow: graph.FollowState.FOLLOW_STATE_REQUESTED),
          rig.database.sessionEpoch.value,
        )
        ..primeFromListItem(
          suggestedUser(3, blocking: true),
          rig.database.sessionEpoch.value,
        )
        ..primeFromListItem(
          suggestedUser(4, muting: true),
          rig.database.sessionEpoch.value,
        );

      expect(_ids(await rig.repository.suggestionsFor('me')), ['u5']);
      expect(rig.suggestionCalls, 1);
    });

    test('drops a row the response itself marks as followed', () async {
      rig.users = [
        suggestedUser(1, follow: graph.FollowState.FOLLOW_STATE_FOLLOWING),
        suggestedUser(2),
      ];

      expect(_ids(await rig.repository.suggestionsFor('me')), ['u2']);
    });

    test('a follow made through the graph repository removes the row, also '
        'from the cached list', () async {
      await rig.repository.suggestionsFor('me');
      await rig.graphRepository.follow(userId: 'u2', idempotencyKey: 'k');

      expect(_ids(await rig.repository.suggestionsFor('me')), [
        'u1',
        'u3',
        'u4',
        'u5',
      ]);
      expect(rig.suggestionCalls, 1);
    });

    test('a stale server answer never overrides what the client already '
        'knows (follow and block made before the fetch)', () async {
      await rig.graphRepository.follow(userId: 'u2', idempotencyKey: 'k');
      rig.graphRepository.primeFromListItem(
        suggestedUser(3, blocking: true),
        rig.database.sessionEpoch.value,
      );
      // The server answers from an older cache: everyone is still "none".
      rig.users = [for (var i = 1; i <= 5; i++) suggestedUser(i)];

      expect(_ids(await rig.repository.suggestionsFor('me')), [
        'u1',
        'u4',
        'u5',
      ]);

      expect(
        rig.graphRepository.cached('u2')!.followState,
        graph.FollowState.FOLLOW_STATE_FOLLOWING,
      );
      expect(rig.graphRepository.cached('u3')!.blocking, isTrue);
      // Accounts the client knew nothing about are seeded from the answer.
      expect(rig.graphRepository.cached('u1'), isNotNull);
    });

    test('keeps at most five rows', () async {
      rig.users = [for (var i = 1; i <= 8; i++) suggestedUser(i)];

      expect((await rig.repository.suggestionsFor('me')).length, 5);
    });
  });

  group('dismissals', () {
    test(
      'hide removes a row for the session; current reads memory only',
      () async {
        await rig.repository.suggestionsFor('me');

        rig.repository.hide('me', 'u2');

        expect(_ids(rig.repository.current('me')), ['u1', 'u3', 'u4', 'u5']);
        expect(_ids(await rig.repository.suggestionsFor('me')), [
          'u1',
          'u3',
          'u4',
          'u5',
        ]);
        expect(rig.suggestionCalls, 1);
      },
    );

    test('are never stored: a restart brings the row back', () async {
      await rig.repository.suggestionsFor('me');
      rig.repository.hide('me', 'u2');

      final restarted = rig.newRepository();

      expect(_ids(await restarted.suggestionsFor('me')), [
        'u1',
        'u2',
        'u3',
        'u4',
        'u5',
      ]);
      expect(rig.suggestionCalls, 1);
    });

    test('belong to one account', () async {
      await rig.repository.suggestionsFor('alice');
      rig.repository.hide('alice', 'u2');

      expect(_ids(await rig.repository.suggestionsFor('bob')), contains('u2'));
    });
  });

  group('SessionEpoch', () {
    test(
      'ending the session drops memory, dismissals and the failure state',
      () async {
        await rig.repository.suggestionsFor('me');
        rig.repository.hide('me', 'u2');

        rig.database.sessionEpoch.end();
        await rig.database.clearAll();

        expect(rig.repository.current('me'), isEmpty);
        expect(_ids(await rig.repository.suggestionsFor('me')).length, 5);
        expect(rig.suggestionCalls, 2);
      },
    );

    test(
      'a response that lands after sign-out is dropped and not stored',
      () async {
        final gate = Completer<graph.ListSuggestedUsersResponse>();
        rig.onSuggestions = () => gate.future;

        final pending = rig.repository.suggestionsFor('me');
        await Future<void>.delayed(Duration.zero);
        rig.database.sessionEpoch.end();
        await rig.database.clearAll();
        gate.complete(graph.ListSuggestedUsersResponse(users: rig.users));

        expect(await pending, isEmpty);
        await Future<void>.delayed(Duration.zero);
        expect(
          await rig.database.readSetting(SuggestionsRepository.key('me')),
          isNull,
        );
        expect(rig.repository.current('me'), isEmpty);
      },
    );

    test('clearSession forgets the unavailable state', () async {
      rig.onSuggestions = () async => throw _featureDisabled();
      await rig.repository.suggestionsFor('me');

      rig.repository.clearSession();
      rig.onSuggestions = null;

      expect(_ids(await rig.repository.suggestionsFor('me')).length, 5);
    });
  });

  group('failures hide the card and never loop', () {
    test('FEATURE_DISABLED: nothing now, no second call this session, a '
        'retry after a restart', () async {
      rig.onSuggestions = () async => throw _featureDisabled();

      expect(await rig.repository.suggestionsFor('me'), isEmpty);
      expect(await rig.repository.suggestionsFor('me'), isEmpty);
      rig.clock = const Duration(hours: 2);
      expect(await rig.repository.suggestionsFor('me'), isEmpty);
      expect(rig.suggestionCalls, 1);

      rig.onSuggestions = null;
      final restarted = rig.newRepository();
      expect(_ids(await restarted.suggestionsFor('me')).length, 5);
      expect(rig.suggestionCalls, 2);
    });

    test('FEATURE_DISABLED naming graph is the same', () async {
      rig.onSuggestions = () async => throw _featureDisabled('graph');

      expect(await rig.repository.suggestionsFor('me'), isEmpty);
      expect(await rig.repository.suggestionsFor('me'), isEmpty);
      expect(rig.suggestionCalls, 1);
    });

    test('UNIMPLEMENTED (dev before W3-12): like disabled, retried on the '
        'next start, not in a loop', () async {
      rig.onSuggestions = () async =>
          throw connect.ConnectException(connect.Code.unimplemented, 'nope');
      var reported = 0;
      rig.onUnexpectedError = (_, _) => reported++;

      expect(await rig.repository.suggestionsFor('me'), isEmpty);
      expect(await rig.repository.suggestionsFor('me'), isEmpty);
      expect(rig.suggestionCalls, 1);
      expect(reported, 0);

      rig.onSuggestions = null;
      expect(_ids(await rig.newRepository().suggestionsFor('me')).length, 5);
    });

    test('RESOURCE_EXHAUSTED (rate limited): backs off for the 24 h window, '
        'restarts included', () async {
      rig.onSuggestions = () async => throw serverError(
        connect.Code.resourceExhausted,
        common.ErrorReason.ERROR_REASON_RATE_LIMITED,
        metadata: {'limit': 'suggestions_daily'},
      );

      expect(await rig.repository.suggestionsFor('me'), isEmpty);
      expect(await rig.repository.suggestionsFor('me'), isEmpty);
      rig.clock = const Duration(hours: 3);
      expect(await rig.newRepository().suggestionsFor('me'), isEmpty);
      expect(rig.suggestionCalls, 1);

      // The next window asks again.
      rig.onSuggestions = null;
      rig.clock = kSuggestionsTtl + const Duration(minutes: 1);
      expect(_ids(await rig.newRepository().suggestionsFor('me')).length, 5);
      expect(rig.suggestionCalls, 2);
    });

    test('RESOURCE_EXHAUSTED without a detail (a quota) is the same', () async {
      rig.onSuggestions = () async =>
          throw connect.ConnectException(connect.Code.resourceExhausted, 'x');

      expect(await rig.repository.suggestionsFor('me'), isEmpty);
      expect(await rig.newRepository().suggestionsFor('me'), isEmpty);
      expect(rig.suggestionCalls, 1);
    });

    test('the short in-flight hold is not a 24 h ban', () async {
      rig.onSuggestions = () async => throw serverError(
        connect.Code.resourceExhausted,
        common.ErrorReason.ERROR_REASON_RATE_LIMITED,
        metadata: {'limit': RateLimitedException.inflightLimitName},
      );

      expect(await rig.repository.suggestionsFor('me'), isEmpty);
      // Not stored: after the failure backoff it asks again.
      rig.onSuggestions = null;
      rig.clock = kSuggestionsFailureBackoff + const Duration(seconds: 1);
      expect(_ids(await rig.repository.suggestionsFor('me')).length, 5);
    });

    test(
      'a network failure: empty, no retry inside the backoff, one after',
      () async {
        rig.onSuggestions = () async =>
            throw connect.ConnectException(connect.Code.unavailable, 'offline');

        expect(await rig.repository.suggestionsFor('me'), isEmpty);
        rig.clock = const Duration(minutes: 9);
        expect(await rig.repository.suggestionsFor('me'), isEmpty);
        expect(rig.suggestionCalls, 1);

        rig.onSuggestions = null;
        rig.clock = kSuggestionsFailureBackoff + const Duration(seconds: 1);
        expect(_ids(await rig.repository.suggestionsFor('me')).length, 5);
        expect(rig.suggestionCalls, 2);
      },
    );

    test('an unexpected server error is reported once and backs off', () async {
      rig.onSuggestions = () async =>
          throw connect.ConnectException(connect.Code.internal, 'boom');
      final reported = <Object>[];
      rig.onUnexpectedError = (error, _) => reported.add(error);

      expect(await rig.repository.suggestionsFor('me'), isEmpty);
      expect(await rig.repository.suggestionsFor('me'), isEmpty);

      expect(reported.single, isA<UnknownApiException>());
      expect(rig.suggestionCalls, 1);
    });
  });
}
