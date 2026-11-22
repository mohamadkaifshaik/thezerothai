part of 'group_starter.dart';

/// Gate 6 (audit L10): the user's discard of a pending init row
/// ([GroupStarter.discardInit]).
extension _InitDiscard on GroupStarter {
  /// The body of [GroupStarter.discardInit] (its contract is written
  /// there). The decision is made in ONE hold of the conversation lock;
  /// what a settle sets going (the drain) runs after it.
  Future<InitDiscard> _discardInit(String id) async {
    try {
      var join = false;
      final outcome = await _locks.run(
        id,
        () => _discardInitLocked(id, onJoin: () => join = true),
      );
      if (outcome == InitDiscard.settled || join) {
        await _afterNext(
          id,
          _Next(join ? _NextKind.join : _NextKind.drain),
          BudgetPriority.user,
        );
      }
      return outcome;
    } on _BadRandom {
      _reportOnce('start.random');
      return InitDiscard.notDecided;
    } on Object catch (e, s) {
      _reportIfBug(e, s, 'start.discardInit');
      return InitDiscard.notDecided;
    }
  }

  /// [onJoin] is called when the group was discarded for another device's
  /// commit (fix round 2, ruling 7): the caller then runs the join path
  /// once the lock is released.
  Future<InitDiscard> _discardInitLocked(
    String id, {
    required void Function() onJoin,
  }) async {
    final op = await _op();
    if (op == null) return InitDiscard.notDecided;
    GroupRecord? group;
    for (final g in await op.vault.groups(id)) {
      if (g.provisional) group = g;
    }
    final pending = group?.pending;
    if (group == null || pending == null || pending.kind != PendingKind.init) {
      return InitDiscard.none;
    }
    final row = await _initRow(op.vault, id, group.generation);
    if (row == null) return InitDiscard.none;

    // Audit L10 (InitSettle.replay). Decision: marks already at or past the
    // init mean it can never be settled ([ConversationCrypto
    // .settleOwnInitLocked] answers `replay` for good), so the server is
    // not asked: the discard is the way out. Why: whatever the server
    // holds, this device moved past that pair without this group, and
    // keeping it held every row of the conversation for good.
    final marks = (await op.vault.conversation(id))?.afterPair;
    final passed = !MlsPair.above(pending.builtOn, marks);
    if (!passed) {
      // Pre-flag-on fix round 2, ruling 3 (code review m-A, audit L-a).
      // Decision: a row with stored attempts of which this run sent no
      // request is held until [kInitResendMargin] after this run began
      // (the construction, or [reset]); nothing is asked meanwhile. Why:
      // the margin rules of [_ownInitStored] are memory of this run, so a
      // request the earlier process made just before it ended is not
      // counted, and it may still be stored after a "not stored" read; the
      // discard would then delete a group the server holds (no welcome
      // exists for its creator). A clock moved back holds it until the
      // clock catches up (the fail-safe direction). Not for the marks
      // already past the init below: that group can never settle,
      // whatever lands.
      //
      // Fix round 3, ruling 1 (audit L-2): a row this run did send is held
      // the same way when its first request in this run found the earlier
      // run's attempts ([GroupStarter._earlierRunRows]). Why: sending it
      // again does not stop the earlier run's request from landing.
      final key = row.idempotencyKey;
      final earlierRun =
          !_sentThisRun.contains(key) || _earlierRunRows.contains(key);
      if (row.attempts > 0 &&
          earlierRun &&
          _now().isBefore(_runStartedAt.add(kInitResendMargin))) {
        return InitDiscard.held;
      }
      // "Not stored" is read only with no call of this init able to land
      // and the margin past the last one ([_ownInitStored]); anything else
      // is "not decided".
      final record = await _ownInitRecord(id, pending, BudgetPriority.user);
      final own = record.own;
      if (own == null) return InitDiscard.notDecided;
      if (record.otherFirst) {
        // Pre-flag-on fix round 2, ruling 7 (code review m-E). Decision:
        // another device's commit is first, so the group goes WITHOUT
        // failing the row, and the winner's welcome is joined after the
        // lock (the resume's STALE_EPOCH path); the row then waits, and
        // the sender encrypts it again under a new key in the joined group.
        // Why: this init can never be stored (the server takes one commit
        // at a pair); failing the row made the user retry a start that the
        // server answers STALE_EPOCH, when the way in is the welcome that
        // is already there. The answer is `discarded`: the group is gone.
        if (!await _crypto.discardProvisionalLocked(id, group.generation)) {
          return InitDiscard.notDecided;
        }
        _forget(row.localId);
        // Fix round 3, ruling 6: as at the other discard below, so a later
        // failure of the row is never shown with an earlier typed error.
        _sender.forgetRefusal(row.localId);
        _onChanged(id);
        onJoin();
        return InitDiscard.discarded;
      }
      if (own) {
        // The server holds it as this device's. Decision: held while an
        // answer may still come: the group is younger than 24 h (the
        // starter still replays it), or a call of it may still land.
        if (_ageOf(group) < kProvisionalExpiry || _initMayStillLand(id)) {
          return InitDiscard.held;
        }
        // 24 h with no answer: the page is the last answer asked for. It
        // holds the message: settled with it, never discarded.
        final found = await _storedAnyway(id, row);
        final delivered = found.delivered;
        if (delivered != null) {
          final next = await _settle(
            id,
            group.generation,
            row,
            delivered,
            BudgetPriority.user,
          );
          return next.kind == _NextKind.drain
              ? InitDiscard.settled
              : InitDiscard.notDecided;
        }
        if (found.unknown) return InitDiscard.notDecided;
        // Pre-flag-on review I-1. Decision: discarded only when this run's
        // last request of the row was its replay and the server refused it
        // with a lasting answer ([GroupStarter._replayRefused]; fix round
        // 2, ruling 2: STALE_EPOCH for this conversation, CANNOT_MESSAGE,
        // FEATURE_DISABLED, NOT_FOUND).
        // Otherwise held. Why: the group's age and a page without the
        // message do not show that no answer will come. A replay gate may
        // have been closed all along (the flag off, removed elsewhere, a
        // thread that cannot be answered, an unattributed pin, the
        // server's retry time), so no replay was refused; meanwhile the
        // peer may write in the group the server holds as ours, and a
        // discard loses that conversation for good (the creator has no
        // welcome for it). A thread that cannot be answered for another
        // reason is no refusal of the replay either. The next resume
        // replays it once its gates open, and its refusal is the evidence.
        if (!_replayRefused.contains(row.localId)) return InitDiscard.held;
        // Decision: the user's discard of an init the server holds as
        // this device's, unanswered for 24 h, whose replay was refused.
        // Cost, accepted for the gate: the creator has no welcome for that
        // group, so a new start for the conversation is answered
        // STALE_EPOCH and the row waits; the user chose to stop waiting
        // for the old one.
      }
    }
    final discarded = await _crypto.discardProvisionalLocked(
      id,
      group.generation,
      lastError: kStartErrorInitDiscarded,
    );
    if (!discarded) return InitDiscard.notDecided;
    _forget(row.localId);
    _sender.forgetRefusal(row.localId);
    _onChanged(id);
    return InitDiscard.discarded;
  }
}
