import 'dart:async';
import 'dart:collection';

/// Calls a minute for `ListConversationCommits`, `ListEpochMessages`,
/// `ListWelcomes` and `AckWelcomes`, divided by the number of own devices (R8).
const int kSyncCallsPerMinute = 60;

/// Calls a minute for the receiver's probe (`ListMessages`, which the server
/// limits with the other list reads), divided by the number of own devices
/// (receive-walks design §1, §9: the read budget).
const int kMlsReadCallsPerMinute = 10;

/// Calls a minute for `ListMyKeyDevices` and `GetKeyDevices`, divided by the
/// number of own devices (R8, KP).
const int kDirectoryCallsPerMinute = 60;

/// Security read L1 (owner-approved): any server-chosen retry or pause time is
/// capped at now + this.
const Duration kMaxServerRetryWait = Duration(hours: 24);

/// A call waiting in a [SyncBudget] was released because [SyncBudget.pauseUntil]
/// paused the budget: it is not made. Not a [StateError] (that is a reset).
/// Carries nothing; prints only its name.
class BudgetPaused implements Exception {
  const BudgetPaused();

  @override
  String toString() => 'BudgetPaused';
}

/// Who is waiting for a unit of a [SyncBudget].
enum BudgetPriority {
  /// The open conversation and sends.
  user,

  /// Everything else.
  background,
}

/// A rolling one-minute budget of calls, shared by the callers of one group of
/// RPCs. Waiting [BudgetPriority.user] calls are served before waiting
/// [BudgetPriority.background] calls. Uses a timer only while a call waits.
class SyncBudget {
  SyncBudget({
    required int perMinute,
    required int Function() ownDeviceCount,
    required DateTime Function() now,
  }) : _perMinute = perMinute,
       _ownDeviceCount = ownDeviceCount,
       _now = now;

  static const Duration _window = Duration(minutes: 1);

  final int _perMinute;
  final int Function() _ownDeviceCount;
  final DateTime Function() _now;

  /// When the calls of the last minute were made, oldest first.
  final Queue<DateTime> _calls = Queue();
  final Queue<Completer<void>> _userWaiting = Queue();
  final Queue<Completer<void>> _backgroundWaiting = Queue();
  DateTime? _pausedUntil;
  Timer? _timer;

  int get _limit {
    final share = _perMinute ~/ (_ownDeviceCount() < 1 ? 1 : _ownDeviceCount());
    return share < 1 ? 1 : share;
  }

  /// True while a [pauseUntil] time has not passed.
  bool get paused => _pauseEnd(_now()) != null;

  /// The end of the pause as of [now], or null when there is none (cleared
  /// once passed). Clamped to [now] + [kMaxServerRetryWait] whenever it is
  /// read, so a clock set back never stretches a pause past 24 h.
  DateTime? _pauseEnd(DateTime now) {
    final until = _pausedUntil;
    if (until == null) return null;
    if (!now.isBefore(until)) {
      _pausedUntil = null;
      return null;
    }
    final cap = now.add(kMaxServerRetryWait);
    if (until.isAfter(cap)) return _pausedUntil = cap;
    return until;
  }

  /// Completes when one call may be made: at most
  /// floor(perMinute / max(1, ownDeviceCount())) per rolling minute (never
  /// less than one). Fails with [StateError] when [reset] ran while waiting,
  /// and with [BudgetPaused] when [pauseUntil] ran while waiting. A call
  /// taken while already paused waits for the pause to end (callers check
  /// [paused] first).
  Future<void> take(BudgetPriority priority) {
    final waiter = Completer<void>();
    (priority == BudgetPriority.user ? _userWaiting : _backgroundWaiting).add(
      waiter,
    );
    _pump();
    return waiter.future;
  }

  /// One unit now, or false: true only when a unit is free at this moment,
  /// the budget is not paused and no [BudgetPriority.user] call is waiting.
  /// Never queues and never waits (for work under a held lock).
  bool tryTake(BudgetPriority priority) {
    final now = _now();
    if (_pauseEnd(now) != null || _userWaiting.isNotEmpty) return false;
    _prune(now);
    if (_calls.length >= _limit) return false;
    _calls.add(now);
    return true;
  }

  /// RATE_LIMITED: no call before [until], capped at now +
  /// [kMaxServerRetryWait]. A later pause never shortens an earlier one.
  /// When the budget ends up paused (the capped time is after now), every
  /// call waiting at that moment is released with [BudgetPaused] (it would
  /// otherwise wait the whole pause, up to 24 h, holding its lock); a time
  /// that is not in the future releases nobody.
  void pauseUntil(DateTime until) {
    final now = _now();
    final cap = now.add(kMaxServerRetryWait);
    final capped = until.isAfter(cap) ? cap : until;
    final current = _pausedUntil;
    if (current == null || capped.isAfter(current)) _pausedUntil = capped;
    // A time that is not in the future (a zero retry time) pauses nothing:
    // nobody is released for it.
    if (_pauseEnd(now) == null) {
      _pump();
      return;
    }
    final waiting = [..._userWaiting, ..._backgroundWaiting];
    _userWaiting.clear();
    _backgroundWaiting.clear();
    for (final w in waiting) {
      w.completeError(const BudgetPaused());
    }
    _pump();
  }

  /// Sign-out or a new vault: forgets the calls made and the pause, and fails
  /// every waiting call with [StateError] (it belonged to the old session).
  void reset() {
    _timer?.cancel();
    _timer = null;
    _calls.clear();
    _pausedUntil = null;
    final waiting = [..._userWaiting, ..._backgroundWaiting];
    _userWaiting.clear();
    _backgroundWaiting.clear();
    for (final w in waiting) {
      w.completeError(StateError('The budget was reset.'));
    }
  }

  /// Drops the calls older than the window.
  void _prune(DateTime now) {
    // A clock set back leaves stamps in the future: such a call counts as
    // made now, so the wait is never longer than one window.
    if (_calls.isNotEmpty && _calls.last.isAfter(now)) {
      final clamped = [for (final c in _calls) c.isAfter(now) ? now : c];
      _calls
        ..clear()
        ..addAll(clamped);
    }
    while (_calls.isNotEmpty && now.difference(_calls.first) >= _window) {
      _calls.removeFirst();
    }
  }

  void _pump() {
    _timer?.cancel();
    _timer = null;
    final now = _now();
    _prune(now);
    while (_userWaiting.isNotEmpty || _backgroundWaiting.isNotEmpty) {
      final until = _pauseEnd(now);
      if (until != null) {
        return _wake(until.difference(now));
      }
      if (_calls.length >= _limit) {
        return _wake(_calls.first.add(_window).difference(now));
      }
      final next = _userWaiting.isNotEmpty
          ? _userWaiting.removeFirst()
          : _backgroundWaiting.removeFirst();
      _calls.add(now);
      next.complete();
    }
  }

  void _wake(Duration after) {
    _timer = Timer(after.isNegative ? Duration.zero : after, _pump);
  }
}
