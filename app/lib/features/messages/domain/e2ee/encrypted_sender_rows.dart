part of 'encrypted_sender.dart';

// The user's retry and discard of a row, the rows `outgoing` lists, and
// forgetting rows that are gone, moved here unchanged from
// `encrypted_sender.dart` (a pure move, Task 9 final review nit: the file
// was over the 900-line split point). The public entries stay in the class
// with their contracts and call these bodies.
extension _Rows on EncryptedSender {
  /// The body of [EncryptedSender.retry] (its contract is written there).
  Future<void> _retryRow(String localId) async {
    final row = await _find(localId);
    final id = row?.conversationId;
    if (row == null || id == null || row.init != null) return;
    if (!_contexts.of(id).canReply) return;
    try {
      if (row.lastError != null) {
        await _locks.run(id, () => _clearFailure(id, localId));
      }
    } on Object catch (e, s) {
      _reportIfBug(e, s, 'send.retry');
    }
    // The user's own retry: user priority.
    await drain(id, priority: BudgetPriority.user);
  }

  /// The body of [EncryptedSender.discard] (its contract is written there).
  Future<void> _discardRow(String localId) async {
    final row = await _find(localId);
    final id = row?.conversationId;
    if (row == null || id == null || row.init != null) return;
    try {
      // The pull proves "no echo" only for the send calls made before it.
      int? calls;
      if (row.stage == OutboxStage.encrypted) {
        final context = _contexts.of(id);
        final previous = context.running;
        if (previous != null) await previous;
        // A different pass may have started while we waited. Its snapshot
        // also predates our witness; leave the row for the next discard.
        if (context.running != null) return;
        final before = _sendCalls[localId] ?? 0;
        final outcome = await _receiver.pullLive(
          id,
          priority: BudgetPriority.user,
        );
        if (outcome.kind == ReceiveOutcomeKind.complete) calls = before;
      }
      await _locks.run(id, () => _discardLocked(id, localId, calls));
    } on Object catch (e, s) {
      _reportIfBug(e, s, 'send.discard');
    }
    _onChanged(id);
  }

  /// The body of [EncryptedSender.outgoing] (its contract is written there).
  Future<List<OutgoingRow>> _outgoingRows(String conversationId) async {
    final vault = _session.vault;
    if (vault == null) throw StateError('The vault is not ready.');
    try {
      final rows = (await vault.outbox(conversationId: conversationId)).items;
      if (rows.isEmpty) return const [];
      final gate = await _gate(vault, conversationId);
      final waitingOn = gate.block != SendBlock.none
          ? gate.block
          : _held[conversationId] ?? SendBlock.none;
      // Audit M2: an encrypted row held for attribution waits, with the
      // reason the plain row's gate gives.
      final owed =
          rows.any((r) => r.stage == OutboxStage.encrypted) &&
          await _attributionOwed(vault, conversationId);
      return [
        for (final r in rows)
          if (r.lastError != null)
            _outgoing(r, OutgoingStatus5a.failed, SendBlock.none)
          else if (r.stage == OutboxStage.encrypted && owed)
            _outgoing(r, OutgoingStatus5a.waiting, _owedReason(gate.block))
          else if (r.stage == OutboxStage.encrypted)
            _outgoing(r, OutgoingStatus5a.sending, SendBlock.none)
          else
            _outgoing(r, OutgoingStatus5a.waiting, waitingOn),
      ];
    } on Object catch (e, s) {
      _reportIfBug(e, s, 'send.outgoing');
      rethrow;
    }
  }

  OutgoingRow _outgoing(OutboxItem r, OutgoingStatus5a status, SendBlock on) {
    final failed = status == OutgoingStatus5a.failed;
    final error = failed ? _errors[r.localId] : null;
    return OutgoingRow(
      localId: r.localId,
      conversationId: r.conversationId,
      content: r.content,
      createdAt: DateTime.fromMicrosecondsSinceEpoch(
        r.createdAtMicros,
        isUtc: true,
      ),
      status: status,
      waitingOn: on,
      error: error,
      retryable: failed && r.lastError != 'CannotMessageException',
      tryTomorrow:
          (error is RateLimitedException && error.isDaily) ||
          error is QuotaExceededException,
    );
  }

  // -------------------------------------------------------------------------
  // Retry and discard (the lock is held)

  Future<void> _clearFailure(String id, String localId) async {
    final op = await _start();
    if (op == null) return;
    await _session.runWrite((v) async {
      op.check(v);
      for (final r in (await v.outbox(conversationId: id)).items) {
        if (r.localId != localId || r.lastError == null) continue;
        await v.transaction((tx) => tx.putOutbox(_copy(r, lastError: null)));
      }
    });
    _errors.remove(localId);
  }

  /// [calls]: the row's send-call count read before a live pull that then
  /// completed; null when no such pull completed.
  Future<void> _discardLocked(String id, String localId, int? calls) async {
    final op = await _start();
    if (op == null) return;
    await _session.runWrite((v) async {
      op.check(v);
      for (final r in (await v.outbox(conversationId: id)).items) {
        if (r.localId != localId || r.init != null) continue;
        // An encrypted row stays unless a pull completed with no send call
        // for it since that pull began.
        if (r.stage == OutboxStage.encrypted &&
            (calls == null || (_sendCalls[localId] ?? 0) != calls)) {
          return;
        }
        await v.transaction((tx) => tx.deleteOutbox(r.idempotencyKey));
        _forget(localId);
      }
    });
  }

  // -------------------------------------------------------------------------

  /// The end of a drain: forgets every row of [id] a send was made for in
  /// this run that is no longer in the outbox (a receive pass stored its
  /// echo). One lock hold, a read only; a failed read forgets nothing.
  Future<void> _forgetGone(String id) async {
    final sent = _sentFor[id];
    if (sent == null) return;
    try {
      await _locks.run(id, () async {
        final vault = _session.vault;
        if (vault == null) return;
        final read = await vault.outbox(conversationId: id);
        if (read.unreadableKeys.isNotEmpty) return;
        final left = {for (final r in read.items) r.localId};
        for (final localId in sent.difference(left)) {
          sent.remove(localId);
          _forget(localId);
        }
        if (sent.isEmpty) _sentFor.remove(id);
      });
    } on Object catch (e, s) {
      _reportIfBug(e, s, 'send.forget');
    }
  }
}
