part of 'conversation_crypto.dart';

/// Applying one commit during catch-up (the conversation lock is held): the
/// epoch's messages are completed first, then the engine's confirm or
/// process and the commit's ONE transaction (pins, rows, group, marks, known
/// set, key history) run in ONE `runWrite` body.
extension _CommitApply on ConversationCrypto {
  /// Step 4 for the commit at [at]: confirm (own, by bytes) or process, then
  /// ONE transaction with the result, in one runWrite body.
  Future<_Applied> _applyLocked(
    _Poll pass,
    String id,
    MlsPair at,
    pb.ConversationCommit commit,
  ) async {
    try {
      await sink?.completeEpoch(id, at, priority: pass.priority);
    } on Object catch (e, s) {
      _reportIfBug(e, s, 'completeEpoch');
      return _Applied.interrupted;
    }
    final _Applied applied;
    // The known set grew in the applied commit's transaction (a migrated v1
    // group that was never in it).
    var knownGrew = false;
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
        try {
          if (pending != null && _sameBytes(bytes, pending.commit)) {
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
        );
        knownGrew = written.knownGrew;
        if (written.newMember) {
          _contexts.of(id)
            ..attributionConcluded = false
            ..attributionPending = true;
        }
        return event?.selfRemoved ?? false ? _Applied.selfRemoved : _Applied.ok;
      });
    } on _Stopped {
      return _Applied.interrupted;
    } on Object catch (e, s) {
      _reportIfBug(e, s, 'applyCommit');
      return _Applied.interrupted;
    }
    if (applied == _Applied.ok || applied == _Applied.selfRemoved) {
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
    try {
      await v.transaction((tx) async {
        if (event != null && event.selfRemoved) {
          // This device was removed: groups and pins go; the pins are kept
          // as former pins (H2) and the rejoin is compared with them.
          for (final group in groups) {
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
        }
        for (final entry in added.entries) {
          if (entry.key == thisHex) continue;
          final pinned = byHex[entry.key];
          if (pinned != null && _sameBytes(pinned.signatureKey, entry.value)) {
            continue;
          }
          final deviceId = _deviceIdOf(entry.key, event, members);
          if (deviceId == null) continue;
          newMember = true;
          final refusal = history.admit(entry.key, entry.value);
          await tx.putMember(
            MemberRecord(
              conversationId: id,
              deviceId: deviceId,
              signatureKey: entry.value,
              side: MemberSide.unattributed,
              since: nextPair,
            ),
          );
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
        await tx.putConversationSync(
          id,
          sync.copyWith(completedEpochs: completed, epochMustAdvance: false),
        );
        if (needKnown) await _known.addIn(tx, v, id);
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
