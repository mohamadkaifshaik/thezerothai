part of 'removal_queue_runner.dart';

/// One conversation's turn in a pass (a pure move out of the runner, fix
/// round 3, ruling 3): the attempt, the devices it may remove, and the
/// prune of the conversation's entries against its pins.
extension _RemovalAttempt on RemovalQueueRunner {
  /// One conversation's turn. True: RATE_LIMITED by a limit of the whole
  /// user, the pass stops. [own]: the own list this pass read fresh (or
  /// reused while young, ruling 6), null when it read none.
  Future<bool> _attempt(
    SecureVault vault,
    String id,
    Uint8List thisDevice,
    BudgetPriority priority,
    int resets,
    DeviceList? own,
  ) async {
    // Fix round 4, ruling 3 (CR2 M-1): an entry with no removed mark was
    // queued because one own list did not show its device. When this
    // pass's list names it again, the miss was a glitch: the entry goes,
    // so it never freezes into a later removal (and the flapping that
    // would follow). An entry of the user's removal has a mark.
    // Fix round 5, ruling 2 (R1): never on a list fetched before the last
    // removal; it may still name the device just removed.
    if (own != null &&
        own.readableNonEmpty &&
        !_beforeLastRemoval(own) &&
        _dropListed(id, own)) {
      await _save(vault);
    }
    // Parked entries wait for their hook; no call. CR Minor 6 (fix round 2,
    // ruling 8): they are pruned first, under the lock and from the stored
    // pins only (read only, no call), so one whose device another commit
    // already removed lets go now instead of at the un-park. Fix round 3,
    // ruling 1: only while those pins are caught up ([_pinsCaughtUp]).
    if (_entries.every((e) => e.conversationId != id || e.parked)) {
      await _locks.run(id, () async {
        if (!_current(vault, resets)) return;
        if (await _prune(vault, id, thisDevice)) await _save(vault);
      });
      return false;
    }
    final context = _contexts.of(id);
    final accepted =
        (await vault.conversation(id))?.sync.requestAccepted ?? false;
    if (!accepted || !context.canReply) {
      // R10, and a thread that cannot be answered: parked (the device's
      // pin is checked first, so a non-member entry goes instead).
      await _locks.run(id, () async {
        // Fix round 5, ruling 3 (m3): after the read and the lock's wait, a
        // reset() (and a reload) must not see this pass park its queue.
        if (!_current(vault, resets)) return;
        await _prune(vault, id, thisDevice);
        _park(id);
        await _save(vault);
      });
      return false;
    }
    if (!context.syncedSinceStart) {
      // A commit needs a live pull of the current pair this run; the pull
      // takes the lock itself, so it runs before the hold.
      await _receiver.pullLive(id, priority: priority);
    }
    return _locks.run(
      id,
      () => _attemptLocked(vault, id, thisDevice, priority, resets),
    );
  }

  Future<bool> _attemptLocked(
    SecureVault vault,
    String id,
    Uint8List thisDevice,
    BudgetPriority priority,
    int resets,
  ) async {
    // Fix round 4, ruling 4 (CR2 M-2): here and after the catch-up, the
    // pass's own check ([_current]): a reset() and a reload meanwhile must
    // not let this pass commit for the next run's queue.
    if (!_current(vault, resets)) return false;
    final groups = await vault.groups(id);
    if (groups.isEmpty || groups.any((g) => g.provisional)) {
      // No current group yet: no pin is caught up, so only this device's
      // own entries go (fix round 3, ruling 1); the rest wait for it.
      if (await _prune(vault, id, thisDevice)) await _save(vault);
      return false;
    }
    final limitBefore = _commits.lastRateLimitIn(id);
    // Ruling 1 (fix round 3): this hold's own catch-up ended current.
    var caughtUp = false;
    CommitOutcome outcome;
    if (groups.last.hasPending) {
      // The one attempt is the resume of the pending record (it may be this
      // queue's earlier removal).
      outcome = await _commits.resumePendingLocked(id, priority: priority);
    } else {
      if (await _crypto.catchUpLocked(id, priority: priority) !=
          CatchUpResult.current) {
        if (await _prune(vault, id, thisDevice)) await _save(vault);
        return false;
      }
      if (!_current(vault, resets)) return false;
      caughtUp = true;
      final members = await vault.members(id);
      if (_pruneAgainst(id, members, thisDevice, caughtUp: true)) {
        await _save(vault);
      }
      // Fix round 4, ruling 11 (SA N2): the key history, read only when an
      // unattributed pin could be removed through its mark.
      final history = members.any((m) => m.side == MemberSide.unattributed)
          ? await _crypto.keyHistory.of(
              vault,
              id,
              currentPins: members,
              formerPins: await const FormerPins().of(vault, id),
            )
          : null;
      var removes = _removable(id, members, history);
      if (removes.isEmpty) return false;
      // Ruling H: a removal the user asked for is exempt from the M5 pause
      // and the fail-closed ledger. Ruling 11: an entry the pass queued for
      // a lost own device (no removed mark) is not; when only the exemption
      // would let the change go, it carries the user's removals alone.
      var exempt = false;
      if (!await _commits.mayCommit(id, PendingKind.change)) {
        removes = [
          for (final d in removes)
            if (_removedByUser(d)) d,
        ];
        if (removes.isEmpty ||
            !await _commits.mayCommit(
              id,
              PendingKind.change,
              pauseExempt: true,
            )) {
          return false;
        }
        exempt = true;
      }
      outcome = await _commits.changeLocked(
        id,
        removeDeviceIds: removes,
        priority: priority,
        pauseExempt: exempt,
      );
    }
    // CR Minor 5 (fix round 2, ruling 7): a reset() or a vault change
    // during the attempt ends the pass here: no hold is written and no
    // timer armed for a queue that is no longer this run's.
    if (!_current(vault, resets)) return true;
    final limit = _commits.lastRateLimitIn(id);
    final rateLimited =
        outcome == CommitOutcome.refused &&
        limit != null &&
        !identical(limit, limitBefore);
    var changed = await _prune(vault, id, thisDevice, caughtUp: caughtUp);
    if (rateLimited) {
      final at = _now().add(_retryWait(limit));
      if (limit.limitName == kLimitCommitsPerConversationDaily) {
        // Review I2: this conversation's own daily cap holds it alone (in
        // memory); the pass goes on, so the lost device leaves every other
        // conversation now.
        _holds[id] = at;
        if (changed) await _save(vault);
        return false;
      }
      _notBeforeMicros = at.microsecondsSinceEpoch;
      await _save(vault);
      _armTimer(at, resets);
      return true;
    }
    if (outcome == CommitOutcome.refused && !_contexts.of(id).canReply) {
      // CANNOT_MESSAGE: parked until the conversation is usable again.
      _park(id);
      changed = true;
    }
    if (changed) await _save(vault);
    return false;
  }

  /// The queued members of [id] this pass may remove: `mine` pins (review
  /// I1; a `theirs` one was pruned already), and (ruling 1, fix round 2)
  /// an `unattributed` pin whose key is the key of the user's removed mark
  /// ([_removedKeyOf]): RemoveKeyDevice took the device out of the own
  /// list, so it can never be attributed, and the mark with the same key is
  /// positive proof it is this user's device. Any other `unattributed` one
  /// waits for its attribution; one whose key differs from its mark's is
  /// reported (`removalQueue.keyMismatch`, once per conversation and run).
  /// Never this device (pruned already). Only these two kinds of pin are
  /// ever removed, so a peer's device (`theirs`) is never touched by the
  /// queue (fix round 2, ruling 9: the last-device backstop, which no pin
  /// could reach, is gone).
  ///
  /// Fix round 4, ruling 11 (SA N2): a marked `unattributed` pin goes only
  /// when [history] answers `none` for its (id, key) pair (not `unrecorded`,
  /// `unreadable`, nor, fix round 5, ruling 1, `tainted`), never weaker
  /// than the guard M2 has (`mayRemoveUnattributed`): a hostile
  /// own list must not let the mark skip the key-history guards. Otherwise
  /// the entry stays and is reported (`removalQueue.keyHistory`, once per
  /// conversation and run). No [history]: unreadable.
  List<Uint8List> _removable(
    String id,
    List<MemberRecord> members,
    KeyHistory? history,
  ) {
    final queued = queuedFor(id);
    final out = <Uint8List>[];
    for (final m in members) {
      if (!queued.any((q) => _same(q, m.deviceId))) continue;
      if (m.side == MemberSide.unattributed) {
        final key = _removedKeyOf(m.deviceId);
        if (key == null) continue;
        if (!_same(key, m.signatureKey)) {
          if (_mismatchReported.add(id)) _reportBug('removalQueue.keyMismatch');
          continue;
        }
        final refusal =
            history?.refusal(vaultDeviceIdHex(m.deviceId), m.signatureKey) ??
            KeyRefusal.unreadable;
        // Fix round 5, ruling 1 (m1): `tainted` too. The runner holds no
        // lists here, so it cannot tell whether a list shows the pair (M2's
        // allowance); it refuses every tainted pair, never weaker than M2.
        if (refusal == KeyRefusal.unrecorded ||
            refusal == KeyRefusal.unreadable ||
            refusal == KeyRefusal.tainted) {
          if (_historyReported.add(id)) _reportBug('removalQueue.keyHistory');
          continue;
        }
      } else if (m.side != MemberSide.mine) {
        continue;
      }
      out.add(m.deviceId);
    }
    return out;
  }

  /// Ruling 3 (fix round 4): drops [id]'s entries that have no removed mark
  /// and whose device the readable [own] list names. True when the queue
  /// changed.
  bool _dropListed(String id, DeviceList own) {
    final before = _entries.length;
    _entries.removeWhere(
      (e) =>
          e.conversationId == id &&
          !_removedByUser(e.deviceId) &&
          own.devices.any((d) => _same(d.deviceId, e.deviceId)),
    );
    if (!_entries.any((e) => e.conversationId == id)) _holds.remove(id);
    final changed = _entries.length != before;
    if (changed) _publish();
    return changed;
  }

  /// [_pruneAgainst] from the stored pins of [id]. [caughtUp]: the caller
  /// read them after its own catch-up ended `current` in this lock hold;
  /// otherwise they count as caught up only when [_pinsCaughtUp] says so.
  Future<bool> _prune(
    SecureVault vault,
    String id,
    Uint8List thisDevice, {
    bool caughtUp = false,
  }) async => _pruneAgainst(
    id,
    await vault.members(id),
    thisDevice,
    caughtUp: caughtUp || await _pinsCaughtUp(vault, id),
  );

  /// Fix round 3, ruling 1 (F1): the stored pins of [id] hold every commit
  /// this device knows of: the current group's pair is the server pair the
  /// last catch-up of this run listed (`serverPairFresh`). False with no
  /// current group, a provisional one, no listing this run (a restart), or
  /// a listed pair this device has not reached. A commit posted after that
  /// listing is not known to it (stated limit, the fix-round-3 report).
  Future<bool> _pinsCaughtUp(SecureVault vault, String id) async {
    final context = _contexts.of(id);
    final server = context.serverPair;
    if (!context.serverPairFresh || server == null) return false;
    final groups = await vault.groups(id);
    if (groups.isEmpty || groups.any((g) => g.provisional)) return false;
    final group = groups.last;
    return MlsPair(group.generation, group.epoch) == server;
  }

  /// Drops [id]'s entries naming this device, and, when [caughtUp], those
  /// whose device is no longer pinned there and (review I1) those whose
  /// device is pinned on the peer's side: it is not this user's device to
  /// remove. That last case is reported (`removalQueue.notOwn`): an own id
  /// was attributed to the peer. True when the queue changed.
  ///
  /// Fix round 3, ruling 1 (F1): on pins this device has not caught up
  /// ([caughtUp] false) only this device's own entries go. A peer's commit
  /// not applied yet may add the device (it is then pinned `unattributed`
  /// once applied, and the entry with the removed mark's key removes it);
  /// dropping the entry on the stale pins would leave the lost device
  /// reading until reconcile's M2 removal found it.
  bool _pruneAgainst(
    String id,
    List<MemberRecord> members,
    Uint8List thisDevice, {
    required bool caughtUp,
  }) {
    final before = _entries.length;
    final notOwn = <Uint8List>[];
    var conflict = false;
    _entries.removeWhere((e) {
      if (e.conversationId != id) return false;
      if (_same(e.deviceId, thisDevice)) return true;
      if (!caughtUp) return false;
      final pinned = members.where((m) => _same(m.deviceId, e.deviceId));
      if (pinned.isEmpty) return true;
      final theirs = pinned.where((m) => m.side == MemberSide.theirs);
      if (theirs.isNotEmpty) {
        // Fix round 4, ruling 9 (CR2 M-7): a peer-side pin with the key the
        // user's own list showed for the removed device is evidence the
        // device is ours, attributed to the peer by the server: the mark
        // stays (it keeps answering wasRemovedByUser) and a key conflict is
        // reported (5b offers a reset). The entry still goes: the queue
        // never removes a peer-side pin.
        final key = _removedKeyOf(e.deviceId);
        if (key != null && theirs.any((m) => _same(m.signatureKey, key))) {
          conflict = true;
        } else {
          notOwn.add(e.deviceId);
        }
        return true;
      }
      return false;
    });
    if (conflict) _reportBug('removalQueue.keyConflict');
    if (notOwn.isNotEmpty) {
      // SA L2 (fix round 2, ruling 13): not this user's device, so not one
      // the user removed either: its mark goes too (written with the
      // queue by the caller's save).
      _removed.removeWhere(
        (m) => notOwn.any((d) => _same(utf8.encode(m.deviceId), d)),
      );
      _reportBug('removalQueue.notOwn');
    }
    if (!_entries.any((e) => e.conversationId == id)) _holds.remove(id);
    final changed = _entries.length != before;
    if (changed) _publish();
    return changed;
  }
}
