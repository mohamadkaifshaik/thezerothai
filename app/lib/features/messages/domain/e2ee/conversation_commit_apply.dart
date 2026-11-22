part of 'conversation_crypto.dart';

/// Applying one commit during catch-up (the conversation lock is held): the
/// epoch's messages are completed first, then the engine's confirm or
/// process and the commit's ONE transaction (pins, rows, group, marks, known
/// set, key history) run in ONE `runWrite` body.
extension _CommitApply on ConversationCrypto {
  /// Step 4 for the commit at [at]: confirm (own, by bytes) or process, then
  /// ONE transaction with the result, in one runWrite body.
  ///
  /// When the commit is this device's own pending one, its adds are pinned
  /// with the sides this run remembers for it (Task 9,
  /// [ConversationCrypto.rememberOwnAdds]): on every path that confirms it,
  /// the runner's direct confirm and any caller's catch-up alike.
  Future<_Applied> _applyLocked(
    _Operation pass,
    String id,
    MlsPair at,
    pb.ConversationCommit commit,
  ) async {
    // Read before the body: only the sides remembered for THIS pair.
    final remembered = _ownAdds[id];
    final ownAdds = remembered != null && remembered.builtOn == at
        ? remembered.sides
        : const <String, _CheckedAdd>{};
    try {
      final sink = this.sink;
      if (sink != null) {
        await sink.completeEpoch(id, at, priority: pass.priority);
        // Never a commit applied while its close walk has not ended (§5.1).
        if (!await sink.epochWalkDone(id, at)) return _Applied.interrupted;
      }
    } on Object catch (e, s) {
      _reportIfBug(e, s, 'completeEpoch');
      return _Applied.interrupted;
    }
    final _Applied applied;
    // The known set grew in the applied commit's transaction (a migrated v1
    // group that was never in it).
    var knownGrew = false;
    // A member was pinned unattributed in the applied commit's transaction:
    // the context hears of it only after the body returned.
    var newMember = false;
    // The applied commit was this device's own pending one (by its bytes).
    var ownConfirmed = false;
    try {
      applied = await _session.runWrite((v) async {
        pass.check(v);
        final group = await v.group(id, at.generation);
        if (group == null || group.provisional || group.epoch != at.epoch) {
          return _Applied.interrupted;
        }
        final deviceState = await v.deviceState();
        if (deviceState == null) return _Applied.interrupted;
        final record = await v.conversation(id);
        final pins = await v.members(id);
        final engine = _engine();
        final bytes = Uint8List.fromList(commit.commit);
        final pending = group.pending;
        final Uint8List next;
        MlsCommitEvent? event;
        GroupDescription? described;
        final own = pending != null && _sameBytes(bytes, pending.commit);
        try {
          if (own) {
            // This device's own accepted commit: merged, never processed.
            next = await engine.confirmCommit(deviceState, group.state);
          } else {
            var state = group.state;
            // A migrated v1 group with a pending commit and no record.
            if (pending == null &&
                (await engine.describe(state)).hasPendingCommit) {
              state = await engine.discardCommit(deviceState, state);
            }
            final result = await engine.process(deviceState, state, bytes);
            final ev = result.event;
            // An application message in the commit list is unprocessable.
            if (ev is! MlsCommitEvent) return _Applied.stuck;
            event = ev;
            next = result.groupState;
          }
          if (event == null || !event.selfRemoved) {
            described = await engine.describe(next);
          }
        } on MlsException catch (err) {
          return _transient(err.code) ? _Applied.interrupted : _Applied.stuck;
        }
        final written = await _writeApplied(
          v,
          id,
          at,
          next: next,
          event: event,
          described: described,
          record: record,
          pins: pins,
          thisDevice: pass.deviceId,
          ownPending: own ? pending : null,
          ownAdds: own ? ownAdds : const {},
        );
        knownGrew = written.knownGrew;
        newMember = written.newMember;
        ownConfirmed = own;
        return event?.selfRemoved ?? false ? _Applied.selfRemoved : _Applied.ok;
      });
    } on _Stopped {
      return _Applied.interrupted;
    } on Object catch (e, s) {
      _reportIfBug(e, s, 'applyCommit');
      return _Applied.interrupted;
    }
    if (newMember) {
      _contexts.of(id)
        ..attributionConcluded = false
        ..attributionPending = true;
    }
    if (ownConfirmed) _ownConfirmed[id] = at;
    if (applied == _Applied.ok || applied == _Applied.selfRemoved) {
      // The pair is settled (this device's commit or a winner): the sides
      // remembered for a commit built on it have been used or are void.
      if (remembered != null && remembered.builtOn == at) _ownAdds.remove(id);
      _onChanged(id);
    }
    if (knownGrew) {
      try {
        await _messaging.noteEverEncrypted(id, session: pass.cacheSession);
      } on Object catch (e, s) {
        _reportIfBug(e, s, 'noteEverEncrypted');
      }
    }
    return applied;
  }

  /// The one transaction of an applied commit (inside the runWrite body that
  /// computed [next]). `newMember`: a member was pinned unattributed (added,
  /// or a changed key); `knownGrew`: the id was added to the known set.
  ///
  /// [ownPending]: the commit is this device's own (its pending record);
  /// [ownAdds]: the side and signature key its added devices were checked
  /// with, when this run still knows them.
  ///
  /// M5, in this same transaction (`DailyLedger.writeIn`): a commit by
  /// another device that undoes an own change of today raises the undo
  /// count; an own commit records what it added and removed. The ledger
  /// record is read in this `runWrite` body (`readLocked`, which the ledger
  /// provides for it), not in a `runWrite` of its own before the body: one
  /// write lock less per applied commit, and a fresher record. The undo is
  /// decided through the record's own method (an exhausted record counts
  /// every reversal).
  Future<({bool newMember, bool knownGrew})> _writeApplied(
    SecureVault v,
    String id,
    MlsPair at, {
    required Uint8List next,
    required MlsCommitEvent? event,
    required GroupDescription? described,
    required ConversationRecord? record,
    required List<MemberRecord> pins,
    required Uint8List thisDevice,
    PendingCommit? ownPending,
    Map<String, _CheckedAdd> ownAdds = const {},
  }) async {
    final nextPair = at.next;
    final sync = record?.sync ?? const ConversationSync();
    final accepted = sync.requestAccepted;
    final nowMicros = _now().microsecondsSinceEpoch;
    // L6's checks (the join's delete, `_unwalked`) only ever look for a
    // stored group's CURRENT (generation, epoch). After this commit the
    // group of `at.generation` is at `at.next`, so no entry of that
    // generation (`at` included) can match again: only the walked last
    // epochs of the other stored generations are kept (at most one each).
    final completed = [
      for (final p in sync.completedEpochs)
        if (p.generation != at.generation) p,
    ];
    final needKnown = !_known.contains(id);
    final groups = await v.groups(id);
    // Read fresh in this body: the key history, cross-checked against the
    // pins and the former pins ([DeviceKeyHistory]).
    final former = await _formerPins.of(v, id);
    final history = await _keyHistory.of(
      v,
      id,
      currentPins: pins,
      formerPins: former,
    );
    var newMember = false;
    // M5: a membership change by another device, measured against this
    // device's own changes of today.
    final byOther =
        event != null &&
        !_sameBytes(event.committerDeviceId, thisDevice) &&
        (event.added.isNotEmpty || event.removed.isNotEmpty);
    final daily = byOther || ownPending != null
        ? await _ledger.readLocked(v)
        : null;
    final undo =
        byOther &&
        daily != null &&
        daily.undoesOwnChange(id, added: event.added, removed: event.removed);
    // A theirs pin was written below (only ever for an own add), and the
    // peer's reference as this run knows it (memory, read before the
    // transaction; attribution's lookup makes calls and cannot run here).
    var ownTheirs = false;
    final peerRef = _contexts.of(id).peerUserId;
    // What this device's own commit added (the members its welcome was
    // addressed to) and removed (the pins deleted below).
    final ownAdded = <Uint8List>[];
    final ownRemoved = <Uint8List>[];
    // The server addresses a welcome by the device id as text.
    final ownWelcomed = {
      for (final device in ownPending?.welcomeDeviceIds ?? const <String>[])
        vaultDeviceIdHex(Uint8List.fromList(utf8.encode(device))),
    };
    try {
      await v.transaction((tx) async {
        if (undo) {
          await _ledger.writeIn(
            tx,
            daily,
            (r) => r.withUndoCounted(
              id,
              added: event.added,
              removed: event.removed,
            ),
          );
        }
        if (event != null && event.selfRemoved) {
          // This device was removed: groups and pins go; the pins are kept
          // as former pins (H2) and the rejoin is compared with them.
          //
          // Task 10 review I-1: except this device's own provisional RESET
          // of a higher generation (with its stage-encrypted rows, which
          // this branch never touches). The server checks only a reset's
          // generation, so it may hold that reset (or a call of it may
          // still land) although this device was removed in g: deleting it
          // here would leave the server at g + 1 with this device's leaf
          // and this device without g + 1's state, every message of g + 1
          // lost for 24 h. The reset's own settle or discard decides (the
          // starter's record rules); a settle reads the former pins kept
          // here, so a member kept from g gets no `deviceAdded` row.
          //
          // Review N-1: the kept reset is marked in the vault
          // (`keptAfterSelfRemoval`), and no call of it is ever made again:
          // a resend would put this device, removed in g, back into g + 1.
          // Only the server's record decides it (ours settles; another
          // record or nothing stored drops it after the margin).
          for (final group in groups) {
            final pending = group.pending;
            if (group.provisional &&
                group.generation > at.generation &&
                pending != null &&
                pending.kind == PendingKind.reset) {
              if (!pending.keptAfterSelfRemoval) {
                await tx.putGroup(
                  GroupRecord(
                    conversationId: group.conversationId,
                    generation: group.generation,
                    epoch: group.epoch,
                    state: group.state,
                    pending: pending.keptBySelfRemoval(),
                    provisional: true,
                    provisionalCreatedAtMicros:
                        group.provisionalCreatedAtMicros,
                  ),
                );
              }
              continue;
            }
            await tx.deleteGroup(id, group.generation);
          }
          for (final p in pins) {
            await tx.deleteMember(id, p.deviceId);
          }
          await _formerPins.putIn(tx, v, id, pins);
          // The rejoin is never a first join: no baseline is kept.
          await _baselines.deleteIn(tx, v, id);
          // The key history is untouched (nothing ever shrinks it): it
          // already holds every pin kept here, and a rejoin is admitted
          // against it.
          if (MlsPair.above(at, record?.afterPair)) {
            await tx.setAfterPair(id, at);
          }
          await tx.clearSentBefore(id, nextPair);
          await tx.putConversationSync(
            id,
            sync.copyWith(
              // Every group was deleted: nothing is left for L6 to check.
              completedEpochs: const [],
              epochMustAdvance: false,
              firstSawGeneration: at.generation,
              firstSawGenerationAtMicros: nowMicros,
            ),
          );
          if (needKnown) await _known.addIn(tx, v, id);
          return;
        }
        final byHex = {for (final p in pins) vaultDeviceIdHex(p.deviceId): p};
        final thisHex = vaultDeviceIdHex(thisDevice);
        final members = described?.members ?? const <GroupMember>[];
        final inGroup = {for (final m in members) vaultDeviceIdHex(m.deviceId)};
        // Removed: from the event, or (an own commit, no event) the pins the
        // group no longer has.
        final removed = event != null
            ? [for (final r in event.removed) vaultDeviceIdHex(r)]
            : [
                for (final hex in byHex.keys)
                  if (hex != thisHex && !inGroup.contains(hex)) hex,
              ];
        for (final hex in removed) {
          final pinned = byHex.remove(hex);
          if (pinned == null) continue;
          // The own removals are the deleted pins: the pending record
          // holds no list of what the commit removed (review m4), so a
          // member this device removed that had no pin is not recorded as
          // an own change, and its re-add by another device counts no undo.
          if (ownPending != null) ownRemoved.add(pinned.deviceId);
          await tx.deleteMember(id, pinned.deviceId);
          // R10: no system row of any kind while unaccepted.
          if (!accepted) continue;
          await tx.putMessage(
            _systemRow(
              id,
              nextPair,
              SystemLine.deviceRemoved,
              nowMicros,
              deviceId: pinned.deviceId,
              side: pinned.side,
            ),
          );
        }
        // Added, and the (id, key) comparison after every commit: a member
        // not pinned, or pinned with another key, is pinned unattributed
        // with the key the group holds (never kept on its old side). Each is
        // admitted to the key history first, in this same transaction and
        // whatever the acceptance state: the history decides, not the pins
        // (a removed device's pin is gone, its recorded key is not). A pair
        // the history refuses (an id seen with another key, a new id while
        // the history is closed) is never attributed; its unknownDevice
        // row, display only, is written here in accepted conversations and
        // by attribution once one is accepted.
        final added = <String, Uint8List>{};
        if (event != null) {
          for (var i = 0; i < event.added.length; i++) {
            if (i < event.addedSignatureKeys.length) {
              added[vaultDeviceIdHex(event.added[i])] =
                  event.addedSignatureKeys[i];
            }
          }
        }
        for (final m in members) {
          final hex = vaultDeviceIdHex(m.deviceId);
          added[hex] = m.signaturePublicKey;
          // Review m4: what this device's own commit ADDED is what its
          // welcome was addressed to (the runner builds one welcome id per
          // add), not the pin diff below: a member that merely had no pin,
          // or a changed key, when an own self-update or removal was
          // confirmed is no change of this device.
          if (ownWelcomed.contains(hex)) ownAdded.add(m.deviceId);
        }
        for (final entry in added.entries) {
          if (entry.key == thisHex) continue;
          final pinned = byHex[entry.key];
          if (pinned != null && _sameBytes(pinned.signatureKey, entry.value)) {
            continue;
          }
          final deviceId = _deviceIdOf(entry.key, event, members);
          if (deviceId == null) continue;
          final refusal = history.admit(entry.key, entry.value);
          // Task 9: a device this device's own commit added keeps the side
          // it was claimed and checked for (R3), when this run still knows
          // it and the history admits the pair. Review m5 (plan-constraints
          // item 1, defence in depth): only when the key the group holds
          // for the member IS the key the claim was checked with; the
          // engine built the leaf from the checked package, so the two
          // agree unless something is wrong, and then the lists decide.
          // Every other new member is unattributed until a list shows it
          // (an own commit confirmed after a restart included).
          final checked = ownPending == null ? null : ownAdds[entry.key];
          final side =
              checked == null ||
                  refusal != KeyRefusal.none ||
                  !_sameBytes(checked.signatureKey, entry.value)
              ? MemberSide.unattributed
              : (checked.side == ClaimSide.mine
                    ? MemberSide.mine
                    : MemberSide.theirs);
          if (side == MemberSide.unattributed) newMember = true;
          if (side == MemberSide.theirs) ownTheirs = true;
          await tx.putMember(
            MemberRecord(
              conversationId: id,
              deviceId: deviceId,
              signatureKey: entry.value,
              side: side,
              since: nextPair,
            ),
          );
          // The row attribution would write for this member (the same id):
          // "device added", the own-device alert when the side is mine.
          // R10: no system row while unaccepted.
          if (side != MemberSide.unattributed && accepted) {
            await tx.putMessage(
              _systemRow(
                id,
                nextPair,
                SystemLine.deviceAdded,
                nowMicros,
                deviceId: deviceId,
                side: side,
              ),
            );
          }
          // No row from an unreadable history.
          if (accepted &&
              refusal != KeyRefusal.none &&
              refusal != KeyRefusal.unreadable) {
            final row = _systemRow(
              id,
              nextPair,
              SystemLine.unknownDevice,
              nowMicros,
              deviceId: deviceId,
            );
            if (!await v.hasMessage(id, row.messageId)) {
              await tx.putMessage(row);
            }
          }
        }
        await tx.putGroup(
          GroupRecord(
            conversationId: id,
            generation: at.generation,
            epoch: nextPair.epoch,
            state: next,
          ),
        );
        if (MlsPair.above(at, record?.afterPair)) {
          await tx.setAfterPair(id, at);
        }
        await tx.clearSentBefore(id, nextPair);
        // R9: an own self-update and an own commit that held a removal renew
        // this device's leaf; an add-only commit does not. A `change` with
        // no welcome added nothing, so it removed (the case of a removed
        // member that had no pin).
        final renewed =
            ownPending != null &&
            (ownPending.kind == PendingKind.selfUpdate ||
                ownRemoved.isNotEmpty ||
                (ownPending.kind == PendingKind.change &&
                    ownPending.welcome == null));
        await tx.putConversationSync(
          id,
          sync.copyWith(
            completedEpochs: completed,
            epochMustAdvance: false,
            lastSelfUpdateAtMicros: renewed
                ? nowMicros
                : sync.lastSelfUpdateAtMicros,
          ),
        );
        if (daily != null && (ownAdded.isNotEmpty || ownRemoved.isNotEmpty)) {
          await _ledger.writeIn(
            tx,
            daily,
            (r) => r.withOwnChange(id, added: ownAdded, removed: ownRemoved),
          );
        }
        // Review m6: a theirs pin written here (an own add confirmed with
        // its checked side) stores the peer ref with the id, as the
        // attribution that pins a theirs member does (C1 / N3). The stored
        // ref is never replaced (first write wins), so this writes only for
        // a conversation that has none yet. One `addIn` per transaction.
        final theirsRef = ownTheirs && peerRef != null && peerRef.isNotEmpty
            ? peerRef
            : null;
        if (needKnown || theirsRef != null) {
          await _known.addIn(tx, v, id, peerUserId: theirsRef);
        }
        // The one history write of this transaction: only when a new id or
        // a taint was recorded (a removal never writes it).
        await _keyHistory.writeIn(tx, id, history);
      });
    } on Object {
      _known.discardStaged();
      rethrow;
    }
    _known.commitStaged();
    return (newMember: newMember, knownGrew: needKnown);
  }
}

enum _Applied { ok, selfRemoved, stuck, interrupted }

Uint8List? _deviceIdOf(
  String hex,
  MlsCommitEvent? event,
  List<GroupMember> members,
) {
  for (final m in members) {
    if (vaultDeviceIdHex(m.deviceId) == hex) return m.deviceId;
  }
  for (final a in event?.added ?? const <Uint8List>[]) {
    if (vaultDeviceIdHex(a) == hex) return a;
  }
  return null;
}

/// `internal`, `deadline` and `unavailable` are transient: the pass stops
/// and changes nothing; the commit is never skipped.
bool _transient(MlsErrorCode code) =>
    code == MlsErrorCode.internal ||
    code == MlsErrorCode.deadline ||
    code == MlsErrorCode.unavailable;
