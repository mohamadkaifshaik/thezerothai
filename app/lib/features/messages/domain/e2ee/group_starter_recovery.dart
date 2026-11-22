part of 'group_starter.dart';

/// R6 step 4: sending a provisional group's init and what each answer does
/// to it, and resuming or expiring provisional groups at vault ready and
/// before a send.
extension _Recovery on GroupStarter {
  /// Resumes or expires every provisional group this class owns (its
  /// pending commit is an init), one conversation lock at a time: a young
  /// one has its init resent byte for byte; one older than
  /// [kProvisionalExpiry] is settled from the server's first stored commit.
  /// Never throws.
  Future<void> _resumeAll(BudgetPriority priority) async {
    final vault = _session.vault;
    if (vault == null) return;
    try {
      if (!_known.isLoadedFor(vault)) await _known.load(vault);
      for (final id in await vault.groupConversationIds()) {
        if (!identical(_session.vault, vault)) return;
        if (!(await vault.groups(id)).any((g) => g.provisional)) continue;
        await _resume(id, priority);
      }
    } on Object catch (e, s) {
      _reportIfBug(e, s, 'start.resumeAll');
    }
  }

  /// One resume of [id] (single flight: a call while one runs joins it).
  Future<void> _resume(String id, BudgetPriority priority) {
    final running = _running[id];
    if (running != null) return running;
    late final Future<void> run;
    run = _resumeOnce(id, priority).whenComplete(() {
      if (identical(_running[id], run)) _running.remove(id);
    });
    return _running[id] = run;
  }

  Future<void> _resumeOnce(String id, BudgetPriority priority) async {
    try {
      var next = await _locks.run(id, () => _resumeLocked(id, priority));
      final rebuild = next.localId;
      if (next.kind == _NextKind.rebuild && rebuild != null) {
        // Fresh claims under no lock; then the new init is sent. One
        // rebuild per resume.
        next = await _rebuild(id, rebuild)
            ? await _locks.run(
                id,
                () => _resumeLocked(id, priority, mayRebuild: false),
              )
            : const _Next(_NextKind.drain);
      }
      // Scheduled here, outside the lock's zone: the resend it starts must
      // not read as holding the lock.
      final wait = next.resendAfter;
      if (wait != null) {
        _schedule(wait, () => unawaited(_resume(id, priority)));
      }
      // What follows runs after the lock was released, through the public
      // entries (each takes the conversation lock itself).
      switch (next.kind) {
        case _NextKind.none:
        case _NextKind.rebuild:
          break;
        case _NextKind.drain:
          await _sender.drain(id, priority: priority);
        case _NextKind.join:
          // Another device started first: join from its welcome (an unheld
          // poll; a held one may stop before the welcome's page), catch up,
          // and the sender encrypts the row again under a NEW key once this
          // device is a member. Until then the row waits.
          try {
            await _crypto.processWelcomes(priority: priority);
          } on Object catch (e, s) {
            _reportIfBug(e, s, 'start.welcomes');
          }
          await _crypto.catchUp(id, priority: priority);
          await _sender.drain(id, priority: priority);
        case _NextKind.pull:
          // The init was found among the stored commits: its message comes
          // back as an echo of the live pull, or the sender resends it.
          await _receiver.pullLive(id, priority: priority);
          await _sender.drain(id, priority: priority);
      }
    } on Object catch (e, s) {
      _reportIfBug(e, s, 'start.resume');
    }
  }

  /// One step with [id]'s lock held.
  Future<_Next> _resumeLocked(
    String id,
    BudgetPriority priority, {
    bool mayRebuild = true,
  }) async {
    const none = _Next(_NextKind.none);
    final op = await _op();
    if (op == null) return none;
    GroupRecord? group;
    for (final g in await op.vault.groups(id)) {
      if (g.provisional) group = g;
    }
    final pending = group?.pending;
    // Not provisional (settled meanwhile), or a provisional group that is
    // not an init's (Task 10's reset owns that one).
    if (group == null || pending == null || pending.kind != PendingKind.init) {
      return none;
    }
    final row = await _initRow(op.vault, id, group.generation);
    final created = group.provisionalCreatedAtMicros;
    final age = created == null
        ? kProvisionalExpiry
        : _now().difference(
            DateTime.fromMicrosecondsSinceEpoch(created, isUtc: true),
          );
    if (row != null && age < kProvisionalExpiry) {
      return _sendLocked(op, id, group, row, priority);
    }
    return _expireLocked(op, id, group, pending, row, priority, mayRebuild);
  }

  /// The row that carries the init of [id]'s provisional group: addressed
  /// by its id, or by the recipient reference stored for it.
  Future<OutboxItem?> _initRow(SecureVault vault, String id, int g) async {
    final peerRef = _known.peerOf(id);
    for (final r in (await vault.outbox()).items) {
      final mine =
          r.conversationId == id ||
          (r.conversationId == null &&
              peerRef != null &&
              r.recipientUserId == peerRef);
      if (mine &&
          r.init != null &&
          r.stage == OutboxStage.encrypted &&
          r.generation == g) {
        return r;
      }
    }
    return null;
  }

  // -------------------------------------------------------------------------
  // The init send

  /// Sends [row] with its init, with the lock held: the same request, byte
  /// for byte under the same key, addressed exactly as stored.
  Future<_Next> _sendLocked(
    _Op op,
    String id,
    GroupRecord group,
    OutboxItem row,
    BudgetPriority priority,
  ) async {
    const none = _Next(_NextKind.none);
    final g = group.generation;
    // An init is never sent with the flag off or unknown (R1), nor by a
    // device removed elsewhere, nor into a thread that cannot be answered.
    if (!_session.mayStart || _removedElsewhere()) return none;
    if (!_contexts.of(id).canReply) return none;
    // The pins of a provisional group all have a side from the start. One
    // that lost it since (a key history that turned unreadable, a taint) is
    // not attributable: these bytes are not handed over.
    if ((await op.vault.members(id))
        .any((m) => m.side == MemberSide.unattributed)) {
      return none;
    }
    final notBefore = _notBefore[row.localId];
    if (notBefore != null && _now().isBefore(notBefore)) return none;

    // Whether an earlier attempt may have reached the server is a stored
    // fact (the row's attempts), written BEFORE the call: a crash in the
    // middle of a first attempt is a retry afterwards, never a "first".
    var first = row.attempts == 0;
    final key = row.idempotencyKey;
    try {
      final noted = await _session.runWrite((v) async {
        op.check(v);
        OutboxItem? fresh;
        for (final r in (await v.outbox()).items) {
          if (r.idempotencyKey == key) fresh = r;
        }
        if (fresh == null ||
            fresh.init == null ||
            fresh.stage != OutboxStage.encrypted) {
          return false;
        }
        await v.transaction(
          (tx) => tx.putOutbox(_withAttempt(fresh!, fresh.attempts + 1)),
        );
        return true;
      });
      if (!noted) return none;
    } on Object catch (e, s) {
      _reportIfBug(e, s, 'start.attempt');
      return none;
    }
    // See SecureVault.confirmStored: exact on Android; on the web
    // persistence before send remains a stated limit.
    var stored = false;
    try {
      stored = await op.vault.confirmStored(key);
    } on Object catch (e, s) {
      _reportIfBug(e, s, 'start.confirmStored');
    }
    if (!stored) return none;

    var tries = _unknown.contains(row.localId) ? 1 : 2;
    while (true) {
      if (!op.live) return none;
      final pb.SendMessageResponse response;
      try {
        response = await _messaging.sendEncrypted(
          idempotencyKey: key,
          conversationId: row.conversationId,
          recipientUserId: row.recipientUserId,
          ciphertext: row.ciphertext,
          pair: MlsPair(row.generation, row.epoch),
          reportCommitment: row.reportCommitment,
          mlsInit: row.init,
        );
      } on StaleEpochException catch (e) {
        // The answer of a send addressed by recipient names the
        // conversation it landed in: it must be the claim's (K2).
        final named = e.conversationId;
        final other = row.recipientUserId != null
            ? named != id
            : named != null && named != id;
        if (other) {
          // Decision: the refusal names another conversation than the
          // claim did (or, for a recipient-addressed send, none). Nothing
          // is deleted on it and nothing is sent again now; the stored
          // commits decide after the expiry.
          _reportOnce('start.staleConversation');
          _unknown.add(row.localId);
          return none;
        }
        // Another device started first. The discard never touches the key
        // history or a mark.
        if (!await _crypto.discardProvisionalLocked(id, g)) return none;
        _forget(row.localId);
        return const _Next(_NextKind.join);
      } on AppException catch (e) {
        if (sendOutcomeUnknown(e)) {
          // The same request again; the group stays provisional.
          first = false;
          tries--;
          final wait = _retryAfterOf(e);
          if (wait == null) {
            if (tries > 0) continue;
          } else {
            _notBefore[row.localId] = _now().add(wait);
            _unknown.add(row.localId);
            // The one automatic resend, at the server's time (scheduled
            // once the lock is released).
            return _Next(_NextKind.none, resendAfter: tries > 0 ? wait : null);
          }
          _unknown.add(row.localId);
          return none;
        }
        // A refusal. On a retry (an earlier attempt's outcome is unknown)
        // the server may hold the init all the same: its first page says.
        // The brief names FEATURE_DISABLED and CANNOT_MESSAGE; decision:
        // every refusal of a retry is checked this way (never a delete on a
        // refusal that may follow a stored init).
        if (!first) {
          final found = await _storedAnyway(id, row);
          if (found.unknown) {
            _unknown.add(row.localId);
            return none;
          }
          final delivered = found.delivered;
          if (delivered != null) {
            return _settle(id, g, row, delivered, priority);
          }
        }
        return _refuse(id, g, row, e);
      } on Object catch (e, s) {
        _reportIfBug(e, s, 'start.sendEncrypted');
        _unknown.add(row.localId);
        return none;
      }
      // Stored under the row's expected id, never the id in the response.
      final message = response.message;
      if (message.id.isNotEmpty && message.id != row.expectedMessageId) {
        _reportOnce('start.responseId');
      }
      return _settle(
        id,
        g,
        row,
        InitDelivered(
          accepted: _acceptedIn(response.conversation, id),
          atMicros: _microsOf(message),
        ),
        priority,
      );
    }
  }

  /// `requestAccepted` comes from the answer's conversation state, for this
  /// conversation only. Nothing else of the answer's header is taken (the
  /// request direction least of all).
  bool _acceptedIn(pb.Conversation header, String id) =>
      header.id == id &&
      header.state == ConversationState.CONVERSATION_STATE_ACCEPTED;

  /// The server stored the init: the one success function.
  Future<_Next> _settle(
    String id,
    int g,
    OutboxItem row,
    InitDelivered delivered,
    BudgetPriority priority,
  ) async {
    final settled = await _crypto.settleOwnInitLocked(
      id,
      g,
      delivered: delivered,
      priority: priority,
    );
    if (settled == InitSettle.settled || settled == InitSettle.notProvisional) {
      _forget(row.localId);
      _onChanged(id);
      // Rows typed while the group was provisional go out now.
      return const _Next(_NextKind.drain);
    }
    // Nothing was written: the row stays, and the same request is answered
    // alike at the next trigger.
    _unknown.add(row.localId);
    return const _Next(_NextKind.none);
  }

  /// A definitive refusal: the provisional group and its pins go, and the
  /// row fails with the server's reason (at stage `plain`, under the
  /// conversation id: the sender shows it).
  Future<_Next> _refuse(
    String id,
    int g,
    OutboxItem row,
    AppException e,
  ) async {
    const none = _Next(_NextKind.none);
    if (!await _crypto.discardProvisionalLocked(
      id,
      g,
      lastError: sendErrorName(e),
    )) {
      _unknown.add(row.localId);
      return none;
    }
    _forget(row.localId);
    _sender.rememberRefusal(row.localId, e);
    if (e is CannotMessageException) _contexts.of(id).canReply = false;
    _onChanged(id);
    return none;
  }

  /// After a refusal of a retry: whether the first `ListMessages` page
  /// holds a message with the row's expected id (and its bytes, or none
  /// when the ciphertext was removed). NOT_FOUND, or a page without it: not
  /// stored. Any other failure: unknown (nothing is deleted on it).
  Future<({InitDelivered? delivered, bool unknown})> _storedAnyway(
    String id,
    OutboxItem row,
  ) async {
    const notStored = (delivered: null, unknown: false);
    const unknown = (delivered: null, unknown: true);
    final pb.ListMessagesResponse page;
    try {
      page = await _messaging.listMlsMessages(conversationId: id);
    } on NotFoundException {
      return notStored;
    } on Object catch (e, s) {
      _reportIfBug(e, s, 'start.listMessages');
      return unknown;
    }
    for (final m in page.messages) {
      if (m.id != row.expectedMessageId) continue;
      if (m.ciphertext.isNotEmpty && !_same(m.ciphertext, row.ciphertext)) {
        // The id with other bytes is not this row's echo: nothing is
        // decided on it.
        _reportOnce('start.echoBytes');
        return unknown;
      }
      return (
        delivered: InitDelivered(
          accepted: _acceptedIn(page.conversation, id),
          atMicros: _microsOf(m),
        ),
        unknown: false,
      );
    }
    return notStored;
  }

  // -------------------------------------------------------------------------
  // Expiry

  /// A provisional group older than [kProvisionalExpiry] (or one whose row
  /// is gone), with the lock held: the server's first stored commit decides.
  Future<_Next> _expireLocked(
    _Op op,
    String id,
    GroupRecord group,
    PendingCommit pending,
    OutboxItem? row,
    BudgetPriority priority,
    bool mayRebuild,
  ) async {
    const none = _Next(_NextKind.none);
    if (!await _takeSyncUnit(priority)) return none;
    // Null: the answer does not say (nothing is decided on it).
    bool? own;
    try {
      final page = await _messaging.listConversationCommits(
        conversationId: id,
        after: null,
        pageSize: kCommitPageSize,
      );
      if (page.commits.isEmpty) {
        // No commit at all, and the server says the conversation has none.
        own = page.mlsGeneration == Int64.ZERO && page.mlsEpoch == Int64.ZERO
            ? false
            : null;
      } else {
        final c = page.commits.first;
        final cg = pairComponentFromInt64(c.mlsGeneration);
        final ce = pairComponentFromInt64(c.mlsEpoch);
        if (cg != null && ce != null) {
          own =
              MlsPair(cg, ce) == pending.builtOn &&
              _same(c.commit, pending.commit);
        }
      }
    } on NotFoundException {
      own = false;
    } on Object catch (e, s) {
      _reportIfBug(e, s, 'start.listConversationCommits');
      return none;
    }
    if (own == null) return none;
    if (own) {
      // The init was accepted: the same success steps, without an answer
      // for the message itself.
      final settled = await _crypto.settleOwnInitLocked(
        id,
        group.generation,
        priority: priority,
      );
      if (settled != InitSettle.settled) return none;
      if (row != null) _forget(row.localId);
      _onChanged(id);
      return const _Next(_NextKind.pull);
    }
    // Decision: while this device may not start again (the flag is not on,
    // or it was removed elsewhere) the group is kept as it is: nothing is
    // sent either way, and nothing is destroyed that it could not rebuild.
    if (!mayRebuild || !_session.mayStart || _removedElsewhere()) return none;
    if (!await _crypto.discardProvisionalLocked(id, group.generation)) {
      return none;
    }
    if (row == null) return const _Next(_NextKind.drain);
    _forget(row.localId);
    return _Next(_NextKind.rebuild, localId: row.localId);
  }

  /// Starts again from fresh claims for the stage-plain row [localId] of
  /// [id] (its discarded group's first message). True when a new
  /// provisional group was stored. At a daily claim cap the row fails
  /// (`tryAgainTomorrow`); on any other refusal it waits.
  Future<bool> _rebuild(String id, String localId) async {
    final vault = _session.vault;
    final peer = _known.peerOf(id);
    if (vault == null || peer == null) return false;
    OutboxItem? row;
    for (final r in (await vault.outbox(conversationId: id)).items) {
      if (r.localId == localId &&
          r.stage == OutboxStage.plain &&
          r.init == null) {
        row = r;
      }
    }
    if (row == null) return false;
    final StartOutcome outcome;
    try {
      outcome = await _begin(
        peer,
        _Draft(
          localId: row.localId,
          content: row.content,
          conversationId: id,
          replaces: row.idempotencyKey,
          createdAtMicros: row.createdAtMicros,
        ),
        rebuild: true,
      );
    } on _BadRandom {
      _reportOnce('start.random');
      return false;
    }
    if (outcome.result == StartResult.started) {
      _onChanged(id);
      return true;
    }
    final cause = outcome.cause;
    if (outcome.result == StartResult.tryAgainTomorrow && cause != null) {
      final key = row.idempotencyKey;
      final op = await _op();
      if (op == null) return false;
      final failed = await _locks.run(
        id,
        () => _session.runWrite((v) async {
          op.check(v);
          OutboxItem? fresh;
          for (final r in (await v.outbox(conversationId: id)).items) {
            if (r.idempotencyKey == key) fresh = r;
          }
          if (fresh == null || fresh.stage != OutboxStage.plain) return false;
          await v.transaction(
            (tx) => tx.putOutbox(
              _withAttempt(
                fresh!,
                fresh.attempts + 1,
                lastError: sendErrorName(cause),
              ),
            ),
          );
          return true;
        }),
      );
      if (failed) {
        _sender.rememberRefusal(localId, cause);
        _onChanged(id);
      }
    }
    return false;
  }

  void _forget(String localId) {
    _unknown.remove(localId);
    _notBefore.remove(localId);
  }
}

/// [r] with its attempts (and, when given, its error) changed; every other
/// field, its bytes, its key and its addressing included, as it is.
OutboxItem _withAttempt(OutboxItem r, int attempts, {String? lastError}) =>
    OutboxItem(
      idempotencyKey: r.idempotencyKey,
      localId: r.localId,
      expectedMessageId: r.expectedMessageId,
      conversationId: r.conversationId,
      recipientUserId: r.recipientUserId,
      generation: r.generation,
      epoch: r.epoch,
      ciphertext: r.ciphertext,
      reportCommitment: r.reportCommitment,
      content: r.content,
      createdAtMicros: r.createdAtMicros,
      stage: r.stage,
      init: r.init,
      attempts: attempts,
      lastError: lastError ?? r.lastError,
    );

/// What a locked step asks to run once the lock is released.
enum _NextKind { none, drain, join, pull, rebuild }

class _Next {
  const _Next(this.kind, {this.localId, this.resendAfter});

  final _NextKind kind;

  /// The local id of the row to rebuild, with [_NextKind.rebuild].
  final String? localId;

  /// The server's retry time of an unknown outcome: one resend is scheduled
  /// when the lock is released.
  final Duration? resendAfter;
}
