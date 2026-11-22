part of 'group_starter.dart';

/// R6 step 4 at 24 h: what the server's first stored commit decides for an
/// expired provisional group, and the 24 h rebuild. Moved from
/// `group_starter_recovery.dart` unchanged (Task 10's file-size rule).
extension _Expiry on GroupStarter {
  // -------------------------------------------------------------------------
  // Expiry

  /// A provisional group [kProvisionalExpiry] old or older (with its init
  /// row, or with none), with the lock held: the server's first stored
  /// commit decides. This init: the identical request is replayed for the
  /// message's answer (review W1). Another, or none: the rebuild, or (no
  /// row) the discard.
  Future<_Next> _expireLocked(
    _Op op,
    String id,
    GroupRecord group,
    PendingCommit pending,
    OutboxItem? row,
    BudgetPriority priority,
    bool mayRebuild,
  ) async {
    const none = _Next(_NextKind.none);
    // Audit M2: [kInitResendMargin] assumed that the last request left the
    // client when its call started. An init call whose client wait ran out
    // may still leave it: while one runs nothing is asked (a "not stored"
    // read now could be followed by the store), and after its end the
    // margin counts from that end. The end schedules the resume. Task 9
    // concern 1: an unknown outcome's margin is not asked here; it holds
    // only a "not stored" answer, in [_ownInitStored].
    if (_abandonedMayLand(id)) return none;
    final own = await _ownInitStored(id, pending, priority);
    if (own == null) return none;
    if (own) {
      if (row != null) {
        // Review W1: the init was accepted. The identical request is sent
        // once more, here under the lock; the server replays the stored
        // message and the group settles WITH its answer (`requestAccepted`
        // and the own-device alert come from it). Unanswered: nothing is
        // settled and the next trigger asks again.
        return _sendLocked(op, id, group, row, priority, replay: true);
      }
      // No row carries the init (it is gone): the same success steps,
      // with no message to answer for.
      final settled = await _crypto.settleOwnInitLocked(
        id,
        group.generation,
        priority: priority,
      );
      if (settled != InitSettle.settled) return none;
      _onChanged(id);
      return const _Next(_NextKind.drain);
    }
    // Decision: while this device may not start again (the flag is not on,
    // or it was removed elsewhere) the group is kept as it is: nothing is
    // sent either way, and nothing is destroyed that it could not rebuild.
    if (!mayRebuild || !_session.mayStart || _removedElsewhere()) return none;
    if (row == null) {
      // No row to send: there is nothing to rebuild the group for. Audit
      // M3: the "not stored" this discard rests on is the answer read just
      // above, in this same hold of the lock, with no await between the
      // two; the group is 24 h old, so no request of it is in flight
      // ([kInitResendMargin]). A second listing here would be the same
      // call twice.
      await _crypto.discardProvisionalLocked(id, group.generation);
      return const _Next(_NextKind.drain);
    }
    // Review I3. Decision: nothing is deleted here. The fresh claims come
    // first, under no lock; the old group goes only in the transaction
    // that stores the new one. A claim that fails for a passing reason
    // (no network, a rate limit, a kill) then leaves this group in place
    // and the next resume tries again, where a discard first would leave
    // "known, no group" with nothing to retry it.
    return _Next(_NextKind.rebuild, localId: row.localId);
  }

  /// Whether the server's first stored commit is this device's init
  /// ([pending]): at its `builtOn` pair, with its exact bytes. False: the
  /// conversation has no commit, or another one first. Null: the answer
  /// does not say, or could not be had (nothing is decided on it). One
  /// `ListConversationCommits` call, with the lock held.
  ///
  /// Task 9 ruling N (the runner's audit M2 rule, here for every keep or
  /// discard of the starter: a retry's refusal or STALE_EPOCH, the expiry,
  /// the rebuild's discard and its replace). "Not stored" is answered only
  /// when no init call of [id] that outlived the client's wait could still
  /// land: none still runs, and [kInitResendMargin] had passed after the
  /// last one's end when the listing STARTED (`provedAt`, review N1's rule).
  /// Otherwise null: nothing is decided, and that call's end schedules the
  /// resume that asks again ([_trackInit]). Why: a "not stored" read while
  /// the request can still be stored deletes a group the server then holds,
  /// which locks its creator out (no welcome exists for a creator). "Stored"
  /// is kept as read: it cannot be undone by a later store.
  Future<bool?> _ownInitStored(
    String id,
    PendingCommit pending,
    BudgetPriority priority,
  ) async => (await _ownInitRecord(id, pending, priority)).own;

  /// [_ownInitStored], and (pre-flag-on fix round 2, ruling 7) whether its
  /// "not stored" was read from ANOTHER commit first (`otherFirst`): true
  /// only with `own == false`, under the same margin rules. Why: that
  /// group can never be stored (the server takes one commit at a pair),
  /// and the winner's welcome is the way in, as the resume's STALE_EPOCH.
  Future<({bool? own, bool otherFirst})> _ownInitRecord(
    String id,
    PendingCommit pending,
    BudgetPriority priority,
  ) async {
    const notDecided = (own: null, otherFirst: false);
    if (!await _takeSyncUnit(priority)) return notDecided;
    final provedAt = _now();
    final read = await _listOwnInit(id, pending);
    if (read.own == false && _initMayStillLand(id, at: provedAt)) {
      // Task 9 concern 1: held only by an unknown outcome's margin (no
      // abandoned call, whose end schedules its own resume): one resume
      // at the margin's end, so the record decides without another
      // trigger.
      final left = _abandonedMayLand(id, at: provedAt)
          ? null
          : _unknownMarginLeft(id, provedAt);
      if (left != null) _armMarginResume(id, left);
      return notDecided;
    }
    return read;
  }

  /// The one `ListConversationCommits` call of [_ownInitStored]:
  /// `otherFirst` when the first stored commit is readable and not
  /// [pending].
  Future<({bool? own, bool otherFirst})> _listOwnInit(
    String id,
    PendingCommit pending,
  ) async {
    bool? own;
    var otherFirst = false;
    try {
      final page = await _messaging.listConversationCommits(
        conversationId: id,
        after: null,
        pageSize: kCommitPageSize,
      );
      if (page.commits.isEmpty) {
        // No commit at all, and the server says the conversation has none.
        own = page.mlsGeneration == Int64.ZERO && page.mlsEpoch == Int64.ZERO
            ? false
            : null;
      } else {
        final c = page.commits.first;
        final cg = pairComponentFromInt64(c.mlsGeneration);
        final ce = pairComponentFromInt64(c.mlsEpoch);
        if (cg != null && ce != null) {
          own =
              MlsPair(cg, ce) == pending.builtOn &&
              _same(c.commit, pending.commit);
          otherFirst = !own;
        }
      }
    } on NotFoundException {
      own = false;
    } on Object catch (e, s) {
      _reportIfBug(e, s, 'start.listConversationCommits');
      return (own: null, otherFirst: false);
    }
    return (own: own, otherFirst: otherFirst);
  }

  /// The 24 h rebuild (review I3): fresh claims for the init row [localId]
  /// of [id]'s expired provisional group, then ONE transaction that
  /// replaces the old group, its pins and its row by the new ones under a
  /// NEW key. True when the new group was stored. A failed claim changes
  /// nothing. At a daily claim cap (`tryAgainTomorrow`), and when the peer
  /// lists no usable device (review N5), the group is discarded and the row
  /// fails with that reason; the user's retry starts again then. Before
  /// either discard, and before the replace, the stored commits are asked
  /// again under the lock (review F2, audit M3): a delete is made only on a
  /// "not stored" read in the same hold.
  Future<bool> _rebuild(
    String id,
    String localId,
    BudgetPriority priority,
  ) async {
    final vault = _session.vault;
    final peer = _known.peerOf(id);
    if (vault == null || peer == null) return false;
    GroupRecord? group;
    for (final g in await vault.groups(id)) {
      if (g.provisional) group = g;
    }
    final pending = group?.pending;
    if (group == null || pending == null) return false;
    final row = await _initRow(vault, id, group.generation);
    if (row == null || row.localId != localId) return false;
    final StartOutcome outcome;
    try {
      outcome = await _begin(
        peer,
        _Draft(
          localId: row.localId,
          content: row.content,
          // Addressed exactly as the old row was.
          recipient: row.recipientUserId,
          conversationId: row.conversationId,
          expectId: id,
          replaces: row.idempotencyKey,
          replacesCommit: pending.commit,
          createdAtMicros: row.createdAtMicros,
        ),
        mode: _Mode.replace,
        priority: priority,
      );
    } on _BadRandom {
      _reportOnce('start.random');
      return false;
    }
    if (outcome.result == StartResult.started) {
      _forget(localId);
      _onChanged(id);
      return true;
    }
    final cause = outcome.cause;
    // The stored reason of a rebuild that cannot be made, or null for an
    // outcome that may pass (the group then stays as it is).
    final String? reason;
    if (outcome.result == StartResult.tryAgainTomorrow && cause != null) {
      // The daily cap: no claim can succeed today, so the row fails now
      // (the group cannot be rebuilt, and its init was not stored).
      reason = sendErrorName(cause);
    } else if (outcome.result == StartResult.peerHasNoDevice) {
      // Review N5. Decision: the peer lists no usable device (it removed
      // them, or R3 refuses every package). The old init is never sent
      // again after 24 h, so keeping the group would leave the first
      // message "sending" for good, with a commit call and two lookups at
      // every resume and no way for the user to discard it. The group goes
      // and the row fails; the user's retry starts again (F1, option c).
      reason = kStartErrorPeerHasNoDevice;
    } else {
      // `lookupFailed` and `unavailable` are kept: a passing failure (no
      // network, a rate limit, a vault that closed), or a state in doubt
      // (the group changed under the claim, a claim that names another
      // conversation). Nothing is deleted on those; [pendingInit] says
      // `waiting`, never `sending`, for such a group.
      reason = null;
    }
    if (reason != null) {
      final discarded = await _locks.run(id, () async {
        // Review F2. Decision: the commits are asked again here, in the
        // hold of the lock that discards, and the group goes only on "not
        // stored". Why: the expiry's own answer is from an earlier hold,
        // before two lookups of up to 30 s each and a claim; a request the
        // server took long over can be stored in between, and a creator
        // that deleted a stored group is locked out of the conversation
        // (no welcome exists for it). An answer that does not say keeps
        // the group; the next resume asks again.
        if (await _ownInitStored(id, pending, priority) != false) return false;
        return _crypto.discardProvisionalLocked(
          id,
          group!.generation,
          lastError: reason,
        );
      });
      if (discarded) {
        _forget(localId);
        if (cause != null) _sender.rememberRefusal(localId, cause);
        _onChanged(id);
      }
    }
    return false;
  }
}
