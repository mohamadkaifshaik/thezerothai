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
  bool waitingForWelcome = false;
}

extension _Walks on MessageReceiver {
  /// One pass (§2). Never throws.
  Future<ReceiveOutcome> _runPass(String id, BudgetPriority priority) async {
    var welcomes = false;
    ReceiveOutcome outcome;
    try {
      outcome = await _passSteps(id, priority, () => welcomes = true);
    } on Object catch (e, s) {
      _reportIfBug(e, s, 'receive.live');
      outcome = ReceiveOutcome.stopped(_now().add(kWalkBackoff));
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
    return outcome;
  }

  Future<ReceiveOutcome> _passSteps(
    String id,
    BudgetPriority priority,
    void Function() onWelcomes,
  ) async {
    final pass = await _start();
    if (pass == null) return ReceiveOutcome.stopped(_now().add(kWalkBackoff));
    // A provisional group only, or none: catch-up and the welcomes own the
    // current pair; an undecryptable (`u`) close or orphan walk left over
    // from a group that is gone is still finished, with no probe.
    if (await _currentPair(pass.vault, id) == null) {
      return _walkWithoutGroup(pass, id, priority);
    }
    final context = _contexts.of(id);

    // 1. The probe.
    final probe = await _probe(pass, id, priority);
    if (probe.waitingForWelcome) onWelcomes();
    if (probe.outcome != null) return probe.outcome!;

    // 2. The reconcile walk: step 2 (an armed entry waits durably).

    // 3-5. The walks, one allowance across them.
    final until = context.walkBackoffUntil;
    if (until != null && _now().isBefore(until)) {
      return ReceiveOutcome.stopped(until);
    }
    var left = priority == BudgetPriority.user
        ? 2 * kWalkPagesPerPass
        : kWalkPagesPerPass;
    int take() => left > 0 ? left-- : 0;
    for (final slot in const [_Slot.close, _Slot.orphan]) {
      final r = await _walk(pass, id, slot, priority, take);
      if (r != null) return r;
    }
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
      newListing: context.endToken != null || settleDue,
      onTokenSaved: () => pulled = true,
    );
    if (r != null) return r;

    // 6. Deferred retries: step 2.

    if (pulled) {
      // M10: a pass that saved the since token (or found it stored) at the
      // group's current pair.
      final pair = await _currentPair(pass.vault, id);
      if (pair != null) {
        context
          ..livePulledAt = pair
          ..syncedSinceStart =
              !context.attributionPending && context.serverPair == pair;
      }
    }
    var after = await _readReceive(pass.vault, id);
    final current = await _currentPair(pass.vault, id);
    final seen = probe.sawLater;
    final kept = context.laterPairSeen;
    if (seen != null && (kept == null || seen.compareTo(kept) > 0)) {
      context.laterPairSeen = seen;
    }
    // M7: a seen pair the current pair has reached is no longer a reason.
    _clearLaterPairReached(context, current);
    if (!probe.caughtUp &&
        current != null &&
        !_commitWalksLeft(after) &&
        (_closeEndedAt(after, current) ||
            context.laterPairSeen != null ||
            context.catchUpDue)) {
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
      // pass (its sink may have set `catchUpDue` again in this run).
      if (result != null && result != CatchUpResult.interrupted) {
        context
          ..laterPairSeen = null
          ..catchUpDue = false;
      }
      _clearLaterPairReached(context, now);
      after = await _readReceive(pass.vault, id);
      if (!moved && !_walksLeft(after)) {
        // Nothing applied and no walk left (no commit visible yet, a
        // failed call, a later pair the server does not have): the next
        // pass waits, never an immediate `more` or a `complete` with a
        // commit left. A walk the catch-up's sink left pending is `more`.
        // The second such run in a row waits with the doubling walk
        // backoff (at least twice the first wait).
        if (context.fruitlessCatchUp) {
          context.walkBackoff ??= kWalkBackoff;
          return _backOff(context);
        }
        context.fruitlessCatchUp = true;
        return ReceiveOutcome.stopped(_now().add(kWalkBackoff));
      }
      context.fruitlessCatchUp = false;
    }
    return pulled && !_walksLeft(after)
        ? ReceiveOutcome.complete
        : ReceiveOutcome.more;
  }

  /// Clears [context]'s later pair once [current] has reached it.
  void _clearLaterPairReached(ConversationContext context, MlsPair? current) {
    final later = context.laterPairSeen;
    if (later != null && current != null && later.compareTo(current) <= 0) {
      context.laterPairSeen = null;
    }
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

  /// A pass with no final group (§3.4 keeps a `u` close or orphan slot whose
  /// group is gone): those walks only, no probe, no catch-up. A pass that
  /// moved neither slot stops (a provisional group at the slot's generation
  /// discards its pages) rather than asking for an immediate next pass.
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

  Future<_Probe> _probe(_Pass pass, String id, BudgetPriority priority) async {
    final context = _contexts.of(id);
    final limited = _messaging.rateLimitedFor();
    if (limited != null) {
      return _Probe(outcome: ReceiveOutcome.held(_retryAt(limited)));
    }
    if (!await _takeUnit(_readBudget, priority)) {
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
    // Against the pair read before the listing (I2's later-pair trigger).
    final later = _highestAbove(page.messages, current);
    return _locks.run(id, () async {
      if (!pass.live) {
        return _Probe(
          outcome: ReceiveOutcome.stopped(_now().add(kWalkBackoff)),
        );
      }
      if (token.isEmpty) {
        // §8.2: the anchor and the armed reconcile entry (its listing is
        // step 2's); the page is not processed.
        await _armLocked(pass, id, page.sinceToken);
        context.endToken = page.sinceToken.isEmpty
            ? null
            : (token: page.sinceToken, sentWith: '', seq: seq);
        return _Probe(sawLater: later);
      }
      if (page.gapPageToken.isEmpty &&
          openEnded &&
          context.serial == serial &&
          await _openEndedNow(vault, id, current)) {
        // Rule 1: the fast path (M5: `open` read again under the lock).
        final messages = [...page.messages];
        _sort(messages);
        final end = await _runBatch(
          pass,
          id,
          messages,
          priority: priority,
          token: (token: page.sinceToken, expect: token),
        );
        return _Probe(
          fastPath: true,
          pulled: end.completed,
          caughtUp: end.caughtUp,
        )..waitingForWelcome = end.waitingForWelcome;
      }
      // Not processed: its messages come through the open walk, in order;
      // its token is saved by rule 2 once that walk ends.
      context.endToken = page.sinceToken.isEmpty
          ? null
          : (token: page.sinceToken, sentWith: token, seq: seq);
      return _Probe(sawLater: later);
    });
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
  /// entry reset (unarmed) in one transaction; a retired anchor is cleared.
  Future<void> _retireLocked(_Pass pass, String id, String token) async {
    if (!pass.live) return;
    _contexts.of(id).endToken = null;
    await _session.runWrite((v) async {
      pass.check(v);
      final sync = (await v.conversation(id))?.sync ?? const ConversationSync();
      if (sync.sinceToken != token) return;
      final record = await _readReceive(v, id);
      await v.transaction((tx) async {
        if (token.isEmpty) {
          await _records.putIn(tx, id, record.copyWith(anchor: ''));
          return;
        }
        await tx.putConversationSync(id, sync.copyWith(sinceToken: ''));
        await _records.putIn(
          tx,
          id,
          record.copyWith(rec: const ReconcileEntry(armed: false)),
        );
      });
    });
    _contexts.of(id).serial++;
  }

  /// The probe with an empty since token: [anchor] (the answer's token)
  /// becomes the anchor and the reconcile entry is armed, in one
  /// transaction (§8.2).
  Future<void> _armLocked(_Pass pass, String id, String anchor) async {
    await _session.runWrite((v) async {
      pass.check(v);
      final sync = (await v.conversation(id))?.sync ?? const ConversationSync();
      if (sync.sinceToken.isNotEmpty) return;
      final record = await _readReceive(v, id);
      final rec = record.rec;
      final armed = ReconcileEntry(
        armed: true,
        t: rec?.t ?? '',
        n: rec?.n ?? 0,
        l: rec?.l ?? '',
      );
      await v.transaction(
        (tx) => _records.putIn(
          tx,
          id,
          record.copyWith(
            rec: armed,
            anchor: anchor.isEmpty || anchor.length > kMaxTokenChars
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
      if (w == null || (w.end && !again)) return null;
      if (take() == 0) return ReceiveOutcome.more;
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
          return step.outcome;
      }
    }
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
    if (!await _takeUnit(_syncBudget, priority)) {
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
  /// was refused (or an answer's token is over [kMaxTokenChars]).
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
      if (page.nextPageToken.length > kMaxTokenChars ||
          page.resumePageToken.length > kMaxTokenChars) {
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
    if (!_inOrder(page.messages, w)) {
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

    final last = page.messages.isEmpty ? null : _posOf(page.messages.last);
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
    final orphanFinal = slot == _Slot.orphan && next.end;
    var tokenWritten = false;
    // The last computed update was not stale (its transaction carries the
    // record); read only after a transaction that used it ran.
    var recordInUpdate = false;
    Future<({ReceiveRecord record, String? sinceToken, int? deleteGroup})?>
    update(SecureVault v, ConversationSync sync) async {
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
      return (
        record: _withSlot(record, slot, orphanFinal ? null : next),
        sinceToken: token,
        deleteGroup: orphanFinal && !gone ? w.pair.generation : null,
      );
    }

    var written = false;
    var changed = false;
    final messages = page.messages;
    for (var i = 0; i < messages.length; i++) {
      final isLast = i == messages.length - 1;
      final step = await _one(
        pass,
        id,
        messages[i],
        mode,
        w.pair,
        record: isLast ? update : null,
      );
      if (step == _Step.stop) {
        if (changed) _onChanged(id);
        // As built: nothing stored for this message, the cursor kept.
        return _StepEnd.stop(
          ReceiveOutcome.stopped(_now().add(kEngineBackoff)),
        );
      }
      if (step == _Step.wrote) {
        changed = true;
        // M1: the message's transaction ran; the record rode with it only
        // when the update was not stale.
        if (isLast) written = recordInUpdate;
      }
    }
    if (!written) written = await _writeAlone(pass, id, update);
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
      if (tokenWritten) onTokenSaved?.call();
    }
    return next.end ? _StepEnd.finished : _StepEnd.advanced;
  }

  /// A page's record update in a transaction of its own (its last message
  /// wrote nothing, or the page is empty). False: nothing was written.
  Future<bool> _writeAlone(_Pass pass, String id, _RecordUpdate update) =>
      _session.runWrite((v) async {
        pass.check(v);
        final sync =
            (await v.conversation(id))?.sync ?? const ConversationSync();
        final u = await update(v, sync);
        if (u == null) return false;
        final token = u.sinceToken;
        await v.transaction((tx) async {
          if (u.deleteGroup != null) await tx.deleteGroup(id, u.deleteGroup!);
          await _records.putIn(tx, id, u.record);
          if (token != null && token.isNotEmpty && token != sync.sinceToken) {
            await tx.putConversationSync(id, sync.copyWith(sinceToken: token));
          }
        });
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
