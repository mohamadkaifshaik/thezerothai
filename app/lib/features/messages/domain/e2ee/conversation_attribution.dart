part of 'conversation_crypto.dart';

/// Member attribution (M2, H2, R10; the conversation lock is held): both
/// device lists are read fresh outside the write body, then ONE `runWrite`
/// body re-reads the pins, the baseline and the key history and pins each
/// unattributed member the history admits to the side a list shows, with
/// its system rows, in ONE transaction. Also the peer reference lookup.
extension _Attribution on ConversationCrypto {
  /// The attribution entry points' body (the lock is held): the known set is
  /// loaded for the current vault like every other entry point. Never throws.
  Future<void> _attributeEntry(String id, BudgetPriority priority) async {
    // Task 12 fix round 1, I1: no device list (ListMyKeyDevices,
    // GetKeyDevices) and no pin while removed elsewhere. Pending stays as
    // it is: attribution runs again once the fact clears.
    if (_removedElsewhere()) return;
    try {
      final pass = await _startOperation(priority);
      if (pass == null) return;
      await _attributeMembersLocked(pass, id);
    } on _Stopped {
      // The vault changed: nothing was written.
    } on Object catch (e, s) {
      _reportIfBug(e, s, 'attribute');
    }
  }

  /// A member pinned by the FIRST join of the conversation (the sealed
  /// baseline record, [JoinBaselines], read fresh in the write body) is a
  /// baseline member: no peer-side row, and the own-device alert only per
  /// security read H2. Every other member (a later join, a member added by a
  /// commit) gets its `deviceAdded` row once attributed. A member whose
  /// (device id, key) the conversation's key history refuses is never
  /// attributed: it stays an unknown device. An ordinary unknown device
  /// (recorded with that one key; its row written by an earlier unknown
  /// verdict) is attributed once a list shows it.
  Future<void> _attributeMembersLocked(_Operation pass, String id) async {
    final priority = pass.priority;
    final vault = pass.vault;
    // I1: also for the callers inside a catch-up or a join.
    if (!pass.live || _removedElsewhere()) return;
    final context = _contexts.of(id);
    if (!(await vault.members(id))
        .any((m) => m.side == MemberSide.unattributed)) {
      context
        ..attributionPending = false
        ..attributionConcluded = true
        ..deferredSince = null;
      return;
    }
    final ref = await _peerRef(id, priority);
    // Plan 5a Task 12, brief amendment 8 (pre-flag fix round 3): the peer
    // ref the vault stored for this conversation binds attribution. A
    // header or first page naming another user decides nothing: no list
    // is fetched and nothing is attributed; the list reads as
    // unverifiable until the refs agree again.
    final stored = _known.peerOf(id);
    if (ref != null && stored != null && ref != stored) {
      context
        ..listUnverifiable = true
        ..attributionPending = false
        ..attributionConcluded = false;
      return;
    }
    final own = await _directory.own(fresh: true, priority: priority);
    final peer = ref == null
        ? const DeviceList.unreadable()
        : await _directory.peer(ref, fresh: true, priority: priority);
    final unreadable =
        own.state == ListState.unreadable || peer.state == ListState.unreadable;
    final deferred =
        !unreadable &&
        (own.state == ListState.deferred || peer.state == ListState.deferred);
    // The context changes this body decides: applied only after it returned
    // (its transaction committed, or nothing was to be written), never when
    // it throws, so memory never runs ahead of the vault.
    final unknownNow = <String>{};
    final attributedNow = <String>{};
    DateTime? reattributeAt;
    DateTime? decidedAt;
    DateTime? seenAt;
    final outcome = await _session.runWrite((v) async {
      pass.check(v);
      final baselineSince = await _baselines.of(v, id);
      final current = await v.members(id);
      // Fresh and cross-checked; attribution never writes the history.
      final history = await _keyHistory.of(
        v,
        id,
        currentPins: current,
        formerPins: await _formerPins.of(v, id),
      );
      final accepted =
          (await v.conversation(id))?.sync.requestAccepted ?? false;
      final now = _now();
      final acceptedSeenAt = accepted ? (context.acceptedSeenAt ?? now) : null;
      decidedAt = now;
      seenAt = acceptedSeenAt;
      // The peer fetch is the full registered list only from
      // kConversationCopyStale after this run knew the conversation accepted.
      final peerFetched = peer.fetchedAt;
      final counts =
          !unreadable &&
          !deferred &&
          peerFetched != null &&
          fetchCounts(fetchedAt: peerFetched, acceptedSeenAt: acceptedSeenAt);
      var waiting = false;
      final everMine = accepted
          ? await _formerPins.everPinnedMine(v, excluding: id)
          : const <({String deviceIdHex, String keyB64})>{};
      final brandNew = accepted && baselineSince != null
          ? await _formerPins.brandNewVault(v, excluding: id)
          : false;
      final nowMicros = _now().microsecondsSinceEpoch;
      final pins = <MemberRecord>[];
      final rows = <StoredMessage>[];
      var stillUnattributed = false;
      var theirsFromPeer = false;
      var baselineLeft = false;
      for (final m in current) {
        if (m.side != MemberSide.unattributed) continue;
        final hex = vaultDeviceIdHex(m.deviceId);
        // A pair the key history refuses ([DeviceKeyHistory]: a tainted id,
        // an id it does not hold, every member while it is unreadable)
        // stays an unknown device whatever the lists now say. Checked
        // before the lists decide anything. Its row is display only:
        // written once the conversation is accepted (R10), never from an
        // unreadable history.
        final refusal = history.refusal(hex, m.signatureKey);
        if (refusal != KeyRefusal.none) {
          stillUnattributed = true;
          if (m.since == baselineSince) baselineLeft = true;
          unknownNow.add(hex);
          if (accepted && refusal != KeyRefusal.unreadable) {
            final row = _systemRow(
              id,
              m.since,
              SystemLine.unknownDevice,
              nowMicros,
              deviceId: m.deviceId,
            );
            if (!await v.hasMessage(id, row.messageId)) rows.add(row);
          }
          continue;
        }
        final side = attribute(
          deviceId: m.deviceId,
          signatureKey: m.signatureKey,
          ownList: own,
          peerList: peer,
        );
        if (side == MemberSide.unattributed) {
          if (m.since == baselineSince) baselineLeft = true;
          stillUnattributed = true;
          // R10: unaccepted, an unmatched member just stays unattributed.
          // An unreadable or deferred list decides nothing (handled below).
          if (!accepted || unreadable || deferred) continue;
          if (!counts) {
            // The server may still answer with active devices only: no row,
            // no flag; one re-attribution at the time the fetch counts.
            waiting = true;
            reattributeAt = acceptedSeenAt!.add(kConversationCopyStale);
            continue;
          }
          // M2: unknown with both lists readable and a counting fetch. One
          // row per device and pair (the stored row is the record of it).
          unknownNow.add(hex);
          final row = _systemRow(
            id,
            m.since,
            SystemLine.unknownDevice,
            nowMicros,
            deviceId: m.deviceId,
          );
          if (!await v.hasMessage(id, row.messageId)) rows.add(row);
          continue;
        }
        attributedNow.add(hex);
        if (side == MemberSide.theirs) theirsFromPeer = true;
        pins.add(
          MemberRecord(
            conversationId: id,
            deviceId: m.deviceId,
            signatureKey: m.signatureKey,
            side: side,
            since: m.since,
          ),
        );
        // R10: no system row of any kind while unaccepted.
        if (!accepted) continue;
        final baseline = baselineSince != null && m.since == baselineSince;
        final bool row;
        if (side == MemberSide.mine) {
          // H2: at a first join only an own-side pair this vault never
          // pinned mine in another accepted conversation alerts, and not on
          // a brand-new vault; after any other join every new key does.
          row =
              !baseline ||
              (!brandNew &&
                  !everMine.contains((
                    deviceIdHex: vaultDeviceIdHex(m.deviceId),
                    keyB64: base64Encode(m.signatureKey),
                  )));
        } else {
          row = !baseline;
        }
        if (row) {
          rows.add(
            StoredMessage(
              conversationId: id,
              messageId: systemLineId(
                id,
                m.since,
                SystemLine.deviceAdded,
                deviceId: m.deviceId,
              ),
              createdAtMicros: nowMicros,
              mine: false,
              state: StoredMessageState.visible,
              generation: m.since.generation,
              epoch: m.since.epoch,
              content: SystemLineContent(
                line: SystemLine.deviceAdded,
                deviceId: m.deviceId,
                side: side,
              ).encode(),
              kind: StoredMessageKind.system,
            ),
          );
        }
      }
      // Pending: a member is unattributed for a reason a later attribution
      // may settle (a list not readable or deferred, a fetch not counting
      // yet). An unreadable or deferred list is retried in an unaccepted
      // conversation too (it writes no row there); an unmatched member of an
      // unaccepted one is not (the lookup there means nothing).
      final pending =
          stillUnattributed &&
          (unreadable || deferred || (accepted && waiting));
      // I-2: the baseline goes once no member at its `since` is unattributed.
      final dropBaseline = baselineSince != null && !baselineLeft;
      if (pins.isEmpty && rows.isEmpty && !dropBaseline) {
        return (wrote: false, pending: pending, knownGrew: false);
      }
      var knownGrew = false;
      try {
        await v.transaction((tx) async {
          for (final p in pins) {
            await tx.putMember(p);
          }
          for (final r in rows) {
            await tx.putMessage(r);
          }
          if (dropBaseline) await _baselines.deleteIn(tx, v, id);
          // C1 / N3: the ref whose list the theirs-side pins came from.
          if (theirsFromPeer && ref != null) {
            knownGrew = await _known.addIn(tx, v, id, peerUserId: ref);
          }
        });
      } on Object {
        _known.discardStaged();
        rethrow;
      }
      _known.commitStaged();
      return (
        wrote: pins.isNotEmpty || rows.isNotEmpty,
        pending: pending,
        knownGrew: knownGrew,
      );
    });
    // The body returned: its decisions reach memory now.
    final at = decidedAt;
    final seen = seenAt;
    if (seen != null) context.acceptedSeenAt ??= seen;
    if (at != null) {
      for (final hex in unknownNow) {
        context.firstSeenUnattributed[hex] ??= at;
        context.unknownDevices.add(hex);
      }
    }
    for (final hex in attributedNow) {
      context.unknownDevices.remove(hex);
      context.firstSeenUnattributed.remove(hex);
    }
    if (reattributeAt != null) context.reattributeAt = reattributeAt;
    // As an applied commit (I-4): the known set grew in that transaction.
    if (outcome.knownGrew) {
      try {
        await _messaging.noteEverEncrypted(id, session: pass.cacheSession);
      } on Object catch (e, s) {
        _reportIfBug(e, s, 'noteEverEncrypted');
      }
    }
    final now = _now();
    final unattributedLeft = (await vault.members(id))
        .any((m) => m.side == MemberSide.unattributed);
    if (unreadable) {
      context.listUnverifiable = true;
    } else if (deferred) {
      // M4: silent while deferred, up to kDeferredWithUnattributedLimit with
      // an unattributed member; then it reads as unreadable.
      if (unattributedLeft) context.deferredSince ??= now;
      if (deferralOutlasted(
        deferredSince: context.deferredSince,
        unattributedPresent: unattributedLeft,
        now: now,
      )) {
        context.listUnverifiable = true;
      }
    } else {
      context
        ..deferredSince = null
        ..listUnverifiable = false;
    }
    context
      ..attributionPending = outcome.pending
      ..attributionConcluded = !outcome.pending;
    if (!outcome.pending) context.reattributeAt = null;
    if (outcome.wrote) _onChanged(id);
  }

  /// The peer's user reference: this run's context, else the cached header,
  /// else the first `ListMessages` page. Null when none is known.
  Future<String?> _peerRef(String id, BudgetPriority priority) async {
    final context = _contexts.of(id);
    String? known() {
      final ref = context.peerUserId;
      return ref == null || ref.isEmpty ? null : ref;
    }

    if (known() != null) return known();
    final row = await _messaging.cachedConversation(id);
    // A cached row gives the peer only: it is no sight (review m5).
    if (row != null) _contexts.note(row, peerOnly: true);
    if (known() != null) return known();
    if (!await _takeSyncUnit(priority)) return null;
    final page = await _messaging.listMlsMessages(conversationId: id);
    if (page.hasConversation()) _contexts.note(page.conversation);
    return known();
  }
}
