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
  /// exists to make a change, so it pulls first when not synced. Never
  /// throws.
  Future<void> _reconcileUnheld(
    String id,
    BudgetPriority priority, {
    required bool recheck,
  }) async {
    try {
      if (recheck && !_contexts.of(id).syncedSinceStart) {
        await _receiver.pullLive(id, priority: priority);
      }
      final first = await _locks.run(
        id,
        () => _reconcileOnce(id, priority, recheck: recheck),
      );
      if (first != CommitOutcome.applied && first != CommitOutcome.superseded) {
        return;
      }
      await _receiver.pullLive(id, priority: priority);
      await _locks.run(
        id,
        () => _reconcileOnce(id, priority, recheck: recheck),
      );
    } on Object catch (e, s) {
      _reportIfBug(e, s, 'upkeep.reconcile');
    }
  }

  /// The held entry (the acceptance steps, [MembershipUpkeep
  /// .reconcileLocked]). It cannot pull: after `superseded` the second pass
  /// commits only while still synced, else it arms one re-check (review I1
  /// c). [recheck]: no self-update (R9 runs only from an open or a send).
  /// Never throws.
  Future<void> _reconcileLocked(
    String id,
    BudgetPriority priority, {
    required bool recheck,
  }) async {
    try {
      // Plan step 4: after `superseded`, once more on the caught-up group.
      for (var round = 0; round < 2; round++) {
        if (await _reconcileOnce(id, priority, recheck: recheck) !=
            CommitOutcome.superseded) {
          return;
        }
      }
    } on Object catch (e, s) {
      _reportIfBug(e, s, 'upkeep.reconcile');
    }
  }

  /// One pass. Answers how this device's commit of the pass ended (its
  /// change, else the resume of a pending record when that settled it);
  /// null when it made none.
  Future<CommitOutcome?> _reconcileOnce(
    String id,
    BudgetPriority priority, {
    required bool recheck,
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
      if (settled == CommitOutcome.pending) return null;
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
    // Task 11's queue: the members it names (never this device).
    final queued = queuedRemovals?.call(id) ?? const <Uint8List>{};
    for (final m in members) {
      if (!_same(m.deviceId, thisDevice) &&
          queued.any((q) => _same(q, m.deviceId))) {
        remove(m.deviceId);
      }
    }
    // M3: one readable own list decides.
    for (final m in members) {
      if (mayRemoveOwnDevice(
        member: m,
        ownList: own,
        thisDeviceId: thisDevice,
      )) {
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
      _scheduleRecheck(id, recheckAt.first);
    }

    final staying = [
      for (final m in members)
        if (!removing.contains(vaultDeviceIdHex(m.deviceId))) m,
    ];
    final mayAdd = _session.mayStart && !unverifiable;

    // M5 and the rest of "may commit": no claim is spent on a change that
    // cannot be made now.
    if (!await _commits.mayCommit(id, PendingKind.change)) {
      // Review I1 c: a change decided while this run has not pulled the
      // current pair (after an own commit) waits for one re-check, which
      // pulls first. Only a pass that is not itself a re-check arms it, so
      // it cannot loop; other reasons (M5, the cap) make that re-check a
      // no-op.
      if (!recheck &&
          !context.syncedSinceStart &&
          (removes.isNotEmpty ||
              (mayAdd &&
                  (await _wanted(
                    own,
                    peer,
                    staying,
                    thisDevice,
                    history,
                  )).isNotEmpty))) {
        _scheduleRecheck(id, _now().add(kPeerRemovalFetchGap));
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
    var outcome = await _commits.changeLocked(
      id,
      adds: adds,
      removeDeviceIds: removes,
      priority: priority,
    );
    // Removals are never held back for adds: the flag went off meanwhile.
    if (outcome == CommitOutcome.notAllowed &&
        adds.isNotEmpty &&
        removes.isNotEmpty &&
        !_session.mayStart) {
      outcome = await _commits.changeLocked(
        id,
        removeDeviceIds: removes,
        priority: priority,
      );
    }
    if (outcome == CommitOutcome.applied) _onChanged(id);
    return outcome;
  }

  /// `devicesToAdd`, without the ids the key history would refuse and the
  /// devices whose claim came back empty today. Reads only.
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
  /// refuse and devices whose claim came back empty today), one claim per
  /// side that has a device to add, `inspectKeyPackage` and `checkClaims`
  /// (R3) against the lists of step 1. An empty claim is recorded for the
  /// IST day after the claims, outside any write body.
  Future<List<UsableClaim>> _claimAdds(
    String id,
    String? ref,
    DeviceList own,
    DeviceList peer,
    List<MemberRecord> members,
    Uint8List thisDevice,
    KeyHistory history,
    BudgetPriority priority,
  ) async {
    final wanted = await _wanted(own, peer, members, thisDevice, history);
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
      final checked = checkClaims(
        side: side,
        claimed: claimed,
        inspected: await _inspect(claimed),
        directory: mine ? own : peer,
        ownList: own,
        members: members,
        thisDeviceId: thisDevice,
        admissible: history.admissible,
      );
      empty.addAll(checked.emptyFor);
      return checked.usable;
    }

    final mine = await side(ClaimSide.mine);
    final theirs = await side(ClaimSide.theirs);
    for (final d in empty) {
      try {
        await _ledger.markEmptyClaim(d);
      } on Object catch (e, s) {
        _reportIfBug(e, s, 'upkeep.emptyClaim');
      }
    }
    // A key or a device id claimed on both sides is on neither.
    bool onBoth(UsableClaim a, List<UsableClaim> other) => other.any(
      (b) =>
          _same(a.signatureKey, b.signatureKey) ||
          _same(a.deviceId, b.deviceId),
    );
    return [
      for (final c in mine)
        if (!onBoth(c, theirs)) c,
      for (final c in theirs)
        if (!onBoth(c, mine)) c,
    ];
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
  /// engine refuses, or an engine that cannot answer now).
  Future<List<KeyPackageInfo?>> _inspect(
    List<kpb.ClaimedKeyPackage> claimed,
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
      } on MlsException {
        out.add(null);
      }
    }
    return out;
  }

  /// The peer's user reference: this run's context, else the cached inbox
  /// row (noted as one). Null when neither knows it.
  Future<String?> _peerRef(String id) async {
    final context = _contexts.of(id);
    String? known() {
      final ref = context.peerUserId;
      return ref == null || ref.isEmpty ? null : ref;
    }

    if (known() != null) return known();
    final row = await _messaging.cachedConversation(id);
    if (row != null) _contexts.note(row);
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
