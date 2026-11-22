part of 'commit_runner.dart';

/// Sending one built commit and settling its pending record (the
/// conversation lock is held): step 2 (the call and what each answer does),
/// catch-up's verdict, the discard, the count of one more call, step 3 (the
/// resume of a record an earlier run or an unknown outcome left) and the one
/// scheduled resume.
extension _CommitSend on CommitRunner {
  /// Step 2: `CommitConversation` with [pending]'s exact bytes, and what
  /// each answer does. [first]: no earlier call of these bytes can have
  /// reached the server (the call follows its build in this same hold);
  /// [tries]: the calls this step may make (the call, and one resend at
  /// once of an unknown outcome). Each call's count was written before it.
  /// Never throws.
  Future<CommitOutcome> _send(
    PipelineOp op,
    String id,
    PendingCommit pending, {
    required String firstKey,
    required bool first,
    required int tries,
    required BudgetPriority priority,
  }) async {
    final at = pending.builtOn;
    final context = _contexts.of(id);
    String? key = firstKey;
    var isFirst = first;
    var left = tries;
    try {
      while (true) {
        if (!op.live) return CommitOutcome.pending;
        // A new 128-bit key per call (K3). The server recognises a repeat
        // by the stored bytes, not by the key.
        final callKey = key ?? hexOf(await randomOf(_engine(), 16));
        key = null;
        // The discard margin counts from this call: until it has passed,
        // the call may still be stored whatever answer the client saw.
        _marginStart[id] = _MarginStart(pending.commit, _now());
        final MlsPair answer;
        try {
          answer = await _messaging.commitConversation(
            idempotencyKey: callKey,
            conversationId: id,
            builtOn: at,
            commit: pending.commit,
            welcome: pending.welcome,
            welcomeDeviceIds: pending.welcomeDeviceIds,
          );
        } on StaleEpochException {
          // Another commit holds the pair, or this one does (an earlier
          // call was stored): catch-up tells which.
          return await _afterCatchUp(op, id, pending, priority);
        } on AppException catch (e) {
          if (sendOutcomeUnknown(e)) {
            isFirst = false;
            left--;
            final named = retryAfterOf(e);
            if (named != null) {
              // The server named a time: nothing is sent before it, and
              // one resume is scheduled for it. Never longer than
              // [kCommitRetryWaitMax]: this record holds every send here.
              final wait = named > kCommitRetryWaitMax
                  ? kCommitRetryWaitMax
                  : named;
              _notBefore[id] = _now().add(wait);
              if (left > 0) _scheduleResume(id, wait, priority);
              return CommitOutcome.pending;
            }
            // The server named none (review I2): a later resume sends
            // nothing before the margin's end. Without this every resume
            // would be one more counted call while the commit RPC times
            // out, and the day's cap would be spent in a row.
            _notBefore[id] = _now().add(kRequestInFlightMargin);
            // The identical bytes once more now (this step's one resend),
            // as one more counted call.
            if (left > 0 && await _countCall(op, id, pending.kind)) continue;
            return CommitOutcome.pending;
          }
          // A refusal. Remembered whatever becomes of the commit.
          if (e is CannotMessageException) context.canReply = false;
          if (e is RateLimitedException) lastRateLimit = e;
          // VALIDATION idempotency_key says the server holds something
          // under the key: never treated as a first call's refusal.
          if (isFirst && e is! IdempotencyKeyReusedException) {
            return await _discard(op, id, pending)
                ? CommitOutcome.refused
                : CommitOutcome.pending;
          }
          // An earlier call's outcome is unknown: never a discard before
          // catch-up showed that no commit is stored at the pair.
          return await _afterCatchUp(op, id, pending, priority, refused: true);
        }
        if (answer == at.next) {
          // The epoch is closed now: its messages are completed, then the
          // commit is confirmed and its transaction written (the adds with
          // the sides this run remembers for them).
          final confirmed = await _crypto.confirmOwnCommitLocked(
            id,
            at,
            priority: priority,
          );
          if (!confirmed) {
            // The server holds the commit; the next catch-up confirms it
            // by its bytes.
            return CommitOutcome.pending;
          }
          _settledNow(id);
          return CommitOutcome.applied;
        }
        // A pair later than the next one (or any other answer): as
        // STALE_EPOCH.
        return await _afterCatchUp(op, id, pending, priority);
      }
    } on BadRandom {
      _reportBug('commit.random');
      return CommitOutcome.pending;
    } on Object catch (e, s) {
      // The pending record stays; the next resume settles it.
      _reportIfBug(e, s, 'commit.send');
      return CommitOutcome.pending;
    }
  }

  /// Catch-up, then what became of [pending]: `applied` when this run
  /// confirmed it by its bytes, `superseded` when the group moved on without
  /// it. Still held: `pending`, unless [refused] (the server refused a call
  /// that was not the first) and the catch-up ended at the server's pair,
  /// which shows no commit is stored at the built-on pair: then it is
  /// discarded (`refused`) once the discard margin has passed
  /// ([_discardProven]). The refusal is remembered, so the resume that
  /// follows the margin drops the commit instead of sending it again.
  Future<CommitOutcome> _afterCatchUp(
    PipelineOp op,
    String id,
    PendingCommit pending,
    BudgetPriority priority, {
    bool refused = false,
  }) async {
    final result = await _crypto.catchUpLocked(id, priority: priority);
    if (!op.live) return CommitOutcome.pending;
    final settled = await _settled(op.vault, id, pending);
    if (settled != null) {
      _settledNow(id);
      return settled;
    }
    if (refused) {
      _refusedResend[id] = pending.commit;
      if (result == CatchUpResult.current) {
        return _discardProven(
          op,
          id,
          pending,
          priority,
          dropped: CommitOutcome.refused,
        );
      }
    }
    return CommitOutcome.pending;
  }

  /// A discard that rests on the catch-up proof (the caller's catch-up just
  /// ended at the server's pair and the group still holds [pending], so no
  /// commit is stored at its built-on pair NOW). Review I1: a call that got
  /// no answer can still be stored after that listing, so nothing is
  /// dropped before [kRequestInFlightMargin] has passed since the last call
  /// of these bytes in this run, or since this run first saw the record
  /// ([CommitRunner._marginStart]). Until then: `pending`, and one resume
  /// is scheduled for the margin's end (it runs catch-up again, so the
  /// proof is fresh when the discard is made). After it: the discard, and
  /// [dropped].
  Future<CommitOutcome> _discardProven(
    PipelineOp op,
    String id,
    PendingCommit pending,
    BudgetPriority priority, {
    required CommitOutcome dropped,
  }) async {
    final left = _marginLeft(id, pending);
    if (left != null) {
      _scheduleResume(id, left, priority);
      return CommitOutcome.pending;
    }
    return await _discard(op, id, pending) ? dropped : CommitOutcome.pending;
  }

  /// This run meets [pending]: the margin of a record it has no call time
  /// for counts from now (a call of an earlier run was made before now).
  void _noteSeen(String id, PendingCommit pending) {
    final start = _marginStart[id];
    if (start == null || !_same(start.commit, pending.commit)) {
      _marginStart[id] = _MarginStart(pending.commit, _now());
    }
  }

  /// What is left of [pending]'s discard margin; null once it has passed.
  Duration? _marginLeft(String id, PendingCommit pending) {
    _noteSeen(id, pending);
    final end = _marginStart[id]!.at.add(kRequestInFlightMargin);
    final now = _now();
    return now.isBefore(end) ? end.difference(now) : null;
  }

  /// Null while the group still holds [pending] at its built-on pair.
  /// Otherwise how it ended: this run confirmed it, or it is gone.
  Future<CommitOutcome?> _settled(
    SecureVault vault,
    String id,
    PendingCommit pending,
  ) async {
    final at = pending.builtOn;
    if (await _holds(vault, id, pending) != null) return null;
    return _crypto.ownCommitConfirmedAt(id) == at
        ? CommitOutcome.applied
        : CommitOutcome.superseded;
  }

  /// The group that still holds [pending] at its built-on pair, or null.
  Future<GroupRecord?> _holds(
    SecureVault vault,
    String id,
    PendingCommit pending,
  ) async {
    final at = pending.builtOn;
    final group = await vault.group(id, at.generation);
    final held = group?.pending;
    if (group == null ||
        group.provisional ||
        group.epoch != at.epoch ||
        held == null ||
        !_same(held.commit, pending.commit)) {
      return null;
    }
    return group;
  }

  /// The commit is settled (applied or superseded): the pair moved, so a
  /// live pull of the new pair is owed before the next send or commit, and
  /// no retry time is kept.
  void _settledNow(String id) {
    _forgetRecord(id);
    _contexts.of(id).syncedSinceStart = false;
  }

  /// The pending record of [id] is gone (settled or discarded): what this
  /// run remembered about it goes too.
  void _forgetRecord(String id) {
    _notBefore.remove(id);
    _marginStart.remove(id);
    _refusedResend.remove(id);
    _crypto.forgetOwnAdds(id);
  }

  /// Drops [pending] in ONE `runWrite` body: the group read fresh, the
  /// engine's discard, and the group state without the pending record.
  /// Only ever called when no call of these bytes can have been stored: the
  /// first call was refused (no other call was made), or catch-up ended at
  /// the server's pair with the record still held and the discard margin
  /// has passed ([_discardProven]). False when nothing was written.
  Future<bool> _discard(PipelineOp op, String id, PendingCommit pending) async {
    try {
      final done = await _session.runWrite((v) async {
        op.check(v);
        final group = await _holds(v, id, pending);
        final deviceState = await v.deviceState();
        if (group == null || deviceState == null) return false;
        final next = await _engine().discardCommit(deviceState, group.state);
        await v.transaction(
          (tx) => tx.putGroup(
            GroupRecord(
              conversationId: id,
              generation: group.generation,
              epoch: group.epoch,
              state: next,
            ),
          ),
        );
        return true;
      });
      if (done) {
        _forgetRecord(id);
        _onChanged(id);
      }
      return done;
    } on Object catch (e, s) {
      _reportIfBug(e, s, 'commit.discard');
      return false;
    }
  }

  /// One more commit call is about to be made: counted first, in its own
  /// transaction. False (make no call) at the day's cap for [kind], or when
  /// nothing could be written.
  Future<bool> _countCall(PipelineOp op, String id, PendingKind kind) async {
    try {
      return await _session.runWrite((v) async {
        op.check(v);
        final sync =
            (await v.conversation(id))?.sync ?? const ConversationSync();
        final calls = _callsToday(sync);
        if (calls >= _cap(kind)) return false;
        await v.transaction(
          (tx) => tx.putConversationSync(
            id,
            sync.copyWith(
              commitCallsDay: istDay(_now()),
              commitCallsToday: calls + 1,
            ),
          ),
        );
        return true;
      });
    } on Object catch (e, s) {
      _reportIfBug(e, s, 'commit.count');
      return false;
    }
  }

  // -------------------------------------------------------------------------
  // Step 3: a pending record of an earlier run

  Future<CommitOutcome> _resumeLocked(
    String id,
    BudgetPriority priority,
  ) async {
    try {
      final op = await _op();
      if (op == null) return CommitOutcome.notAllowed;
      final group = await _currentGroup(op.vault, id);
      final pending = group?.pending;
      // An init or a reset is not this runner's (Tasks 8 and 10).
      if (pending == null ||
          (pending.kind != PendingKind.change &&
              pending.kind != PendingKind.selfUpdate)) {
        return CommitOutcome.notAllowed;
      }
      // The first sight of a record an earlier run left starts its margin.
      _noteSeen(id, pending);
      // A device removed elsewhere sends and decides nothing.
      if (_removedElsewhere()) return CommitOutcome.pending;
      final result = await _crypto.catchUpLocked(id, priority: priority);
      if (!op.live) return CommitOutcome.pending;
      final settled = await _settled(op.vault, id, pending);
      if (settled != null) {
        _settledNow(id);
        return settled;
      }
      // Only at the server's pair is "no commit is stored at the built-on
      // pair" known; anything else waits for the next resume.
      if (result != CatchUpResult.current) return CommitOutcome.pending;
      // The server refused a resend of these bytes: they are not sent
      // again; they are dropped once the margin has passed.
      final refusedBytes = _refusedResend[id];
      if (refusedBytes != null && _same(refusedBytes, pending.commit)) {
        return await _discardProven(
          op,
          id,
          pending,
          priority,
          dropped: CommitOutcome.refused,
        );
      }
      final notBefore = _notBefore[id];
      if (notBefore != null && _now().isBefore(notBefore)) {
        return CommitOutcome.pending;
      }
      if (!_usable(id)) return CommitOutcome.pending;
      // May these bytes still be sent? When not (and never again today),
      // they are dropped rather than left to hold the conversation's sends:
      // the catch-up above showed the server does not hold them, and the
      // margin makes sure no earlier call can still be stored.
      if (!await _maySendAgain(op.vault, id, pending) ||
          !await _countCall(op, id, pending.kind)) {
        return await _discardProven(
          op,
          id,
          pending,
          priority,
          dropped: CommitOutcome.notAllowed,
        );
      }
      return await _send(
        op,
        id,
        pending,
        firstKey: hexOf(await randomOf(_engine(), 16)),
        first: false,
        tries: 1,
        priority: priority,
      );
    } on BadRandom {
      _reportBug('commit.random');
      return CommitOutcome.pending;
    } on Object catch (e, s) {
      _reportIfBug(e, s, 'commit.resume');
      return CommitOutcome.pending;
    }
  }

  /// The stored and remembered conditions of [mayCommit] that can have
  /// changed since [pending] was built (the daily cap is [_countCall]'s).
  Future<bool> _maySendAgain(
    SecureVault vault,
    String id,
    PendingCommit pending,
  ) async {
    final sync =
        (await vault.conversation(id))?.sync ?? const ConversationSync();
    if (!sync.requestAccepted) return false;
    if (!_contexts.of(id).canReply) return false;
    // A commit with a welcome adds: the flag must still be on (R1).
    if (pending.welcome != null && !_session.mayStart) return false;
    if (pending.kind == PendingKind.change &&
        await _ledger.undone(id) >= kAntiFlapUndosPerDay) {
      return false;
    }
    return true;
  }

  /// One resume of [id] after [wait]: at the server's retry time, or at the
  /// end of the discard margin (at most one scheduled per conversation).
  /// Scheduled in the root zone: the callback must not read as holding the
  /// conversation lock this was called under.
  void _scheduleResume(String id, Duration wait, BudgetPriority priority) {
    if (!_resumeScheduled.add(id)) return;
    Zone.root.run(
      () => _schedule(wait, () {
        _resumeScheduled.remove(id);
        unawaited(resumePending(id, priority: priority));
      }),
    );
  }
}
