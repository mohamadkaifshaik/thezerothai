part of 'membership_upkeep.dart';

/// `reconcile` (plan Task 9, steps 1-5; M1, M2, M3, M4): the unheld entry
/// (with the live pull between two passes) and the passes, each with the
/// conversation lock held.
extension _Reconcile on MembershipUpkeep {
  /// The unheld entry: [MembershipUpkeep.reconcile] and the re-check timer
  /// ([recheck]). Review I1: a pass whose commit or resume moved the pair
  /// (`applied`, `superseded`) leaves the conversation unsynced, and the
  /// live pull that syncs it takes the lock itself, so it runs here,
  /// between two holds, before the ONE more pass (plan step 4). A re-check
  /// exists to make a change, so it pulls first when not synced. [depth]:
  /// the re-check's place in a chain (0 for an outside trigger and a
  /// re-check that waits on a clock; see [kMaxChainedRechecks]). Never
  /// throws.
  Future<void> _reconcileUnheld(
    String id,
    BudgetPriority priority, {
    required bool recheck,
    int depth = 0,
  }) async {
    try {
      if (recheck && !_contexts.of(id).syncedSinceStart) {
        await _receiver.pullLive(id, priority: priority);
      }
      final first = await _locks.run(
        id,
        () => _reconcileOnce(
          id,
          priority,
          recheck: recheck,
          depth: depth,
          mayRunAgain: true,
        ),
      );
      if (first != CommitOutcome.applied && first != CommitOutcome.superseded) {
        return;
      }
      final pull = await _receiver.pullLive(id, priority: priority);
      if (pull.kind != ReceiveOutcomeKind.complete) {
        // Ruling C: the pull the next pass needs failed, so whatever it
        // decides cannot be committed now. One re-check, which pulls
        // first.
        _armRetry(id, depth, _now().add(kPeerRemovalFetchGap));
      }
      await _locks.run(
        id,
        () => _reconcileOnce(
          id,
          priority,
          recheck: recheck,
          depth: depth,
          mayRunAgain: false,
        ),
      );
    } on Object catch (e, s) {
      _reportIfBug(e, s, 'upkeep.reconcile');
    }
  }

  /// Ruling C: a change of [id] decided by a pass at [depth] did not land.
  /// One re-check at [at] (the earliest due one is kept), one place
  /// further in the chain, unless the chain is at [kMaxChainedRechecks].
  void _armRetry(String id, int depth, DateTime at) {
    if (depth >= kMaxChainedRechecks) return;
    _scheduleRecheck(id, at, depth: depth + 1);
  }

  /// Ruling O: whether adds of [id] wait for a RATE_LIMITED answer's retry
  /// time ([MembershipUpkeep._addsNotBefore]).
  bool _addsHeld(String id) {
    final at = _addsNotBefore[id];
    if (at == null) return false;
    if (_now().isBefore(at)) return true;
    _addsNotBefore.remove(id);
    return false;
  }

  /// When the re-check of a change left `pending` is due: the runner's
  /// not-before when it lies ahead, else [kRequestInFlightMargin] on.
  DateTime _pendingDue(String id) {
    final now = _now();
    final notBefore = _commits.resendNotBefore(id);
    return notBefore != null && notBefore.isAfter(now)
        ? notBefore
        : now.add(kRequestInFlightMargin);
  }

  /// The held entry (the acceptance steps only; review m-5 removed the
  /// public held entry): ONE pass. Review m-3: a second pass here could
  /// never commit, because a `superseded` answer leaves the conversation
  /// unsynced and the held steps cannot pull. Plan step 4's "once more on
  /// the caught-up group" is the re-check that answer arms instead (ruling
  /// C): it runs unheld, pulls first and reconciles on the new group.
  /// [recheck]: no self-update (R9 runs only from an open or a send).
  /// Never throws.
  Future<void> _reconcileLocked(
    String id,
    BudgetPriority priority, {
    required bool recheck,
  }) async {
    try {
      await _reconcileOnce(
        id,
        priority,
        recheck: recheck,
        depth: 0,
        mayRunAgain: false,
      );
    } on Object catch (e, s) {
      _reportIfBug(e, s, 'upkeep.reconcile');
    }
  }

  /// One pass. Answers how this device's commit of the pass ended (its
  /// change, else the resume of a pending record when that settled it);
  /// null when it made none. [depth]: see [_reconcileUnheld]; a change of
  /// this pass that does not land arms one re-check through [_armRetry].
  /// [mayRunAgain]: this is the unheld entry's first pass, which pulls and
  /// runs one more pass after an `applied` or `superseded` answer.
  Future<CommitOutcome?> _reconcileOnce(
    String id,
    BudgetPriority priority, {
    required bool recheck,
    required int depth,
    required bool mayRunAgain,
  }) async {
    final vault = _session.vault;
    if (vault == null || _removedElsewhere()) return null;
    // R10 and pilot gate 5.3: before any list call.
    if (!((await vault.conversation(id))?.sync.requestAccepted ?? false)) {
      return null;
    }
    var group = await _currentGroup(vault, id);
    if (group == null) return null;
    // 9a decision 2: a pending record is settled first, before any list.
    CommitOutcome? resumed;
    if (group.hasPending) {
      final settled = await _commits.resumePendingLocked(
        id,
        priority: priority,
      );
      if (settled == CommitOutcome.pending) {
        // Review I-A: the record holds every send here, and nothing else
        // settles it this session; one re-check, when a resend may go.
        _armRetry(id, depth, _pendingDue(id));
        return null;
      }
      if (settled == CommitOutcome.applied ||
          settled == CommitOutcome.superseded) {
        resumed = settled;
      }
    }
    if (await _crypto.catchUpLocked(id, priority: priority) !=
        CatchUpResult.current) {
      return resumed;
    }
    if (!identical(_session.vault, vault)) return resumed;
    group = await _currentGroup(vault, id);
    final thisDevice = await vault.deviceId();
    if (group == null || group.hasPending || thisDevice == null) {
      return resumed;
    }
    final context = _contexts.of(id);
    final accepted = context.acceptedSeenAt;
    // Review m-2: the resume settled the record, so the unheld entry pulls
    // and runs one more pass after this one; a change this pass cannot
    // commit for want of that pull needs no re-check of its own.
    final willRunAgain =
        mayRunAgain &&
        (resumed == CommitOutcome.applied ||
            resumed == CommitOutcome.superseded);

    // Which re-checks are due: a due one reads fresh lists.
    var members = await vault.members(id);
    final now = _now();
    _forgetGone(context, members);
    final unattributedDue = members.any((m) {
      if (m.side != MemberSide.unattributed) return false;
      final first = context.firstSeenUnattributed[vaultDeviceIdHex(m.deviceId)];
      return first != null && !now.isBefore(first.add(kUnattributedRecheck));
    });
    final peerDue = context.firstMiss.values.any(
      (first) => !now.isBefore(first.add(kPeerRemovalFetchGap)),
    );
    if (unattributedDue) {
      // M2: one fresh fetch of both lists, and the members attributed
      // again (attribution fetches both fresh).
      await _crypto.attributeMembersLocked(id, priority: priority);
      if (!identical(_session.vault, vault)) return resumed;
      members = await vault.members(id);
    }

    // Step 1: the lists (reused within kDeviceListReuse).
    final ref = await _peerRef(id);
    final own = await _directory.own(priority: priority);
    var peer = ref == null
        ? const DeviceList.unreadable()
        : await _directory.peer(
            ref,
            fresh: peerDue && !unattributedDue,
            priority: priority,
          );
    // A reused list from before the removal clock started never counts;
    // once a fetch would, one fresh one is made.
    if (ref != null &&
        peer.readable &&
        accepted != null &&
        !_counts(peer, accepted) &&
        !now.isBefore(accepted.add(kConversationCopyStale))) {
      peer = await _directory.peer(ref, fresh: true, priority: priority);
    }
    if (!identical(_session.vault, vault)) return resumed;
    final unattributed = members.any((m) => m.side == MemberSide.unattributed);
    var unverifiable =
        own.state == ListState.unreadable || peer.state == ListState.unreadable;
    final deferred =
        !unverifiable &&
        (own.state == ListState.deferred || peer.state == ListState.deferred);
    if (deferred) {
      // M4: silent, unless it outlasts 30 minutes with a member
      // unattributed; then it counts as unreadable here.
      if (unattributed) context.deferredSince ??= now;
      if (deferralOutlasted(
        deferredSince: context.deferredSince,
        unattributedPresent: unattributed,
        now: now,
      )) {
        unverifiable = true;
      }
    } else if (!unverifiable) {
      context.deferredSince = null;
    }
    if (unverifiable) {
      context.listUnverifiable = true;
    } else if (!deferred) {
      context.listUnverifiable = false;
    }

    final history = await _crypto.keyHistory.of(
      vault,
      id,
      currentPins: members,
      formerPins: await _former.of(vault, id),
    );

    // Step 2: removals.
    final removes = <Uint8List>[];
    final removing = <String>{};
    void remove(Uint8List deviceId) {
      if (removing.add(vaultDeviceIdHex(deviceId))) removes.add(deviceId);
    }

    final recheckAt = <DateTime>[];
    // Ruling H (audit L2): the removals the M5 pause and the fail-closed
    // ledger do not hold: the user's queued ones and M3's own devices.
    final pauseExempt = <Uint8List>[];
    final exempting = <String>{};
    void exempt(Uint8List deviceId) {
      if (exempting.add(vaultDeviceIdHex(deviceId))) pauseExempt.add(deviceId);
    }

    // Task 11's queue: the members it names (never this device). Only
    // `mine` pins, and an `unattributed` pin whose key is the key of the
    // user's removed mark (fix round 2, ruling 1), are ever removed from it,
    // so a peer's device (`theirs`) is never touched by the queue (Task 11
    // review I1; the runner drops an entry pinned on the peer's side).
    final queued = queuedRemovals?.call(id) ?? const <Uint8List>{};
    for (final m in members) {
      if (!_same(m.deviceId, thisDevice) &&
          queued.any((q) => _same(q, m.deviceId))) {
        if (m.side == MemberSide.unattributed) {
          final key = removedKeyOf?.call(m.deviceId);
          if (key == null || !_same(key, m.signatureKey)) continue;
          // Task 11 fix round 4, ruling 11 (SA N2), and fix round 5, ruling
          // 1: M2's full key-history guard holds for the mark path too
          // (`tainted` with a list that shows the pair included; the runner
          // reports it).
          if (keyHistoryRefuses(
            member: m,
            refusal: history.refusal(
              vaultDeviceIdHex(m.deviceId),
              m.signatureKey,
            ),
            ownList: own,
            peerList: peer,
          )) {
            continue;
          }
        } else if (m.side != MemberSide.mine) {
          continue;
        }
        // Fix round 4, ruling 3 (CR2 M-1): a queued id with no removed mark
        // is a lost own device the runner's pass found on one own list; M3
        // below decides it on this pass's own list, so one list that missed
        // it does not freeze into a removal (and flapping). No seam set (no
        // runner): every queued id is the user's.
        if (removedByUser?.call(m.deviceId) == false) continue;
        remove(m.deviceId);
        exempt(m.deviceId);
      }
    }
    // Fix round 1, ruling 3 (SA M2): a `mine` pin whose id has an unexpired
    // "removed by the user" mark with this very key is removed with NO
    // queue entry. Why: the entry is pruned once the pins no longer name
    // the device, and a later commit (a peer's, or a reset built before
    // the mark) can pin it again; an own list that still shows it (hostile
    // or stale) keeps M3 from removing it, and the add checks never see a
    // member. The key must match the mark's (an id alone is no proof), and
    // M2's key-history guard holds as on the mark path above. The user's
    // removal is exempt from the M5 pause (ruling H).
    for (final m in members) {
      if (m.side != MemberSide.mine || _same(m.deviceId, thisDevice)) continue;
      final hex = vaultDeviceIdHex(m.deviceId);
      if (removing.contains(hex)) continue;
      final key = removedKeyOf?.call(m.deviceId);
      if (key == null || !_same(key, m.signatureKey)) continue;
      if (keyHistoryRefuses(
        member: m,
        refusal: history.refusal(hex, m.signatureKey),
        ownList: own,
        peerList: peer,
      )) {
        continue;
      }
      remove(m.deviceId);
      exempt(m.deviceId);
    }
    // M3: one readable own list decides.
    for (final m in members) {
      if (mayRemoveOwnDevice(
        member: m,
        ownList: own,
        thisDeviceId: thisDevice,
      )) {
        exempt(m.deviceId);
        remove(m.deviceId);
      }
    }
    // M4. The count of peer-side members is per call: lowered after each
    // removal decided here, so the last one always stays.
    var theirs = members
        .where(
          (m) =>
              m.side == MemberSide.theirs &&
              !removing.contains(vaultDeviceIdHex(m.deviceId)),
        )
        .length;
    final peerCounts = accepted != null && _counts(peer, accepted);
    for (final m in members) {
      if (m.side != MemberSide.theirs) continue;
      final hex = vaultDeviceIdHex(m.deviceId);
      if (removing.contains(hex)) continue;
      final listed = peer.readable && _lists(peer, m.deviceId);
      if (peerCounts && listed) {
        // Any counting fetch that lists the id clears its first miss.
        context.firstMiss.remove(hex);
        continue;
      }
      if (peerCounts && peer.readableNonEmpty && !listed) {
        context.firstMiss[hex] ??= peer.fetchedAt!;
      }
      final first = context.firstMiss[hex];
      if (mayRemovePeerDevice(
        member: m,
        peerList: peer,
        evidence: RemovalEvidence(acceptedSeenAt: accepted, firstMissAt: first),
        theirMemberCount: theirs,
      )) {
        remove(m.deviceId);
        theirs--;
        continue;
      }
      if (first != null) {
        final due = first.add(kPeerRemovalFetchGap);
        if (now.isBefore(due)) recheckAt.add(due);
      } else if (peer.readableNonEmpty &&
          !listed &&
          accepted != null &&
          !peerCounts) {
        // The removal clock has not started: one look when it has.
        recheckAt.add(accepted.add(kConversationCopyStale));
      }
    }
    // M2, with the key history's refusal (device-key-history-design.md,
    // "Removal rule (Task 9)").
    for (final m in members) {
      if (m.side != MemberSide.unattributed) continue;
      final hex = vaultDeviceIdHex(m.deviceId);
      final first = context.firstSeenUnattributed[hex];
      if (first == null || removing.contains(hex)) continue;
      final refusal = history.refusal(hex, m.signatureKey);
      if (!unverifiable &&
          mayRemoveUnattributed(
            member: m,
            ownList: own,
            peerList: peer,
            firstSeenUnattributedAt: first,
            acceptedSeenAt: accepted,
            refusal: refusal,
          )) {
        remove(m.deviceId);
        continue;
      }
      final due = first.add(kUnattributedRecheck);
      if (now.isBefore(due) &&
          (refusal == KeyRefusal.none || refusal == KeyRefusal.tainted)) {
        recheckAt.add(due);
      }
    }
    if (recheckAt.isNotEmpty) {
      recheckAt.sort();
      // A clock's re-check keeps this pass's place in a chain.
      _scheduleRecheck(id, recheckAt.first, depth: depth);
    }

    final staying = [
      for (final m in members)
        if (!removing.contains(vaultDeviceIdHex(m.deviceId))) m,
    ];
    final mayAdd = _session.mayStart && !unverifiable && !_addsHeld(id);

    // M5 and the rest of "may commit": no claim is spent on a change that
    // cannot be made now.
    if (!await _commits.mayCommit(id, PendingKind.change)) {
      // Ruling H (audit L2): the M5 pause or the fail-closed ledger may be
      // all that says no. A lost own phone and a removal the user asked
      // for still go then, alone (no add, no peer-side removal), within
      // the daily call cap; [CommitRunner.mayCommit] with `pauseExempt`
      // still checks everything else.
      if (pauseExempt.isNotEmpty &&
          await _commits.mayCommit(id, PendingKind.change, pauseExempt: true)) {
        final limitBefore = _commits.lastRateLimitIn(id);
        final outcome = await _commits.changeLocked(
          id,
          removeDeviceIds: pauseExempt,
          priority: priority,
          pauseExempt: true,
        );
        _afterChange(
          id,
          outcome,
          depth: depth,
          mayRunAgain: mayRunAgain,
          limitBefore: limitBefore,
        );
        return outcome;
      }
      // Review I1 c: a change decided while this run has not pulled the
      // current pair (after an own commit) waits for one re-check, which
      // pulls first (ruling C's chain bounds it). Other reasons (M5, the
      // cap) arm none: a re-check could not change them.
      if (!willRunAgain &&
          !context.syncedSinceStart &&
          (removes.isNotEmpty ||
              (mayAdd &&
                  (await _ownForAdds(
                    own,
                    peer,
                    staying,
                    thisDevice,
                    history,
                    priority,
                    mayReadFresh: false,
                  )).wanted.isNotEmpty))) {
        _armRetry(id, depth, _now().add(kPeerRemovalFetchGap));
      }
      if (removes.isEmpty && !recheck) {
        await _selfUpdateLocked(id, priority, caughtUp: true);
      }
      return resumed;
    }

    // Step 3: adds, only with the flag (R1), against step 1's lists.
    final adds = mayAdd
        ? await _claimAdds(
            id,
            ref,
            own,
            peer,
            staying,
            thisDevice,
            history,
            priority,
          )
        : const <UsableClaim>[];

    // Step 4.
    if (removes.isEmpty && adds.isEmpty) {
      if (!recheck) await _selfUpdateLocked(id, priority, caughtUp: true);
      return resumed;
    }
    final limitBefore = _commits.lastRateLimitIn(id);
    var outcome = await _commits.changeLocked(
      id,
      adds: adds,
      removeDeviceIds: removes,
      priority: priority,
    );
    // Task 9 ruling O: a RATE_LIMITED answer to THIS change (the runner
    // records each one per conversation; compared by identity with the one
    // before it). Round P (review Minor 3): the record of this
    // conversation, which only commits under this lock change, never the
    // runner-wide one another conversation may have changed meanwhile.
    final rateLimited = !identical(_commits.lastRateLimitIn(id), limitBefore);
    final unbuildable =
        outcome == CommitOutcome.notAllowed &&
        _commits.lastChangeUnbuildable(id);
    if (adds.isNotEmpty &&
        ((outcome == CommitOutcome.refused && !rateLimited) ||
            (unbuildable && removes.isEmpty))) {
      // Audit M1: the engine could not build a commit with these adds, or
      // the server refused the commit that carried them. Each is tried for
      // the IST day, so one broken or poisoned package is not claimed
      // again on every pass (a key package and a claim of the cap each
      // time, and a commit call on the refused path). Ruling O: never on
      // RATE_LIMITED. Why: a rate limit is transient and says nothing about
      // the device; the add waits only for the server's retry time. An
      // unbuildable change that also removes is judged after its
      // removal-only follow-up (below).
      await _markTried([for (final a in adds) a.deviceId]);
    }
    if (adds.isNotEmpty && outcome == CommitOutcome.refused && rateLimited) {
      // Ruling O: the adds wait for the server's retry time, in this run:
      // the pass that follows (the unheld entry's second, or the removal
      // follow-up's) claims none before it, and one re-check is armed for
      // it (ruling C), whatever the follow-up answers.
      final wait = _commits.lastRateLimitIn(id)?.retryAfter;
      final at = _now().add(
        wait != null && wait > Duration.zero ? wait : kPeerRemovalFetchGap,
      );
      _addsNotBefore[id] = at;
      _armRetry(id, depth, at);
    }
    // Audit M1: removals are never held back for adds. A change with adds
    // that ends `notAllowed` (the flag went off meanwhile, the engine
    // refused a package) or `refused`, for any reason, is followed by the
    // removals alone, in this same pass: a lost phone must not keep
    // reading because a peer's package is broken.
    if ((outcome == CommitOutcome.notAllowed ||
            outcome == CommitOutcome.refused) &&
        adds.isNotEmpty &&
        removes.isNotEmpty) {
      outcome = await _commits.changeLocked(
        id,
        removeDeviceIds: removes,
        priority: priority,
      );
      // Task 9 round P (review Minor 2): the adds of an unbuildable mixed
      // change are tried for the day only when the removals alone then
      // built (any answer but `notAllowed` means a commit was built and
      // stored). When they did not build either, the fault is not shown to
      // be the adds' (the engine, or the removal), and nothing is marked.
      // Why: a mark must rest on evidence that the add itself is bad; an
      // honest new device must not wait a day for an engine fault.
      if (unbuildable && outcome != CommitOutcome.notAllowed) {
        await _markTried([for (final a in adds) a.deviceId]);
      }
    }
    _afterChange(
      id,
      outcome,
      depth: depth,
      mayRunAgain: mayRunAgain,
      limitBefore: limitBefore,
    );
    return outcome;
  }

  /// What a pass does after its change answered [outcome] (ruling C):
  /// `applied` tells the app; `pending`, `refused` and a `superseded` with
  /// no further pass coming ([mayRunAgain] false) arm one re-check.
  /// [limitBefore]: [CommitRunner.lastRateLimitIn] of [id] before the
  /// change, so only a RATE_LIMITED answer to THIS change names the retry
  /// time (round P, review Minor 3: never another conversation's).
  void _afterChange(
    String id,
    CommitOutcome outcome, {
    required int depth,
    required bool mayRunAgain,
    required RateLimitedException? limitBefore,
  }) {
    switch (outcome) {
      case CommitOutcome.applied:
        _onChanged(id);
      case CommitOutcome.pending:
        // Review I-A: nothing else settles it this session.
        _armRetry(id, depth, _pendingDue(id));
      case CommitOutcome.refused:
        // Audit L1: a RATE_LIMITED answer names when to ask again.
        final limit = _commits.lastRateLimitIn(id);
        final wait = identical(limit, limitBefore) ? null : limit?.retryAfter;
        _armRetry(
          id,
          depth,
          _now().add(
            wait != null && wait > Duration.zero ? wait : kPeerRemovalFetchGap,
          ),
        );
      case CommitOutcome.superseded:
        // Review m-1: the unheld entry runs one more pass after the first;
        // a superseded change with no such pass coming waits for a
        // re-check.
        if (!mayRunAgain) {
          _armRetry(id, depth, _now().add(kPeerRemovalFetchGap));
        }
      case CommitOutcome.notAllowed:
        break;
    }
  }

  /// `devicesToAdd`, without the ids the key history would refuse and the
  /// devices tried today (a claim that came back empty, a package the
  /// checks dropped, an add the engine or the server refused; audit M1).
  /// Reads only.
  Future<List<DeviceToAdd>> _wanted(
    DeviceList own,
    DeviceList peer,
    List<MemberRecord> members,
    Uint8List thisDevice,
    KeyHistory history,
  ) async {
    if (history.unreadable) return const [];
    final wanted = <DeviceToAdd>[];
    for (final d in devicesToAdd(
      ownList: own,
      peerList: peer,
      members: members,
      thisDeviceId: thisDevice,
      admissible: history.admissible,
    )) {
      if (!await _ledger.emptyClaimTried(d.deviceId)) wanted.add(d);
    }
    return wanted;
  }

  /// Plan step 3: `devicesToAdd` (skipping ids the key history would
  /// refuse and devices tried today), one claim per side that has a device
  /// to add, `inspectKeyPackage` and `checkClaims` (R3) against the lists
  /// of step 1. An empty claim, and a claimed package the checks dropped
  /// (audit M1), is recorded for the IST day after the claims, outside any
  /// write body.
  ///
  /// Task 11 follow-up: [_ownForAdds] decides the own list of this step (a
  /// fresh one replaces step 1's while the removal answer is unknown) and
  /// the own devices it keeps out.
  Future<List<UsableClaim>> _claimAdds(
    String id,
    String? ref,
    DeviceList stepOneOwn,
    DeviceList peer,
    List<MemberRecord> members,
    Uint8List thisDevice,
    KeyHistory history,
    BudgetPriority priority,
  ) async {
    final ownAdds = await _ownForAdds(
      stepOneOwn,
      peer,
      members,
      thisDevice,
      history,
      priority,
      mayReadFresh: true,
    );
    final own = ownAdds.list;
    final wanted = ownAdds.wanted;
    if (wanted.isEmpty) return const [];
    final empty = <Uint8List>[];
    Future<List<UsableClaim>> side(ClaimSide side) async {
      final mine = side == ClaimSide.mine;
      final devices = [
        for (final d in wanted)
          if (d.side == side) d,
      ];
      if (devices.isEmpty) return const [];
      final me = _ownUserId();
      final user = mine ? me : ref;
      if (user == null || user.isEmpty) return const [];
      final kpb.ClaimKeyPackagesResponse answer;
      try {
        answer = await _claim(user, mine ? utf8.decode(thisDevice) : '');
      } on AppException {
        // Nothing is added on this side now; a later reconcile asks again.
        return const [];
      }
      // A peer claim must be for THIS conversation (the claim names it).
      if (!mine && answer.conversationId != id) return const [];
      final claimed = [
        for (final c in answer.keyPackages)
          if (devices.any((d) => _same(utf8.encode(c.deviceId), d.deviceId))) c,
      ];
      // A listed device the answer left out counts as an empty claim too
      // (as the starter decides, Task 8 review M6).
      for (final d in devices) {
        if (!claimed.any((c) => _same(utf8.encode(c.deviceId), d.deviceId))) {
          empty.add(d.deviceId);
        }
      }
      final engineDown = <String>{};
      final checked = checkClaims(
        side: side,
        claimed: claimed,
        inspected: await _inspect(claimed, engineDown),
        directory: mine ? own : peer,
        ownList: own,
        members: members,
        thisDeviceId: thisDevice,
        admissible: history.admissible,
      );
      empty.addAll(checked.emptyFor);
      // Audit M1: a listed device (every one asked for here is in step 1's
      // lists) whose claimed package the checks dropped is tried for the
      // IST day as an empty claim is: claiming it again on every pass would
      // spend a key package and a claim of the cap each time, for a
      // package that fails the same way. Task 9 round P (review Minor 2):
      // not a package the engine could not inspect because it is down,
      // which says nothing about the package.
      for (final c in claimed) {
        if (engineDown.contains(c.deviceId)) continue;
        final cid = utf8.encode(c.deviceId);
        if (!checked.usable.any((u) => _same(u.deviceId, cid))) {
          empty.add(Uint8List.fromList(cid));
        }
      }
      return checked.usable;
    }

    final mine = await side(ClaimSide.mine);
    final theirs = await side(ClaimSide.theirs);
    // A key or a device id claimed on both sides is on neither (and is
    // tried for the day, as a package the checks dropped).
    bool onBoth(UsableClaim a, List<UsableClaim> other) => other.any(
      (b) =>
          _same(a.signatureKey, b.signatureKey) ||
          _same(a.deviceId, b.deviceId),
    );
    // Fix round 1, ruling 2 (CR I-2): a peer claim with the key of ANY
    // device on this step's own list is dropped too (and tried for the
    // day). Why: an own device the user removed is never claimed now
    // (`_wanted` leaves it out), so the dedupe above no longer sees its
    // key; a peer device carrying it under another id would bring the
    // removed device's key into the group. Before the Task 11 follow-up
    // the removed device was claimed and `onBoth` dropped both.
    bool ownKey(UsableClaim c) =>
        own.devices.any((d) => _same(d.signatureKey, c.signatureKey));
    final usable = <UsableClaim>[];
    for (final (c, other) in [
      for (final c in mine) (c, theirs),
      for (final c in theirs) (c, mine),
    ]) {
      if (onBoth(c, other) || (c.side == ClaimSide.theirs && ownKey(c))) {
        empty.add(c.deviceId);
      } else {
        usable.add(c);
      }
    }
    await _markTried(empty);
    return usable;
  }

  /// Marks [deviceIds] tried for the IST day (`DailyLedger.markEmptyClaim`,
  /// the one daily set `_wanted` skips): an empty claim, a package the
  /// checks dropped, or an add the engine or the server refused (audit M1).
  /// Outside any write body. A failed write is reported if it is a bug and
  /// otherwise only means the device is claimed again later.
  Future<void> _markTried(List<Uint8List> deviceIds) async {
    for (final d in deviceIds) {
      try {
        await _ledger.markEmptyClaim(d);
      } on Object catch (e, s) {
        _reportIfBug(e, s, 'upkeep.emptyClaim');
      }
    }
  }

  /// One `ClaimKeyPackages` call under its own random key (a claim is not
  /// replayed), bounded by [kMlsRpcTimeout].
  Future<kpb.ClaimKeyPackagesResponse> _claim(
    String userId,
    String excludeDeviceId,
  ) async {
    final key = hexOf(await randomOf(_engine(), 16));
    return _keys
        .claim(
          userId: userId,
          excludeDeviceId: excludeDeviceId,
          idempotencyKey: key,
        )
        .timeout(
          kMlsRpcTimeout,
          onTimeout: () => throw const NetworkException('timed out'),
        );
  }

  /// The engine's reading of each claimed package (null: none, or one the
  /// engine refuses, or an engine that cannot answer now). The device id of
  /// each package the engine could not read because it is down
  /// ([_engineDown]) is added to [engineDown].
  Future<List<KeyPackageInfo?>> _inspect(
    List<kpb.ClaimedKeyPackage> claimed,
    Set<String> engineDown,
  ) async {
    final out = <KeyPackageInfo?>[];
    for (final c in claimed) {
      if (!c.hasKeyPackage_4 || c.keyPackage.isEmpty) {
        out.add(null);
        continue;
      }
      try {
        out.add(
          await _engine().inspectKeyPackage(Uint8List.fromList(c.keyPackage)),
        );
      } on MlsException catch (e) {
        if (_engineDown(e)) engineDown.add(c.deviceId);
        out.add(null);
      }
    }
    return out;
  }

  /// Task 9 round P (review Minor 2): whether [e] says the engine could not
  /// answer now rather than that the input is bad: the guarded engine is
  /// unavailable (its code, or its flag as read after the failure) or the
  /// call ran out of its deadline. Both are transient and say nothing about
  /// the package.
  bool _engineDown(MlsException e) {
    if (e.code == MlsErrorCode.unavailable || e.code == MlsErrorCode.deadline) {
      return true;
    }
    final engine = _engine();
    return engine is GuardedCryptoEngine && engine.unavailable.value;
  }

  /// The peer's user reference. Audit L3: the one stored for [id] in the
  /// known conversations (first write wins, `KnownConversations.addIn`)
  /// when there is one, since memory can be overwritten by a send answer
  /// or a cached row, and a removal decided against another user's list
  /// would remove the peer's devices. Else this run's context, else the
  /// cached inbox row (its peer only: a cached row is no sight, review
  /// m5). Null when none knows it, or when the stored set cannot be read
  /// (fail closed: no peer list, so no peer-side add or removal).
  Future<String?> _peerRef(String id) async {
    final vault = _session.vault;
    if (vault == null) return null;
    try {
      if (!_known.isLoadedFor(vault)) await _known.load(vault);
    } on Object catch (e, s) {
      _reportIfBug(e, s, 'upkeep.known');
      return null;
    }
    final stored = _known.peerOf(id);
    if (stored != null && stored.isNotEmpty) return stored;
    final context = _contexts.of(id);
    String? known() {
      final ref = context.peerUserId;
      return ref == null || ref.isEmpty ? null : ref;
    }

    if (known() != null) return known();
    final row = await _messaging.cachedConversation(id);
    if (row != null) _contexts.note(row, peerOnly: true);
    return known();
  }

  /// The highest stored group when none is provisional, else null.
  Future<GroupRecord?> _currentGroup(SecureVault vault, String id) async {
    final groups = await vault.groups(id);
    if (groups.isEmpty || groups.any((g) => g.provisional)) return null;
    return groups.last; // ascending generation
  }

  /// Memory about members that are gone goes too.
  void _forgetGone(ConversationContext context, List<MemberRecord> members) {
    final present = {for (final m in members) vaultDeviceIdHex(m.deviceId)};
    context.firstMiss.removeWhere((hex, _) => !present.contains(hex));
  }

  bool _counts(DeviceList list, DateTime accepted) {
    final at = list.fetchedAt;
    return list.readable &&
        at != null &&
        fetchCounts(fetchedAt: at, acceptedSeenAt: accepted);
  }

  bool _lists(DeviceList list, Uint8List deviceId) =>
      list.devices.any((d) => _same(d.deviceId, deviceId));
}
