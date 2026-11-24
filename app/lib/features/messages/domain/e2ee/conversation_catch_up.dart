part of 'conversation_crypto.dart';

/// Catch-up of one conversation (the conversation lock is held): the pass
/// over the current generation's commits, the generation switch with its
/// nested welcome poll, the server-pair step, and the waiting / walked
/// records. Applying one commit is [_CommitApply]'s.
extension _CatchUp on ConversationCrypto {
  /// Catch-up with [id]'s lock held. Never throws: an unexpected failure is
  /// `interrupted` (nothing was written by a failed body).
  ///
  /// [parent]: the welcome poll this catch-up runs inside (its welcomes are
  /// acknowledged by it, never again by a nested poll).
  Future<CatchUpResult> _catchUpLocked(
    String id, {
    required BudgetPriority priority,
    _Operation? parent,
  }) async {
    final context = _contexts.of(id);
    // Set again only by a pass that ends at the server pair (step 8). Until
    // a commit listing of THIS catch-up answers, the remembered server pair
    // is an older answer (audit M1).
    context
      ..syncedSinceStart = false
      ..serverPairFresh = false;
    try {
      final pass = await _startOperation(priority, parent: parent);
      if (pass == null) return CatchUpResult.interrupted;
      for (var i = 0; i < _kSwitchesPerPass; i++) {
        final step = await _passLocked(pass, id);
        if (step == null) continue; // a newer generation was joined
        // After the pass, so attribution has used the peer reference this
        // run already held before a header could replace it.
        await _settleAcceptanceSightLocked(pass, id);
        switch (step) {
          case CatchUpResult.stuck:
            context.stuck = true;
          case CatchUpResult.current:
          case CatchUpResult.waitingForWelcome:
          case CatchUpResult.notEncrypted:
            context.stuck = false;
          case CatchUpResult.interrupted:
            break;
        }
        return step;
      }
      return CatchUpResult.interrupted;
    } on Object catch (e, s) {
      _reportIfBug(e, s, 'catchUp');
      return CatchUpResult.interrupted;
    }
  }

  /// Defect fix (acceptance sighting): acceptance comes only from the
  /// server's header for a conversation this device keeps state for, and a
  /// since-poll carries none.
  ///
  /// 1. A sight a header made before this vault kept a record or a group
  ///    ([ConversationContext.acceptedSightingHeld]) is handed back to
  ///    [ConversationContexts.onAcceptedSeen] now that one exists (it only
  ///    queues; the caller holds the lock).
  /// 2. A restart loses that memory: while a final group is here and the
  ///    stored record is not accepted, one first-page `ListMessages` read
  ///    takes the header. It is the receiver's read (the READ budget, lane
  ///    = the conversation, paused on a rate limit as the probe does), at
  ///    background priority only (a user-priority pass, which a send may
  ///    follow, makes none), once per conversation and run, at most
  ///    [kAcceptanceHeaderReadsPerRun] across conversations and
  ///    [kAcceptanceHeaderFailuresPerRun] failures per conversation. None
  ///    when a header of the conversation was already noted this run or a
  ///    held sight was just applied. The header is taken for state, folder
  ///    and `can_reply`; a peer reference the context already holds stays.
  /// 3. A stored accepted record settles the conversation for the run, so
  ///    later passes read nothing here.
  Future<void> _settleAcceptanceSightLocked(_Operation pass, String id) async {
    final context = _contexts.of(id);
    if (context.acceptanceSettled || !pass.live) return;
    final held = context.acceptedSightingHeld;
    final wantRead =
        !context.acceptanceHeaderRead &&
        context.acceptanceHeaderFailures < kAcceptanceHeaderFailuresPerRun &&
        _contexts.acceptanceHeaderReads < kAcceptanceHeaderReadsPerRun &&
        pass.priority != BudgetPriority.user;
    try {
      final groups = await pass.vault.groups(id);
      final record = await pass.vault.conversation(id);
      if (record?.sync.requestAccepted ?? false) {
        context.acceptanceSettled = true;
        return;
      }
      if (held && (record != null || groups.isNotEmpty)) {
        context.acceptedSightingHeld = false;
        _contexts.onAcceptedSeen?.call(id);
        return;
      }
      if (!wantRead ||
          !groups.any((g) => !g.provisional) ||
          !pass.live ||
          _messaging.rateLimitedFor() != null ||
          _readBudget.paused ||
          _removedElsewhere()) {
        return;
      }
      _contexts.acceptanceHeaderReads++;
      await _readBudget.take(BudgetPriority.background, lane: id);
      if (!pass.live || _removedElsewhere()) return;
    } on BudgetPaused {
      return;
    } on StateError {
      return;
    } on Object catch (e, s) {
      _reportIfBug(e, s, 'catchUp.acceptanceHeader');
      return;
    }
    try {
      final page = await _messaging.listMlsMessages(conversationId: id);
      if (!pass.live) return;
      context.acceptanceHeaderRead = true;
      // Only the header of the conversation asked for.
      if (page.hasConversation() && page.conversation.id == id) {
        _contexts.note(page.conversation, keepPeer: true);
      }
    } on RateLimitedException catch (e) {
      context.acceptanceHeaderFailures++;
      var wait = e.retryAfter ?? const Duration(minutes: 1);
      if (wait > kMaxServerRetryWait) wait = kMaxServerRetryWait;
      if (wait.isNegative) wait = Duration.zero;
      _readBudget.pauseUntil(_now().add(wait));
    } on Object catch (e, s) {
      context.acceptanceHeaderFailures++;
      _reportIfBug(e, s, 'catchUp.acceptanceHeader');
    }
  }

  /// One pass over the current group's generation. Null: a newer generation
  /// was joined, start again with it.
  Future<CatchUpResult?> _passLocked(_Operation pass, String id) async {
    if (!pass.live) return CatchUpResult.interrupted;
    final context = _contexts.of(id);
    final vault = pass.vault;
    final groups = await vault.groups(id);
    GroupRecord? current;
    for (final group in groups) {
      if (!group.provisional) current = group; // ascending generation
    }
    final record = await vault.conversation(id);
    final accepted = record?.sync.requestAccepted ?? false;
    if (accepted) context.acceptedSeenAt ??= _now();

    // 1. No group: learn the current pair once.
    if (current == null) {
      // A provisional group only: Task 8 settles it; nothing to apply.
      if (groups.isNotEmpty) return CatchUpResult.interrupted;
      final page = await _listCommits(pass, id, null);
      final server = page == null ? null : _serverPairOf(page);
      if (server == null) return CatchUpResult.interrupted;
      if (server == const MlsPair(0, 0)) {
        context.serverPair = null;
        return CatchUpResult.notEncrypted;
      }
      context
        ..serverPair = server
        ..serverPairFresh = true;
      await _noteWaiting(pass, id, server.generation);
      return CatchUpResult.waitingForWelcome;
    }

    final g = current.generation;
    var e = current.epoch;
    // The pair of the last commit applied to this group.
    var after = e >= 1 ? MlsPair(g, e - 1) : record?.afterPair;
    MlsPair? server;
    var switching = false;
    var gStuck = false;
    var read = 0;
    pages:
    while (true) {
      final page = await _listCommits(pass, id, after);
      server = page == null ? null : _serverPairOf(page);
      if (page == null || server == null) return CatchUpResult.interrupted;
      context
        ..serverPair = server
        ..serverPairFresh = true;
      final serverAhead = server.generation > g;
      for (final c in page.commits) {
        final cg = pairComponentFromInt64(c.mlsGeneration);
        final ce = pairComponentFromInt64(c.mlsEpoch);
        if (cg != null && cg > g) {
          // 6. A later generation: g is done; its epoch-0 record is never
          // applied.
          switching = true;
          break pages;
        }
        if (cg != g || ce != e) {
          // 5. A gap (or a pair the client cannot hold).
          if (serverAhead) {
            gStuck = true;
            switching = true;
            break pages;
          }
          return CatchUpResult.stuck;
        }
        switch (await _applyLocked(pass, id, MlsPair(g, e), c)) {
          case _Applied.ok:
            after = MlsPair(g, e);
            e++;
          case _Applied.selfRemoved:
            return CatchUpResult.waitingForWelcome;
          case _Applied.interrupted:
            return CatchUpResult.interrupted;
          case _Applied.stuck:
            if (serverAhead) {
              gStuck = true;
              switching = true;
              break pages;
            }
            return CatchUpResult.stuck;
        }
      }
      if (!page.more || page.commits.isEmpty) break;
      // The page cap: every applied commit is stored; the next pass goes on
      // from the stored after-pair (never stuck, never a switch).
      if (++read >= _kCommitPagesMax) return CatchUpResult.interrupted;
    }

    if (!switching) {
      final here = MlsPair(g, e);
      if (server.generation > g) {
        switching = true;
      } else if (server == here) {
        return _atServerPair(pass, id, server);
      } else if (server.compareTo(here) > 0) {
        // 5. No commit returned while the server pair is ahead.
        return CatchUpResult.stuck;
      } else {
        // The server is behind this device: nothing to apply; look again.
        return CatchUpResult.interrupted;
      }
    }

    // 6. Generation switch: g's last epoch is walked to its end first (L6).
    final last = MlsPair(g, e);
    // A LOWER stored generation catch-up never walks (it walks the highest
    // only), not recorded as walked: its last epoch is decrypted with its
    // kept group (the orphan walk, receive-walks §6) and recorded with g's,
    // so the join deletes it too.
    final done =
        (await vault.conversation(id))?.sync.completedEpochs ??
        const <MlsPair>[];
    final orphans = [
      for (final old in await vault.groups(id))
        if (!old.provisional &&
            old.generation < g &&
            !done.contains(MlsPair(old.generation, old.epoch)))
          MlsPair(old.generation, old.epoch),
    ];
    final sink = this.sink;
    try {
      for (final o in orphans) {
        await sink?.completeEpoch(id, o, priority: pass.priority);
      }
      if (gStuck) {
        await sink?.markEpochUndecryptable(id, last, priority: pass.priority);
      } else {
        await sink?.completeEpoch(id, last, priority: pass.priority);
      }
    } on Object catch (err, s) {
      _reportIfBug(err, s, 'completeEpoch');
      return CatchUpResult.interrupted;
    }
    await _noteWalked(pass, id, [...orphans, last]);
    await _pollWelcomes(
      priority: pass.priority,
      held: id,
      serverPairs: {id: server},
      parent: pass,
      fromSwitch: true,
    );
    if (!pass.live) return CatchUpResult.interrupted;
    final after2 = await vault.groups(id);
    if (after2.any((x) => !x.provisional && x.generation > g)) return null;
    await _noteWaiting(pass, id, server.generation);
    return CatchUpResult.waitingForWelcome;
  }

  /// Step 8: the pair is current. Attribution when a member is unattributed
  /// and not concluded this run; then R7 / M10's `syncedSinceStart`.
  Future<CatchUpResult> _atServerPair(
    _Operation pass,
    String id,
    MlsPair server,
  ) async {
    final context = _contexts.of(id);
    if (!pass.live) return CatchUpResult.interrupted;
    final unattributed = (await pass.vault.members(id))
        .any((m) => m.side == MemberSide.unattributed);
    if (!unattributed) {
      context
        ..attributionPending = false
        ..attributionConcluded = true
        ..deferredSince = null;
    } else if (!context.attributionConcluded) {
      try {
        await _attributeMembersLocked(pass, id);
      } on Object catch (e, s) {
        _reportIfBug(e, s, 'attribute');
        context.attributionPending = true;
      }
    }
    context.syncedSinceStart =
        !context.attributionPending &&
        context.serverPairFresh &&
        context.livePulledAt == server;
    return CatchUpResult.current;
  }

  /// One `ListConversationCommits` call (one sync-budget unit); null when it
  /// could not be made or failed.
  Future<pb.ListConversationCommitsResponse?> _listCommits(
    _Operation pass,
    String id,
    MlsPair? after,
  ) async {
    // Fix wave 4 (CR Minor A): a stale operation (its vault gone, or "set
    // up again" ran since it started) lists nothing.
    if (!pass.live || !await _takeSyncUnit(pass.priority) || !pass.live) {
      return null;
    }
    try {
      return await _messaging.listConversationCommits(
        conversationId: id,
        after: after,
        pageSize: kCommitPageSize,
      );
    } on Object catch (e, s) {
      _reportIfBug(e, s, 'listConversationCommits');
      return null;
    }
  }

  /// Steps 1 and 6: the device waits for a welcome of [generation]. The
  /// first-saw record is written when that generation is not recorded yet
  /// (never moved earlier), with the known set (C1) in the same transaction.
  Future<void> _noteWaiting(_Operation pass, String id, int generation) async {
    final wrote = await _session.runWrite((v) async {
      pass.check(v);
      final record = await v.conversation(id);
      final sync = record?.sync ?? const ConversationSync();
      final seen = sync.firstSawGeneration;
      final record0 =
          seen == null ||
          seen < generation ||
          sync.firstSawGenerationAtMicros == null;
      final needKnown = !_known.contains(id);
      if (!record0 && !needKnown) return false;
      try {
        await v.transaction((tx) async {
          if (record0) {
            await tx.putConversationSync(
              id,
              sync.copyWith(
                firstSawGeneration: generation,
                firstSawGenerationAtMicros: _now().microsecondsSinceEpoch,
              ),
            );
          }
          if (needKnown) await _known.addIn(tx, v, id);
        });
      } on Object {
        _known.discardStaged();
        rethrow;
      }
      _known.commitStaged();
      return needKnown;
    });
    if (wrote) {
      try {
        await _messaging.noteEverEncrypted(id, session: pass.cacheSession);
      } on Object catch (e, s) {
        _reportIfBug(e, s, 'noteEverEncrypted');
      }
    }
  }

  /// L6: [walked], generation g's last epoch (and those of lower stored
  /// generations left behind), was walked to its end after the server
  /// reported a later generation (completed or marked undecryptable):
  /// recorded in `completedEpochs`, which the next join reads to delete
  /// those generations.
  Future<void> _noteWalked(_Operation pass, String id, List<MlsPair> walked) =>
      _session.runWrite((v) async {
        pass.check(v);
        final sync =
            (await v.conversation(id))?.sync ?? const ConversationSync();
        final add = [
          for (final p in walked)
            if (!sync.completedEpochs.contains(p)) p,
        ];
        if (add.isEmpty) return;
        await v.transaction(
          (tx) => tx.putConversationSync(
            id,
            sync.copyWith(completedEpochs: [...sync.completedEpochs, ...add]),
          ),
        );
      });
}

MlsPair? _serverPairOf(pb.ListConversationCommitsResponse page) {
  final g = pairComponentFromInt64(page.mlsGeneration);
  final e = pairComponentFromInt64(page.mlsEpoch);
  return g == null || e == null ? null : MlsPair(g, e);
}
