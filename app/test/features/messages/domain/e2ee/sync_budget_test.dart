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

  void take(String label, [BudgetPriority p = BudgetPriority.background]) {
    budget.take(p).then((_) => served.add(label));
  }

  void settle() => async.flushMicrotasks();
}

void main() {
  test('one own device allows 60 calls in a minute and the 61st waits for the '
      'window', () {
    fakeAsync((async) {
      final rig = _Rig(async);
      for (var i = 0; i < 61; i++) {
        rig.take('c$i');
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
        rig.take('c$i');
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
        rig.take('c$i');
      }
      rig.settle();
      expect(rig.served, hasLength(12));
    });
  });

  test('no timer is pending while nothing waits', () {
    fakeAsync((async) {
      final rig = _Rig(async, perMinute: 2);
      expect(async.pendingTimers, isEmpty);
      rig.take('a');
      rig.take('b');
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
      rig.take('a');
      rig.take('b');
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
}
