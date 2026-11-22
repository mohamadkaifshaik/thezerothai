part of 'conversation_crypto.dart';

/// What the settle of this device's own reset decided for memory (applied
/// by `_afterOwnInit` once the transaction committed). No `toString`: it
/// holds device ids.
class _ResetSettled {
  _ResetSettled({required this.unattributed, required this.unknown});

  /// A member of the new generation was pinned unattributed.
  final bool unattributed;

  /// Device ids (hex) the key history refused: unknown devices.
  final Set<String> unknown;
}

/// Task 10 (R6 step 5): the success steps of this device's own RESET, the
/// generation-agnostic settle's reset branch ([_Provisional._settleOwnInitIn]
/// hands a provisional group whose pending commit is a reset to it). Runs in
/// the caller's `runWrite` body as ONE transaction.
extension _ResetSettle on ConversationCrypto {
  /// The server stored this device's reset of [group]'s generation (its
  /// record at (g + 1, 0), the pending commit's `builtOn`). In ONE
  /// transaction:
  ///
  /// - the group becomes final with the after-pair (g + 1, 0);
  /// - a lower generation goes only once its last epoch was completed or
  ///   marked (security read L6; the caller walked it first); otherwise it
  ///   stays until it is;
  /// - the pins are replaced by the members of g + 1 (`describe`). Each
  ///   member other than this device is ADMITTED to the key history first
  ///   (device-key-history-design.md, the Task 10 row): a refused pair is
  ///   pinned unattributed and gets an `unknownDevice` row. Every admitted
  ///   one is attributed by [attributeAfterReset]: a member pinned at the
  ///   end of g (or among the former pins) with the same key and a side
  ///   keeps that side; anything else is attributed from [ownList] and
  ///   [peerList] (the reset's own fresh lists, when this run made it;
  ///   unreadable otherwise), else `unattributed`. This device is `mine`;
  /// - one `encryptionReset` row; a member that got a side and did not
  ///   keep one (a new key, and, PR 1 carryover, a device reclaimed through
  ///   an UNATTRIBUTED pin) gets its `deviceAdded` row with that side, so a
  ///   new own-side key alerts as the own-device alert and a new peer-side
  ///   key as the device-change line;
  /// - the sync record: `lastSelfUpdateAtMicros` = now, `completedEpochs`
  ///   emptied, first-saw cleared, `epochMustAdvance` false;
  /// - the former pins and the join baseline go (this is never a first
  ///   join); the key history is written once and never shrinks: `closed`
  ///   and `allow` are left as they are.
  ///
  /// A reset is made only in an accepted conversation, so the rows are
  /// always written (R10 is checked all the same). Null, with nothing
  /// written, when the marks are already at or past the reset (a replay).
  Future<_ResetSettled?> _settleResetIn(
    SecureVault v,
    String id,
    GroupRecord group, {
    required Uint8List thisDevice,
    DeviceList? ownList,
    DeviceList? peerList,
  }) async {
    final pending = group.pending!;
    final g = group.generation;
    final stored = await v.conversation(id);
    if (!MlsPair.above(pending.builtOn, stored?.afterPair)) return null;
    final sync = stored?.sync ?? const ConversationSync();
    final accepted = sync.requestAccepted;
    final nowMicros = _now().microsecondsSinceEpoch;
    final since = pending.builtOn.next;

    final description = await _engine().describe(group.state);
    final pins = await v.members(id);
    final former = await _formerPins.of(v, id);
    final history = await _keyHistory.of(
      v,
      id,
      currentPins: pins,
      formerPins: former,
    );
    final pinnedAtEnd = [...pins, ...former];
    final thisHex = vaultDeviceIdHex(thisDevice);
    final newPins = <MemberRecord>[];
    final lines = <StoredMessage>[];
    final unknown = <String>{};
    var unattributed = false;
    for (final m in description.members) {
      final hex = vaultDeviceIdHex(m.deviceId);
      final key = m.signaturePublicKey;
      if (hex == thisHex) {
        newPins.add(
          MemberRecord(
            conversationId: id,
            deviceId: m.deviceId,
            signatureKey: key,
            side: MemberSide.mine,
            since: since,
          ),
        );
        continue;
      }
      // Admitted BEFORE attribution (the Task 10 row of the key history's
      // design): a refused pair never gets a side.
      final refusal = history.admit(hex, key);
      final String side;
      if (refusal != KeyRefusal.none) {
        side = MemberSide.unattributed;
        unknown.add(hex);
        if (accepted && refusal != KeyRefusal.unreadable) {
          final row = _systemRow(
            id,
            since,
            SystemLine.unknownDevice,
            nowMicros,
            deviceId: m.deviceId,
          );
          if (!await v.hasMessage(id, row.messageId)) lines.add(row);
        }
      } else {
        side = attributeAfterReset(
          deviceId: m.deviceId,
          signatureKey: key,
          pinnedAtEndOfPrevious: pinnedAtEnd,
          ownList: ownList ?? const DeviceList.unreadable(),
          peerList: peerList ?? const DeviceList.unreadable(),
        );
        // Kept: pinned at the end of g with this key AND a side. A pin that
        // was unattributed is no sight of the device: it is new here.
        final kept = pinnedAtEnd.any(
          (p) =>
              _sameBytes(p.deviceId, m.deviceId) &&
              _sameBytes(p.signatureKey, key) &&
              p.side != MemberSide.unattributed,
        );
        if (side != MemberSide.unattributed && !kept && accepted) {
          lines.add(
            _systemRow(
              id,
              since,
              SystemLine.deviceAdded,
              nowMicros,
              deviceId: m.deviceId,
              side: side,
            ),
          );
        }
      }
      if (side == MemberSide.unattributed) unattributed = true;
      newPins.add(
        MemberRecord(
          conversationId: id,
          deviceId: m.deviceId,
          signatureKey: key,
          side: side,
          since: since,
        ),
      );
    }
    if (accepted) {
      lines.add(_systemRow(id, since, SystemLine.encryptionReset, nowMicros));
    }
    final rows = await _provisionalRows(v, id, g);
    final done = sync.completedEpochs;
    final walked = [
      for (final old in await v.groups(id))
        if (old.generation < g &&
            !old.provisional &&
            done.contains(MlsPair(old.generation, old.epoch)))
          old.generation,
    ];

    await v.transaction((tx) async {
      await tx.clearProvisional(id, g, afterPair: pending.builtOn);
      await tx.putGroup(
        GroupRecord(
          conversationId: id,
          generation: g,
          epoch: group.epoch,
          state: group.state,
        ),
      );
      for (final generation in walked) {
        await tx.deleteGroup(id, generation);
      }
      await _baselines.deleteIn(tx, v, id);
      for (final p in pins) {
        await tx.deleteMember(id, p.deviceId);
      }
      for (final p in newPins) {
        await tx.putMember(p);
      }
      await _formerPins.deleteIn(tx, v, id);
      await tx.putConversationSync(
        id,
        sync.copyWith(
          firstSawGeneration: null,
          firstSawGenerationAtMicros: null,
          completedEpochs: const [],
          epochMustAdvance: false,
          lastSelfUpdateAtMicros: nowMicros,
        ),
      );
      // A row of the new generation carries no init (a reset sends none):
      // it keeps its key and bytes under the conversation id.
      for (final item in rows) {
        await tx.putOutbox(
          OutboxItem(
            idempotencyKey: item.idempotencyKey,
            localId: item.localId,
            expectedMessageId: item.expectedMessageId,
            conversationId: id,
            generation: item.generation,
            epoch: item.epoch,
            ciphertext: item.ciphertext,
            reportCommitment: item.reportCommitment,
            content: item.content,
            createdAtMicros: item.createdAtMicros,
            init: item.init,
            attempts: item.attempts,
            lastError: item.lastError,
          ),
        );
      }
      for (final row in lines) {
        await tx.putMessage(row);
      }
      // The one history write: the admitted members; `closed` and `allow`
      // are untouched (a reset never changes them).
      await _keyHistory.writeIn(tx, id, history);
    });
    return _ResetSettled(unattributed: unattributed, unknown: unknown);
  }
}
