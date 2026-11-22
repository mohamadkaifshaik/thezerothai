part of 'group_starter.dart';

/// The user's retry of an unsent row, and the new start of a known
/// conversation this device was never a member of (review F1, option c).
extension _KnownRestart on GroupStarter {
  /// The body of [GroupStarter.retryStart] (its contract is written there).
  Future<void> _retryStart(String localId) async {
    try {
      final vault = _session.vault;
      if (vault == null) return;
      if (!_known.isLoadedFor(vault)) await _known.load(vault);
      OutboxItem? row;
      for (final r in (await vault.outbox()).items) {
        if (r.localId == localId) row = r;
      }
      if (row == null) return;
      if (row.init != null) {
        // Code review M3. Decision: only the conversation whose provisional
        // group this row belongs to is resumed, found as [pendingInit]
        // finds it. Why: one retry is one user action in one conversation;
        // resuming every provisional group sent every pending init and
        // could rebuild (and claim for) other conversations.
        final own = await _conversationOfInit(vault, row);
        if (own != null) await _resume(own, BudgetPriority.user);
        return;
      }
      final id = row.conversationId;
      final peer = id == null ? null : _known.peerOf(id);
      if (id != null &&
          peer != null &&
          await _restartKnown(id, peer, retried: localId) ==
              _Restart.notStarted) {
        return;
      }
      // Not eligible: the sender's row. Started: the sender's retry does
      // nothing for the row that now carries the init, and clears the
      // failure of [localId] when the start took an older row.
    } on Object catch (e, s) {
      // Audit L3. Decision: a failed read says nothing about whose row
      // this is, so nothing more is done with it. Why: falling through to
      // the sender's `retry` would clear the failure of a row only a new
      // start can send (review N1: "waiting" with no reason, for good).
      _reportIfBug(e, s, 'start.retry');
      return;
    }
    await _sender.retry(localId);
  }

  /// The conversation whose provisional group the init row [row] belongs
  /// to, or null: the row's own conversation id, or (a row addressed by
  /// recipient) each known conversation stored for that reference, kept
  /// only when [_initRow] of its provisional group is this row (review N7:
  /// never by resolving the recipient, which can name another id).
  Future<String?> _conversationOfInit(SecureVault vault, OutboxItem row) async {
    final direct = row.conversationId;
    final ids = direct != null
        ? [direct]
        : [
            for (final id in _known.ids)
              if (_known.peerOf(id) == row.recipientUserId) id,
          ];
    for (final id in ids) {
      for (final g in await vault.groups(id)) {
        if (!g.provisional) continue;
        final init = await _initRow(vault, id, g.generation);
        if (init?.idempotencyKey == row.idempotencyKey) return id;
      }
    }
    return null;
  }

  /// Review F1, ruling (c): whether a NEW start from fresh claims may be
  /// made for the known conversation [id] with [peer]. Read from [v] (in
  /// the creating `runWrite` body too), never from memory or the server.
  ///
  /// True only when the vault shows this device was never a member: no
  /// group of any generation, no mark, no first-saw generation, no former
  /// pins; and the stored peer ref is [peer]. Why: a refusal must never
  /// shrink the known set (that could reach plaintext), and "stuck for
  /// good" after a rate limit is not acceptable. Any sign that a group
  /// exists elsewhere keeps the row waiting for its welcome instead. Cost
  /// if wrong: a second group is started; the server's STALE_EPOCH for
  /// generation 1 is the backstop, and nothing is ever plaintext.
  Future<bool> _neverMember(SecureVault v, String id, String peer) async {
    if (_known.peerOf(id) != peer) return false;
    if ((await v.groups(id)).isNotEmpty) return false;
    final record = await v.conversation(id);
    if (record?.afterPair != null ||
        record?.joinHighWater != null ||
        record?.sync.firstSawGeneration != null) {
      return false;
    }
    return (await GroupStarter._former.of(v, id)).isEmpty;
  }

  /// Starts again from fresh claims for the head row of the known
  /// conversation [id] (review F1, option c). Called ONLY from an explicit
  /// trigger: a new send through [startOrRoute], or [retryStart]; never
  /// from [resumeProvisional], a timer or a drain. [retried]: the local id
  /// of the row the user retried; null for a new send. Never throws.
  ///
  /// Review N1: three answers, because the caller of a retry must tell "the
  /// sender's row" (`notEligible`: the sender's retry runs) from "a start
  /// that was not made" (`notStarted`: the row keeps its failure).
  Future<_Restart> _restartKnown(
    String id,
    String peer, {
    String? retried,
  }) async {
    try {
      final vault = _session.vault;
      // Not with the flag not on, not when removed elsewhere, and not into
      // a thread this run saw refused with CANNOT_MESSAGE.
      if (vault == null ||
          !_session.mayStart ||
          _removedElsewhere() ||
          _engineDown() ||
          !_contexts.of(id).canReply) {
        return _Restart.notEligible;
      }
      if (!await _neverMember(vault, id, peer)) return _Restart.notEligible;
      final read = await vault.outbox(conversationId: id);
      // Review N4. Decision: no new start while a row of the conversation
      // no longer opens. Why: only that row's place in the order is known;
      // taking the oldest READABLE row would make a later message the first
      // one, ahead of a message the user still expects to go out. The
      // sender stops at such a row for the same reason (Task 7), and the
      // way out is the same: the row is deleted by key (Task 13b).
      // `notStarted`, not `notEligible`: a failed row keeps its failure.
      if (read.unreadableKeys.isNotEmpty) return _Restart.notStarted;
      final rows = read.items;
      // The oldest waiting row becomes the new group's first message, so
      // the order the user typed is kept.
      if (rows.isEmpty) return _Restart.notStarted;
      final head = rows.first;
      if (head.stage != OutboxStage.plain || head.init != null) {
        return _Restart.notEligible;
      }
      // Review 3d. Decision: a failed row stays failed until the user
      // retries or discards THAT row. Why: Task 7's rule is "nothing goes
      // past a failed head row"; a bubble marked "not sent" must not go out
      // hours later because another message was typed, and `canReply`
      // (CANNOT_MESSAGE) is forgotten at a restart. Cost: later sends wait
      // behind a failed head the user never touches, as everywhere else.
      if (head.lastError != null && head.localId != retried) {
        return _Restart.notStarted;
      }
      // Review N3. Decision: one new start per conversation at a time; a
      // trigger that comes while one runs starts nothing and leaves its row
      // as it is. Why: each start claims the peer's one-time packages and
      // counts against the 20 claims per target per day, and the second
      // claim is always wasted (the lock then finds the first one's group).
      // Taken only here, after the checks above, with no await before
      // [_begin]: a row that is the sender's is never answered
      // `notStarted` because another call was reading.
      if (!_restarting.add(id)) return _Restart.notStarted;
      final StartOutcome outcome;
      try {
        outcome = await _begin(
          peer,
          _Draft(
            localId: head.localId,
            content: head.content,
            conversationId: id,
            replaces: head.idempotencyKey,
            createdAtMicros: head.createdAtMicros,
          ),
          mode: _Mode.restart,
        );
      } finally {
        _restarting.remove(id);
      }
      if (outcome.result == StartResult.started) {
        // Review F3: the head row is an init row again; the typed error of
        // its earlier failure is not shown with a later one.
        _sender.forgetRefusal(head.localId);
        _onChanged(id);
        unawaited(_resume(id, BudgetPriority.user));
        return _Restart.started;
      }
      final cause = outcome.cause;
      switch (outcome.result) {
        case StartResult.tryAgainTomorrow:
          // The daily cap: the row fails with it, a failed row too (the
          // cap is today's reason).
          if (cause != null) {
            await _failRow(
              id,
              head.idempotencyKey,
              head.localId,
              sendErrorName(cause),
              cause,
            );
          }
        case StartResult.lookupFailed:
        case StartResult.peerHasNoDevice:
        case StartResult.unavailable:
          // Review W2. Decision: an eligible start the user asked for that
          // could not be made fails a head row that had no failure: with
          // the cause's name, else a fixed one. Why: the row would
          // otherwise read "waiting" with no reason and no retry control
          // (the state N1 and N5 were ruled against); failed, it is
          // retryable, and the retry comes back here. A head row that
          // already failed keeps its own reason (review N1).
          if (head.lastError == null) {
            await _failRow(
              id,
              head.idempotencyKey,
              head.localId,
              _startErrorName(outcome.result, cause),
              cause,
            );
          }
        case StartResult.started:
        case StartResult.joinedExisting:
        case StartResult.plaintext:
          // `joinedExisting`: a group appeared meanwhile; the row is the
          // sender's. A restart never answers `plaintext`.
          break;
      }
      return _Restart.notStarted;
    } on _BadRandom {
      _reportOnce('start.random');
      return _Restart.notStarted;
    } on Object catch (e, s) {
      // Decision: a failed read says nothing about whose row this is; the
      // row is left as it is (its failure included).
      _reportIfBug(e, s, 'start.restart');
      return _Restart.notStarted;
    }
  }

  /// The stored error name of a start that could not be made (review W2):
  /// the cause's own name when it has one the sender stores, else the
  /// fixed name of [result].
  String _startErrorName(StartResult result, AppException? cause) {
    final named = cause == null ? null : sendErrorName(cause);
    if (named != null && named != 'AppException') return named;
    return switch (result) {
      StartResult.peerHasNoDevice => kStartErrorPeerHasNoDevice,
      StartResult.lookupFailed => kStartErrorLookupFailed,
      _ => kStartErrorUnavailable,
    };
  }
}

/// What [_KnownRestart._restartKnown] did (review N1).
///
/// `started`: a new provisional group is stored and its init is being sent.
/// `notEligible`: not a conversation a new start is for (this device was a
/// member, or the flag is not on, it was removed elsewhere, the thread
/// cannot be answered): the rows are the sender's. `notStarted`: a start
/// could be made and was not; the row stays as it is.
enum _Restart { started, notEligible, notStarted }
