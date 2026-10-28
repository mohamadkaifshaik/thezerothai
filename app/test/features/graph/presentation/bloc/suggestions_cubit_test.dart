import 'dart:async';

import 'package:dzeroth/features/graph/data/suggestions_repository.dart'
    show kSuggestionsTtl;
import 'package:dzeroth/features/graph/presentation/bloc/suggestions_cubit.dart';
import 'package:dzeroth/gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import 'package:flutter_test/flutter_test.dart';

import '../../../../support/suggestions_fixtures.dart';

List<String> _ids(SuggestionsCubit cubit) => [
  for (final item in cubit.state.items) item.user.userId,
];

void main() {
  late SuggestionsRig rig;
  late SuggestionsCubit cubit;

  setUp(() {
    rig = SuggestionsRig();
    cubit = SuggestionsCubit(repository: rig.repository);
  });

  tearDown(() async {
    await cubit.close();
    await rig.database.close();
  });

  test('starts empty and shows the rows once loaded', () async {
    expect(cubit.state.items, isEmpty);

    await cubit.ensureLoaded('me');

    expect(_ids(cubit), ['u1', 'u2', 'u3', 'u4', 'u5']);
    expect(rig.suggestionCalls, 1);
  });

  test('two surfaces asking at once make one call', () async {
    await Future.wait([cubit.ensureLoaded('me'), cubit.ensureLoaded('me')]);
    await cubit.ensureLoaded('me');

    expect(rig.suggestionCalls, 1);
    expect(cubit.state.items.length, 5);
  });

  test('hide removes the row from the state and the repository', () async {
    await cubit.ensureLoaded('me');

    cubit.hide('u2');

    expect(_ids(cubit), ['u1', 'u3', 'u4', 'u5']);
    await cubit.ensureLoaded('me');
    expect(_ids(cubit), ['u1', 'u3', 'u4', 'u5']);
    expect(rig.suggestionCalls, 1);
  });

  test(
    'drop removes the row for good: state, repository and disk (L-1)',
    () async {
      await cubit.ensureLoaded('me');

      cubit.drop('u2');

      expect(_ids(cubit), ['u1', 'u3', 'u4', 'u5']);
      // A restart within the TTL reads the disk entry without it.
      final restarted = rig.newRepository();
      expect(
        [
          for (final item in await restarted.suggestionsFor('me'))
            item.user.userId,
        ],
        ['u1', 'u3', 'u4', 'u5'],
      );
      expect(rig.suggestionCalls, 1);
    },
  );

  group('followed (Amendment 2 B2 rule 4)', () {
    /// A confirmed follow: the graph state first, then the cubit.
    Future<void> follow(String userId) async {
      await rig.graphRepository.follow(userId: userId, idempotencyKey: 'k');
      await cubit.followed(userId);
    }

    test('a follow that leaves rows hides the row and asks nothing', () async {
      await cubit.ensureLoaded('me');

      await follow('u2');

      expect(_ids(cubit), ['u1', 'u3', 'u4', 'u5']);
      expect(rig.suggestionCalls, 1);
    });

    test(
      'the follow that takes the last row loads the new list, once',
      () async {
        rig.users = [suggestedUser(1), suggestedUser(2)];
        await cubit.ensureLoaded('me');
        rig.users = [suggestedUser(7), suggestedUser(8), suggestedUser(9)];

        await follow('u1');
        expect(_ids(cubit), ['u2']);
        await follow('u2');

        expect(_ids(cubit), ['u7', 'u8', 'u9']);
        expect(rig.suggestionCalls, 2);

        // The second exhaustion leaves the card empty and sends nothing.
        await follow('u7');
        await follow('u8');
        await follow('u9');
        expect(cubit.state.items, isEmpty);
        await cubit.ensureLoaded('me');
        expect(cubit.state.items, isEmpty);
        expect(rig.suggestionCalls, 2);
      },
    );

    test('the card keeps its state until the new list arrives', () async {
      rig.users = [suggestedUser(1)];
      await cubit.ensureLoaded('me');
      final gate = Completer<graph.ListSuggestedUsersResponse>();
      rig.onSuggestions = () => gate.future;
      await rig.graphRepository.follow(userId: 'u1', idempotencyKey: 'k');

      final pending = cubit.followed('u1');
      await Future<void>.delayed(Duration.zero);
      expect(_ids(cubit), ['u1']);
      gate.complete(
        graph.ListSuggestedUsersResponse(users: [suggestedUser(7)]),
      );
      await pending;

      expect(_ids(cubit), ['u7']);
    });

    test('a surface mounting during the refill shares its one call', () async {
      rig.users = [suggestedUser(1)];
      await cubit.ensureLoaded('me');
      rig.users = [suggestedUser(7)];
      await rig.graphRepository.follow(userId: 'u1', idempotencyKey: 'k');

      await Future.wait([cubit.followed('u1'), cubit.ensureLoaded('me')]);

      expect(_ids(cubit), ['u7']);
      expect(rig.suggestionCalls, 2);
    });

    test('dismissals never refill, even when they empty the card', () async {
      rig.users = [suggestedUser(1), suggestedUser(2)];
      await cubit.ensureLoaded('me');

      cubit
        ..hide('u1')
        ..hide('u2');
      await cubit.ensureLoaded('me');

      expect(cubit.state.items, isEmpty);
      expect(rig.suggestionCalls, 1);
    });

    test('a NOT_FOUND drop never refills', () async {
      rig.users = [suggestedUser(1)];
      await cubit.ensureLoaded('me');

      cubit.drop('u1');
      await cubit.ensureLoaded('me');

      expect(cubit.state.items, isEmpty);
      expect(rig.suggestionCalls, 1);
    });

    test(
      'a refill that fails leaves the card empty and does not throw',
      () async {
        rig.users = [suggestedUser(1)];
        await cubit.ensureLoaded('me');
        rig.onSuggestions = () async => throw StateError('boom');

        await follow('u1');

        expect(cubit.state.items, isEmpty);
        expect(rig.suggestionCalls, 2);
      },
    );

    test('a sign-out during the refill drops its late answer', () async {
      rig.users = [suggestedUser(1)];
      await cubit.ensureLoaded('me');
      final gate = Completer<graph.ListSuggestedUsersResponse>();
      rig.onSuggestions = () => gate.future;
      await rig.graphRepository.follow(userId: 'u1', idempotencyKey: 'k');

      final pending = cubit.followed('u1');
      await Future<void>.delayed(Duration.zero);
      cubit.reset();
      gate.complete(
        graph.ListSuggestedUsersResponse(users: [suggestedUser(7)]),
      );
      await pending;

      expect(cubit.state.items, isEmpty);
    });

    test('before anything is loaded it does nothing', () async {
      await cubit.followed('u1');

      expect(cubit.state.items, isEmpty);
      expect(rig.suggestionCalls, 0);
    });

    test('after close it does not throw', () async {
      await cubit.ensureLoaded('me');
      await cubit.close();

      await expectLater(cubit.followed('u1'), completes);
    });
  });

  test('drop before anything is loaded does nothing', () {
    cubit.drop('u2');

    expect(cubit.state.items, isEmpty);
  });

  test('hide before anything is loaded does nothing', () {
    cubit.hide('u2');

    expect(cubit.state.items, isEmpty);
  });

  test('reset empties the state and forgets the session', () async {
    await cubit.ensureLoaded('me');
    cubit.hide('u2');

    cubit.reset();

    expect(cubit.state.items, isEmpty);
    expect(rig.repository.current('me'), isEmpty);
    await cubit.ensureLoaded('me');
    expect(_ids(cubit), ['u1', 'u2', 'u3', 'u4', 'u5']);
  });

  test('a list for another account replaces the first at once', () async {
    await cubit.ensureLoaded('alice');
    rig.users = [suggestedUser(7)];

    final bob = cubit.ensureLoaded('bob');
    expect(cubit.state.items, isEmpty);
    await bob;

    expect(_ids(cubit), ['u7']);
  });

  test('a late answer for the previous account is ignored', () async {
    final gate = Completer<graph.ListSuggestedUsersResponse>();
    rig.onSuggestions = () => gate.future;
    final late = cubit.ensureLoaded('alice');
    await Future<void>.delayed(Duration.zero);

    rig
      ..onSuggestions = null
      ..users = [suggestedUser(7)];
    await cubit.ensureLoaded('bob');
    gate.complete(graph.ListSuggestedUsersResponse(users: [suggestedUser(1)]));
    await late;

    expect(_ids(cubit), ['u7']);
  });

  test('a failure leaves the list empty and does not throw', () async {
    rig.onSuggestions = () async => throw StateError('boom');

    await cubit.ensureLoaded('me');

    expect(cubit.state.items, isEmpty);
  });

  test('reset after close does not throw', () async {
    await cubit.close();

    expect(cubit.reset, returnsNormally);
  });

  group('expiry timer (security L-1: a mounted card is bounded too)', () {
    late FakeTimers timers;
    late SuggestionsCubit timed;

    setUp(() {
      timers = FakeTimers();
      timed = SuggestionsCubit(repository: rig.repository, timer: timers.make);
    });

    tearDown(() => timed.close());

    List<String> ids() => [
      for (final item in timed.state.items) item.user.userId,
    ];

    test('one timer for the expiry; no call before it', () async {
      await timed.ensureLoaded('me');

      expect(timers.live, hasLength(1));
      expect(timers.live.single.delay, kSuggestionsTtl);
      expect(rig.suggestionCalls, 1);
      expect(ids(), hasLength(5));
    });

    test('the delay is what is left, by the repository clock', () async {
      await timed.ensureLoaded('me');
      rig.clock = const Duration(hours: 10);
      await timed.ensureLoaded('me');

      expect(
        timers.live.single.delay,
        kSuggestionsTtl - const Duration(hours: 10),
      );
    });

    test('at expiry it asks exactly once and shows the new rows', () async {
      await timed.ensureLoaded('me');
      rig.users = [suggestedUser(9)];
      rig.clock = kSuggestionsTtl + const Duration(minutes: 1);

      timers.fire();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(rig.suggestionCalls, 2);
      expect(ids(), ['u9']);
      // Re-armed for the new entry: one live timer, not a poll.
      expect(timers.live, hasLength(1));
      timers.fire();
      await Future<void>.delayed(Duration.zero);
      expect(rig.suggestionCalls, 2);
    });

    test(
      'two surfaces mounting keep one timer and make one call at expiry',
      () async {
        await Future.wait([timed.ensureLoaded('me'), timed.ensureLoaded('me')]);
        expect(timers.live, hasLength(1));

        rig.clock = kSuggestionsTtl + const Duration(minutes: 1);
        timers.fire();
        await Future.wait([timed.ensureLoaded('me'), timed.ensureLoaded('me')]);

        expect(rig.suggestionCalls, 2);
        expect(timers.live, hasLength(1));
      },
    );

    test('sign-out and close cancel it', () async {
      await timed.ensureLoaded('me');
      timed.reset();
      expect(timers.live, isEmpty);

      await timed.ensureLoaded('me');
      expect(timers.live, hasLength(1));
      await timed.close();
      expect(timers.live, isEmpty);
    });

    test('a failing call at expiry clears the rows, arms nothing and is not '
        'retried by the timer', () async {
      await timed.ensureLoaded('me');
      rig.onSuggestions = () async => throw StateError('boom');
      rig.clock = kSuggestionsTtl + const Duration(minutes: 1);

      timers.fire();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(timed.state.items, isEmpty);
      expect(timers.live, isEmpty);
      expect(rig.suggestionCalls, 2);

      // Backed off: asking again (a resume, a mount) sends nothing either.
      await timed.ensureLoaded('me');
      expect(timers.live, isEmpty);
      expect(rig.suggestionCalls, 2);
    });

    test('stale rows are cleared at once on a resume while the call is held '
        'back', () async {
      await timed.ensureLoaded('me');
      final gate = Completer<graph.ListSuggestedUsersResponse>();
      rig.onSuggestions = () => gate.future;
      rig.clock = kSuggestionsTtl + const Duration(minutes: 1);

      final pending = timed.ensureLoaded('me');
      await Future<void>.delayed(Duration.zero);
      expect(timed.state.items, isEmpty);
      gate.complete(
        graph.ListSuggestedUsersResponse(users: [suggestedUser(7)]),
      );
      await pending;

      expect(ids(), ['u7']);
    });

    test('nothing held, nothing armed', () async {
      rig.onSuggestions = () async => throw StateError('boom');

      await timed.ensureLoaded('me');

      expect(timers.made, isEmpty);
    });
  });
}
