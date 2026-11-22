part of 'conversation_crypto.dart';

/// What the server's answer said of an init it stored (Task 8): the send
/// response, or the first `ListMessages` page that held the message. No
/// `toString`.
class InitDelivered {
  const InitDelivered({required this.accepted, this.atMicros});

  /// The answer's conversation state was ACCEPTED. Nothing else of that
  /// answer is taken.
  final bool accepted;

  /// The stored message's `created_at`; null when the answer had none this
  /// client can hold.
  final int? atMicros;
}

/// What [ConversationCrypto.settleOwnInitLocked] did.
///
/// `settled`: the group is final. `notProvisional`: there was nothing to
/// settle (settled or discarded meanwhile). `replay`: the marks are already
/// at or past the init, so they cannot be written; nothing changed.
/// `waiting`: a lower generation is not walked to its end yet, or the vault
/// is not usable; nothing changed, try again later.
enum InitSettle { settled, notProvisional, replay, waiting }

/// The two ends of a provisional group (R6): the ONE success function and
/// the ONE discard, each used by every path that settles one: Task 8's send
/// success, its recovery, and the join code's "own init already stored"
/// step. Both run in the caller's `runWrite` body as ONE transaction.
extension _Provisional on ConversationCrypto {
  /// This device's own init (or reset) of [group]'s generation was stored by
  /// the server: the group becomes final and the after-pair is written, in
  /// ONE transaction with everything that follows from it.
  ///
  /// - A lower generation that was walked to its end and kept goes (L6).
  /// - With [delivered] (an answer for the message itself): the message is
  ///   stored under the row's expected id and the row deleted. Without it
  ///   (the init was found among the stored commits): the row loses its
  ///   `init` and is addressed by the conversation id, with the same key
  ///   and bytes, so the live pull completes it as an echo, or the sender
  ///   resends it as an ordinary message.
  /// - `requestAccepted` is set only from [delivered] (never cleared).
  /// - Security read H2: when the conversation is accepted, a
  ///   `deviceAdded` / mine row for each own-side member whose (device id,
  ///   key) this vault never pinned mine in another accepted conversation;
  ///   none on a brand-new vault. In an unaccepted conversation nothing is
  ///   written (Task 9's acceptance steps write it).
  ///
  /// Review F4 (binding for Task 9): a settle WITHOUT [delivered] (the 24 h
  /// expiry, a retry settled from the stored commits, the join code's
  /// own-init-already-stored step) has no server answer, so it sets no
  /// `requestAccepted` and writes no own-device alert. Both are left to
  /// Task 9's acceptance steps, which must run on the FIRST sight of
  /// ACCEPTED for a conversation whose stored `requestAccepted` is false,
  /// not only on a transition seen in this run. Until then the sender
  /// holds every row of the conversation (fail closed).
  ///
  /// The key history is neither read nor written: no pin changes here.
  /// False, with nothing written, when the marks are already at or past the
  /// init (a replay).
  Future<bool> _settleOwnInitIn(
    SecureVault v,
    String id,
    GroupRecord group, {
    required Uint8List thisDevice,
    InitDelivered? delivered,
  }) async {
    final pending = group.pending;
    if (!group.provisional || pending == null) return false;
    final g = group.generation;
    final stored = await v.conversation(id);
    if (!MlsPair.above(pending.builtOn, stored?.afterPair)) return false;
    final sync = stored?.sync ?? const ConversationSync();
    final accepted = sync.requestAccepted || (delivered?.accepted ?? false);
    final nowMicros = _now().microsecondsSinceEpoch;
    final thisHex = vaultDeviceIdHex(thisDevice);

    // H2, read inside this body: this conversation's own pins never count.
    final alerts = <StoredMessage>[];
    if (accepted && !await _formerPins.brandNewVault(v, excluding: id)) {
      final ever = await _formerPins.everPinnedMine(v, excluding: id);
      for (final m in await v.members(id)) {
        final hex = vaultDeviceIdHex(m.deviceId);
        if (m.side != MemberSide.mine || hex == thisHex) continue;
        if (ever.contains((
          deviceIdHex: hex,
          keyB64: base64Encode(m.signatureKey),
        ))) {
          continue;
        }
        final row = _systemRow(
          id,
          m.since,
          SystemLine.deviceAdded,
          nowMicros,
          deviceId: m.deviceId,
          side: MemberSide.mine,
        );
        if (!await v.hasMessage(id, row.messageId)) alerts.add(row);
      }
    }

    final rows = await _provisionalRows(v, id, g);
    final cleared = sync.clearedAtMicros;
    final at = delivered?.atMicros ?? nowMicros;
    final keep = <String>{};
    if (delivered != null) {
      for (final item in rows) {
        // Only the row that carried the init was answered. Never over a
        // stored row (a tombstone), never at or before cleared_at.
        if (item.init != null &&
            !(cleared != null && at <= cleared) &&
            !await v.hasMessage(id, item.expectedMessageId)) {
          keep.add(item.idempotencyKey);
        }
      }
    }
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
      // The init is accepted: nothing of it is pending any more.
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
      // As any join after the first: this is never a first join.
      await _baselines.deleteIn(tx, v, id);
      await tx.putConversationSync(
        id,
        sync.copyWith(
          firstSawGeneration: null,
          firstSawGenerationAtMicros: null,
          completedEpochs: const [],
          epochMustAdvance: false,
          lastSelfUpdateAtMicros: nowMicros,
          requestAccepted: accepted,
        ),
      );
      for (final item in rows) {
        if (delivered == null || item.init == null) {
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
              attempts: item.attempts,
              lastError: item.lastError,
            ),
          );
          continue;
        }
        if (keep.contains(item.idempotencyKey)) {
          await tx.putMessage(
            StoredMessage(
              conversationId: id,
              messageId: item.expectedMessageId,
              createdAtMicros: at,
              mine: true,
              state: StoredMessageState.visible,
              generation: item.generation,
              epoch: item.epoch,
              content: item.content,
              senderDeviceId: thisDevice,
            ),
          );
        }
        await tx.deleteOutbox(item.idempotencyKey);
      }
      for (final row in alerts) {
        await tx.putMessage(row);
      }
    });
    return true;
  }

  /// The server did not store this device's init of generation [g] (another
  /// device's was first, or it was refused): ONE transaction deletes the
  /// provisional group and the pins it made and returns its rows to stage
  /// `plain`, addressed by the conversation id (the sender owns them then).
  /// A row keeps its key, which is never put on the wire again: whoever
  /// encrypts it makes a new one. With [lastError] (a refusal) the rows
  /// fail with that error name and one more attempt.
  ///
  /// The marks, the known set and the key history are not touched: nothing
  /// ever shrinks a key history.
  Future<void> _discardProvisionalIn(
    SecureVault v,
    String id,
    int g, {
    String? lastError,
  }) async {
    final members = await v.members(id);
    final rows = await _provisionalRows(v, id, g);
    await v.transaction((tx) async {
      await tx.deleteGroup(id, g);
      for (final m in members) {
        if (m.since.generation >= g) await tx.deleteMember(id, m.deviceId);
      }
      for (final item in rows) {
        await tx.putOutbox(
          OutboxItem(
            idempotencyKey: item.idempotencyKey,
            localId: item.localId,
            expectedMessageId: item.expectedMessageId,
            conversationId: id,
            generation: 0,
            epoch: 0,
            ciphertext: Uint8List(0),
            reportCommitment: Uint8List(0),
            content: item.content,
            createdAtMicros: item.createdAtMicros,
            stage: OutboxStage.plain,
            attempts: item.attempts + (lastError == null ? 0 : 1),
            lastError: lastError ?? item.lastError,
          ),
        );
      }
    });
  }

  /// The stage-encrypted rows of generation [g] of [id]: addressed by its
  /// id, or by the recipient reference stored for it.
  Future<List<OutboxItem>> _provisionalRows(
    SecureVault v,
    String id,
    int g,
  ) async {
    final peerRef = _known.peerOf(id);
    return [
      for (final item in (await v.outbox()).items)
        if ((item.conversationId == id ||
                (item.conversationId == null &&
                    peerRef != null &&
                    item.recipientUserId == peerRef)) &&
            item.stage == OutboxStage.encrypted &&
            item.generation == g)
          item,
    ];
  }

  Future<InitSettle> _settleOwnInitLocked(
    String id,
    int generation,
    InitDelivered? delivered,
    BudgetPriority priority,
  ) async {
    try {
      final pass = await _startOperation(priority);
      if (pass == null) return InitSettle.waiting;
      // The old generation is walked to its end first (L6): catch-up walks
      // it once the server reports the later generation.
      if (await _unwalked(pass.vault, id, generation)) {
        await _catchUpLocked(id, priority: priority);
        if (!pass.live) return InitSettle.waiting;
        final now = await pass.vault.group(id, generation);
        if (now == null || !now.provisional) return InitSettle.notProvisional;
        if (await _unwalked(pass.vault, id, generation)) {
          return InitSettle.waiting;
        }
      }
      final result = await _session.runWrite((v) async {
        pass.check(v);
        final group = await v.group(id, generation);
        if (group == null || !group.provisional || group.pending == null) {
          return InitSettle.notProvisional;
        }
        return await _settleOwnInitIn(
              v,
              id,
              group,
              thisDevice: pass.deviceId,
              delivered: delivered,
            )
            ? InitSettle.settled
            : InitSettle.replay;
      });
      if (result == InitSettle.settled) _afterOwnInit(id);
      return result;
    } on _Stopped {
      return InitSettle.waiting;
    } on Object catch (e, s) {
      // A vault error or a closed vault: the transaction stored nothing.
      _reportIfBug(e, s, 'settleOwnInit');
      return InitSettle.waiting;
    }
  }

  /// Memory after an own init settled: the next send syncs first (commits
  /// to the server's pair, then one live pull).
  void _afterOwnInit(String id) {
    _contexts.of(id)
      ..syncedSinceStart = false
      ..livePulledAt = null;
    _onChanged(id);
  }

  Future<bool> _discardProvisionalLocked(
    String id,
    int generation,
    String? lastError,
  ) async {
    try {
      final pass = await _startOperation(BudgetPriority.user);
      if (pass == null) return false;
      final discarded = await _session.runWrite((v) async {
        pass.check(v);
        final group = await v.group(id, generation);
        if (group == null || !group.provisional) return false;
        await _discardProvisionalIn(v, id, generation, lastError: lastError);
        return true;
      });
      if (discarded) _onChanged(id);
      return discarded;
    } on _Stopped {
      return false;
    } on Object catch (e, s) {
      _reportIfBug(e, s, 'discardProvisional');
      return false;
    }
  }
}
