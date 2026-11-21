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

  /// Work for a conversation the user is not looking at that should not
  /// wait behind the background sweep (a push that says a message came).
  /// Served after every waiting [user] call and before every waiting
  /// [background] call; it shares the background reserve.
  live,

  /// Everything else.
  background,
}

/// A rolling one-minute budget of calls, shared by the callers of one group of
/// RPCs. Uses a timer only while a call waits.
///
/// - **Units.** One unit is one call. The limit is
///   floor(perMinute / max(1, ownDeviceCount())) calls per rolling minute,
///   never less than one.
/// - **Order.** Waiting [BudgetPriority.user] calls are served first, in
///   the order they came; then waiting [BudgetPriority.live] calls, in the
///   order they came; then waiting [BudgetPriority.background] calls,
///   round-robin by lane (the `lane` of [take], the conversation id for the
///   receiver; calls with no lane share one), first in first out within a
///   lane. So one conversation with a long backlog never starves the others.
/// - **The reserve.** At a limit of 2 or more, `live` and `background`
///   calls together take at most limit - 1 units per rolling minute: one
///   unit a minute is always there for a `user` call. At a limit of 1 there
///   is no reserve. [tryTake] respects it too.
/// - **Spent.** [take] waits (its caller holds no lock); [tryTake] answers
///   false at once.
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

  /// When the calls of the last minute were made, oldest first, and
  /// whether each was a [BudgetPriority.user] call (the reserve counts the
  /// others).
  final Queue<({DateTime at, bool user})> _calls = Queue();
  final Queue<Completer<void>> _userWaiting = Queue();
  final Queue<Completer<void>> _liveWaiting = Queue();

  /// Lane -> its waiting background calls, in the order the lanes are
  /// served next (a served lane with calls left goes to the end).
  final LinkedHashMap<Object?, Queue<Completer<void>>> _lanes = LinkedHashMap();
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
  /// [paused] first). [lane] groups background calls for the round-robin
  /// (the conversation id; ignored for the other priorities).
  Future<void> take(BudgetPriority priority, {Object? lane}) {
    final waiter = Completer<void>();
    switch (priority) {
      case BudgetPriority.user:
        _userWaiting.add(waiter);
      case BudgetPriority.live:
        _liveWaiting.add(waiter);
      case BudgetPriority.background:
        _lanes.putIfAbsent(lane, Queue.new).add(waiter);
    }
    _pump();
    return waiter.future;
  }

  /// One unit now, or false: true only when a unit is free at this moment
  /// for [priority] (the reserve is left to [BudgetPriority.user]), the
  /// budget is not paused and no [BudgetPriority.user] call is waiting.
  /// Never queues and never waits (for work under a held lock).
  bool tryTake(BudgetPriority priority) {
    final now = _now();
    if (_pauseEnd(now) != null || _userWaiting.isNotEmpty) return false;
    _prune(now);
    final user = priority == BudgetPriority.user;
    if (!_free(user: user)) return false;
    _calls.add((at: now, user: user));
    return true;
  }

  /// A unit is free now (after [_prune]): the limit is not reached, and for
  /// a call that is not a user's the reserve is left alone.
  bool _free({required bool user}) {
    final limit = _limit;
    if (_calls.length >= limit) return false;
    if (user || limit < 2) return true;
    var others = 0;
    for (final c in _calls) {
      if (!c.user) others++;
    }
    return others < limit - 1;
  }

  /// Every waiting call, removed from its queue.
  List<Completer<void>> _takeWaiting() {
    final waiting = [
      ..._userWaiting,
      ..._liveWaiting,
      for (final lane in _lanes.values) ...lane,
    ];
    _userWaiting.clear();
    _liveWaiting.clear();
    _lanes.clear();
    return waiting;
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
    for (final w in _takeWaiting()) {
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
    for (final w in _takeWaiting()) {
      w.completeError(StateError('The budget was reset.'));
    }
  }

  /// Drops the calls older than the window.
  void _prune(DateTime now) {
    // A clock set back leaves stamps in the future: such a call counts as
    // made now, so the wait is never longer than one window.
    if (_calls.isNotEmpty && _calls.last.at.isAfter(now)) {
      final clamped = [
        for (final c in _calls) c.at.isAfter(now) ? (at: now, user: c.user) : c,
      ];
      _calls
        ..clear()
        ..addAll(clamped);
    }
    while (_calls.isNotEmpty && now.difference(_calls.first.at) >= _window) {
      _calls.removeFirst();
    }
  }

  void _pump() {
    _timer?.cancel();
    _timer = null;
    final now = _now();
    _prune(now);
    while (_userWaiting.isNotEmpty ||
        _liveWaiting.isNotEmpty ||
        _lanes.isNotEmpty) {
      final until = _pauseEnd(now);
      if (until != null) {
        return _wake(until.difference(now));
      }
      final user = _userWaiting.isNotEmpty;
      if (!_free(user: user)) {
        // No unit for the call that is next (the limit, or the reserve):
        // asked again when the oldest call of the window leaves it. A
        // waiter never passes one that is ahead of it.
        return _wake(_calls.first.at.add(_window).difference(now));
      }
      final Completer<void> next;
      if (user) {
        next = _userWaiting.removeFirst();
      } else if (_liveWaiting.isNotEmpty) {
        next = _liveWaiting.removeFirst();
      } else {
        // Round-robin: the first lane's oldest call; the lane goes to the
        // end while it has calls left.
        final lane = _lanes.keys.first;
        final queue = _lanes.remove(lane)!;
        next = queue.removeFirst();
        if (queue.isNotEmpty) _lanes[lane] = queue;
      }
      _calls.add((at: now, user: user));
      next.complete();
    }
  }

  void _wake(Duration after) {
    _timer = Timer(after.isNegative ? Duration.zero : after, _pump);
  }
}
