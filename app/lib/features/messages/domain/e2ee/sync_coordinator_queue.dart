part of 'sync_coordinator.dart';

/// The re-queued passes (gate items 54-61): one timer for the earliest due
/// conversation; queued passes run one at a time, round-robin by
/// conversation (insertion order; a re-queued conversation goes to the
/// end), at background priority.
extension _Queue on SyncCoordinator {
  /// [id]'s next pass is due at [at] (an earlier due time already set is
  /// kept). It moves to the end of the round.
  void _enqueue(String id, DateTime at) {
    final existing = _due.remove(id);
    _due[id] = existing != null && existing.isBefore(at) ? existing : at;
    _arm();
  }

  /// The next wait of [id] in [waits]: [kRequeueFirst], doubling up to
  /// [kWalkBackoffMax].
  Duration _nextWait(Map<String, Duration> waits, String id) {
    final previous = waits[id];
    final next = previous == null
        ? kRequeueFirst
        : (previous * 2 > kWalkBackoffMax ? kWalkBackoffMax : previous * 2);
    waits[id] = next;
    return next;
  }

  void _cancelTimer() {
    final cancel = _timerCancel;
    _timerCancel = null;
    cancel?.call();
  }

  /// One timer for the earliest due pass (none while paused, stopped or
  /// while the queue runs: it arms again when it ends).
  void _arm() {
    _cancelTimer();
    if (_paused || !_active || _queueRunning || _due.isEmpty) return;
    final now = _now();
    var earliest = _due.values.first;
    for (final at in _due.values) {
      if (at.isBefore(earliest)) earliest = at;
    }
    final wait = earliest.difference(now);
    _timerCancel = _schedule(wait.isNegative ? Duration.zero : wait, () {
      _timerCancel = null;
      _track(_runQueue());
    });
  }

  Future<void> _runQueue() async {
    if (_queueRunning || _paused || !_active) return;
    _queueRunning = true;
    final run = _run;
    try {
      while (_live(run) && !_paused) {
        final now = _now();
        String? next;
        for (final e in _due.entries) {
          if (!e.value.isAfter(now)) {
            next = e.key;
            break;
          }
        }
        if (next == null) break;
        _due.remove(next);
        await _queuedPass(next, run);
      }
    } finally {
      _queueRunning = false;
      // Review I1: arm for whatever run is active now, not only this loop's
      // (a start while this loop ran queued passes that need the timer).
      if (_active) _arm();
    }
  }

  /// One queued pass: `pullLive`, then a catch-up when one is owed (gate
  /// item 60) or this is the conversation's first pass of the app-start
  /// sweep (gate item 26), never a catch-up loop.
  Future<void> _queuedPass(String id, int run) async {
    const p = BudgetPriority.background;
    final o = await _pull(id, p);
    if (!_live(run)) return;
    final first = _catchUpOnce.remove(id);
    final owed =
        first ||
        await _value('catchUpOwed', () => _work.catchUpOwed(id), false);
    if (!_live(run)) return;
    CatchUpResult? c;
    if (owed) {
      c = await _catchUp(id, p);
      if (!_live(run)) return;
    }
    await _afterPass(id, o);
    if (c != null) await _afterCatchUp(id, c);
  }

  /// What a pass's answer [o] for [id] asks of the queue.
  Future<void> _afterPass(String id, ReceiveOutcome? o) async {
    if (o == null) return;
    final now = _now();
    switch (o.kind) {
      case ReceiveOutcomeKind.complete:
        _backoff.remove(id);
        if (_chained.remove(id)) {
          // Gate items 59 and 61: the chain is over; one trailing pass is
          // still owed, and the sends the pulls held may go now.
          _enqueue(id, now.add(kOwedTrailingPass));
          await _step(
            'drain',
            () => _work.drain(id, priority: BudgetPriority.background),
          );
        }
      case ReceiveOutcomeKind.more:
        _chained.add(id);
        _enqueue(id, now.add(_nextWait(_backoff, id)));
      case ReceiveOutcomeKind.held:
        _chained.add(id);
        final until = o.until;
        _enqueue(id, until != null && until.isAfter(now) ? until : now);
      case ReceiveOutcomeKind.stopped:
        final has = await _value('hasGroup', () => _work.hasGroup(id), true);
        if (!has) {
          // Gate item 56: no group here. The answer cannot be told from a
          // failure; resume, open, push and a joined welcome drive it.
          _chained.remove(id);
          _backoff.remove(id);
          return;
        }
        _chained.add(id);
        final wait = now.add(_nextWait(_backoff, id));
        final until = o.until;
        _enqueue(id, until != null && until.isAfter(wait) ? until : wait);
    }
  }

  /// What a catch-up's answer [c] for [id] asks: `waitingForWelcome` is an
  /// other reason for a welcome poll (gate item 57); `interrupted` re-queues
  /// one PASS with its own doubling wait (gate items 55 and 58: a pull, never
  /// a catch-up loop).
  Future<void> _afterCatchUp(String id, CatchUpResult? c) async {
    switch (c) {
      case null:
        return;
      case CatchUpResult.interrupted:
        _chained.add(id);
        _enqueue(id, _now().add(_nextWait(_catchUpWaits, id)));
      case CatchUpResult.waitingForWelcome:
        _catchUpWaits.remove(id);
        await _pollWelcomes(BudgetPriority.background, floor: true);
      case CatchUpResult.current:
      case CatchUpResult.stuck:
      case CatchUpResult.notEncrypted:
        _catchUpWaits.remove(id);
    }
  }
}
