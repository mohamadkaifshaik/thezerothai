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
/// `waiting`: a lower generation is not walked to its end yet, the vault is
/// not usable, or no answer was given while a row still carries the init
/// (review W1); nothing changed, try again later.
enum InitSettle { settled, notProvisional, replay, waiting }

/// The two ends of a provisional group (R6): the ONE success function and
/// the ONE discard, each used by every path that settles one: Task 8's send
/// success, its recovery, and the join code's "own init already stored"
/// step (which settles only a group with no init row, review W1). Both run
/// in the caller's `runWrite` body as ONE transaction.
extension _Provisional on ConversationCrypto {
  /// This device's own init (or reset) of [group]'s generation was stored by
  /// the server: the group becomes final and the after-pair is written, in
  /// ONE transaction with everything that follows from it.
  ///
  /// - A lower generation that was walked to its end and kept goes (L6).
  /// - With [delivered] (an answer for the message itself): the message is
  ///   stored under the row's expected id and the row deleted.
  /// - Without [delivered] there must be NO row that carries the init (a
  ///   reset, or an init whose row is gone): [_hasInitRow] is asked first by
  ///   every caller, and such a group is not settled here. Review W1: a
  ///   row's key that once carried an init is never sent without it (the
  ///   server binds the init into the request hash: VALIDATION
  ///   idempotency_key), so no path takes the init off a row and hands the
  ///   row to the sender. Task 8's starter gets the answer instead, by
  ///   sending the identical request again (the server replays it).
  /// - `requestAccepted` is set only from [delivered] (never cleared).
  /// - Security read H2: when the conversation is accepted, a
  ///   `deviceAdded` / mine row for each own-side member whose (device id,
  ///   key) this vault never pinned mine in another accepted conversation;
  ///   none on a brand-new vault. In an unaccepted conversation nothing is
  ///   written (Task 9's acceptance steps write it).
  ///
  /// Review F4 (binding for Task 9): a settle WITHOUT [delivered] (a group
  /// with no init row: a reset, or an init whose row is gone) has no server
  /// answer, so it sets no `requestAccepted` and writes no own-device
  /// alert. Both are left to Task 9's acceptance steps, which must run on
  /// the FIRST sight of ACCEPTED for a conversation whose stored
  /// `requestAccepted` is false, not only on a transition seen in this
  /// run. Until then the sender holds every row of the conversation (fail
  /// closed).
  ///
  /// The key history is neither read nor written: no pin changes here.
  /// False, with nothing written, when the marks are already at or past the
  /// init (a replay).
  ///
  /// Task 10: a provisional group whose pending commit is a RESET is settled
  /// by its own branch ([_ResetSettle._settleResetIn]: the pins are
  /// replaced by the new generation's members, with the reset's rows), with
  /// [ownList] and [peerList] when the reset was made in this run. What it
  /// decided for memory is applied by [_afterOwnInit].
  Future<bool> _settleOwnInitIn(
    SecureVault v,
    String id,
    GroupRecord group, {
    required Uint8List thisDevice,
    InitDelivered? delivered,
    DeviceList? ownList,
    DeviceList? peerList,
  }) async {
    final pending = group.pending;
    if (!group.provisional || pending == null) return false;
    if (pending.kind == PendingKind.reset) {
      final settled = await _settleResetIn(
        v,
        id,
        group,
        thisDevice: thisDevice,
        ownList: ownList,
        peerList: peerList,
      );
      if (settled == null) return false;
      _resetSettled[id] = settled;
      return true;
    }
    final g = group.generation;
    final stored = await v.conversation(id);
    if (!MlsPair.above(pending.builtOn, stored?.afterPair)) return false;
    final sync = stored?.sync ?? const ConversationSync();
    final accepted = sync.requestAccepted || (delivered?.accepted ?? false);
    final nowMicros = _now().microsecondsSinceEpoch;

    // H2, read inside this body: this conversation's own pins never count.
    final alerts = accepted
        ? await _ownDeviceAlertsIn(
            v,
            id,
            thisDevice: thisDevice,
            nowMicros: nowMicros,
          )
        : const <StoredMessage>[];

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
        // A row without an init keeps its key and bytes under the
        // conversation id (the sender's). A row WITH one is here only with
        // [delivered] ([_hasInitRow]): it is answered below.
        if (item.init == null) {
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

  /// Whether a stage-encrypted row of generation [g] of [id] carries an
  /// init (review W1: such a group is settled only with the message's
  /// answer).
  Future<bool> _hasInitRow(SecureVault v, String id, int g) async =>
      (await _provisionalRows(v, id, g)).any((r) => r.init != null);

  Future<InitSettle> _settleOwnInitLocked(
    String id,
    int generation,
    InitDelivered? delivered,
    BudgetPriority priority, {
    DeviceList? ownList,
    DeviceList? peerList,
  }) async {
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
        // Review W1: never without the message's answer while a row
        // carries the init. Nothing changes; the starter's replay answers.
        if (delivered == null && await _hasInitRow(v, id, generation)) {
          return InitSettle.waiting;
        }
        return await _settleOwnInitIn(
              v,
              id,
              group,
              thisDevice: pass.deviceId,
              delivered: delivered,
              ownList: ownList,
              peerList: peerList,
            )
            ? InitSettle.settled
            : InitSettle.replay;
      });
      if (result == InitSettle.settled) _afterOwnInit(id);
      return result;
    } on _Stopped {
      _resetSettled.remove(id);
      return InitSettle.waiting;
    } on Object catch (e, s) {
      // A vault error or a closed vault: the transaction stored nothing.
      _resetSettled.remove(id);
      _reportIfBug(e, s, 'settleOwnInit');
      return InitSettle.waiting;
    }
  }

  /// Memory after an own init settled: the next send syncs first (commits
  /// to the server's pair, then one live pull). After an own RESET (Task
  /// 10) the conversation is no longer stuck (the new generation is this
  /// device's own), and what its settle decided about the members reaches
  /// memory now: an unattributed member asks for attribution, a refused
  /// one is an unknown device.
  void _afterOwnInit(String id) {
    final context = _contexts.of(id)
      ..syncedSinceStart = false
      ..livePulledAt = null;
    final reset = _resetSettled.remove(id);
    if (reset != null) {
      context.stuck = false;
      if (reset.unattributed) {
        context
          ..attributionConcluded = false
          ..attributionPending = true;
      }
      final now = _now();
      for (final hex in reset.unknown) {
        context.firstSeenUnattributed[hex] ??= now;
        context.unknownDevices.add(hex);
      }
    }
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
