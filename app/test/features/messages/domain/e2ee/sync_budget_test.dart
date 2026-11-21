import 'package:dzeroth/features/keys/data/keys_repository.dart';
import 'package:dzeroth/features/messages/domain/e2ee/device_directory.dart';
import 'package:dzeroth/features/messages/domain/e2ee/sync_budget.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

/// Time zero of every test here; the fake clock only moves by `elapsed`.
final DateTime _epoch = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

/// Never called: only its existence matters to the directory.
class _UnusedKeys implements KeysRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('no call expected');
}

class _Rig {
  _Rig(this.async, {int perMinute = 60, int Function()? own}) {
    budget = SyncBudget(
      perMinute: perMinute,
      ownDeviceCount: own ?? () => 1,
      now: now,
    );
  }

  final FakeAsync async;
  late final SyncBudget budget;
  final List<String> served = [];

  /// Moves the injected clock without moving the fake timers (a clock that
  /// was set forward or back).
  Duration skew = Duration.zero;

  DateTime now() => _epoch.add(async.elapsed).add(skew);

  void take(
    String label, [
    BudgetPriority p = BudgetPriority.background,
    Object? lane,
  ]) {
    budget.take(p, lane: lane).then((_) => served.add(label));
  }

  void settle() => async.flushMicrotasks();
}

void main() {
  test('one own device allows 60 calls in a minute and the 61st waits for the '
      'window', () {
    fakeAsync((async) {
      final rig = _Rig(async);
      for (var i = 0; i < 61; i++) {
        // The limit itself: user calls (other calls leave the reserve).
        rig.take('c$i', BudgetPriority.user);
      }
      rig.settle();
      expect(rig.served, hasLength(60));
      async.elapse(const Duration(seconds: 59));
      expect(rig.served, hasLength(60));
      async.elapse(const Duration(seconds: 1));
      expect(rig.served, hasLength(61));
    });
  });

  test('five own devices allow 12', () {
    fakeAsync((async) {
      final rig = _Rig(async, own: () => 5);
      for (var i = 0; i < 13; i++) {
        // The limit itself: user calls (other calls leave the reserve).
        rig.take('c$i', BudgetPriority.user);
      }
      rig.settle();
      expect(rig.served, hasLength(12));
      async.elapse(const Duration(minutes: 1));
      expect(rig.served, hasLength(13));
    });
  });

  test('a waiting user call is served before an earlier background call', () {
    fakeAsync((async) {
      final rig = _Rig(async, perMinute: 1);
      rig.take('first');
      rig.settle();
      rig.take('background');
      rig.take('user', BudgetPriority.user);
      rig.settle();
      expect(rig.served, ['first']);
      async.elapse(const Duration(minutes: 1));
      expect(rig.served, ['first', 'user']);
      async.elapse(const Duration(minutes: 1));
      expect(rig.served, ['first', 'user', 'background']);
    });
  });

  test('pauseUntil holds every call until that time', () {
    fakeAsync((async) {
      final rig = _Rig(async);
      rig.budget.pauseUntil(rig.now().add(const Duration(minutes: 10)));
      rig.take('a');
      rig.take('b', BudgetPriority.user);
      rig.settle();
      expect(rig.served, isEmpty);
      async.elapse(const Duration(minutes: 9, seconds: 59));
      expect(rig.served, isEmpty);
      async.elapse(const Duration(seconds: 1));
      expect(rig.served, ['b', 'a']);
    });
  });

  test('a later pause never shortens an earlier one', () {
    fakeAsync((async) {
      final rig = _Rig(async);
      rig.budget.pauseUntil(rig.now().add(const Duration(minutes: 10)));
      rig.budget.pauseUntil(rig.now().add(const Duration(minutes: 1)));
      rig.take('a');
      rig.settle();
      async.elapse(const Duration(minutes: 9));
      expect(rig.served, isEmpty);
      async.elapse(const Duration(minutes: 1));
      expect(rig.served, ['a']);
    });
  });

  test('a pause further than 24 h away is capped at 24 h', () {
    fakeAsync((async) {
      final rig = _Rig(async);
      rig.budget.pauseUntil(rig.now().add(const Duration(hours: 100)));
      rig.take('a');
      rig.settle();
      async.elapse(const Duration(hours: 23, minutes: 59));
      expect(rig.served, isEmpty);
      async.elapse(const Duration(minutes: 1));
      expect(rig.served, ['a']);
    });
  });

  test('the divisor is 5 before the own list was read', () {
    fakeAsync((async) {
      final directory = DeviceDirectory(
        keys: _UnusedKeys(),
        budget: SyncBudget(
          perMinute: 60,
          ownDeviceCount: () => 1,
          now: () => _epoch,
        ),
        now: () => _epoch,
      );
      expect(directory.ownDeviceCount, 5);
      final rig = _Rig(async, own: () => directory.ownDeviceCount);
      for (var i = 0; i < 13; i++) {
        // The limit itself: user calls (other calls leave the reserve).
        rig.take('c$i', BudgetPriority.user);
      }
      rig.settle();
      expect(rig.served, hasLength(12));
    });
  });

  test('no timer is pending while nothing waits', () {
    fakeAsync((async) {
      final rig = _Rig(async, perMinute: 2);
      expect(async.pendingTimers, isEmpty);
      rig.take('a', BudgetPriority.user);
      rig.take('b', BudgetPriority.user);
      rig.settle();
      expect(async.pendingTimers, isEmpty);
      rig.budget.pauseUntil(rig.now().add(const Duration(minutes: 5)));
      expect(async.pendingTimers, isEmpty);
      rig.take('c');
      rig.settle();
      expect(async.pendingTimers, hasLength(1));
      async.elapse(const Duration(minutes: 5));
      expect(rig.served, ['a', 'b', 'c']);
      expect(async.pendingTimers, isEmpty);
    });
  });

  test('a clock moved back never blocks longer than one window', () {
    fakeAsync((async) {
      final rig = _Rig(async, perMinute: 2);
      rig.skew = const Duration(hours: 2);
      rig.take('a', BudgetPriority.user);
      rig.take('b', BudgetPriority.user);
      rig.settle();
      expect(rig.served, ['a', 'b']);
      // The clock is set back two hours: the stamps are now in the future.
      rig.skew = Duration.zero;
      rig.take('c');
      rig.settle();
      expect(rig.served, ['a', 'b']);
      async.elapse(const Duration(minutes: 1));
      expect(rig.served, ['a', 'b', 'c']);
    });
  });

  test('pauseUntil releases waiting calls with BudgetPaused', () {
    fakeAsync((async) {
      final rig = _Rig(async, perMinute: 1);
      rig.take('a');
      rig.settle();
      final errors = <Object>[];
      rig.budget
          .take(BudgetPriority.background)
          .catchError((Object e) => errors.add(e));
      rig.budget
          .take(BudgetPriority.user)
          .catchError((Object e) => errors.add(e));
      rig.settle();
      expect(errors, isEmpty);
      rig.budget.pauseUntil(rig.now().add(const Duration(hours: 20)));
      rig.settle();
      expect(errors, hasLength(2));
      expect(errors.every((e) => e is BudgetPaused), isTrue);
      expect(errors.first, isNot(isA<StateError>()));
      expect(errors.first.toString(), 'BudgetPaused');
      expect(async.pendingTimers, isEmpty);
      // A call made after the pause still waits for its end.
      rig.take('b');
      rig.settle();
      expect(rig.served, ['a']);
      async.elapse(const Duration(hours: 20));
      expect(rig.served, ['a', 'b']);
    });
  });

  test('pauseUntil with a time that is not in the future releases nobody', () {
    fakeAsync((async) {
      final rig = _Rig(async, perMinute: 1);
      rig.take('a');
      rig.settle();
      final errors = <Object>[];
      rig.budget
          .take(BudgetPriority.background)
          .then((_) => rig.served.add('b'))
          .catchError((Object e) => errors.add(e));
      rig.settle();
      // A RATE_LIMITED answer with a zero retry time, and one in the past.
      rig.budget.pauseUntil(rig.now());
      rig.budget.pauseUntil(rig.now().subtract(const Duration(seconds: 5)));
      rig.settle();
      expect(errors, isEmpty);
      expect(rig.budget.paused, isFalse);
      async.elapse(const Duration(minutes: 1));
      expect(rig.served, ['a', 'b']);
      expect(errors, isEmpty);
    });
  });

  test('a clock moved back never extends a pause past 24 h', () {
    fakeAsync((async) {
      final rig = _Rig(async);
      rig.budget.pauseUntil(rig.now().add(const Duration(hours: 24)));
      // The clock is set back two hours: without a cap the pause would now
      // end 26 h from now.
      rig.skew = const Duration(hours: -2);
      expect(rig.budget.paused, isTrue);
      rig.take('a');
      rig.settle();
      async.elapse(const Duration(hours: 23, minutes: 59));
      expect(rig.served, isEmpty);
      async.elapse(const Duration(minutes: 1));
      expect(rig.served, ['a']);
      expect(rig.budget.paused, isFalse);
    });
  });

  test('reset fails the waiting calls, clears the pause and the window', () {
    fakeAsync((async) {
      final rig = _Rig(async, perMinute: 1);
      rig.take('a');
      rig.settle();
      Object? error;
      rig.budget.take(BudgetPriority.background).catchError((Object e) {
        error = e;
      });
      rig.settle();
      expect(async.pendingTimers, hasLength(1));
      rig.budget.reset();
      rig.settle();
      expect(error, isA<StateError>());
      expect(async.pendingTimers, isEmpty);
      rig.take('b');
      rig.settle();
      expect(rig.served, ['a', 'b']);
    });
  });

  test('tryTake is false when no unit is free and never queues', () {
    fakeAsync((async) {
      final rig = _Rig(async, perMinute: 2);
      expect(rig.budget.tryTake(BudgetPriority.background), isTrue);
      expect(rig.budget.tryTake(BudgetPriority.user), isTrue);
      // The window is full: false, and nothing waits (no timer).
      expect(rig.budget.tryTake(BudgetPriority.user), isFalse);
      expect(async.pendingTimers, isEmpty);
      rig.take('queued');
      rig.settle();
      expect(rig.served, isEmpty);
      async.elapse(const Duration(minutes: 1));
      expect(rig.served, ['queued']);
      // A queued user waiter keeps the free unit: tryTake leaves it.
      rig.take('u1', BudgetPriority.user);
      rig.take('u2', BudgetPriority.user);
      rig.settle();
      expect(rig.served, ['queued', 'u1']);
      expect(rig.budget.tryTake(BudgetPriority.background), isFalse);
      // A paused budget gives nothing.
      async.elapse(const Duration(minutes: 1));
      expect(rig.served, ['queued', 'u1', 'u2']);
      rig.budget.pauseUntil(rig.now().add(const Duration(minutes: 5)));
      async.elapse(const Duration(minutes: 2));
      expect(rig.budget.tryTake(BudgetPriority.user), isFalse);
      async.elapse(const Duration(minutes: 4));
      expect(rig.budget.tryTake(BudgetPriority.user), isTrue);
    });
  });

  group('lanes, live and the reserve (receive-walks design §9)', () {
    test('background lanes are served round-robin', () {
      fakeAsync((async) {
        // A limit of 2: one unit a minute for background work.
        final rig = _Rig(async, perMinute: 2);
        // Lane a asks for four calls before lanes b and c ask for theirs.
        for (final label in ['a1', 'a2', 'a3', 'a4']) {
          rig.take(label, BudgetPriority.background, 'a');
        }
        rig.take('b1', BudgetPriority.background, 'b');
        rig.take('b2', BudgetPriority.background, 'b');
        rig.take('c1', BudgetPriority.background, 'c');
        rig.settle();
        expect(rig.served, ['a1']);
        for (var i = 0; i < 6; i++) {
          async.elapse(const Duration(minutes: 1));
        }
        // One per lane in turn, first in first out within a lane.
        // (Lane a's second call was waiting before the other lanes came.)
        expect(rig.served, ['a1', 'a2', 'b1', 'c1', 'a3', 'b2', 'a4']);
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('a call with no lane shares one lane with the other such calls', () {
      fakeAsync((async) {
        final rig = _Rig(async, perMinute: 2);
        rig.take('n0');
        rig.take('n1');
        rig.take('n2');
        rig.take('a1', BudgetPriority.background, 'a');
        rig.settle();
        for (var i = 0; i < 3; i++) {
          async.elapse(const Duration(minutes: 1));
        }
        expect(rig.served, ['n0', 'n1', 'a1', 'n2']);
      });
    });

    test('one unit a minute is kept for user priority', () {
      fakeAsync((async) {
        final rig = _Rig(async, perMinute: 3);
        rig.take('l0', BudgetPriority.live);
        for (var i = 0; i < 3; i++) {
          rig.take('b$i', BudgetPriority.background, 'lane$i');
        }
        rig.settle();
        // Live and background together take at most limit - 1.
        expect(rig.served, ['l0', 'b0']);
        // The kept unit is there for a user call at once.
        rig.take('u0', BudgetPriority.user);
        rig.settle();
        expect(rig.served, ['l0', 'b0', 'u0']);
        // The limit itself still holds for users.
        rig.take('u1', BudgetPriority.user);
        rig.settle();
        expect(rig.served, hasLength(3));
        async.elapse(const Duration(minutes: 1));
        expect(rig.served, ['l0', 'b0', 'u0', 'u1', 'b1', 'b2']);
        expect(async.pendingTimers, isEmpty);
        // User calls may use the whole limit when nothing else ran.
        async.elapse(const Duration(minutes: 1));
        for (var i = 0; i < 4; i++) {
          rig.take('v$i', BudgetPriority.user);
        }
        rig.settle();
        expect(rig.served.skip(6), ['v0', 'v1', 'v2']);
      });
    });

    test('a limit of one keeps no reserve and serves users first', () {
      fakeAsync((async) {
        final rig = _Rig(async, perMinute: 1);
        rig.take('b0');
        rig.settle();
        // No reserve: the one unit goes to background work.
        expect(rig.served, ['b0']);
        rig.take('b1');
        rig.take('l1', BudgetPriority.live);
        rig.take('u1', BudgetPriority.user);
        rig.settle();
        for (var i = 0; i < 3; i++) {
          async.elapse(const Duration(minutes: 1));
        }
        expect(rig.served, ['b0', 'u1', 'l1', 'b1']);
        expect(rig.budget.tryTake(BudgetPriority.background), isFalse);
        async.elapse(const Duration(minutes: 1));
        expect(rig.budget.tryTake(BudgetPriority.background), isTrue);
      });
    });

    test('live is served before background', () {
      fakeAsync((async) {
        final rig = _Rig(async, perMinute: 2);
        rig.take('b0', BudgetPriority.background, 'a');
        rig.settle();
        rig.take('b1', BudgetPriority.background, 'a');
        rig.take('b2', BudgetPriority.background, 'b');
        rig.take('l1', BudgetPriority.live, 'a');
        rig.take('l2', BudgetPriority.live, 'b');
        rig.settle();
        expect(rig.served, ['b0']);
        for (var i = 0; i < 4; i++) {
          async.elapse(const Duration(minutes: 1));
        }
        expect(rig.served, ['b0', 'l1', 'l2', 'b1', 'b2']);
      });
    });

    test('tryTake leaves the reserve to user priority', () {
      fakeAsync((async) {
        final rig = _Rig(async, perMinute: 3);
        expect(rig.budget.tryTake(BudgetPriority.background), isTrue);
        expect(rig.budget.tryTake(BudgetPriority.live), isTrue);
        // The last unit of the minute is the reserve.
        expect(rig.budget.tryTake(BudgetPriority.background), isFalse);
        expect(rig.budget.tryTake(BudgetPriority.live), isFalse);
        expect(rig.budget.tryTake(BudgetPriority.user), isTrue);
        expect(rig.budget.tryTake(BudgetPriority.user), isFalse);
        expect(async.pendingTimers, isEmpty);
        // A minute later the same again; a user call that used a unit
        // leaves background work what is left under the limit.
        async.elapse(const Duration(minutes: 1));
        expect(rig.budget.tryTake(BudgetPriority.user), isTrue);
        expect(rig.budget.tryTake(BudgetPriority.user), isTrue);
        expect(rig.budget.tryTake(BudgetPriority.background), isTrue);
        expect(rig.budget.tryTake(BudgetPriority.background), isFalse);
      });
    });

    test('a pause and a reset release live and laned waiters too', () {
      fakeAsync((async) {
        final rig = _Rig(async, perMinute: 1);
        rig.take('b0');
        rig.settle();
        final errors = <Object>[];
        for (final (p, lane) in [
          (BudgetPriority.live, 'a'),
          (BudgetPriority.background, 'a'),
          (BudgetPriority.background, 'b'),
        ]) {
          rig.budget
              .take(p, lane: lane)
              .then<void>((_) {}, onError: errors.add);
        }
        rig.budget.pauseUntil(rig.now().add(const Duration(minutes: 5)));
        rig.settle();
        expect(errors, hasLength(3));
        expect(errors, everyElement(isA<BudgetPaused>()));
        async.elapse(const Duration(minutes: 6));
        rig.take('b1');
        rig.settle();
        errors.clear();
        rig.budget
            .take(BudgetPriority.live, lane: 'a')
            .then<void>((_) {}, onError: errors.add);
        rig.budget
            .take(BudgetPriority.background, lane: 'b')
            .then<void>((_) {}, onError: errors.add);
        rig.budget.reset();
        rig.settle();
        expect(errors, hasLength(2));
        expect(errors, everyElement(isA<StateError>()));
        expect(async.pendingTimers, isEmpty);
      });
    });
  });
}
