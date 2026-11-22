part of 'group_starter.dart';

/// Gate 6 (audit L10): the user's discard of a pending init row
/// ([GroupStarter.discardInit]).
extension _InitDiscard on GroupStarter {
  /// The body of [GroupStarter.discardInit] (its contract is written
  /// there). The decision is made in ONE hold of the conversation lock;
  /// what a settle sets going (the drain) runs after it.
  Future<InitDiscard> _discardInit(String id) async {
    try {
      final outcome = await _locks.run(id, () => _discardInitLocked(id));
      if (outcome == InitDiscard.settled) {
        await _afterNext(id, const _Next(_NextKind.drain), BudgetPriority.user);
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

  Future<InitDiscard> _discardInitLocked(String id) async {
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
      // "Not stored" is read only with no call of this init able to land
      // and the margin past the last one ([_ownInitStored]); anything else
      // is "not decided".
      final own = await _ownInitStored(id, pending, BudgetPriority.user);
      if (own == null) return InitDiscard.notDecided;
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
        // ([GroupStarter._replayRefused]; CANNOT_MESSAGE included).
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
