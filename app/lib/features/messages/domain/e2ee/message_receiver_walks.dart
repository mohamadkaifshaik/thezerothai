part of 'message_receiver.dart';

/// The three walk slots of the receive record (§3.1).
enum _Slot { open, close, orphan }

WalkEntry? _slotOf(ReceiveRecord r, _Slot slot) => switch (slot) {
  _Slot.open => r.open,
  _Slot.close => r.close,
  _Slot.orphan => r.orphan,
};

ReceiveRecord _withSlot(ReceiveRecord r, _Slot slot, WalkEntry? w) =>
    switch (slot) {
      _Slot.open => r.copyWith(open: w),
      _Slot.close => r.copyWith(close: w),
      _Slot.orphan => r.copyWith(orphan: w),
    };

/// What one walk step (or one probe) ended with. [outcome] set: the pass
/// stops with it.
class _StepEnd {
  const _StepEnd._(this.kind, {this.outcome, this.ended = false});

  static const _StepEnd stale = _StepEnd._(_StepKind.stale);
  static const _StepEnd restarted = _StepEnd._(_StepKind.restarted);
  static const _StepEnd advanced = _StepEnd._(_StepKind.applied);
  static const _StepEnd finished = _StepEnd._(_StepKind.applied, ended: true);

  factory _StepEnd.stop(ReceiveOutcome outcome) =>
      _StepEnd._(_StepKind.stop, outcome: outcome);

  final _StepKind kind;
  final ReceiveOutcome? outcome;
  final bool ended;
}

enum _StepKind { applied, stale, restarted, stop }

/// What the probe did (§4).
class _Probe {
  _Probe({
    this.outcome,
    this.fastPath = false,
    this.pulled = false,
    this.caughtUp = false,
    this.sawLater,
    this.listAgain = false,
  });

  /// The pass stops with this (rate limited, budget paused, a failed call,
  /// a retired token).
  final ReceiveOutcome? outcome;

  /// The page was processed on the fast path (§4 rule 1).
  final bool fastPath;

  /// The fast path saved the token or found it already stored.
  final bool pulled;

  /// The fast path's batch ran its one catch-up (a message of a later
  /// pair): the pass runs no other.
  final bool caughtUp;

  /// The page was not processed: the highest pair of its messages above the
  /// group's current pair (as read before the listing); null: none.
  final MlsPair? sawLater;

  /// The page was not processed and its since token was refused for its
  /// shape (nothing is kept for §4 rule 2): the open walk still lists once
  /// more in this pass, so the page's messages come through it.
  final bool listAgain;
  bool waitingForWelcome = false;

  /// The listing was ANSWERED for a request that sent the stored, non-empty
  /// since token (not the anchor, not an empty token): the pass has seen
  /// what changed since that token. Only then may a deferred message be
  /// given to the engine by a retry (fix round 2) or, while no reconcile
  /// entry stands, by a final attempt (the whole-branch fix wave). The
  /// witness itself is the context's
  /// ([ConversationContext.noteProbeAnswered]).
  bool listed = false;
}

extension _Walks on MessageReceiver {
  /// One pass (§2). Never throws.
  Future<ReceiveOutcome> _runPass(String id, BudgetPriority priority) async {
    var welcomes = false;
    // The pass whose probe was answered for the stored, non-empty since
    // token (null: no such answer in this pass).
    _Pass? listed;
    ReceiveOutcome outcome;
    try {
      try {
        outcome = await _passSteps(
          id,
          priority,
          () => welcomes = true,
          (pass) => listed = pass,
        );
      } on Object catch (e, s) {
        _reportIfBug(e, s, 'receive.live');
        outcome = ReceiveOutcome.stopped(_now().add(kWalkBackoff));
      }
      // 6. The deferred retries, after the pass's fresh work (§7.4),
      // whatever the pass ended with (a walk backoff alone skips nothing).
      // Their engine-free checks always run; a due item reaches the ENGINE
      // only with this pass's freshness witness (its probe was answered
      // for the stored since token, [listed]), while no engine hold stands
      // and no reconcile entry exists.
      await _retryDeferred(id, listed: listed);
    } finally {
      // The pass is over, however it ended: the facts that are ITS own
      // (its listing reached the end; its probe was answered for the
      // stored since token) have no life beyond it. The welcome poll below
      // and any catch-up outside a pass never have them.
      _contexts.of(id)
        ..clearListedToEnd()
        ..clearProbeAnswered();
    }
    // Catch-up's held poll stops at a page that lacks the welcome: a welcome
    // it did not find is looked for by an unheld poll, after the lock is
    // released (never a public entry under a held lock).
    if (welcomes) {
      try {
        await _crypto.processWelcomes(priority: priority);
      } on Object catch (e, s) {
        _reportIfBug(e, s, 'receive.welcomes');
      }
    }
    // A `complete` pass does NOT end a fruitless-catch-up streak (a ruling
    // after the design): only the pair moving does, or a catch-up there
    // that applies something or leaves a walk.
    return outcome;
  }

  Future<ReceiveOutcome> _passSteps(
    String id,
    BudgetPriority priority,
    void Function() onWelcomes,
    void Function(_Pass pass) onListed,
  ) async {
    final pass = await _start();
    if (pass == null) return ReceiveOutcome.stopped(_now().add(kWalkBackoff));
    // §7.3: an unreadable deferred record is replaced, and the walks reset,
    // before anything of this pass reads it.
    final held0 = await _deferred.read(pass.vault, id);
    if (held0.unreadable) {
      await _locks.run(id, () => _repairDeferredLocked(pass, id));
    } else {
      _contexts.of(id).deferredEmpty = held0.record.items.isEmpty;
    }
    // A provisional group only, or none (after a reset, after this device
    // was removed, before the conversation is set up again): catch-up and
    // the welcomes own the current pair, and no message can be processed.
    // A ruling after the design: such a pass still probes, as a DETECTOR
    // only, and still runs the reconcile step, so a takedown or an erased
    // account clears stored text also while no group is stored.
    final grouped = await _currentPair(pass.vault, id) != null;

    // 1. The probe. An engine hold (§7.2 as amended: the receiver-wide one
    // after device-level trouble seen by ANY conversation, or this
    // conversation's own after a group-level failure) does not gate the
    // listing: the probe still detects a retired token, arms the reconcile
    // entry and ends a taken-down deferred message. The hold gates the
    // engine: the fast path's batch stops at the first message that needs
    // it. With no final group the probe's page is never processed.
    final probe = await _probe(pass, id, priority, detector: !grouped);
    if (probe.waitingForWelcome) onWelcomes();
    if (probe.listed) onListed(pass);
    if (probe.outcome != null) return probe.outcome!;

    // 2. The reconcile walk (§8.2), right after the probe that may have
    // armed it and before the walks: it needs no engine, so no engine hold
    // and no walk backoff keeps it from running. Whatever it ends with,
    // the walks still run (a tombstone listing that is refused must never
    // stall the conversation); its own outcome only replaces a `complete`.
    var left = kReconcilePagesPerPass;
    int takePage() => left > 0 ? left-- : 0;
    var reconciled = await _reconcileStep(
      pass,
      id,
      priority,
      takePage,
      answered: true,
    );
    if (!grouped) {
      // 3. With no final group: an undecryptable (`u`) close or orphan walk
      // left over from a group that is gone is still finished (§3.4).
      final walked = await _walkWithoutGroup(pass, id, priority);
      if (walked.kind != ReceiveOutcomeKind.complete) return walked;
      // Never `complete` while the reconcile entry has work left. A listing
      // that reached its end and only waits for a since token rests here:
      // no walk of a conversation without a group saves one, so the pass
      // waits (it never asks for an immediate next pass). Each later pass
      // is one probe and that listing's last page again, and a takedown
      // still clears its stored row by id (it shows on the probe's page, or
      // it retires the anchor and the listing begins again from the top).
      return reconciled.outcome ??
          (reconciled.awaiting
              ? ReceiveOutcome.stopped(_now().add(kWalkBackoff))
              : ReceiveOutcome.complete);
    }
    var out = await _walkSteps(pass, id, priority, probe, onWelcomes);
    if (reconciled.awaiting &&
        ((await pass.vault.conversation(id))?.sync.sinceToken ?? '')
            .isNotEmpty) {
      // The listing had reached its end with no since token to leave the
      // conversation with, and this pass saved one: what is left of the
      // allowance lists again (from the top when a page had been applied),
      // and the last page disarms.
      reconciled = await _reconcileStep(
        pass,
        id,
        priority,
        takePage,
        answered: true,
      );
    }
    if (out.kind == ReceiveOutcomeKind.complete) {
      // Never `complete` while the entry is armed with work left.
      out =
          reconciled.outcome ??
          (reconciled.awaiting ? ReceiveOutcome.more : ReceiveOutcome.complete);
    }
    return out;
  }

  /// Steps 3 to 5 of a pass and its end: the walks, one allowance across
  /// them, then the end-of-pass catch-up.
  Future<ReceiveOutcome> _walkSteps(
    _Pass pass,
    String id,
    BudgetPriority priority,
    _Probe probe,
    void Function() onWelcomes,
  ) async {
    final context = _contexts.of(id);
    // 3-5. The walks, one allowance across them.
    final until = context.walkBackoffUntil;
    if (until != null && _now().isBefore(until)) {
      final held = _engineHoldOf(context);
      return ReceiveOutcome.stopped(
        held != null && held.isAfter(until) ? held : until,
      );
    }
    var left = priority == BudgetPriority.user
        ? 2 * kWalkPagesPerPass
        : kWalkPagesPerPass;
    int take() => left > 0 ? left-- : 0;
    // A close or orphan walk that needs no engine goes on under a hold; one
    // that decrypts stops before it lists ([_walk]).
    for (final slot in const [_Slot.close, _Slot.orphan]) {
      final r = await _walk(pass, id, slot, priority, take);
      if (r != null) return r;
    }
    // The open walk decrypts, and so does applying a commit: neither under
    // a hold (also when the fast path's batch stopped on an engine answer).
    final held = _engineHoldOf(context);
    if (held != null) return ReceiveOutcome.stopped(held);
    final record = await _readReceive(pass.vault, id);
    final open = record.open;
    final lt = open?.lt;
    final settleDue =
        probe.fastPath &&
        (lt == null ||
            _now().microsecondsSinceEpoch - lt >=
                kOpenSettleEvery.inMicroseconds);
    var pulled = probe.pulled;
    final r = await _walk(
      pass,
      id,
      _Slot.open,
      priority,
      take,
      newListing: context.endToken != null || probe.listAgain || settleDue,
      onTokenSaved: () => pulled = true,
    );
    if (r != null) return r;

    // (Step 2 of a pass is the reconcile walk, before these walks; step 6,
    // the deferred retries, runs in `_runPass` after everything here.)

    if (pulled) {
      // M10: a pass that saved the since token (or found it stored) at the
      // group's current pair. Audit M1: only against the server pair the
      // LAST catch-up read (an interrupted one leaves an older answer).
      final pair = await _currentPair(pass.vault, id);
      if (pair != null) {
        context
          ..livePulledAt = pair
          ..syncedSinceStart =
              !context.attributionPending &&
              context.serverPairFresh &&
              context.serverPair == pair;
      }
    }
    var after = await _readReceive(pass.vault, id);
    final current = await _currentPair(pass.vault, id);
    final seen = probe.sawLater;
    final kept = context.laterPairSeen;
    if (seen != null && (kept == null || seen.compareTo(kept) > 0)) {
      context.laterPairSeen = seen;
    }
    // M7: a seen pair the current pair has reached, or a due pair it has
    // passed, is no longer a reason (the fast path or another catch-up
    // applied the commit); a fruitless streak at another pair ends.
    _clearReached(context, current);
    if (!probe.caughtUp &&
        current != null &&
        !_commitWalksLeft(after) &&
        (_closeEndedAt(after, current) ||
            context.laterPairSeen != null ||
            context.catchUpDueAt != null)) {
      // The catch-up's own wait (after fruitless runs at this pair): only
      // this trigger waits, the walks above ran. A commit still waits, so
      // never `complete`.
      final notBefore = context.catchUpNotBefore;
      if (notBefore != null && _now().isBefore(notBefore)) {
        return _walksLeft(after)
            ? ReceiveOutcome.more
            : ReceiveOutcome.stopped(notBefore);
      }
      // The pass finishes the job (I2): the walks the commit gate reads
      // have ended and a commit waits (the current pair's close walk ended,
      // the probe showed a later pair, or a catch-up was refused behind an
      // older walk that has ended since). ONE lock hold with the locked
      // catch-up, as the fast path's batch does; its unheld welcome poll
      // runs after the lock is released (`_runPass`). At most once per pass.
      final result = await _locks.run(id, () async {
        if (!pass.live) return null;
        final fresh = await _readReceive(pass.vault, id);
        if (_commitWalksLeft(fresh) ||
            await _currentPair(pass.vault, id) != current) {
          return null;
        }
        return _crypto.catchUpLocked(id, priority: priority);
      });
      if (result == CatchUpResult.waitingForWelcome) onWelcomes();
      final now = await _currentPair(pass.vault, id);
      final moved = now != current;
      // A failed (`interrupted`) catch-up keeps both facts for the next
      // pass (its sink may have set `catchUpDueAt` again in this run).
      if (result != null && result != CatchUpResult.interrupted) {
        context
          ..laterPairSeen = null
          ..catchUpDueAt = null;
      }
      _clearReached(context, now);
      after = await _readReceive(pass.vault, id);
      if (!moved && !_walksLeft(after)) {
        // Nothing applied and no walk left (no commit visible yet, a
        // failed call, a later pair the server does not have): the next
        // pass waits, never an immediate `more` or a `complete` with a
        // commit left. A walk the catch-up's sink left pending is `more`.
        return _fruitlessCatchUp(context, current);
      }
      _resetCatchUpWait(context);
    }
    return pulled && !_walksLeft(after)
        ? ReceiveOutcome.complete
        : ReceiveOutcome.more;
  }

  /// With the group's [current] pair known: clears [context]'s later pair
  /// once [current] has reached it, its due pair once [current] is strictly
  /// past it, and a fruitless streak kept at another pair. An unknown pair
  /// clears nothing.
  void _clearReached(ConversationContext context, MlsPair? current) {
    if (current == null) return;
    final later = context.laterPairSeen;
    if (later != null && later.compareTo(current) <= 0) {
      context.laterPairSeen = null;
    }
    final due = context.catchUpDueAt;
    if (due != null && current.compareTo(due) > 0) {
      context.catchUpDueAt = null;
    }
    final streak = context.fruitlessCatchUpAt;
    if (streak != null && streak != current) _resetCatchUpWait(context);
  }

  /// An end-of-pass catch-up at [current] applied nothing and left no walk.
  /// The first at a pair waits the flat [kWalkBackoff] and arms nothing;
  /// each next one at the same pair doubles the catch-up's own wait (up to
  /// [kWalkBackoffMax]) and holds only the trigger, never the walks.
  ReceiveOutcome _fruitlessCatchUp(
    ConversationContext context,
    MlsPair current,
  ) {
    if (context.fruitlessCatchUpAt != current) {
      context
        ..fruitlessCatchUpAt = current
        ..catchUpBackoff = kWalkBackoff
        ..catchUpNotBefore = null;
      return ReceiveOutcome.stopped(_now().add(kWalkBackoff));
    }
    var d = (context.catchUpBackoff ?? kWalkBackoff) * 2;
    if (d > kWalkBackoffMax) d = kWalkBackoffMax;
    final until = _now().add(d);
    context
      ..catchUpBackoff = d
      ..catchUpNotBefore = until;
    return ReceiveOutcome.stopped(until);
  }

  /// Ends a fruitless streak and the catch-up's own wait.
  void _resetCatchUpWait(ConversationContext context) {
    context
      ..fruitlessCatchUpAt = null
      ..catchUpBackoff = null
      ..catchUpNotBefore = null;
  }

  /// A close, orphan or open walk of [r] has pages left.
  bool _walksLeft(ReceiveRecord r) => r.orphan != null || _commitWalksLeft(r);

  /// A close or open walk of [r] has pages left: the walks the end-of-pass
  /// catch-up waits for. The orphan walk is left out: no commit's gate
  /// (`epochWalkDone` for the current or a later pair) reads it.
  bool _commitWalksLeft(ReceiveRecord r) =>
      (r.close != null && !r.close!.end) || (r.open != null && !r.open!.end);

  /// [r]'s close walk for [current] has ended: its commit can apply.
  bool _closeEndedAt(ReceiveRecord r, MlsPair current) =>
      r.close != null && r.close!.end && r.close!.pair == current;

  /// The walks of a pass with no final group (§3.4 keeps a `u` close or
  /// orphan slot whose group is gone): those walks only, no open walk, no
  /// catch-up (the pass's detector probe and its reconcile step ran before
  /// this). A pass that moved neither slot stops (a provisional group at
  /// the slot's generation discards its pages) rather than asking for an
  /// immediate next pass.
  Future<ReceiveOutcome> _walkWithoutGroup(
    _Pass pass,
    String id,
    BudgetPriority priority,
  ) async {
    final before = await _readReceive(pass.vault, id);
    final closeLeft = before.close != null && !before.close!.end;
    if (!closeLeft && before.orphan == null) return ReceiveOutcome.complete;
    final context = _contexts.of(id);
    final until = context.walkBackoffUntil;
    if (until != null && _now().isBefore(until)) {
      return ReceiveOutcome.stopped(until);
    }
    var left = priority == BudgetPriority.user
        ? 2 * kWalkPagesPerPass
        : kWalkPagesPerPass;
    int take() => left > 0 ? left-- : 0;
    ReceiveOutcome? stop;
    for (final slot in const [_Slot.close, _Slot.orphan]) {
      stop = await _walk(pass, id, slot, priority, take);
      if (stop != null) break;
    }
    if (stop != null && stop.kind != ReceiveOutcomeKind.more) return stop;
    final after = await _readReceive(pass.vault, id);
    final left2 =
        (after.close != null && !after.close!.end) || after.orphan != null;
    if (!left2) return ReceiveOutcome.complete;
    if (_sameWalk(before.close, after.close) &&
        _sameWalk(before.orphan, after.orphan)) {
      return ReceiveOutcome.stopped(_now().add(kWalkBackoff));
    }
    return ReceiveOutcome.more;
  }

  bool _sameWalk(WalkEntry? a, WalkEntry? b) => a == null
      ? b == null
      : b != null && a.pair == b.pair && a.t == b.t && a.end == b.end;

  // -------------------------------------------------------------------------
  // The probe (§4)

  /// [detector] (a pass with no final group; a ruling after the design):
  /// the probe only detects. Its page's messages are never processed (no
  /// fast path, so no engine call, no row for a message and no since token
  /// saved), and nothing of it is kept for §4 rule 2 (no open walk exists
  /// to save it); its tombstones are noted and applied to stored rows and
  /// deferred copies as for any page that is not processed, a refused
  /// token is retired and an empty since token arms the reconcile entry.
  /// It is never the witness an engine retry needs.
  Future<_Probe> _probe(
    _Pass pass,
    String id,
    BudgetPriority priority, {
    bool detector = false,
  }) async {
    final context = _contexts.of(id);
    final limited = _messaging.rateLimitedFor();
    if (limited != null) {
      return _Probe(outcome: ReceiveOutcome.held(_retryAt(limited)));
    }
    if (!await _takeUnit(_readBudget, priority, id)) {
      return _Probe(outcome: ReceiveOutcome.held(_now().add(kWalkBackoff)));
    }
    final vault = pass.vault;
    final token = (await vault.conversation(id))?.sync.sinceToken ?? '';
    final before = await _readReceive(vault, id);
    final current = await _currentPair(vault, id);
    final open = before.open;
    final openEnded = open != null && open.pair == current && open.end;
    final serial = context.serial;
    final sent = token.isNotEmpty ? token : before.anchor;
    final pb.ListMessagesResponse page;
    try {
      page = await _messaging.listMlsMessages(
        conversationId: id,
        sinceToken: sent,
      );
    } on ValidationException catch (e) {
      if (e.field == 'since_token' && sent.isNotEmpty) {
        await _locks.run(id, () => _retireLocked(pass, id, token));
        return _Probe(outcome: ReceiveOutcome.more);
      }
      return _Probe(outcome: ReceiveOutcome.stopped(_now().add(kWalkBackoff)));
    } on RateLimitedException catch (e) {
      final until = _retryAt(e);
      _readBudget.pauseUntil(until);
      return _Probe(outcome: ReceiveOutcome.held(until));
    } on Object catch (e, s) {
      _reportIfBug(e, s, 'receive.listMessages');
      return _Probe(outcome: ReceiveOutcome.stopped(_now().add(kWalkBackoff)));
    }
    final seq = ++_seq;
    if (page.hasConversation()) _contexts.note(page.conversation);
    // A since token outside the one token shape reads as no token: it is
    // never the anchor, never kept for §4 rule 2 and never saved by the fast
    // path (the stored token stays).
    final since = isTokenShape(page.sinceToken) ? page.sinceToken : '';
    final refused = since != page.sinceToken;
    // Against the pair read before the listing (I2's later-pair trigger).
    final later = _highestAbove(page.messages, current);
    final probe = await _locks.run(id, () async {
      if (!pass.live) {
        return _Probe(
          outcome: ReceiveOutcome.stopped(_now().add(kWalkBackoff)),
        );
      }
      if (token.isEmpty) {
        // §8.2: the anchor and the armed reconcile entry (its listing is
        // step 2's); the page is not processed. Its tombstones are
        // remembered for the run BEFORE the arming write is asked for: when
        // that write never starts, nothing below runs.
        _tombstoneStates(
          id,
          page.messages,
        ).forEach((mid, state) => _noteTombstone(context, mid, state));
        await _armLocked(pass, id, since);
        await _tombstonesSeenLocked(pass, id, page.messages);
        if (detector) return _Probe();
        context.endToken = since.isEmpty
            ? null
            : (token: since, sentWith: '', seq: seq);
        return _Probe(sawLater: later, listAgain: refused);
      }
      if (!detector &&
          page.gapPageToken.isEmpty &&
          openEnded &&
          context.serial == serial &&
          await _openEndedNow(vault, id, current)) {
        // Rule 1: the fast path (M5: `open` read again under the lock).
        final messages = [...page.messages];
        _sort(messages);
        // Every tombstone of the page is remembered for the run BEFORE the
        // batch: a batch that stops early (an engine answer, a later pair,
        // a failed write) never reaches the ones after its stop, and this
        // pass's retries must not give such a message to the engine (§7.4
        // check 2 ends it as its tombstone row instead).
        _tombstoneStates(
          id,
          messages,
        ).forEach((mid, state) => _noteTombstone(context, mid, state));
        // The freshness witness, noted before the batch (its last
        // transaction may save the answer's token over the one sent).
        context.noteProbeAnswered(pass, token);
        final end = await _runBatch(
          pass,
          id,
          messages,
          priority: priority,
          token: (token: since, expect: token),
        );
        return _Probe(
            fastPath: true,
            pulled: end.completed,
            caughtUp: end.caughtUp,
          )
          ..waitingForWelcome = end.waitingForWelcome
          ..listed = true;
      }
      // Not processed: its messages come through the open walk, in order;
      // its token is saved by rule 2 once that walk ends. A tombstone on it
      // still ends a deferred copy of its message now (§8.1).
      await _tombstonesSeenLocked(pass, id, page.messages);
      if (detector) return _Probe();
      context.endToken = since.isEmpty
          ? null
          : (token: since, sentWith: token, seq: seq);
      // The freshness witness: every tombstone of the page was noted for
      // the run (and applied) just above.
      context.noteProbeAnswered(pass, token);
      return _Probe(sawLater: later, listAgain: refused)..listed = true;
    });
    // `listed` (and the witness in the context) is set only where the
    // listing was ANSWERED for a request that sent the stored, non-empty
    // since token (never the anchor, never an empty token) and applied
    // under the lock with the vault still open: the pass has seen what
    // changed since that token, and every tombstone on the page was noted
    // for the run before anything else was done with the page. Never by a
    // detector probe: with no final group nothing may reach the engine.
    return probe;
  }

  /// Under the lock: the group's current pair is still [before] and the
  /// fresh `open` entry is for it with `end` (§4 rule 1).
  Future<bool> _openEndedNow(
    SecureVault vault,
    String id,
    MlsPair? before,
  ) async {
    final current = await _currentPair(vault, id);
    if (current == null || current != before) return false;
    final open = (await _readReceive(vault, id)).open;
    return open != null && open.pair == current && open.end;
  }

  /// The highest pair above [current] that [messages] hold (null: none, or
  /// [current] not known).
  MlsPair? _highestAbove(List<pb.Message> messages, MlsPair? current) {
    if (current == null) return null;
    MlsPair? highest;
    for (final m in messages) {
      final g = pairComponentFromInt64(m.mlsGeneration);
      final e = pairComponentFromInt64(m.mlsEpoch);
      if (g == null || e == null) continue;
      final p = MlsPair(g, e);
      if (p.compareTo(highest ?? current) > 0) highest = p;
    }
    return highest;
  }

  /// A retired since token (§8.2): the token is cleared and the reconcile
  /// entry reset (unarmed, its listing from the top) in one transaction; a
  /// retired anchor is cleared, with the same reset of the entry.
  ///
  /// The restart rule (step 2 carry-overs 9 and 18): EVERY retirement (of
  /// the since token or of the anchor)
  /// begins the by-id listing again, since only a listing begun after the
  /// arming that follows it may disarm the entry. It is bounded: the
  /// entry's failure count is kept across the reset, and a retirement that
  /// interrupts a listing in progress is counted as one more failure (at
  /// most one per spacing, [_reconcileCounted]), so a server that retires
  /// without end reaches [kReconcileGiveUpAfter] like one that refuses.
  Future<void> _retireLocked(_Pass pass, String id, String token) async {
    // Whatever this pass listed before no longer says what the thread
    // holds: the final-attempt gate closes at once, for an entry that
    // stands (the listing's end) and for a null one (the answered probe).
    _contexts.of(id)
      ..clearListedToEnd()
      ..clearProbeAnswered();
    if (!pass.live) return;
    _contexts.of(id).endToken = null;
    var gaveUp = false;
    await _session.runWrite((v) async {
      pass.check(v);
      final sync = (await v.conversation(id))?.sync ?? const ConversationSync();
      if (sync.sinceToken != token) return;
      final record = await _readReceive(v, id);
      final had = record.rec;
      final counted = had != null && had.armed && had.begun
          ? _reconcileCounted(had)
          : null;
      final reset =
          (counted ?? had)?.restarted(armed: false) ??
          const ReconcileEntry(armed: false);
      await v.transaction((tx) async {
        if (token.isEmpty) {
          // A retired ANCHOR restarts the listing too (fix round 1 of step
          // 2b): the thread changed behind a cursor that may already be
          // past the id that changed, and tombstone ids are not in time
          // order.
          await _records.putIn(tx, id, record.copyWith(anchor: '', rec: reset));
          return;
        }
        await tx.putConversationSync(id, sync.copyWith(sinceToken: ''));
        await _records.putIn(tx, id, record.copyWith(rec: reset));
      });
      gaveUp = counted != null && counted.gaveUp;
    });
    _contexts.of(id).serial++;
    if (gaveUp) _reconcileGaveUp();
  }

  /// The probe with an empty since token: [anchor] (the answer's token)
  /// becomes the anchor and the reconcile entry is armed, in one
  /// transaction (§8.2).
  Future<void> _armLocked(_Pass pass, String id, String anchor) async {
    // An arming closes the final-attempt gate (the listing that may open
    // it again is the one this pass makes after it).
    _contexts.of(id).clearListedToEnd();
    await _session.runWrite((v) async {
      pass.check(v);
      final sync = (await v.conversation(id))?.sync ?? const ConversationSync();
      if (sync.sinceToken.isNotEmpty) return;
      final record = await _readReceive(v, id);
      // The cursor and the failure count are kept (the count bounds a
      // server that never lets the listing finish).
      final armed =
          record.rec?.copyWith(armed: true) ??
          const ReconcileEntry(armed: true);
      await v.transaction(
        (tx) => _records.putIn(
          tx,
          id,
          record.copyWith(
            rec: armed,
            // A token outside the one shape is refused as an anchor.
            anchor: anchor.isEmpty || !isTokenShape(anchor)
                ? record.anchor
                : anchor,
          ),
        ),
      );
    });
    _contexts.of(id).serial++;
  }

  // -------------------------------------------------------------------------
  // A walk (§3, §5)

  /// Walks [slot] with the pages [take] still allows (each step takes one).
  /// [newListing]: a walk at its end lists once more from its settle token
  /// (for §4 rule 2 or the settle refresh). Null: done for this pass;
  /// otherwise the pass ends with the outcome.
  Future<ReceiveOutcome?> _walk(
    _Pass pass,
    String id,
    _Slot slot,
    BudgetPriority priority,
    int Function() take, {
    bool newListing = false,
    void Function()? onTokenSaved,
  }) async {
    var again = newListing;
    while (true) {
      final record = await _readReceive(pass.vault, id);
      final w = _slotOf(record, slot);
      if (w == null) return null;
      if (w.end && !again) {
        await _releaseEnded(pass, id, slot, w);
        return null;
      }
      final context = _contexts.of(id);
      // Under an engine hold a walk that decrypts is not listed (its page
      // could not be applied); one that needs no engine goes on.
      final held = _engineHoldOf(context);
      if (held != null && await _needsEngine(pass.vault, id, slot, w)) {
        return ReceiveOutcome.stopped(held);
      }
      if (take() == 0) return ReceiveOutcome.more;
      final backOffs = context.walkBackOffs;
      final step = await _walkStep(pass, id, slot, w, priority, onTokenSaved);
      switch (step.kind) {
        case _StepKind.applied:
          again = false;
          if (step.ended) return null;
        case _StepKind.stale:
          _contexts.of(id).discardedPages++;
        case _StepKind.restarted:
          break;
        case _StepKind.stop:
          // This walk's own page was refused (an order violation, a missing
          // order echo or the restart cap; never a failed or rate-limited
          // call): counted in the sealed record, and an undecryptable walk
          // that can never finish is given up, so it does not block every
          // later commit for good.
          if (context.walkBackOffs != backOffs &&
              await _countRefusal(pass, id, slot, w)) {
            return null;
          }
          return step.outcome;
      }
    }
  }

  /// [slot]'s walk [w] gives its messages to the engine: the open walk
  /// always; a close or orphan walk unless it is in mode `u` or the group
  /// of its generation is gone or provisional.
  Future<bool> _needsEngine(
    SecureVault vault,
    String id,
    _Slot slot,
    WalkEntry w,
  ) async {
    if (slot == _Slot.open) return true;
    if (slot == _Slot.close && w.mode == WalkMode.undecryptable) return false;
    final group = await vault.group(id, w.pair.generation);
    return group != null && !group.provisional;
  }

  /// A ruling after the design (step 2 carry-over 4, amended by fix round
  /// 1: the count is DURABLE): [slot]'s walk [w] needs no engine (mode `u`,
  /// or its group is gone; never while a PROVISIONAL group of its
  /// generation is stored) and its own page was just refused. With the
  /// lock, in ONE `runWrite` and ONE transaction on the record read fresh:
  /// the refusal is counted on the entry (`mf`, `mfAt`), at most one per
  /// [kWalkRefusalSpacing] whatever the app run (the first at once), and at
  /// [kWalkGiveUpAfter] the walk is ABANDONED in that same transaction: a
  /// close slot is left at its `end` (so the commit gate reads the walk as
  /// over and the sink may take the slot; cleared, the sink would only
  /// create it again), an orphan slot is cleared, and the record's
  /// abandoned-walk count grows. Reported once as a fixed pipeline error
  /// naming the step. No row is written for messages that were never
  /// listed. The open walk and a walk that decrypts are never counted. An
  /// applied page resets the count ([WalkEntry.afterPage]). True: abandoned
  /// (the walk backoff is cleared with it).
  Future<bool> _countRefusal(
    _Pass pass,
    String id,
    _Slot slot,
    WalkEntry w,
  ) async {
    if (slot == _Slot.open) return false;
    final context = _contexts.of(id);
    // Null: nothing written; else whether the walk was abandoned.
    final abandoned = await _locks.run<bool?>(id, () async {
      if (!pass.live) return null;
      return _session.runWrite<bool?>((v) async {
        pass.check(v);
        final record = await _readReceive(v, id);
        final now = _slotOf(record, slot);
        if (now == null || now.pair != w.pair || now.end) return null;
        final group = await v.group(id, now.pair.generation);
        // Never under a PROVISIONAL group of the slot's generation (fix
        // round 1): it can still become final, and an abandoned close slot
        // is left at `end`, which must never stand for a walk of a group
        // that is then deleted, or skipped, unwalked. Such a refusal is not
        // counted either.
        if (group != null && group.provisional) return null;
        final needsNoEngine =
            group == null ||
            (slot == _Slot.close && now.mode == WalkMode.undecryptable);
        if (!needsNoEngine) return null;
        final at = _now().microsecondsSinceEpoch;
        // Either way: a local clock set back does not stop the count.
        final counted =
            now.mf < 1 ||
            (at - now.mfAt).abs() >= kWalkRefusalSpacing.inMicroseconds;
        final mf = now.mf + (counted ? 1 : 0);
        if (mf >= kWalkGiveUpAfter) {
          await v.transaction(
            (tx) => _records.putIn(
              tx,
              id,
              _withSlot(
                record,
                slot,
                slot == _Slot.close
                    ? now.copyWith(end: true, mf: 0, mfAt: 0)
                    : null,
              ).copyWith(abandoned: record.abandoned + 1),
            ),
          );
          return true;
        }
        if (!counted) return null;
        await v.transaction(
          (tx) => _records.putIn(
            tx,
            id,
            _withSlot(record, slot, now.copyWith(mf: mf, mfAt: at)),
          ),
        );
        return false;
      });
    });
    if (abandoned == null) return false;
    context.serial++;
    if (!abandoned) return false;
    context
      ..walkBackoff = null
      ..walkBackoffUntil = null;
    _onUnexpectedError?.call(
      const E2eePipelineError('receive.walk.abandoned'),
      StackTrace.current,
    );
    return true;
  }

  /// A pass met [slot]'s walk [w] already at its end (no lock held). When it
  /// reads as the last epoch of a generation below the current one with its
  /// group still kept (the walk ended while that generation was current, and
  /// the generation moved since), the final step is taken under the lock,
  /// where everything is read again ([_releaseEndedLocked]). One lock run of
  /// its own, and only then.
  Future<void> _releaseEnded(
    _Pass pass,
    String id,
    _Slot slot,
    WalkEntry w,
  ) async {
    if (slot == _Slot.open || !w.end) return;
    final current = await _currentPair(pass.vault, id);
    if (current == null || w.pair.generation >= current.generation) return;
    final group = await pass.vault.group(id, w.pair.generation);
    if (group == null || group.provisional || group.epoch != w.pair.epoch) {
      return;
    }
    await _locks.run(id, () => _releaseEndedLocked(pass, id, slot));
  }

  /// §6 "whoever reaches it", for a close (or orphan) walk whose end was
  /// recorded earlier. With the lock held, in ONE transaction: the group of
  /// the walk's generation is deleted and [slot] is cleared. Only when,
  /// read fresh in the write body, the entry has `end`, its generation is
  /// strictly below the current pair's, and that generation's group is
  /// stored, not provisional and at the entry's epoch (the conditions of the
  /// transaction that records a walk's end, [_applyPageLocked]). Anything
  /// else writes nothing. A deferred message of the generation gets its
  /// final attempt in that same transaction; FALSE: one is owed and must
  /// wait, so the group stays (the caller must not treat the generation as
  /// let go).
  Future<bool> _releaseEndedLocked(_Pass pass, String id, _Slot slot) async {
    assert(_locks.isHeld(id), 'The caller must hold the conversation lock.');
    if (slot == _Slot.open || !pass.live) return true;
    var itemsEnded = false;
    var waiting = false;
    final released = await _session.runWrite((v) async {
      pass.check(v);
      final record = await _readReceive(v, id);
      final w = _slotOf(record, slot);
      if (w == null || !w.end) return false;
      final current = await _currentPair(v, id);
      if (current == null || w.pair.generation >= current.generation) {
        return false;
      }
      final group = await v.group(id, w.pair.generation);
      if (group == null || group.provisional || group.epoch != w.pair.epoch) {
        return false;
      }
      // A deferred message of the generation is owed its final attempt
      // first, in this same transaction; while it must wait, the group
      // stays (§7.6 end 1).
      final plan = await _finalAttempts(
        v,
        pass,
        id,
        w.pair,
        // As the walk's own end ([_endWalkLocked]): a walk in mode `u`
        // never gives a message to the engine, its deferred items are rows.
        engine: w.mode != WalkMode.undecryptable,
        generationEnds: true,
        // Read fresh in this body (the sink reaches this with no probe,
        // and then no item is given to the engine).
        rec: record.rec,
      );
      if (plan == null) {
        waiting = true;
        return false;
      }
      final sync = (await v.conversation(id))?.sync ?? const ConversationSync();
      await v.transaction((tx) async {
        await tx.deleteGroup(id, w.pair.generation);
        await _writePlanIn(tx, id, plan, sync);
        await _records.putIn(tx, id, _withSlot(record, slot, null));
      });
      final rest = plan.deferred;
      if (rest != null) {
        _contexts.of(id).deferredEmpty = rest.items.isEmpty;
        itemsEnded = true;
      }
      return true;
    });
    if (released) _contexts.of(id).serial++;
    if (itemsEnded) _onChanged(id);
    return !waiting;
  }

  /// One page of [slot] (§2 "a walk step"): [w] is the snapshot read with no
  /// lock; the page is listed with no lock, then applied under the lock only
  /// when the snapshot still holds (§5.1).
  Future<_StepEnd> _walkStep(
    _Pass pass,
    String id,
    _Slot slot,
    WalkEntry w,
    BudgetPriority priority,
    void Function()? onTokenSaved,
  ) async {
    final context = _contexts.of(id);
    final serial = context.serial;
    if (!await _takeUnit(_syncBudget, priority, id)) {
      return _StepEnd.stop(ReceiveOutcome.held(_now().add(kWalkBackoff)));
    }
    final seq = ++_seq;
    final listed = await _listOrdered(id, w);
    if (listed.outcome != null) return _StepEnd.stop(listed.outcome!);
    return _locks.run(id, () async {
      if (!pass.live) return _StepEnd.stale;
      final fresh = _slotOf(await _readReceive(pass.vault, id), slot);
      if (fresh == null ||
          fresh.pair != w.pair ||
          fresh.t != w.t ||
          context.serial != serial) {
        return _StepEnd.stale;
      }
      if (listed.page == null) return _restartLocked(pass, id, slot, fresh);
      return _applyPageLocked(
        pass,
        id,
        slot,
        fresh,
        listed.page!,
        listSeq: seq,
        onTokenSaved: onTokenSaved,
      );
    });
  }

  /// One ordered page at [w]'s token. `page` null with no outcome: the token
  /// was refused (or an answer's next or resume token is outside the one
  /// token shape, [isTokenShape]).
  Future<({pb.ListEpochMessagesResponse? page, ReceiveOutcome? outcome})>
  _listOrdered(String id, WalkEntry w) async {
    try {
      final page = await _messaging.listEpochMessages(
        conversationId: id,
        pair: w.pair,
        pageSize: _pageSize,
        pageToken: w.t,
        order: EpochMessageOrder.EPOCH_MESSAGE_ORDER_CREATED_AT,
      );
      if (!isTokenShape(page.nextPageToken) ||
          !isTokenShape(page.resumePageToken)) {
        return (page: null, outcome: null);
      }
      return (page: page, outcome: null);
    } on ValidationException catch (e) {
      if (e.field == 'page_token' && w.t.isNotEmpty) {
        return (page: null, outcome: null);
      }
      return (
        page: null,
        outcome: ReceiveOutcome.stopped(_now().add(kWalkBackoff)),
      );
    } on RateLimitedException catch (e) {
      final until = _retryAt(e);
      _syncBudget.pauseUntil(until);
      return (page: null, outcome: ReceiveOutcome.held(until));
    } on Object catch (e, s) {
      _reportIfBug(e, s, 'receive.listEpochMessages');
      return (
        page: null,
        outcome: ReceiveOutcome.stopped(_now().add(kWalkBackoff)),
      );
    }
  }

  /// A refused token (§3.2): the walk lists again from the start, at most
  /// [kWalkRestartsPerRun] times a run; then the walk backs off. Past the
  /// cap the restarted position is still written, so the attempt after the
  /// backoff lists from the start and never sends the refused token again.
  Future<_StepEnd> _restartLocked(
    _Pass pass,
    String id,
    _Slot slot,
    WalkEntry fresh,
  ) async {
    final context = _contexts.of(id);
    final capped = ++context.walkRestarts > kWalkRestartsPerRun;
    await _session.runWrite((v) async {
      pass.check(v);
      final record = await _readReceive(v, id);
      final now = _slotOf(record, slot);
      if (now == null || now.pair != fresh.pair || now.t != fresh.t) return;
      await v.transaction(
        (tx) =>
            _records.putIn(tx, id, _withSlot(record, slot, now.restarted())),
      );
    });
    context.serial++;
    if (capped) return _StepEnd.stop(_backOff(context));
    return _StepEnd.restarted;
  }

  /// Applies [page] to [slot]'s entry [w] (read fresh under the held lock):
  /// the order check, the group check, then each message oldest first in its
  /// own `runWrite`; the last one's transaction writes the new entry (or a
  /// transaction alone does). Shared by the pass and the sink.
  Future<_StepEnd> _applyPageLocked(
    _Pass pass,
    String id,
    _Slot slot,
    WalkEntry w,
    pb.ListEpochMessagesResponse page, {
    required int listSeq,
    void Function()? onTokenSaved,
  }) async {
    final context = _contexts.of(id);
    // §3.3: the order check, before anything is processed.
    if (page.messages.length > _pageSize ||
        // M2: the server names a next page only after a full one; an empty
        // or short page with a next token could be served without end.
        (page.nextPageToken.isNotEmpty && page.messages.length < _pageSize)) {
      context.orderViolation++;
      return _StepEnd.stop(_backOff(context));
    }
    if (page.order != EpochMessageOrder.EPOCH_MESSAGE_ORDER_CREATED_AT) {
      context.orderMissing++;
      return _StepEnd.stop(_backOff(context));
    }
    // A message whose time this client cannot hold and that already has a
    // row (the live path stored it at time 0) is skipped by id: it takes no
    // part in the order check or in the recorded position, so its walk can
    // finish. Without a row such a message still refuses the page.
    final messages = <pb.Message>[];
    for (final m in page.messages) {
      if (!_timeConverts(m) &&
          _messageIdShape.hasMatch(m.id) &&
          await pass.vault.hasMessage(id, m.id)) {
        continue;
      }
      messages.add(m);
    }
    if (!_inOrder(messages, w)) {
      context.orderViolation++;
      return _StepEnd.stop(_backOff(context));
    }
    // §5.1 rule 4: the group for the pair.
    final group = await pass.vault.group(id, w.pair.generation);
    final usable =
        group != null && !group.provisional && group.epoch == w.pair.epoch;
    final _Mode mode;
    var entry = w;
    // A provisional group at the slot's generation holds none of its keys
    // (§3.4 reads it as gone too): mode u, never a page discarded forever.
    final gone = group == null || group.provisional;
    if (gone && slot != _Slot.open) {
      // Its keys are gone: rows for the unlisted rest, no engine.
      mode = _Mode.undecryptable;
      if (slot == _Slot.close) {
        entry = entry.copyWith(mode: WalkMode.undecryptable);
      }
    } else if (!usable) {
      // Moved past the pair (ended), provisional, or gone for `open`: the
      // record is normalized at its next read.
      return _StepEnd.stale;
    } else if (slot == _Slot.close && w.mode == WalkMode.undecryptable) {
      mode = _Mode.undecryptable;
    } else {
      mode = _Mode.epoch;
    }
    final cleared = _clearedAtOf(page);
    if (cleared != null) await _saveClearedAt(pass, id, cleared);

    final last = messages.isEmpty ? null : _posOf(messages.last);
    final next = entry.afterPage(
      next: page.nextPageToken,
      resume: page.resumePageToken,
      settled: page.resumeSettled,
      last: last,
      open: slot == _Slot.open,
      nowLocal: _now().microsecondsSinceEpoch,
    );
    if (slot == _Slot.open && w.r) context.openListingSeq = listSeq;
    final end = context.endToken;
    final saveEnd =
        slot == _Slot.open &&
        next.end &&
        end != null &&
        (context.openListingSeq ?? -1) > end.seq;
    // The end of a close or orphan walk never rides on its page's last
    // message: it is ONE transaction of its own, after the final attempts
    // of the pair's deferred messages ([_endWalkLocked]), so `end` is never
    // recorded, and the group never deleted, while one is still owed.
    final ending = next.end && slot != _Slot.open;
    var tokenWritten = false;
    // The last computed update was not stale (its transaction carries the
    // record); read only after a transaction that used it ran.
    var recordInUpdate = false;
    Future<({ReceiveRecord record, String? sinceToken})?> update(
      SecureVault v,
      ConversationSync sync,
    ) async {
      recordInUpdate = false;
      tokenWritten = false;
      final record = await _readReceive(v, id);
      final now = _slotOf(record, slot);
      if (now == null || now.pair != w.pair || now.t != w.t) return null;
      final token = saveEnd && sync.sinceToken == end.sentWith
          ? end.token
          : null;
      tokenWritten = token != null;
      recordInUpdate = true;
      var written = _withSlot(record, slot, next);
      // §8.2 as built: a since token saved over an EMPTY one begins a
      // reconcile listing in progress again from the top, in this same
      // transaction, so the listing that disarms the entry began after
      // the token the conversation is left with was issued. At most once
      // per retirement (the token is empty only after one).
      final rec = written.rec;
      if (token != null &&
          token.isNotEmpty &&
          sync.sinceToken.isEmpty &&
          rec != null &&
          rec.begun) {
        written = written.copyWith(rec: rec.restarted());
      }
      return (record: written, sinceToken: token);
    }

    var written = false;
    var changed = false;
    for (var i = 0; i < messages.length; i++) {
      final isLast = i == messages.length - 1;
      final step = await _one(
        pass,
        id,
        messages[i],
        mode,
        w.pair,
        record: isLast && !ending ? update : null,
      );
      if (step == _Step.stop) {
        if (changed) _onChanged(id);
        // Nothing stored for this message, the cursor kept (§7.2: the hold
        // an engine answer set; otherwise as built).
        return _StepEnd.stop(
          ReceiveOutcome.stopped(
            _engineHoldOf(context) ?? _now().add(kEngineBackoff),
          ),
        );
      }
      if (step == _Step.wrote) {
        changed = true;
        // M1: the message's transaction ran; the record rode with it only
        // when the update was not stale.
        if (isLast) written = recordInUpdate;
      }
    }
    if (ending) {
      final walkEnd = await _endWalkLocked(
        pass,
        id,
        slot,
        w,
        next,
        gone: gone,
        decrypt: mode == _Mode.epoch,
        onItemsEnded: () => changed = true,
      );
      if (walkEnd == _WalkEnd.waiting) {
        if (changed) _onChanged(id);
        // A final attempt is owed: the walk has not ended, its group stays
        // and the page is listed again after the hold.
        return _StepEnd.stop(
          ReceiveOutcome.stopped(
            _engineHoldOf(context) ?? _now().add(kEngineBackoff),
          ),
        );
      }
      written = walkEnd == _WalkEnd.done;
    } else if (!written) {
      written = await _writeAlone(pass, id, update);
    }
    if (changed) _onChanged(id);
    if (!written) return _StepEnd.stale;
    context.serial++;
    context.walkBackoff = null;
    // M3: the restart count is per listing, not per run, so a long run never
    // backs off for good; reset only at a listing's end, so a server that
    // refuses every continuation token still reaches the backoff.
    if (next.end) context.walkRestarts = 0;
    if (saveEnd) {
      context.endToken = null;
      if (tokenWritten) {
        // A since token saved over an empty one begins the listing again:
        // the gate is the entry's alone from here (null once disarmed).
        context.clearListedToEnd();
        onTokenSaved?.call();
      }
    }
    return next.end ? _StepEnd.finished : _StepEnd.advanced;
  }

  /// A page's record update in a transaction of its own (its last message
  /// wrote nothing, or the page is empty). False: nothing was written.
  Future<bool> _writeAlone(
    _Pass pass,
    String id,
    _RecordUpdate update,
  ) => _session.runWrite((v) async {
    pass.check(v);
    final sync = (await v.conversation(id))?.sync ?? const ConversationSync();
    final u = await update(v, sync);
    if (u == null) return false;
    final token = u.sinceToken;
    final saves = token != null && token.isNotEmpty && token != sync.sinceToken;
    await v.transaction((tx) async {
      await _records.putIn(tx, id, u.record);
      if (saves) {
        await tx.putConversationSync(id, sync.copyWith(sinceToken: token));
      }
    });
    // The pass's own save: its freshness witness follows the token.
    if (saves) {
      _contexts.of(id).noteSinceTokenSaved(pass, sync.sinceToken, token);
    }
    return true;
  });

  /// §3.3: every id is 32 lower-case hex and every set time one [_micros]
  /// holds (a page position is recorded, and a record holding any other id
  /// or a time above 2^53 - 1 would not decode); strictly ascending by
  /// (created_at, id); a continuation page starts after [w]'s last
  /// position, a listing-start page after its settle floor.
  bool _inOrder(List<pb.Message> messages, WalkEntry w) {
    if (messages.isEmpty) return true;
    WalkPos? previous;
    for (final m in messages) {
      if (!_messageIdShape.hasMatch(m.id) || !_timeConverts(m)) return false;
      final p = _posOf(m);
      if (previous != null && p.compareTo(previous) <= 0) return false;
      previous = p;
    }
    final first = _posOf(messages.first);
    final l = w.l;
    final f = w.f;
    if (!w.r && l != null && first.compareTo(l) <= 0) return false;
    if (w.r && f != null && first.compareTo(f) <= 0) return false;
    return true;
  }

  /// The walk backoff (1 min doubling to 1 h, memory).
  ReceiveOutcome _backOff(ConversationContext context) {
    final previous = context.walkBackoff;
    context.walkBackOffs++;
    var d = previous == null ? kWalkBackoff : previous * 2;
    if (d > kWalkBackoffMax) d = kWalkBackoffMax;
    context.walkBackoff = d;
    final until = _now().add(d);
    context.walkBackoffUntil = until;
    return ReceiveOutcome.stopped(until);
  }

  /// A server retry time, 1 min without a hint, capped at
  /// [kMaxServerRetryWait].
  DateTime _retryAt(RateLimitedException e) {
    var wait = e.retryAfter ?? const Duration(minutes: 1);
    if (wait > kMaxServerRetryWait) wait = kMaxServerRetryWait;
    if (wait.isNegative) wait = Duration.zero;
    return _now().add(wait);
  }
}
