import 'dart:async';
import 'dart:convert';

import 'package:connectrpc/connect.dart' as connect;
import 'package:drift/drift.dart'
    show ApplyInterceptor, QueryExecutor, QueryInterceptor, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/storage/app_database.dart';
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

const _oneMinute = Duration(minutes: 1);

/// Holds every delete back, so a read issued meanwhile can overtake it.
class _SlowDeletes extends QueryInterceptor {
  @override
  Future<int> runDelete(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    return super.runDelete(executor, statement, args);
  }
}

/// Writes a disk entry by hand, as an older build (no `life`) or this one
/// would: [age] before the rig's "now".
Future<void> _writeEntry(
  SuggestionsRig rig, {
  required Duration age,
  required List<graph.UserListItem> users,
  Object? life,
  String uid = 'me',
}) => rig.database.writeSetting(
  SuggestionsRepository.key(uid),
  jsonEncode({
    'v': 1,
    'at': rig.now.subtract(age).toUtc().millisecondsSinceEpoch,
    'users': base64Encode(
      graph.ListSuggestedUsersResponse(users: users).writeToBuffer(),
    ),
    'life': ?life,
  }),
);

Future<Map<String, Object?>> _storedEntry(
  SuggestionsRig rig, [
  String uid = 'me',
]) async => jsonDecode(
  (await rig.database.readSetting(SuggestionsRepository.key(uid)))!,
) as Map<String, Object?>;

/// A `ListSuggestedUsers` answer that is a limit (the daily cap).
Future<graph.ListSuggestedUsersResponse> _limit() async => throw serverError(
  connect.Code.resourceExhausted,
  common.ErrorReason.ERROR_REASON_RATE_LIMITED,
  metadata: {'limit': 'suggestions_daily'},
);

void main() {
  late SuggestionsRig rig;

  setUp(() => rig = SuggestionsRig());
  tearDown(() => rig.database.close());

  test('the lifetimes are 48 h, 6 h and 24 h (ADR-0024 Amendment 2)', () {
    expect(kSuggestionsTtl, const Duration(hours: 48));
    expect(kSuggestionsEmptyTtl, const Duration(hours: 6));
    expect(kSuggestionsLimitBackoff, const Duration(hours: 24));
  });

  group('the answer cache (48 h)', () {
    test('one call asks for 5 and returns them best first', () async {
      final rows = await rig.repository.suggestionsFor('me');

      expect(_ids(rows), ['u1', 'u2', 'u3', 'u4', 'u5']);
      expect(rig.suggestionCalls, 1);
      expect(rig.requestedMax, [kSuggestionsMax]);
    });

    test('a second call in the session costs nothing', () async {
      await rig.repository.suggestionsFor('me');
      await rig.repository.suggestionsFor('me');
      rig.clock = kSuggestionsTtl - _oneMinute;
      await rig.repository.suggestionsFor('me');

      expect(rig.suggestionCalls, 1);
    });

    test('a restart within the TTL reads the disk entry: 0 RPCs', () async {
      await rig.repository.suggestionsFor('me');
      rig.clock = const Duration(hours: 5);

      final restarted = rig.newRepository();
      final rows = await restarted.suggestionsFor('me');

      expect(_ids(rows), ['u1', 'u2', 'u3', 'u4', 'u5']);
      expect(rig.suggestionCalls, 1);
    });

    test('the boundary: one minute before the TTL is a hit, one minute after '
        'is a call (memory and disk)', () async {
      await rig.repository.suggestionsFor('me');

      rig.clock = kSuggestionsTtl - _oneMinute;
      await rig.repository.suggestionsFor('me');
      await rig.newRepository().suggestionsFor('me');
      expect(rig.suggestionCalls, 1);

      rig.users = [suggestedUser(9)];
      rig.clock = kSuggestionsTtl + _oneMinute;
      expect(_ids(await rig.repository.suggestionsFor('me')), ['u9']);
      expect(rig.suggestionCalls, 2);
    });

    test('a restart past the TTL is a call too', () async {
      await rig.repository.suggestionsFor('me');
      rig.users = [suggestedUser(9)];
      rig.clock = kSuggestionsTtl + _oneMinute;

      expect(_ids(await rig.newRepository().suggestionsFor('me')), ['u9']);
      expect(rig.suggestionCalls, 2);
    });

    test('a 24 h old answer is still fresh (it was stale before the 48 h '
        'cache)', () async {
      await rig.repository.suggestionsFor('me');
      rig.clock = const Duration(hours: 25);

      await rig.repository.suggestionsFor('me');
      await rig.newRepository().suggestionsFor('me');

      expect(rig.suggestionCalls, 1);
    });

    test(
      'after the TTL the entry is stale and one more call goes out',
      () async {
        await rig.repository.suggestionsFor('me');
        rig.users = [suggestedUser(9)];
        rig.clock = kSuggestionsTtl + _oneMinute;

        expect(_ids(await rig.repository.suggestionsFor('me')), ['u9']);
        expect(rig.suggestionCalls, 2);

        // The new answer lives a full TTL from its own fetch, and the restart
        // path honours the same window.
        rig.clock += kSuggestionsTtl - _oneMinute;
        await rig.newRepository().suggestionsFor('me');
        expect(rig.suggestionCalls, 2);
        rig.clock += const Duration(minutes: 2);
        await rig.newRepository().suggestionsFor('me');
        expect(rig.suggestionCalls, 3);
      },
    );

    test('the disk entry stays v: 1 and records its lifetime', () async {
      await rig.repository.suggestionsFor('me');

      final stored = await _storedEntry(rig);

      expect(stored['v'], 1);
      expect(stored['life'], 'full');
      expect(stored.keys, containsAll(['v', 'at', 'users', 'life']));
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

    test('an empty answer lives 6 h, not 48: not asked before, asked after '
        '(memory and disk)', () async {
      rig.users = const [];
      expect(await rig.repository.suggestionsFor('me'), isEmpty);
      expect((await _storedEntry(rig))['life'], 'empty');

      rig.clock = kSuggestionsEmptyTtl - _oneMinute;
      await rig.repository.suggestionsFor('me');
      await rig.newRepository().suggestionsFor('me');
      expect(rig.suggestionCalls, 1);

      // The account followed 3 accounts meanwhile: the next ask has rows.
      rig.users = [suggestedUser(1), suggestedUser(2)];
      rig.clock = kSuggestionsEmptyTtl + _oneMinute;
      expect(_ids(await rig.repository.suggestionsFor('me')), ['u1', 'u2']);
      expect(rig.suggestionCalls, 2);
    });

    test('a restart past the empty lifetime asks again too', () async {
      rig.users = const [];
      await rig.repository.suggestionsFor('me');
      rig.users = [suggestedUser(1)];
      rig.clock = kSuggestionsEmptyTtl + _oneMinute;

      expect(_ids(await rig.newRepository().suggestionsFor('me')), ['u1']);
      expect(rig.suggestionCalls, 2);
    });

    test('the answer after an empty one is a full TTL again', () async {
      rig.users = const [];
      await rig.repository.suggestionsFor('me');
      rig.users = [suggestedUser(1)];
      rig.clock = kSuggestionsEmptyTtl + _oneMinute;
      await rig.repository.suggestionsFor('me');

      rig.clock += kSuggestionsTtl - _oneMinute;
      await rig.repository.suggestionsFor('me');
      await rig.newRepository().suggestionsFor('me');

      expect(rig.suggestionCalls, 2);
      expect((await _storedEntry(rig))['life'], 'full');
    });

    test('a limit answer is kept 24 h: no call before, restarts included, '
        'one after', () async {
      rig.onSuggestions = _limit;
      expect(await rig.repository.suggestionsFor('me'), isEmpty);
      expect((await _storedEntry(rig))['life'], 'limit');

      // Past the 6 h of an empty answer: the field is what keeps it quiet.
      rig.clock = kSuggestionsEmptyTtl + const Duration(hours: 1);
      expect(await rig.repository.suggestionsFor('me'), isEmpty);
      expect(await rig.newRepository().suggestionsFor('me'), isEmpty);
      rig.clock = kSuggestionsLimitBackoff - _oneMinute;
      expect(await rig.repository.suggestionsFor('me'), isEmpty);
      expect(await rig.newRepository().suggestionsFor('me'), isEmpty);
      expect(rig.suggestionCalls, 1);

      rig.onSuggestions = null;
      rig.clock = kSuggestionsLimitBackoff + _oneMinute;
      expect(_ids(await rig.newRepository().suggestionsFor('me')).length, 5);
      expect(rig.suggestionCalls, 2);
    });

    test('an entry an older build wrote (no lifetime field) is judged by '
        'content: non-empty 48 h, empty 6 h', () async {
      // One account per case: a fetch's own disk write never lands on the
      // entry of the next case.
      // 30 h old and non-empty: stale for the 24 h build, fresh now.
      await _writeEntry(
        rig,
        uid: 'a',
        age: const Duration(hours: 30),
        users: [suggestedUser(8)],
      );
      expect(_ids(await rig.repository.suggestionsFor('a')), ['u8']);
      expect(rig.suggestionCalls, 0);

      // Non-empty and past 48 h: a call.
      await _writeEntry(
        rig,
        uid: 'b',
        age: kSuggestionsTtl + _oneMinute,
        users: [suggestedUser(8)],
      );
      expect(_ids(await rig.newRepository().suggestionsFor('b')).length, 5);
      expect(rig.suggestionCalls, 1);

      // Empty, 5 h old: still quiet. Empty, 7 h old: a call.
      await _writeEntry(
        rig,
        uid: 'c',
        age: kSuggestionsEmptyTtl - const Duration(hours: 1),
        users: const [],
      );
      expect(await rig.newRepository().suggestionsFor('c'), isEmpty);
      expect(rig.suggestionCalls, 1);
      await _writeEntry(
        rig,
        uid: 'd',
        age: kSuggestionsEmptyTtl + const Duration(hours: 1),
        users: const [],
      );
      expect(_ids(await rig.newRepository().suggestionsFor('d')).length, 5);
      expect(rig.suggestionCalls, 2);
    });

    test('an unknown or malformed lifetime is judged by content too', () async {
      var i = 0;
      for (final life in <Object>['future', 7, true]) {
        final uid = 'life${i++}';
        await _writeEntry(
          rig,
          uid: uid,
          age: kSuggestionsEmptyTtl + const Duration(hours: 1),
          users: const [],
          life: life,
        );
        final before = rig.suggestionCalls;
        await rig.newRepository().suggestionsFor(uid);
        expect(rig.suggestionCalls, before + 1, reason: 'life: $life');
      }
    });

    test(
      'an entry this build wrote is read back with its own lifetime',
      () async {
        // A limit entry 7 h old would be a call if judged by content.
        await _writeEntry(
          rig,
          age: kSuggestionsEmptyTtl + const Duration(hours: 1),
          users: const [],
          life: 'limit',
        );
        expect(await rig.newRepository().suggestionsFor('me'), isEmpty);
        expect(rig.suggestionCalls, 0);
      },
    );

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

  group('drop (a row the server says is gone, W3-22 L-1)', () {
    test('leaves the memory entry and the session at once', () async {
      await rig.repository.suggestionsFor('me');

      rig.repository.drop('me', 'u2');

      expect(_ids(rig.repository.current('me')), ['u1', 'u3', 'u4', 'u5']);
      expect(_ids(await rig.repository.suggestionsFor('me')), [
        'u1',
        'u3',
        'u4',
        'u5',
      ]);
      expect(rig.suggestionCalls, 1);
    });

    test('is stored: a restart does not bring the row back, 0 RPCs', () async {
      await rig.repository.suggestionsFor('me');
      rig.repository.drop('me', 'u2');

      final restarted = rig.newRepository();

      expect(_ids(await restarted.suggestionsFor('me')), [
        'u1',
        'u3',
        'u4',
        'u5',
      ]);
      expect(rig.suggestionCalls, 1);
    });

    test(
      'keeps the age of the entry: the TTL window is not stretched',
      () async {
        await rig.repository.suggestionsFor('me');
        rig.clock = kSuggestionsTtl - const Duration(hours: 4);
        rig.repository.drop('me', 'u2');

        // An hour before the TTL ends the restarted repository still reads
        // the disk.
        rig.clock = kSuggestionsTtl - const Duration(hours: 1);
        final restarted = rig.newRepository();
        expect(
          _ids(await restarted.suggestionsFor('me')),
          isNot(contains('u2')),
        );
        expect(rig.suggestionCalls, 1);

        // An hour after, the entry is stale, though the drop was 3 h before.
        rig.clock = kSuggestionsTtl + const Duration(hours: 1);
        await rig.newRepository().suggestionsFor('me');
        expect(rig.suggestionCalls, 2);
      },
    );

    test('keeps the lifetime too: dropping every row of a full answer does '
        'not turn it into a 6 h empty one', () async {
      await rig.repository.suggestionsFor('me');
      for (var i = 1; i <= 5; i++) {
        rig.repository.drop('me', 'u$i');
      }

      expect(rig.repository.current('me'), isEmpty);
      rig.clock = kSuggestionsEmptyTtl + const Duration(hours: 1);
      expect(await rig.newRepository().suggestionsFor('me'), isEmpty);
      expect((await _storedEntry(rig))['life'], 'full');
      expect(rig.suggestionCalls, 1);
    });

    test('an unknown user or an empty cache changes nothing', () async {
      rig.repository.drop('me', 'u9');
      expect(rig.repository.current('me'), isEmpty);

      await rig.repository.suggestionsFor('me');
      rig.repository.drop('me', 'u9');

      expect(_ids(rig.repository.current('me')), [
        'u1',
        'u2',
        'u3',
        'u4',
        'u5',
      ]);
    });

    test('belongs to one account', () async {
      await rig.repository.suggestionsFor('alice');
      rig.repository.drop('alice', 'u2');

      expect(_ids(await rig.repository.suggestionsFor('bob')), contains('u2'));
    });
  });

  group('followed: the refill, once per session (Amendment 2 B2 rule 4)', () {
    /// The rig's list is [first]; the server's next answer is [next].
    Future<void> load(
      List<graph.UserListItem> first, {
      List<graph.UserListItem>? next,
      String uid = 'me',
    }) async {
      rig.users = first;
      await rig.repository.suggestionsFor(uid);
      if (next != null) rig.users = next;
    }

    /// A confirmed follow from the card: the graph state first, then the hook.
    Future<bool> follow(String userId, {String uid = 'me'}) async {
      await rig.graphRepository.follow(userId: userId, idempotencyKey: 'k');
      return rig.repository.followed(uid, userId);
    }

    test('a follow that leaves rows is just a hide: no refill', () async {
      await load([for (var i = 1; i <= 5; i++) suggestedUser(i)]);

      expect(await follow('u1'), isFalse);

      expect(_ids(rig.repository.current('me')), ['u2', 'u3', 'u4', 'u5']);
      expect(rig.suggestionCalls, 1);
    });

    test('following the last visible row discards the entry and one RPC '
        'brings the new rows', () async {
      await load(
        [suggestedUser(1), suggestedUser(2)],
        next: [suggestedUser(7), suggestedUser(8)],
      );

      expect(await follow('u1'), isFalse);
      expect(await follow('u2'), isTrue);

      // Discarded at once, in memory...
      expect(rig.repository.current('me'), isEmpty);
      // ... and the very next call is the RPC, not the old disk entry.
      expect(_ids(await rig.repository.suggestionsFor('me')), ['u7', 'u8']);
      expect(rig.suggestionCalls, 2);
      expect(rig.requestedMax, [kSuggestionsMax, kSuggestionsMax]);
    });

    test('the refilled answer is stored (a restart reads it, 0 RPCs) with a '
        'full lifetime', () async {
      await load([suggestedUser(1)], next: [suggestedUser(7)]);
      expect(await follow('u1'), isTrue);
      await rig.repository.suggestionsFor('me');

      final restarted = rig.newRepository();

      expect(_ids(await restarted.suggestionsFor('me')), ['u7']);
      expect(rig.suggestionCalls, 2);
      expect((await _storedEntry(rig))['life'], 'full');
    });

    test('the old disk entry is gone before the refill reads: a restart in '
        'between finds nothing to serve', () async {
      await load([suggestedUser(1)], next: [suggestedUser(7)]);
      expect(await follow('u1'), isTrue);

      // The refill has not run yet; a new process reading now must not be
      // served the exhausted entry.
      rig.users = [suggestedUser(8)];
      expect(_ids(await rig.newRepository().suggestionsFor('me')), ['u8']);
      expect(rig.suggestionCalls, 2);
    });

    test('the refill waits for the disk delete: a slow delete does not bring '
        'the exhausted entry back', () async {
      // The group's own rig is open too: a second AppDatabase is on purpose.
      final warn = driftRuntimeOptions.dontWarnAboutMultipleDatabases;
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
      addTearDown(
        () => driftRuntimeOptions.dontWarnAboutMultipleDatabases = warn,
      );
      final slow = SuggestionsRig(
        database: AppDatabase.forTesting(
          NativeDatabase.memory().interceptWith(_SlowDeletes()),
        ),
      );
      addTearDown(slow.database.close);
      slow.users = [suggestedUser(1)];
      await slow.repository.suggestionsFor('me');
      slow.users = [suggestedUser(7)];
      await slow.graphRepository.follow(userId: 'u1', idempotencyKey: 'k');

      expect(slow.repository.followed('me', 'u1'), isTrue);

      expect(_ids(await slow.repository.suggestionsFor('me')), ['u7']);
      expect(slow.suggestionCalls, 2);
    });

    test('a second exhaustion in the session asks nothing, now or on a '
        'later mount', () async {
      await load(
        [suggestedUser(1)],
        next: [suggestedUser(7), suggestedUser(8)],
      );
      expect(await follow('u1'), isTrue);
      expect(_ids(await rig.repository.suggestionsFor('me')), ['u7', 'u8']);
      expect(rig.suggestionCalls, 2);

      expect(await follow('u7'), isFalse);
      expect(await follow('u8'), isFalse);

      expect(rig.repository.current('me'), isEmpty);
      // A surface mounting later reads the kept entry: still no RPC.
      expect(await rig.repository.suggestionsFor('me'), isEmpty);
      expect(await rig.repository.suggestionsFor('me'), isEmpty);
      expect(rig.suggestionCalls, 2);
    });

    test('two confirmations landing together refill once', () async {
      await load(
        [suggestedUser(1), suggestedUser(2)],
        next: [suggestedUser(7)],
      );
      await rig.graphRepository.follow(userId: 'u1', idempotencyKey: 'k1');
      await rig.graphRepository.follow(userId: 'u2', idempotencyKey: 'k2');

      final results = [
        rig.repository.followed('me', 'u1'),
        rig.repository.followed('me', 'u2'),
      ];

      expect(results.where((refill) => refill), hasLength(1));
      await rig.repository.suggestionsFor('me');
      expect(rig.suggestionCalls, 2);
    });

    test('dismissing every row never refills: followed is not involved and '
        'nothing is sent', () async {
      await load([suggestedUser(1), suggestedUser(2)]);

      rig.repository
        ..hide('me', 'u1')
        ..hide('me', 'u2');

      expect(rig.repository.current('me'), isEmpty);
      expect(await rig.repository.suggestionsFor('me'), isEmpty);
      expect(rig.suggestionCalls, 1);
    });

    test('dropping the last row never refills, and the entry keeps its '
        'lifetime', () async {
      await load([suggestedUser(1)]);

      rig.repository.drop('me', 'u1');

      expect(rig.repository.current('me'), isEmpty);
      expect(await rig.repository.suggestionsFor('me'), isEmpty);
      expect(rig.suggestionCalls, 1);
    });

    test('the follow that takes the last row after dismissals still refills '
        '(the follow is what empties the card)', () async {
      await load(
        [for (var i = 1; i <= 3; i++) suggestedUser(i)],
        next: [suggestedUser(7)],
      );
      rig.repository
        ..hide('me', 'u1')
        ..hide('me', 'u2');

      expect(await follow('u3'), isTrue);

      expect(_ids(await rig.repository.suggestionsFor('me')), ['u7']);
      expect(rig.suggestionCalls, 2);
    });

    test('an empty answer is not refilled, and nothing loaded means nothing '
        'to refill', () async {
      expect(rig.repository.followed('me', 'u1'), isFalse);
      rig.users = const [];
      await rig.repository.suggestionsFor('me');

      expect(rig.repository.followed('me', 'u1'), isFalse);
      expect(rig.suggestionCalls, 1);
    });

    test(
      'a follow of an account that is not in the list does not refill',
      () async {
        await load([suggestedUser(1)]);
        rig.repository.hide('me', 'u1');

        expect(rig.repository.followed('me', 'u99'), isFalse);
        expect(rig.suggestionCalls, 1);
      },
    );

    test('a failing refill cannot loop: the failure backoff holds', () async {
      await load([suggestedUser(1)]);
      expect(await follow('u1'), isTrue);
      rig.onSuggestions = () async =>
          throw connect.ConnectException(connect.Code.unavailable, 'offline');

      expect(await rig.repository.suggestionsFor('me'), isEmpty);
      expect(await rig.repository.suggestionsFor('me'), isEmpty);
      rig.clock = kSuggestionsFailureBackoff - const Duration(minutes: 1);
      expect(await rig.repository.suggestionsFor('me'), isEmpty);

      expect(rig.suggestionCalls, 2);
    });

    test('a refill that meets a limit is kept for the limit window', () async {
      await load([suggestedUser(1)]);
      expect(await follow('u1'), isTrue);
      rig.onSuggestions = _limit;

      expect(await rig.repository.suggestionsFor('me'), isEmpty);
      rig.clock = kSuggestionsEmptyTtl + const Duration(hours: 1);
      expect(await rig.newRepository().suggestionsFor('me'), isEmpty);

      expect(rig.suggestionCalls, 2);
    });

    test('is per account: refilling one does not use up another', () async {
      await load([suggestedUser(1)], uid: 'alice', next: [suggestedUser(7)]);
      expect(await follow('u1', uid: 'alice'), isTrue);
      await rig.repository.suggestionsFor('alice');

      rig.users = [suggestedUser(2)];
      await rig.repository.suggestionsFor('bob');
      expect(await follow('u2', uid: 'bob'), isTrue);
    });

    test('the flag is reset with the session: sign-out makes the refill '
        'available again', () async {
      await load([suggestedUser(1)], next: [suggestedUser(7)]);
      expect(await follow('u1'), isTrue);
      await rig.repository.suggestionsFor('me');
      expect(await follow('u7'), isFalse);

      rig.database.sessionEpoch.end();
      await rig.database.clearAll();
      rig.users = [suggestedUser(11)];
      expect(_ids(await rig.repository.suggestionsFor('me')), ['u11']);
      rig.users = [suggestedUser(12)];
      expect(await follow('u11'), isTrue);

      expect(_ids(await rig.repository.suggestionsFor('me')), ['u12']);
    });

    test('clearSession resets the flag too', () async {
      await load([suggestedUser(1)], next: [suggestedUser(7)]);
      expect(await follow('u1'), isTrue);
      await rig.repository.suggestionsFor('me');

      rig.repository.clearSession();
      await rig.database.clearAll();
      rig.users = [suggestedUser(11)];
      await rig.repository.suggestionsFor('me');

      expect(await follow('u11'), isTrue);
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
      rig.onSuggestions = _limit;

      expect(await rig.repository.suggestionsFor('me'), isEmpty);
      expect(await rig.repository.suggestionsFor('me'), isEmpty);
      rig.clock = const Duration(hours: 3);
      expect(await rig.newRepository().suggestionsFor('me'), isEmpty);
      // Past the 6 h of an empty answer, and one minute short of the window.
      rig.clock = kSuggestionsLimitBackoff - const Duration(minutes: 1);
      expect(await rig.newRepository().suggestionsFor('me'), isEmpty);
      expect(rig.suggestionCalls, 1);

      // The next window asks again.
      rig.onSuggestions = null;
      rig.clock = kSuggestionsLimitBackoff + const Duration(minutes: 1);
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
