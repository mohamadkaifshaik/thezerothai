part of 'group_starter.dart';

/// Task 10: what decides a reset once it was sent (its record at
/// (g + 1, 0)), its settle and drop, its resume and expiry, and the stuck
/// member's automatic repair. Moved from `group_starter_reset.dart`
/// unchanged (Task 10's file-size rule).
extension _ResetResume on GroupStarter {
  /// What the server holds at the reset's record pair (g + 1, 0), read from
  /// the stored after-pair on, and decided under the lock held:
  ///
  /// - this device's bytes: accepted, remembered as held (audit M1) and
  ///   settled ([_resetSettleLocked]);
  /// - another record (another reset or commit won), or the server already
  ///   past g + 1 without it: the provisional group goes and this device
  ///   joins from the winner's welcome. Amendment 1: only while no call of
  ///   the reset's bytes that outlived the client's wait still runs (a
  ///   reset can then no longer reach the server; one that reached it names
  ///   generation g, which is no longer current, so it cannot be stored).
  ///   While one runs nothing is decided; its end schedules the resume that
  ///   decides ([CommitCallTracker.trackAbandoned]);
  /// - nothing at the pair while the server is still at g: NOT stored now.
  ///   Without a refusal ([refusal]) or the expiry ([expire]) nothing is
  ///   decided and nothing is scheduled here (the caller resends, or the
  ///   next trigger lists again). With one, the group is dropped only when
  ///   no such call runs (else: nothing decided; that call's end schedules
  ///   the resume) and the margin had passed when the listing STARTED (Task
  ///   8 B / Task 9 N). Inside the margin, nothing is decided and the
  ///   answer carries the wait to the margin's end as `resendAfter`: the
  ///   caller's `_afterNext` schedules one resume then (review m-4: only
  ///   in this case is one scheduled);
  /// - an answer that does not say, or a listing not asked: nothing is
  ///   decided and nothing is scheduled.
  Future<_Next> _resetDecideLocked(
    _Op op,
    String id,
    GroupRecord group,
    PendingCommit pending,
    BudgetPriority priority, {
    AppException? refusal,
    bool expire = false,
  }) async {
    final provedAt = _now();
    final record = await _resetRecord(op.vault, id, pending, priority);
    return _resetDecideOnLocked(
      id,
      group,
      pending,
      priority,
      record,
      provedAt,
      refusal: refusal,
      expire: expire,
    );
  }

  /// [_resetDecideLocked]'s decision on a [record] whose listing started at
  /// [provedAt].
  Future<_Next> _resetDecideOnLocked(
    String id,
    GroupRecord group,
    PendingCommit pending,
    BudgetPriority priority,
    _Record record,
    DateTime provedAt, {
    AppException? refusal,
    bool expire = false,
  }) async {
    const none = _Next(_NextKind.none);
    switch (record) {
      case _Record.ours:
        // Audit M1: from now on no call of these bytes is made again.
        _resetHeld[id] = pending.commit;
        return _resetSettleLocked(id, group, priority);
      case _Record.other:
        if (_resetCalls.callStillOut(id, pending.commit)) return none;
        return _resetDropLocked(id, group, join: true);
      case _Record.notStored:
        if (refusal == null && !expire) return none;
        if (_resetCalls.callStillOut(id, pending.commit)) return none;
        final left = _resetCalls.marginLeft(id, pending.commit, provedAt);
        if (left != null) {
          // The resume at the margin's end lists again and decides.
          return _Next(_NextKind.none, resendAfter: left);
        }
        return _resetDropLocked(id, group, refusal: refusal);
      case _Record.unknown:
      case _Record.notAsked:
        return none;
    }
  }

  /// The listing behind [_resetDecideLocked]: pages from the stored
  /// after-pair (when it is below g + 1), each one sync-budget unit. A unit
  /// the budget refuses is `notAsked` (audit M1), never `unknown`.
  Future<_Record> _resetRecord(
    SecureVault vault,
    String id,
    PendingCommit pending,
    BudgetPriority priority,
  ) async {
    final at = pending.builtOn;
    final stored = (await vault.conversation(id))?.afterPair;
    MlsPair? after = stored != null && stored.generation < at.generation
        ? stored
        : null;
    try {
      for (var i = 0; i < _kResetPagesMax; i++) {
        if (!await _takeSyncUnit(priority)) return _Record.notAsked;
        final page = await _messaging.listConversationCommits(
          conversationId: id,
          after: after,
          pageSize: kCommitPageSize,
        );
        for (final c in page.commits) {
          final cg = pairComponentFromInt64(c.mlsGeneration);
          final ce = pairComponentFromInt64(c.mlsEpoch);
          if (cg == null || ce == null) return _Record.unknown;
          // Audit L2: every listed pair moves the listing forward. One that
          // does not (a repeated page with `more`, a page out of order) is
          // no answer, and the listing stops there.
          if (!MlsPair.above(MlsPair(cg, ce), after)) return _Record.unknown;
          if (cg == at.generation) {
            if (ce != 0) return _Record.unknown;
            return _same(c.commit, pending.commit)
                ? _Record.ours
                : _Record.other;
          }
          if (cg > at.generation) return _Record.other;
          after = MlsPair(cg, ce);
        }
        if (!page.more || page.commits.isEmpty) {
          final sg = pairComponentFromInt64(page.mlsGeneration);
          if (sg == null) return _Record.unknown;
          if (sg < at.generation) return _Record.notStored;
          // The server is past g without a record this listing showed.
          return sg > at.generation ? _Record.other : _Record.unknown;
        }
      }
    } on NotFoundException {
      return _Record.unknown;
    } on Object catch (e, s) {
      _reportIfBug(e, s, 'reset.listConversationCommits');
      return _Record.unknown;
    }
    return _Record.unknown;
  }

  /// The server stored this device's reset: the one success function
  /// (`ConversationCrypto.settleOwnInitLocked`, which walks g to its end
  /// first), with the reset's own lists when this run made it.
  Future<_Next> _resetSettleLocked(
    String id,
    GroupRecord group,
    BudgetPriority priority,
  ) async {
    final pending = group.pending!;
    final lists = _resetLists[id];
    final mine = lists != null && _same(lists.commit, pending.commit);
    final settled = await _crypto.settleOwnInitLocked(
      id,
      group.generation,
      priority: priority,
      ownList: mine ? lists.own : null,
      peerList: mine ? lists.theirs : null,
    );
    switch (settled) {
      case InitSettle.settled:
      case InitSettle.notProvisional:
        _forgetReset(id);
        _onChanged(id);
        if (settled == InitSettle.settled) onResetSettled?.call(id);
        return const _Next(_NextKind.settledReset);
      case InitSettle.replay:
        // Amendment 6: the marks are already at or past this reset (this
        // device joined a later generation meanwhile): it can never be
        // settled, and its commit, stored or not, is in the past. It is
        // ended here, never left provisional for good.
        return _resetDropLocked(id, group);
      case InitSettle.waiting:
        return const _Next(_NextKind.none);
    }
  }

  /// The provisional group of the reset goes (the shared discard: no mark,
  /// no pin of g, the key history untouched). [join]: another reset or
  /// commit won, so this device then catches up and joins from its welcome.
  /// [refusal]: the server's answer, handed back to the user's reset.
  Future<_Next> _resetDropLocked(
    String id,
    GroupRecord group, {
    bool join = false,
    AppException? refusal,
  }) async {
    if (!await _crypto.discardProvisionalLocked(id, group.generation)) {
      return const _Next(_NextKind.none);
    }
    _forgetReset(id);
    _onChanged(id);
    return _Next(join ? _NextKind.join : _NextKind.none, refusal: refusal);
  }

  /// Review N-1 (controller ruling, round Q): [id]'s provisional reset was
  /// kept by an applied removal of this device in g
  /// ([PendingCommit.keptAfterSelfRemoval], in the vault, so a restart
  /// knows it too). No call of its bytes is ever made again. Why: the
  /// server checks only a reset's generation, so a resend would put a
  /// device removed in g back into g + 1, where it reads every new message.
  /// The server's record alone decides, with the lock held:
  /// - ours: remembered as held (audit M1) and settled;
  /// - another record, or nothing stored: the group goes (joining the
  ///   winner's welcome for another record), but only once no call of the
  ///   bytes is out and the margin had passed when the listing STARTED;
  ///   inside the margin one resume is scheduled for its end;
  /// - an answer that does not say, or a listing not asked: nothing is
  ///   decided (the next trigger lists again).
  /// While held back after an unknown outcome nothing is listed (review
  /// m-5); one resume is scheduled for the wait's end.
  Future<_Next> _resetKeptLocked(
    _Op op,
    String id,
    GroupRecord group,
    PendingCommit pending,
    BudgetPriority priority,
  ) async {
    const none = _Next(_NextKind.none);
    if (_resetCalls.callStillOut(id, pending.commit)) return none;
    if (_resetCalls.heldBack(id)) {
      final until = _resetCalls.notBefore(id);
      if (until == null) return none;
      return _Next(_NextKind.none, resendAfter: until.difference(_now()));
    }
    final provedAt = _now();
    final record = await _resetRecord(op.vault, id, pending, priority);
    switch (record) {
      case _Record.ours:
        _resetHeld[id] = pending.commit;
        return _resetSettleLocked(id, group, priority);
      case _Record.other:
      case _Record.notStored:
        if (_resetCalls.callStillOut(id, pending.commit)) return none;
        final left = _resetCalls.marginLeft(id, pending.commit, provedAt);
        if (left != null) return _Next(_NextKind.none, resendAfter: left);
        return _resetDropLocked(id, group, join: record == _Record.other);
      case _Record.unknown:
      case _Record.notAsked:
        return none;
    }
  }

  /// Audit M1: whether this run knows the server holds [commit] as [id]'s
  /// reset ([GroupStarter._resetHeld]).
  bool _serverHolds(String id, Uint8List commit) {
    final held = _resetHeld[id];
    return held != null && _same(held, commit);
  }

  /// Amendment 4: [resumeProvisional] for a provisional RESET, with the
  /// lock held. Its record at (g + 1, 0) decides first (a restart finds a
  /// stored reset and settles it; another winner is joined).
  /// [kProvisionalExpiry] old and not stored: the group goes, only on a
  /// listing that started after the margin with no call still out.
  ///
  /// Audit M1, first, at any age: when this run knows the server holds
  /// these bytes ([GroupStarter._resetHeld]: a call answered (g + 1,
  /// e >= 1), or a listing showed them), nothing is listed or sent; only
  /// the settle is retried.
  ///
  /// Then, at any age (review m-5): while a call of these bytes may still
  /// land, or while held back after an unknown outcome
  /// ([CommitCallTracker.heldBack]), nothing, not even the listing (one
  /// sync unit spared per trigger); an expired or refused reset is decided
  /// at the next trigger after the wait.
  ///
  /// Young (review I1: the server draws both of its caps BEFORE it
  /// recognises a retry, `service_mls.go` `commitCaps`, so every needless
  /// resend spends one of this conversation's 20 calls and one of the
  /// user's 10 resets a day, shared by every conversation):
  /// - the record is OURS: never a call. The server holds the reset; the
  ///   settle (which may wait, for example while g's walk is interrupted)
  ///   is retried at the next trigger;
  /// - another record, or the server past g + 1: decided as before;
  /// - NOT stored: the identical bytes are sent once more (spaced, counted,
  ///   never inside the margin before the expiry, never again after a
  ///   refusal of them);
  /// - the server failed the listing (or answered what the client cannot
  ///   read): sent once more only when no call of these bytes was made (nor
  ///   the record first seen) in this run within [kRequestInFlightMargin]
  ///   ([CommitCallTracker.marginLeft] at now), so at most one resend per
  ///   margin however many triggers come;
  /// - the local sync budget refused the listing (audit M1, `notAsked`):
  ///   nothing was asked, so nothing is decided and nothing is sent.
  Future<_Next> _resetResumeLocked(
    _Op op,
    String id,
    GroupRecord group,
    PendingCommit pending,
    BudgetPriority priority,
  ) async {
    const none = _Next(_NextKind.none);
    // The first sight of a record an earlier run left starts its margin.
    _resetCalls.noteSeen(id, pending.commit);
    // Audit M1: the server holds these bytes. No listing and no call: the
    // settle is retried (at any age; a stored reset is never expired).
    if (_serverHolds(id, pending.commit)) {
      return _resetSettleLocked(id, group, priority);
    }
    // Review N-1: kept across a removal of this device: no resend at any
    // age; the record alone decides.
    if (pending.keptAfterSelfRemoval) {
      return _resetKeptLocked(op, id, group, pending, priority);
    }
    if (_resetCalls.callStillOut(id, pending.commit)) return none;
    final refused = _resetRefused[id];
    final wasRefused = refused != null && _same(refused, pending.commit);
    final expired = _ageOf(group) >= kProvisionalExpiry;
    // Review m-5: inside the wait after an unknown outcome nothing is
    // listed, the expired or refused reset included (one sync unit spared
    // per trigger). Decision: such a reset still needs its decision, so one
    // resume is scheduled for the wait's end. Why: the resume an abandoned
    // call's end schedules can fall inside this wait, and without this the
    // decision would wait for an unrelated trigger. A young reset needs
    // none: its next trigger resends, and a server retry time is scheduled
    // by the send itself.
    if (_resetCalls.heldBack(id)) {
      final until = _resetCalls.notBefore(id);
      if (!(expired || wasRefused) || until == null) return none;
      return _Next(_NextKind.none, resendAfter: until.difference(_now()));
    }
    if (expired || wasRefused) {
      return _resetDecideLocked(op, id, group, pending, priority, expire: true);
    }
    final provedAt = _now();
    final record = await _resetRecord(op.vault, id, pending, priority);
    final decided = await _resetDecideOnLocked(
      id,
      group,
      pending,
      priority,
      record,
      provedAt,
    );
    switch (record) {
      case _Record.ours:
      case _Record.other:
      // Audit M1: nothing was asked (the local budget refused): no
      // decision and no call.
      case _Record.notAsked:
        return decided;
      case _Record.notStored:
        break;
      // A listing the server failed: resent at most once per margin.
      case _Record.unknown:
        if (_resetCalls.marginLeft(id, pending.commit, _now()) != null) {
          return decided;
        }
    }
    if (decided.kind != _NextKind.none || decided.resendAfter != null) {
      return decided;
    }
    if (await _provisionalReset(op.vault, id) == null) return decided;
    return _resetSendLocked(op, id, priority, first: false);
  }

  /// The body of [GroupStarter.repairIfStuck] (its contract is written
  /// there). Never throws.
  Future<void> _repairIfStuck(String id) async {
    if (!_repairing.add(id)) return;
    try {
      // A flag-off device never resets: the conversation stays stuck, and
      // `describeState` says so (`canReset` false).
      if (!_session.mayStart) return;
      // Audit M2 / L5: checked BEFORE the count, so nothing is counted for
      // an attempt that cannot run (`canReset` says the same).
      if (_session.vault == null || _removedElsewhere() || _engineDown()) {
        return;
      }
      final state = await _crypto.describeState(id);
      if (state.phase != ConversationPhase.stuck || !state.canReset) return;
      // Security read M9: at most kAutoResetsPerDay automatic resets per
      // conversation per IST day, and (audit L1) kAutoResetsPerUserPerDay
      // across the user's conversations, both read and the count written
      // BEFORE the first claim, in one body (so a crash or a failed reset
      // never undercounts, and the bound never rests on the server; an
      // exhausted ledger is at both caps). At a limit the conversation stays
      // stuck with the manual offer.
      if (!await _ledger.takeAutoReset(id)) return;
      // Decision: at `live` priority. Why: the repair is no user intent
      // (amendment 2) but follows the conversation's own catch-up, and a
      // deferred list would spend the day's automatic reset for nothing.
      await _resetConversation(id, BudgetPriority.live, automatic: true);
    } on E2eeActionException {
      // Counted: the conversation stays stuck with the manual offer.
    } on AppException {
      // The same: a refusal or a cap of the server.
    } on Object catch (e, s) {
      _reportIfBug(e, s, 'reset.repair');
    } finally {
      _repairing.remove(id);
    }
  }
}
