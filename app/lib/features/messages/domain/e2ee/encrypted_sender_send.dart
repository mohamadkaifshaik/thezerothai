part of 'encrypted_sender.dart';

// The send and what each answer does to the row, moved here unchanged from
// `encrypted_sender.dart` (a pure move, Task 9 step 9b: the file was over
// the 900-line split point), as the commit runner keeps its send in
// `commit_runner_send.dart`.
extension _Send on EncryptedSender {
  /// Sends the stage-encrypted [row], with the lock held: the barrier, then
  /// the identical request (once more at once when the outcome is unknown
  /// and the server named no time).
  Future<_Next> _send(_Op op, String id, OutboxItem row, _Run run) async {
    if (_removedElsewhere()) return _stop(id, SendBlock.unavailable);
    if (!_contexts.of(id).canReply) return _stop(id, SendBlock.cannotMessage);
    // Audit M2: these bytes are not handed over, for the first time or
    // again, while a member is not attributable. The step that calls
    // this already checks the same thing; this second check is kept as
    // defence in depth for a future caller.
    if (await _attributionOwed(op.vault, id)) {
      return _stop(id, SendBlock.notSynced);
    }
    final notBefore = _notBefore[row.localId];
    if (notBefore != null && _now().isBefore(notBefore)) return _stop(id);
    final key = row.idempotencyKey;
    // See SecureVault.confirmStored: exact on Android. On the web this
    // checks the row on the same connection; persistence remains a stated limit.
    var stored = false;
    try {
      stored = await op.vault.confirmStored(key);
    } on Object catch (e, s) {
      _reportIfBug(e, s, 'send.confirmStored');
    }
    if (!stored) return _stop(id, SendBlock.unavailable);
    var tries = _unknown.contains(row.localId) ? 1 : 2;
    _sentFor.putIfAbsent(id, () => {}).add(row.localId);
    while (true) {
      if (!op.live) return _stop(id, SendBlock.unavailable);
      // Counted when it starts and when it ends: a discard's pull is no
      // proof for a call in flight either.
      void count() =>
          _sendCalls[row.localId] = (_sendCalls[row.localId] ?? 0) + 1;
      count();
      final pb.SendMessageResponse response;
      try {
        response = await _messaging
            .sendEncrypted(
              idempotencyKey: key,
              conversationId: id,
              ciphertext: row.ciphertext,
              pair: MlsPair(row.generation, row.epoch),
              reportCommitment: row.reportCommitment,
            )
            .whenComplete(count);
      } on StaleEpochException {
        // M1: the server may have stored it all the same. Catch-up first,
        // then the live pull, with the row still at stage encrypted.
        run
          ..staleRounds += 1
          ..stale = (key: key, localId: row.localId);
        run.catchUp = await _crypto.catchUpLocked(id, priority: run.priority);
        return _Next.pull;
      } on AppException catch (e) {
        if (!_outcomeUnknown(e)) {
          return _refused(op, id, key, row.localId, e);
        }
        tries--;
        final wait = _retryAfterOf(e);
        if (wait == null) {
          if (tries > 0) continue;
        } else {
          _notBefore[row.localId] = _now().add(wait);
          // The one automatic resend, at the server's time.
          if (tries > 0) run.resendAfter = wait;
        }
        _unknown.add(row.localId);
        return _stop(id);
      } on Object catch (e, s) {
        _reportIfBug(e, s, 'send.sendEncrypted');
        _unknown.add(row.localId);
        return _stop(id);
      }
      return _delivered(op, id, row, response);
    }
  }

  /// The server accepted [row]: one transaction stores the message and
  /// deletes the row.
  Future<_Next> _delivered(
    _Op op,
    String id,
    OutboxItem row,
    pb.SendMessageResponse response,
  ) async {
    final message = response.message;
    final messageId = row.expectedMessageId;
    if (message.id.isNotEmpty && message.id != messageId) {
      _reportOnce('send.responseId');
    }
    final at = _serverMicros(message) ?? _now().microsecondsSinceEpoch;
    try {
      await _session.runWrite((v) async {
        op.check(v);
        // Gone: its echo was stored by a pass meanwhile.
        if (await _rowOf(v, id, row.idempotencyKey) == null) return;
        final cleared = (await v.conversation(id))?.sync.clearedAtMicros;
        // Never over a stored row (a tombstone), never at or before
        // cleared_at.
        final keep =
            !(cleared != null && at <= cleared) &&
            !await v.hasMessage(id, messageId);
        await v.transaction((tx) async {
          if (keep) {
            await tx.putMessage(
              StoredMessage(
                conversationId: id,
                messageId: messageId,
                createdAtMicros: at,
                mine: true,
                state: StoredMessageState.visible,
                generation: row.generation,
                epoch: row.epoch,
                content: row.content,
                senderDeviceId: op.deviceId,
              ),
            );
          }
          await tx.deleteOutbox(row.idempotencyKey);
        });
      });
    } on Object catch (e, s) {
      // The row stays: the same request is sent again and answered alike.
      _reportIfBug(e, s, 'send.delivered');
      return _stop(id, SendBlock.unavailable);
    }
    if (response.hasConversation() && response.conversation.id == id) {
      // The peer and can_reply only: a send answer's direction and state
      // never drive the acceptance (Task 9 brief amendment 2).
      _contexts.note(response.conversation, sendAnswer: true);
    }
    _forget(row.localId);
    _onChanged(id);
    return _Next.again;
  }

  /// A refusal: the row keeps its bytes and its key, with one more attempt
  /// and the error's type name; the typed error stays in memory.
  Future<_Next> _refused(
    _Op op,
    String id,
    String key,
    String localId,
    AppException error,
  ) async {
    try {
      await _session.runWrite((v) async {
        op.check(v);
        // Memory is written for the vault the send was made with only.
        _errors[localId] = error;
        if (error is CannotMessageException) _contexts.of(id).canReply = false;
        final row = await _rowOf(v, id, key);
        if (row == null || row.stage != OutboxStage.encrypted) return;
        await v.transaction(
          (tx) => tx.putOutbox(
            _copy(
              row,
              attempts: row.attempts + 1,
              lastError: _errorName(error),
            ),
          ),
        );
      });
    } on Object catch (e, s) {
      _reportIfBug(e, s, 'send.refused');
      _unknown.add(localId);
      _onChanged(id);
      return _stop(id, SendBlock.unavailable);
    }
    _onChanged(id);
    return _stop(id);
  }

  /// After a `STALE_EPOCH` answer for the row [key] (local id [localId]),
  /// its catch-up and one live pull (the lock is held again; everything is
  /// read fresh).
  Future<_Next> _afterStale(
    _Op op,
    String id,
    List<OutboxItem> rows,
    String key,
    String localId,
    _Run run,
  ) async {
    final capped = run.staleRounds >= kStaleEpochRoundsPerDrain;
    OutboxItem? row;
    for (final r in rows) {
      if (r.idempotencyKey == key) row = r;
    }
    if (row == null) {
      // Its echo was found (the same id and the same bytes): done, and
      // nothing was encrypted again.
      _forget(localId);
      _onChanged(id);
      return _Next.again;
    }
    final current = await _currentGroup(op.vault, id);
    final advanced =
        current != null &&
        MlsPair(current.generation, current.epoch) !=
            MlsPair(row.generation, row.epoch);
    if (row.stage != OutboxStage.encrypted || !advanced) {
      // The pair did not move: an unknown outcome. The row keeps its bytes
      // and its key and is resent at the next trigger.
      _unknown.add(row.localId);
      return _stop(id, capped ? SendBlock.notSynced : SendBlock.none);
    }
    // Catch-up moved this device past the row's pair (a commit applied, or
    // another generation), and the walk of that pair found no echo: back to
    // plain under a NEW key and a new expected id, in one transaction.
    try {
      final next = _hexOf(await _random(16));
      await _session.runWrite((v) async {
        op.check(v);
        final fresh = await _rowOf(v, id, key);
        if (fresh == null || fresh.stage != OutboxStage.encrypted) return;
        await v.transaction((tx) async {
          await tx.deleteOutbox(key);
          await tx.putOutbox(
            OutboxItem(
              idempotencyKey: next,
              localId: fresh.localId,
              expectedMessageId: expectedMessageId(v.uid, next),
              conversationId: id,
              generation: 0,
              epoch: 0,
              ciphertext: Uint8List(0),
              reportCommitment: Uint8List(0),
              content: fresh.content,
              createdAtMicros: fresh.createdAtMicros,
              stage: OutboxStage.plain,
              attempts: fresh.attempts,
            ),
          );
        });
      });
    } on _BadRandom {
      _reportOnce('send.stale.random');
      return _stop(id, SendBlock.unavailable);
    } on Object catch (e, s) {
      // The row stays encrypted: the next drain meets the refusal again.
      _reportIfBug(e, s, 'send.stale');
      return _stop(id, SendBlock.unavailable);
    }
    _forget(row.localId);
    _onChanged(id);
    return capped ? _stop(id, SendBlock.notSynced) : _Next.again;
  }
}
