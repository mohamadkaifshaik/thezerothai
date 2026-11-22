part of 'group_starter.dart';

/// R6 step 4: sending a provisional group's init and what each answer does
/// to it, and resuming or expiring provisional groups at vault ready and
/// before a send.
extension _Recovery on GroupStarter {
  /// Resumes or expires every provisional group this class owns (its
  /// pending commit is an init or, Task 10, a reset), one conversation lock
  /// at a time. An init: a young one has its init resent byte for byte; one
  /// [kProvisionalExpiry] old is decided by the server's first stored commit
  /// ([_expireLocked]). A reset: its record at (g + 1, 0) decides, and a
  /// young one is resent only as [_resetResumeLocked] allows. Never throws.
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
        next = await _rebuild(id, rebuild, priority)
            ? await _locks.run(
                id,
                () => _resumeLocked(id, priority, mayRebuild: false),
              )
            : const _Next(_NextKind.none);
      }
      await _afterNext(id, next, priority);
    } on Object catch (e, s) {
      _reportIfBug(e, s, 'start.resume');
    }
  }

  /// What a locked step asked for, run once the lock was released (the
  /// resume's and the reset's). Never throws.
  Future<void> _afterNext(
    String id,
    _Next next,
    BudgetPriority priority,
  ) async {
    try {
      // Scheduled here, outside the lock's zone: the resend it starts must
      // not read as holding the lock. Review m-4 (the sender's m1 rule): a
      // timer is no user intent, so the resend never runs at user priority
      // (the drain after a settle could then accept a request, audit M3);
      // a user start's resend runs at live, ahead of the background sweep,
      // and any other keeps its priority.
      final wait = next.resendAfter;
      if (wait != null) {
        final later = priority == BudgetPriority.user
            ? BudgetPriority.live
            : priority;
        _schedule(wait, () => unawaited(_resume(id, later)));
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
          // The server holds the init and no answer for its message could
          // be had ([_answerFromPage]): one live pull. The group is still
          // provisional and the row still carries its init.
          await _receiver.pullLive(id, priority: priority);
          await _sender.drain(id, priority: priority);
        case _NextKind.settledReset:
          // Task 10: the reset is final; catch up on g + 1 (attribution
          // of its members) and the rows waiting behind it go out (a row
          // of g is answered STALE_EPOCH and re-encrypted in g + 1).
          await _crypto.catchUp(id, priority: priority);
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
    if (group == null || pending == null) return none;
    // Task 10 amendment 4: a provisional reset is resumed, or settled or
    // expired from its record at (g + 1, 0), by its own steps.
    if (pending.kind == PendingKind.reset) {
      return _resetResumeLocked(op, id, group, pending, priority);
    }
    // Not an init's (nothing else is ever provisional).
    if (pending.kind != PendingKind.init) return none;
    final row = await _initRow(op.vault, id, group.generation);
    if (_ageOf(group) < kProvisionalExpiry) {
      // Audit M3. Decision: a young group with no readable init row waits;
      // it is not expired. Why: the row may only be unreadable now, and a
      // request of it may still be in flight; the commits asked now could
      // answer "not stored" and the discard that follows cannot be undone.
      // At 24 h the commits decide, with nothing in flight.
      if (row == null) return none;
      // Inside the margin before expiry no init is sent ([_sendsNoMore]).
      if (_sendsNoMore(group)) return none;
      return _sendLocked(op, id, group, row, priority);
    }
    return _expireLocked(op, id, group, pending, row, priority, mayRebuild);
  }

  /// How long ago [group] was made provisional; [kProvisionalExpiry] when
  /// it carries no creation time.
  ///
  /// Review M4 (the class of N8). Decision: a creation time AFTER now (the
  /// device clock moved back) has no age that can be told, so the group
  /// counts as expired: its init is sent no more and the stored commits
  /// decide. Why: a negative age would pass as "young" for as long as the
  /// clock stays behind, and the 24 h bound on resending one init would not
  /// hold.
  Duration _ageOf(GroupRecord group) {
    final created = group.provisionalCreatedAtMicros;
    if (created == null) return kProvisionalExpiry;
    final at = DateTime.fromMicrosecondsSinceEpoch(created, isUtc: true);
    final now = _now();
    return at.isAfter(now) ? kProvisionalExpiry : now.difference(at);
  }

  /// Audit M3: whether [group]'s init is sent no more: it is within
  /// [kInitResendMargin] of [kProvisionalExpiry], or older.
  bool _sendsNoMore(GroupRecord group) =>
      _ageOf(group) >= kProvisionalExpiry - kInitResendMargin;

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
  ///
  /// [replay] (review W1): the stored commits say the server holds this
  /// init, and this send is the REPLAY that asks for the message's answer.
  /// The server answers a stored message of this key and this request with
  /// that message for good, ahead of STALE_EPOCH and of the device check
  /// (`backend/internal/messaging/repo_firestore.go`, `Send` and
  /// `replayOrRefuse`; `service_init_test.go`, TestSendInit_Replay). One
  /// request, and no answer to it deletes the group or fails the row: a
  /// refusal made before the server's replay lookup (the recipient checks,
  /// a rate limit) is asked of the first `ListMessages` page instead, and
  /// an outcome that stays unknown leaves the group provisional and the row
  /// with its init, for the next trigger. The gates below hold a replay as
  /// they hold any init send (nothing is decided while one does).
  Future<_Next> _sendLocked(
    _Op op,
    String id,
    GroupRecord group,
    OutboxItem row,
    BudgetPriority priority, {
    bool replay = false,
  }) async {
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

    var tries = replay || _unknown.contains(row.localId) ? 1 : 2;
    while (true) {
      if (!op.live) return none;
      // Audit M3: checked before EVERY request of the loop, so the
      // automatic resend does not start inside the margin either. A replay
      // is exempt: the commits already said "stored", and no answer to it
      // deletes anything.
      if (!replay && _sendsNoMore(group)) return none;
      // Task 9 concern 1: when this call's outcome stays unknown, its
      // request may reach the server until [kInitResendMargin] after now.
      // Not for a replay: the commits already said "stored", and a later
      // store cannot undo that.
      final callStartedAt = _now();
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
        // The commits say this init is stored: the page answers, or nothing
        // is decided. Never a discard.
        if (replay) return _answerFromPage(id, group, row, priority);
        if (!first) {
          final kept = await _keptIfStored(id, group, row, priority);
          if (kept != null) return kept;
        }
        // Another device started first. The discard never touches the key
        // history or a mark.
        if (!await _crypto.discardProvisionalLocked(id, g)) return none;
        _forget(row.localId);
        return const _Next(_NextKind.join);
      } on AppException catch (e) {
        if (sendOutcomeUnknown(e)) {
          if (!replay) _noteUnknownStart(id, callStartedAt);
          // Audit M2: a call the client stopped waiting for may still
          // leave it; the expiry waits for its end.
          _trackInit(id, key);
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
        // Review W1. Decision: VALIDATION idempotency_key says the server
        // holds a message under this row's key, so it is "stored", on a
        // first attempt too: the row never fails on it and the group is
        // never discarded on it. Why: the key is this device's own random
        // one, so the stored message is this row's, whatever the request
        // it was stored from. The same for any refusal of the replay.
        if (replay || e is IdempotencyKeyReusedException) {
          return _answerFromPage(id, group, row, priority);
        }
        // A refusal. The brief names FEATURE_DISABLED and CANNOT_MESSAGE on
        // a retry; decision: every refusal of a retry is checked (never a
        // delete on an answer that may follow a stored init).
        if (!first) {
          final kept = await _keptIfStored(id, group, row, priority);
          if (kept != null) return kept;
        }
        return _refuse(id, g, row, e);
      } on Object catch (e, s) {
        // An outcome nobody can tell: as an unknown one.
        if (!replay) _noteUnknownStart(id, callStartedAt);
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

  /// Review M3. On a RETRY (an earlier attempt's outcome is unknown), before
  /// a refusal or a STALE_EPOCH may delete the group: whether the server
  /// holds this init all the same. Decision: the stored commits decide, not
  /// one `ListMessages` page (a stored init can hide behind 50 newer
  /// messages). The server's replay of a stored message does not expire,
  /// but a refusal made before its replay lookup (the recipient checks, a
  /// rate limit, a disabled feature) can follow a stored init all the
  /// same; deleting a group the server stored would lock its creator out
  /// of it, with no welcome.
  ///
  /// Task 9 ruling N: an earlier attempt that outlived the client's wait
  /// and may still land makes the commits' answer "not decided"
  /// ([_ownInitStored]): the group is kept and the row keeps its init.
  ///
  /// Null: the init is not stored (the caller goes on to discard). Else
  /// what to do instead: the group settled with the message's answer when
  /// the first page holds it; otherwise nothing is decided and the group
  /// stays provisional ([_answerFromPage]), as when the commits do not say.
  Future<_Next?> _keptIfStored(
    String id,
    GroupRecord group,
    OutboxItem row,
    BudgetPriority priority,
  ) async {
    const none = _Next(_NextKind.none);
    final pending = group.pending;
    final own = pending == null
        ? null
        : await _ownInitStored(id, pending, priority);
    if (own == false) return null;
    if (own == null) {
      _unknown.add(row.localId);
      return none;
    }
    // The identical request was refused a moment ago (that is why this is
    // asked): the page is the answer that is left.
    return _answerFromPage(id, group, row, priority);
  }

  /// Review W1. The server holds this init (the stored commits say so, or
  /// it answered VALIDATION idempotency_key for the row's key) and the
  /// identical request got no answer for the message: the first
  /// `ListMessages` page is asked for it.
  ///
  /// The page holds the message: the group settles WITH that answer. Else
  /// NOTHING is settled. Decision: there is no settle without the message's
  /// answer while a row carries the init. Why: a settle without it took the
  /// init off the row and handed the row to the sender, which sent the
  /// row's key without `mls_init`; the server binds the init into the
  /// request hash, so that was VALIDATION idempotency_key (a false "not
  /// sent"), or, once the epoch moved, a second copy of the first message
  /// under a new key. A key that once carried an init is never sent without
  /// it: the group stays provisional, the row keeps its init and is not the
  /// sender's, and the next trigger sends the identical request again
  /// (the server's replay of it is permanent). Cost: the conversation
  /// waits until one answer comes.
  ///
  /// [_storedAnyway]'s `unknown` (the page could not be had, or held the id
  /// with other bytes) is "nothing decided, try again". A readable page
  /// without the message (it can hide behind 50 newer ones) asks for one
  /// live pull, as ruled for the idempotency_key answer; a pull processes
  /// no message while the only group is provisional, so the row is still
  /// answered by the next replay.
  Future<_Next> _answerFromPage(
    String id,
    GroupRecord group,
    OutboxItem row,
    BudgetPriority priority,
  ) async {
    final found = await _storedAnyway(id, row);
    final delivered = found.delivered;
    if (delivered != null) {
      return _settle(id, group.generation, row, delivered, priority);
    }
    _unknown.add(row.localId);
    return _Next(found.unknown ? _NextKind.none : _NextKind.pull);
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

  /// For an init the server holds ([_answerFromPage]): whether the first
  /// `ListMessages` page holds a message with the row's expected id (and
  /// its bytes, or none when the ciphertext was removed). NOT_FOUND, or a
  /// page without it: not shown. Any other failure, or the id with other
  /// bytes: `unknown`, nothing decided, try again. Neither settles
  /// anything.
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

  /// A provisional group [kProvisionalExpiry] old or older (with its init
  /// row, or with none), with the lock held: the server's first stored
  /// commit decides. This init: the identical request is replayed for the
  /// message's answer (review W1). Another, or none: the rebuild, or (no
  /// row) the discard.
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
    // Audit M2: [kInitResendMargin] assumed that the last request left the
    // client when its call started. An init call whose client wait ran out
    // may still leave it: while one runs nothing is asked (a "not stored"
    // read now could be followed by the store), and after its end the
    // margin counts from that end. The end schedules the resume. Task 9
    // concern 1: an unknown outcome's margin is not asked here; it holds
    // only a "not stored" answer, in [_ownInitStored].
    if (_abandonedMayLand(id)) return none;
    final own = await _ownInitStored(id, pending, priority);
    if (own == null) return none;
    if (own) {
      if (row != null) {
        // Review W1: the init was accepted. The identical request is sent
        // once more, here under the lock; the server replays the stored
        // message and the group settles WITH its answer (`requestAccepted`
        // and the own-device alert come from it). Unanswered: nothing is
        // settled and the next trigger asks again.
        return _sendLocked(op, id, group, row, priority, replay: true);
      }
      // No row carries the init (it is gone): the same success steps,
      // with no message to answer for.
      final settled = await _crypto.settleOwnInitLocked(
        id,
        group.generation,
        priority: priority,
      );
      if (settled != InitSettle.settled) return none;
      _onChanged(id);
      return const _Next(_NextKind.drain);
    }
    // Decision: while this device may not start again (the flag is not on,
    // or it was removed elsewhere) the group is kept as it is: nothing is
    // sent either way, and nothing is destroyed that it could not rebuild.
    if (!mayRebuild || !_session.mayStart || _removedElsewhere()) return none;
    if (row == null) {
      // No row to send: there is nothing to rebuild the group for. Audit
      // M3: the "not stored" this discard rests on is the answer read just
      // above, in this same hold of the lock, with no await between the
      // two; the group is 24 h old, so no request of it is in flight
      // ([kInitResendMargin]). A second listing here would be the same
      // call twice.
      await _crypto.discardProvisionalLocked(id, group.generation);
      return const _Next(_NextKind.drain);
    }
    // Review I3. Decision: nothing is deleted here. The fresh claims come
    // first, under no lock; the old group goes only in the transaction
    // that stores the new one. A claim that fails for a passing reason
    // (no network, a rate limit, a kill) then leaves this group in place
    // and the next resume tries again, where a discard first would leave
    // "known, no group" with nothing to retry it.
    return _Next(_NextKind.rebuild, localId: row.localId);
  }

  /// Whether the server's first stored commit is this device's init
  /// ([pending]): at its `builtOn` pair, with its exact bytes. False: the
  /// conversation has no commit, or another one first. Null: the answer
  /// does not say, or could not be had (nothing is decided on it). One
  /// `ListConversationCommits` call, with the lock held.
  ///
  /// Task 9 ruling N (the runner's audit M2 rule, here for every keep or
  /// discard of the starter: a retry's refusal or STALE_EPOCH, the expiry,
  /// the rebuild's discard and its replace). "Not stored" is answered only
  /// when no init call of [id] that outlived the client's wait could still
  /// land: none still runs, and [kInitResendMargin] had passed after the
  /// last one's end when the listing STARTED (`provedAt`, review N1's rule).
  /// Otherwise null: nothing is decided, and that call's end schedules the
  /// resume that asks again ([_trackInit]). Why: a "not stored" read while
  /// the request can still be stored deletes a group the server then holds,
  /// which locks its creator out (no welcome exists for a creator). "Stored"
  /// is kept as read: it cannot be undone by a later store.
  Future<bool?> _ownInitStored(
    String id,
    PendingCommit pending,
    BudgetPriority priority,
  ) async {
    if (!await _takeSyncUnit(priority)) return null;
    final provedAt = _now();
    final own = await _listOwnInit(id, pending);
    if (own == false && _initMayStillLand(id, at: provedAt)) {
      // Task 9 concern 1: held only by an unknown outcome's margin (no
      // abandoned call, whose end schedules its own resume): one resume
      // at the margin's end, so the record decides without another
      // trigger.
      final left = _abandonedMayLand(id, at: provedAt)
          ? null
          : _unknownMarginLeft(id, provedAt);
      if (left != null) _armMarginResume(id, left);
      return null;
    }
    return own;
  }

  /// The one `ListConversationCommits` call of [_ownInitStored].
  Future<bool?> _listOwnInit(String id, PendingCommit pending) async {
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
      return null;
    }
    return own;
  }

  /// The 24 h rebuild (review I3): fresh claims for the init row [localId]
  /// of [id]'s expired provisional group, then ONE transaction that
  /// replaces the old group, its pins and its row by the new ones under a
  /// NEW key. True when the new group was stored. A failed claim changes
  /// nothing. At a daily claim cap (`tryAgainTomorrow`), and when the peer
  /// lists no usable device (review N5), the group is discarded and the row
  /// fails with that reason; the user's retry starts again then. Before
  /// either discard, and before the replace, the stored commits are asked
  /// again under the lock (review F2, audit M3): a delete is made only on a
  /// "not stored" read in the same hold.
  Future<bool> _rebuild(
    String id,
    String localId,
    BudgetPriority priority,
  ) async {
    final vault = _session.vault;
    final peer = _known.peerOf(id);
    if (vault == null || peer == null) return false;
    GroupRecord? group;
    for (final g in await vault.groups(id)) {
      if (g.provisional) group = g;
    }
    final pending = group?.pending;
    if (group == null || pending == null) return false;
    final row = await _initRow(vault, id, group.generation);
    if (row == null || row.localId != localId) return false;
    final StartOutcome outcome;
    try {
      outcome = await _begin(
        peer,
        _Draft(
          localId: row.localId,
          content: row.content,
          // Addressed exactly as the old row was.
          recipient: row.recipientUserId,
          conversationId: row.conversationId,
          expectId: id,
          replaces: row.idempotencyKey,
          replacesCommit: pending.commit,
          createdAtMicros: row.createdAtMicros,
        ),
        mode: _Mode.replace,
        priority: priority,
      );
    } on _BadRandom {
      _reportOnce('start.random');
      return false;
    }
    if (outcome.result == StartResult.started) {
      _forget(localId);
      _onChanged(id);
      return true;
    }
    final cause = outcome.cause;
    // The stored reason of a rebuild that cannot be made, or null for an
    // outcome that may pass (the group then stays as it is).
    final String? reason;
    if (outcome.result == StartResult.tryAgainTomorrow && cause != null) {
      // The daily cap: no claim can succeed today, so the row fails now
      // (the group cannot be rebuilt, and its init was not stored).
      reason = sendErrorName(cause);
    } else if (outcome.result == StartResult.peerHasNoDevice) {
      // Review N5. Decision: the peer lists no usable device (it removed
      // them, or R3 refuses every package). The old init is never sent
      // again after 24 h, so keeping the group would leave the first
      // message "sending" for good, with a commit call and two lookups at
      // every resume and no way for the user to discard it. The group goes
      // and the row fails; the user's retry starts again (F1, option c).
      reason = kStartErrorPeerHasNoDevice;
    } else {
      // `lookupFailed` and `unavailable` are kept: a passing failure (no
      // network, a rate limit, a vault that closed), or a state in doubt
      // (the group changed under the claim, a claim that names another
      // conversation). Nothing is deleted on those; [pendingInit] says
      // `waiting`, never `sending`, for such a group.
      reason = null;
    }
    if (reason != null) {
      final discarded = await _locks.run(id, () async {
        // Review F2. Decision: the commits are asked again here, in the
        // hold of the lock that discards, and the group goes only on "not
        // stored". Why: the expiry's own answer is from an earlier hold,
        // before two lookups of up to 30 s each and a claim; a request the
        // server took long over can be stored in between, and a creator
        // that deleted a stored group is locked out of the conversation
        // (no welcome exists for it). An answer that does not say keeps
        // the group; the next resume asks again.
        if (await _ownInitStored(id, pending, priority) != false) return false;
        return _crypto.discardProvisionalLocked(
          id,
          group!.generation,
          lastError: reason,
        );
      });
      if (discarded) {
        _forget(localId);
        if (cause != null) _sender.rememberRefusal(localId, cause);
        _onChanged(id);
      }
    }
    return false;
  }

  /// The stage-plain row [key] of [id] fails with the error name [name] (a
  /// restart that met a daily claim cap, or that could not be made, review
  /// W2): one more attempt and the name. [cause], when there is a typed
  /// error, is what the sender shows with it; with none, an error this run
  /// remembered for the row earlier is forgotten.
  Future<void> _failRow(
    String id,
    String key,
    String localId,
    String name,
    AppException? cause,
  ) async {
    final op = await _op();
    if (op == null) return;
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
            _withAttempt(fresh!, fresh.attempts + 1, lastError: name),
          ),
        );
        return true;
      }),
    );
    if (failed) {
      if (cause != null) {
        _sender.rememberRefusal(localId, cause);
      } else {
        _sender.forgetRefusal(localId);
      }
      _onChanged(id);
    }
  }

  void _forget(String localId) {
    _unknown.remove(localId);
    _notBefore.remove(localId);
  }

  /// Audit M2: the init call under [key] got no answer in the client's
  /// wait. When it still runs (`MessagingRepository.abandonedMlsCall`), the
  /// expiry of [id] waits for its end; once no such call runs, one resume
  /// is scheduled for [kInitResendMargin] after the end (at background
  /// priority: a timer is no user intent). An end after [reset] changes
  /// nothing.
  void _trackInit(String id, String key) {
    final call = _messaging.abandonedMlsCall(key);
    if (call == null) return;
    final serial = _runSerial;
    _initCallsOut[id] = (_initCallsOut[id] ?? 0) + 1;
    unawaited(
      call.then((_) {
        if (serial != _runSerial) return;
        final left = (_initCallsOut[id] ?? 1) - 1;
        _initCallEndedAt[id] = _now();
        if (left > 0) {
          _initCallsOut[id] = left;
          return;
        }
        _initCallsOut.remove(id);
        // Outside any lock's zone: the resume takes the lock itself.
        Zone.root.run(
          () => _schedule(
            kInitResendMargin,
            () => unawaited(_resume(id, BudgetPriority.background)),
          ),
        );
      }),
    );
  }

  /// Whether an init request of [id] may still reach the server, at [at]
  /// (now when not given; ruling N passes the start of a commit listing):
  /// an abandoned call may still land ([_abandonedMayLand]), or (Task 9
  /// concern 1) a call whose outcome stayed unknown started less than
  /// [kInitResendMargin] before [at] ([_unknownMarginLeft]).
  bool _initMayStillLand(String id, {DateTime? at}) =>
      _abandonedMayLand(id, at: at) ||
      _unknownMarginLeft(id, at ?? _now()) != null;

  /// Task 9 concern 1 (the gate). The runner's rule for the starter: a
  /// call whose outcome stayed unknown (a timeout, a lost answer, an
  /// error nobody can tell) started at [at] for [id]; a later "not
  /// stored" read decides nothing until [kInitResendMargin] after the
  /// LAST such start. Why: the client's wait is shorter than the server's
  /// request deadline, so that request can still be stored after a
  /// refusal of the retry and after the listing that follows it; a
  /// discard then deletes a group the server holds (no welcome exists
  /// for its creator). Cost: a refusal right after an unknown attempt is
  /// decided one margin later (Task 8 decided it at once). Memory of this
  /// run: after a restart the calls of the earlier run are not counted (a
  /// stated limit; the process that made them is gone).
  void _noteUnknownStart(String id, DateTime at) {
    final last = _initUnknownStartedAt[id];
    if (last == null || at.isAfter(last)) _initUnknownStartedAt[id] = at;
  }

  /// The time left, from now, until [kInitResendMargin] has passed after
  /// [id]'s last unknown-outcome call start; null when it had passed at
  /// [at]. Zero when it ends between [at] and now.
  Duration? _unknownMarginLeft(String id, DateTime at) {
    final last = _initUnknownStartedAt[id];
    if (last == null) return null;
    final end = last.add(kInitResendMargin);
    if (!at.isBefore(end)) return null;
    final now = _now();
    return now.isBefore(end) ? end.difference(now) : Duration.zero;
  }

  /// One resume of [id] after [wait] (at background priority: a timer is
  /// no user intent), armed once per conversation at a time. An end after
  /// [reset] changes nothing.
  void _armMarginResume(String id, Duration wait) {
    if (!_marginArmed.add(id)) return;
    final serial = _runSerial;
    Zone.root.run(
      () => _schedule(wait, () {
        if (serial != _runSerial) return;
        _marginArmed.remove(id);
        unawaited(_resume(id, BudgetPriority.background));
      }),
    );
  }

  /// Audit M2: whether an init call of [id] whose client wait ran out
  /// still runs, or ended less than [kInitResendMargin] before [at] (now
  /// when not given).
  bool _abandonedMayLand(String id, {DateTime? at}) {
    if ((_initCallsOut[id] ?? 0) > 0) return true;
    final ended = _initCallEndedAt[id];
    if (ended == null) return false;
    if ((at ?? _now()).isBefore(ended.add(kInitResendMargin))) return true;
    // [at] is never after now: the margin has passed by now as well.
    _initCallEndedAt.remove(id);
    return false;
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
/// `settledReset` (Task 10): an own reset settled; catch up, then drain.
enum _NextKind { none, drain, join, pull, rebuild, settledReset }

class _Next {
  const _Next(this.kind, {this.localId, this.resendAfter, this.refusal});

  final _NextKind kind;

  /// Task 10: the server's refusal of a reset, for the user's
  /// [GroupStarter.resetConversation] to throw (the group is gone).
  final AppException? refusal;

  /// The local id of the row to rebuild, with [_NextKind.rebuild].
  final String? localId;

  /// The server's retry time of an unknown outcome: one resend is scheduled
  /// when the lock is released.
  final Duration? resendAfter;
}
