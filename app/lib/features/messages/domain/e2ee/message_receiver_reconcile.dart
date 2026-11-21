part of 'message_receiver.dart';

/// What one tombstone page did under the lock. `stale`: the page was listed
/// for an entry that changed meanwhile (discarded); `failed`: the listing
/// was refused, unavailable or out of order (counted, backed off);
/// `halted`: nothing could be written now (not counted); `applied`: the
/// cursor advanced; `awaiting`: the listing reached its end while the since
/// token is empty (its tombstones are applied, the entry stays armed);
/// `finished`: the listing ended and the entry is disarmed.
enum _RecStep { stale, failed, halted, applied, awaiting, finished }

/// What a reconcile step ended with. [outcome] null: nothing is left for
/// this pass (not armed, or disarmed just now). [awaiting]: the listing
/// reached its end and only waits for a since token to be saved.
class _Reconciled {
  const _Reconciled(this.outcome, {this.awaiting = false});

  static const _Reconciled done = _Reconciled(null);

  final ReceiveOutcome? outcome;
  final bool awaiting;
}

/// The reconcile walk (design rev 3 §8.2), AS BUILT in step 2b (where a
/// line below and §8.2 differ, the line below is the rule):
///
/// - **Arming.** A retirement resets the entry unarmed, from the top; the
///   next probe with an empty since token arms it. An entry is created
///   armed when the since token is empty and there is none (§3.4).
/// - **Listing.** `ListMessageTombstones`, [kTombstonePageSize] a page, at
///   most [kReconcilePagesPerPass] pages a pass, each listed WITHOUT the
///   lock on the sync budget and applied under it in ONE transaction, only
///   when the entry and the record serial are still the ones it was listed
///   for. NO engine call, and no engine hold gates it.
/// - **A page** marks every stored row of its ids `removed` /
///   `deletedAccount` (the content goes), ends every deferred message
///   among them as its tombstone row (§8.1, through [_tombstoneDeferred]),
///   remembers every id for the run and advances the cursor.
/// - **The disarm** (the entry becomes null) happens ONLY in the
///   transaction of the LAST page of a listing (no next token), and only
///   when the since token read in that body is not empty. With an empty
///   token the last page is applied, the entry stays armed with its cursor
///   unmoved, and the page is listed again by a later step.
/// - **The final-attempt gate.** A last page applied by a pass's own step
///   (after that pass's probe was answered) is noted for that pass, in
///   memory only ([ConversationContext.noteListedToEnd]): until the record
///   is next written or the pass ends, its final attempts may reach the
///   engine although the entry still waits for a since token
///   ([_finalAttempts]). The disarm itself is unchanged.
/// - **Begun after the token.** The transaction that saves a since token
///   over an empty one begins a listing in progress again from the top
///   ([_applyPageLocked]), so the listing that disarms began after the
///   token it leaves the conversation with was issued: a takedown older
///   than that token is on that listing, a newer one on the since listings.
/// - **Failures.** FEATURE_DISABLED, UNIMPLEMENTED, any other refused call,
///   a refused page token (the listing begins again from the top), a page
///   out of order or shape, a listing past [kReconcilePagesMax] pages
///   (begun again), and a network failure in a pass whose probe the server
///   had just answered: the entry stays armed, the listing waits
///   [kWalkBackoff] doubling to [kWalkBackoffMax] (memory), and the failure
///   is COUNTED in the entry (`f`, `fa`), at most one per [kEngineBackoff]
///   doubling with the count, across app runs. A retirement that interrupts
///   a listing in progress is counted the same way. At
///   [kReconcileGiveUpAfter] the final attempts stop waiting for the entry
///   ([_finalAttempts]); the count is reported once. The count is cleared
///   by the transaction of a listing's LAST page, whether that page
///   disarms the entry or leaves it armed for want of a since token.
/// - **Not counted:** a rate-limited call (`held`), a paused budget, a
///   network failure with no answered probe just before it (the device may
///   be offline), a page discarded as stale, a vault that cannot be
///   written.
extension _Reconcile on MessageReceiver {
  /// The public entry: one allowance of the walk alone. Never throws.
  Future<ReceiveOutcome> _reconcileAlone(
    String id,
    BudgetPriority priority,
  ) async {
    try {
      final pass = await _start();
      if (pass == null) {
        return ReceiveOutcome.stopped(_now().add(kWalkBackoff));
      }
      var left = kReconcilePagesPerPass;
      final r = await _reconcileStep(
        pass,
        id,
        priority,
        () => left > 0 ? left-- : 0,
        answered: false,
      );
      if (r.awaiting) return ReceiveOutcome.stopped(_now().add(kWalkBackoff));
      return r.outcome ?? ReceiveOutcome.complete;
    } on Object catch (e, s) {
      _reportIfBug(e, s, 'receive.reconcile');
      return ReceiveOutcome.stopped(_now().add(kWalkBackoff));
    }
  }

  /// Step 2 of a pass: the pages [take] still allows. [answered]: the
  /// server answered this pass's probe just before (the witness that a
  /// failed tombstone call is not the device being offline).
  Future<_Reconciled> _reconcileStep(
    _Pass pass,
    String id,
    BudgetPriority priority,
    int Function() take, {
    required bool answered,
  }) async {
    final context = _contexts.of(id);
    while (true) {
      final rec = (await _readReceive(pass.vault, id)).rec;
      if (rec == null || !rec.armed) return _Reconciled.done;
      final wait = context.reconcileNotBefore;
      if (wait != null && _now().isBefore(wait)) {
        return _Reconciled(ReceiveOutcome.stopped(wait));
      }
      if (take() == 0) return const _Reconciled(ReceiveOutcome.more);
      final serial = context.serial;
      if (!await _takeUnit(_syncBudget, priority, id)) {
        return _Reconciled(ReceiveOutcome.held(_now().add(kWalkBackoff)));
      }
      pb.ListMessageTombstonesResponse? page;
      var refused = false;
      try {
        page = await _messaging.listMessageTombstones(
          conversationId: id,
          pageSize: kTombstonePageSize,
          pageToken: rec.t,
        );
      } on ValidationException catch (e) {
        refused = e.field == 'page_token' && rec.t.isNotEmpty;
      } on RateLimitedException catch (e) {
        final until = _retryAt(e);
        _syncBudget.pauseUntil(until);
        return _Reconciled(ReceiveOutcome.held(until));
      } on NetworkException {
        // With no answered probe just before, this may be the device being
        // offline: a wait, nothing counted.
        if (!answered) return _Reconciled(_reconcileBackOff(context));
      } on Object catch (e, s) {
        _reportIfBug(e, s, 'receive.listMessageTombstones');
      }
      final listed = page;
      final step = await _locks.run(id, () async {
        if (!pass.live) return _RecStep.halted;
        final fresh = (await _readReceive(pass.vault, id)).rec;
        if (fresh == null ||
            !fresh.armed ||
            fresh.t != rec.t ||
            fresh.n != rec.n ||
            context.serial != serial) {
          return _RecStep.stale;
        }
        if (listed == null) {
          return _reconcileFailedLocked(pass, id, restart: refused);
        }
        final tooLong = fresh.n >= kReconcilePagesMax;
        final states = tooLong ? null : _tombstonePage(listed, fresh);
        if (states == null) {
          context.reconcileViolation++;
          return _reconcileFailedLocked(pass, id, restart: tooLong);
        }
        final applied = await _applyTombstonesLocked(
          pass,
          id,
          fresh,
          listed,
          states,
        );
        // The final-attempt gate (fix round 1 of step 2b): THIS pass's
        // listing reached its end (the last page passed the check and was
        // applied for the entry and serial it was listed for) after this
        // pass's probe was answered. Noted after the page's own change of
        // the serial, still under the lock; never by the public step.
        if (answered && applied == _RecStep.awaiting) {
          context.noteListedToEnd(pass);
        }
        return applied;
      });
      switch (step) {
        case _RecStep.stale:
          context.reconcileDiscarded++;
        case _RecStep.failed:
          return _Reconciled(_reconcileBackOff(context));
        case _RecStep.halted:
          return _Reconciled(ReceiveOutcome.stopped(_now().add(kWalkBackoff)));
        case _RecStep.applied:
          _reconcileBackoffCleared(context);
        case _RecStep.awaiting:
          _reconcileBackoffCleared(context);
          return const _Reconciled(null, awaiting: true);
        case _RecStep.finished:
          _reconcileBackoffCleared(context);
          return _Reconciled.done;
      }
    }
  }

  void _reconcileBackoffCleared(ConversationContext context) {
    context
      ..reconcileBackoff = null
      ..reconcileNotBefore = null;
  }

  /// The listing's own wait (1 min doubling to 1 h, memory).
  ReceiveOutcome _reconcileBackOff(ConversationContext context) {
    final previous = context.reconcileBackoff;
    var d = previous == null ? kWalkBackoff : previous * 2;
    if (d > kWalkBackoffMax) d = kWalkBackoffMax;
    final until = _now().add(d);
    context
      ..reconcileBackoff = d
      ..reconcileNotBefore = until;
    return ReceiveOutcome.stopped(until);
  }

  /// The order and shape check of a tombstone page listed at [rec]'s
  /// cursor, before anything of it is used: at most [kTombstonePageSize]
  /// tombstones; every id 32 lower-case hex; every state REMOVED or
  /// DELETED_ACCOUNT; ids strictly ascending and after the last id applied
  /// in this listing; a next token of the one token shape, and never on a
  /// page with no tombstone (the cursor could not be checked to move; the
  /// server skips a malformed row but then still returns the others of a
  /// full page). Null: refused. Otherwise message id -> stored state name,
  /// ascending.
  Map<String, String>? _tombstonePage(
    pb.ListMessageTombstonesResponse page,
    ReconcileEntry rec,
  ) {
    final next = page.nextPageToken;
    if (page.tombstones.length > kTombstonePageSize ||
        !isTokenShape(next) ||
        (page.tombstones.isEmpty && next.isNotEmpty)) {
      return null;
    }
    final states = <String, String>{};
    var previous = rec.l;
    for (final t in page.tombstones) {
      final String state;
      if (t.state == MessageState.MESSAGE_STATE_REMOVED) {
        state = StoredMessageState.removed;
      } else if (t.state == MessageState.MESSAGE_STATE_DELETED_ACCOUNT) {
        state = StoredMessageState.deletedAccount;
      } else {
        return null;
      }
      if (!_messageIdShape.hasMatch(t.id) || t.id.compareTo(previous) <= 0) {
        return null;
      }
      previous = t.id;
      states[t.id] = state;
    }
    return states;
  }

  /// [rec] with one more counted failure, or null when this one is not
  /// counted: the count is at its bound, or less than the spacing has
  /// passed since the last counted one ([kEngineBackoff], doubling with
  /// the count up to [kWalkBackoffMax]; either way, so a local clock set
  /// back does not stop the count).
  ReconcileEntry? _reconcileCounted(ReconcileEntry rec) {
    if (rec.gaveUp) return null;
    final now = _now().microsecondsSinceEpoch;
    if (rec.f > 0) {
      var spacing = kEngineBackoff;
      for (var i = 1; i < rec.f && spacing < kWalkBackoffMax; i++) {
        spacing *= 2;
      }
      if (spacing > kWalkBackoffMax) spacing = kWalkBackoffMax;
      if ((now - rec.fa).abs() < spacing.inMicroseconds) return null;
    }
    return rec.copyWith(f: rec.f + 1, fa: now < 0 ? 0 : now);
  }

  /// The count reached [kReconcileGiveUpAfter] in a transaction that just
  /// committed: reported once, by its step name only.
  void _reconcileGaveUp() => _onUnexpectedError?.call(
    const E2eePipelineError('receive.reconcile.gaveUp'),
    StackTrace.current,
  );

  /// A refused, unavailable or out-of-order listing, with the lock held:
  /// ONE transaction on the record read fresh counts it (when it counts)
  /// and, with [restart], begins the listing again from the top. The entry
  /// stays armed. Always `failed` (the caller backs off).
  Future<_RecStep> _reconcileFailedLocked(
    _Pass pass,
    String id, {
    required bool restart,
  }) async {
    try {
      var gaveUp = false;
      final wrote = await _session.runWrite((v) async {
        pass.check(v);
        final record = await _readReceive(v, id);
        final rec = record.rec;
        if (rec == null || !rec.armed) return false;
        final counted = _reconcileCounted(rec);
        final again = restart && rec.begun;
        if (counted == null && !again) return false;
        var next = counted ?? rec;
        if (again) next = next.restarted();
        await v.transaction(
          (tx) => _records.putIn(tx, id, record.copyWith(rec: next)),
        );
        gaveUp = counted != null && counted.gaveUp;
        return true;
      });
      if (wrote) {
        // A counted failure or a restart of the listing: the record was
        // written, and the final-attempt gate closes with it.
        final context = _contexts.of(id);
        context.serial++;
        context.clearListedToEnd();
      }
      if (gaveUp) _reconcileGaveUp();
    } on _Stopped {
      // The vault changed: nothing is counted.
    } on Object catch (e, s) {
      _reportIfBug(e, s, 'receive.reconcile.count');
    }
    return _RecStep.failed;
  }

  /// One checked tombstone page ([states], ascending) listed at [listed]'s
  /// cursor, with the lock held, in ONE `runWrite` and ONE transaction on
  /// records read fresh: stored rows marked, deferred messages ended as
  /// their tombstone rows, and the entry advanced, kept (the last page with
  /// an empty since token) or cleared (the last page with a since token:
  /// the disarm). No visible row, no engine call.
  Future<_RecStep> _applyTombstonesLocked(
    _Pass pass,
    String id,
    ReconcileEntry listed,
    pb.ListMessageTombstonesResponse page,
    Map<String, String> states,
  ) async {
    final context = _contexts.of(id);
    // Remembered for the run BEFORE the write is asked for: when the write
    // never starts, this pass's retries must still not give such a message
    // to the engine (§7.4 check 2).
    states.forEach((mid, state) => _noteTombstone(context, mid, state));
    final last = page.nextPageToken.isEmpty;
    var changed = false;
    var recordWritten = false;
    _RecStep step;
    try {
      step = await _session.runWrite<_RecStep>((v) async {
        pass.check(v);
        final sync =
            (await v.conversation(id))?.sync ?? const ConversationSync();
        final record = await _readReceive(v, id);
        final now = record.rec;
        if (now == null ||
            !now.armed ||
            now.t != listed.t ||
            now.n != listed.n) {
          return _RecStep.stale;
        }
        final plan = await _tombstoneDeferred(v, id, states);
        final marks = <String, String>{};
        for (final e in states.entries) {
          final stored = await v.message(id, e.key);
          if (stored != null && stored.state != e.value) {
            marks[e.key] = e.value;
          }
        }
        // The disarm: only with the last page of the listing, and never
        // while the since token is empty.
        final disarm = last && sync.sinceToken.isNotEmpty;
        // A listing that reached its end shows the tombstone server works:
        // the failure count goes in this transaction, also while the entry
        // stays armed for want of a since token (a kill switch or a flaky
        // hour must not row later final attempts on a recovered server).
        final clearCount = last && !disarm && (now.f != 0 || now.fa != 0);
        final writeRecord = !last || disarm || clearCount;
        final next = last
            ? (disarm ? null : now.copyWith(f: 0, fa: 0))
            : now.copyWith(
                t: page.nextPageToken,
                n: now.n + 1,
                l: states.keys.last,
              );
        if (plan == null && marks.isEmpty && !writeRecord) {
          return _RecStep.awaiting;
        }
        await v.transaction((tx) async {
          for (final row in plan?.rows ?? const <StoredMessage>[]) {
            await tx.putMessage(row);
          }
          for (final e in marks.entries) {
            await tx.setMessageState(id, e.key, e.value);
          }
          if (plan != null) await _deferred.putIn(tx, id, plan.deferred);
          if (writeRecord) {
            await _records.putIn(tx, id, record.copyWith(rec: next));
          }
        });
        if (plan != null) {
          context.deferredEmpty = plan.deferred.items.isEmpty;
        }
        changed = plan != null || marks.isNotEmpty;
        recordWritten = writeRecord;
        if (!last) return _RecStep.applied;
        return disarm ? _RecStep.finished : _RecStep.awaiting;
      });
    } on _Stopped {
      return _RecStep.halted;
    } on _DeferredUnreadable {
      // Nothing written: the next pass replaces the record (§7.3).
      return _RecStep.halted;
    } on Object catch (e, s) {
      // A vault error: nothing written; listed again later.
      _reportIfBug(e, s, 'receive.reconcile.page');
      return _RecStep.halted;
    }
    // The record was written: any page listed without the lock before this
    // is discarded and listed again (§8.2 "held pages").
    if (recordWritten) context.serial++;
    if (changed) _onChanged(id);
    return step;
  }
}
