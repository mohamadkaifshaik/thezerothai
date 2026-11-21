part of 'message_receiver.dart';

/// The deferred record of a conversation is unreadable: nothing is written
/// by the body that met it; the next pass replaces it and resets the walks
/// in one transaction (§7.3). Carries nothing.
class _DeferredUnreadable implements Exception {
  const _DeferredUnreadable();
}

/// What one engine attempt on one message gave (first sight, a retry or a
/// final attempt alike). [code] set: the engine failed with `internal`,
/// `deadline` or `unavailable` (nothing to store yet). Otherwise [row] is
/// the row to store (null: handled without a row), [group] the group state
/// a success advanced. No `toString`.
class _Attempt {
  const _Attempt.row(this.row, {this.group, this.epochMustAdvance = false})
    : code = null;
  const _Attempt.rowless()
    : row = null,
      group = null,
      epochMustAdvance = false,
      code = null;
  const _Attempt.failed(MlsErrorCode this.code)
    : row = null,
      group = null,
      epochMustAdvance = false;

  final StoredMessage? row;
  final GroupRecord? group;
  final bool epochMustAdvance;
  final MlsErrorCode? code;
}

/// The class of an `internal` / `deadline` / `unavailable` answer, from the
/// error code and the receiver's own probes (§7.1).
enum _FailKind {
  /// `unavailable`, from the call or from a probe: the device is down.
  deviceDown,

  /// `internal`, the describe probe answered: message-specific.
  witnessed,

  /// `deadline`, the describe probe answered: a witnessed crash.
  witnessedCrash,

  /// `deadline`, the describe probe failed: an unwitnessed crash.
  unwitnessedCrash,

  /// `internal`, the describe probe failed, the device probe answered.
  groupLevel,

  /// `internal`, both probes failed: the device-level breaker.
  breaker,
}

typedef _Fail = ({_FailKind kind, int stamp});

/// What one deferred item's turn ended with: `kept` (nothing the screens
/// show changed), `changed` (the item ended), `stop` (an engine answer
/// stopped the pass: no later engine retry in it).
enum _Retry { kept, changed, stop }

/// Oldest first: the server's time, then the id.
int _oldestFirst(DeferredItem a, DeferredItem b) {
  final c = a.at.compareTo(b.at);
  return c != 0 ? c : a.id.compareTo(b.id);
}

extension _Failures on MessageReceiver {
  /// An engine call whose success is counted in [_okSeq] (§7.1).
  Future<T> _counted<T>(Future<T> call) async {
    final result = await call;
    _okSeq++;
    return result;
  }

  /// The end of an engine hold of [context] still in the future, or null.
  DateTime? _engineHoldOf(ConversationContext context) {
    final until = context.engineHoldUntil;
    return until != null && _now().isBefore(until) ? until : null;
  }

  /// No engine call for this conversation before [kEngineBackoff] from now
  /// (the breaker: 1 min doubling to 1 h).
  void _holdEngine(ConversationContext context, {bool breaker = false}) {
    var d = kEngineBackoff;
    if (breaker) {
      final previous = context.breakerBackoff;
      if (previous != null) d = previous * 2;
      if (d > kWalkBackoffMax) d = kWalkBackoffMax;
      context.breakerBackoff = d;
      _breakerOpen++;
    }
    context.engineHoldUntil = _now().add(d);
  }

  bool _groupBroken(ConversationContext context, MlsPair p) =>
      context.groupBroken['${p.generation}:${p.epoch}'] == _runId;

  void _breakGroup(ConversationContext context, MlsPair p) =>
      context.groupBroken['${p.generation}:${p.epoch}'] = _runId;

  /// The deferred record, read fresh with the body's [v]. Throws
  /// [_DeferredUnreadable] (write nothing) when it does not read.
  Future<DeferredRecord> _readDeferred(SecureVault v, String id) async {
    final read = await _deferred.read(v, id);
    if (read.unreadable) throw const _DeferredUnreadable();
    _contexts.of(id).deferredEmpty = read.record.items.isEmpty;
    return read.record;
  }

  /// As [_readDeferred] for a lookup only ("is this id deferred?"): not
  /// read again while this run's last read or write left it empty.
  Future<DeferredRecord> _deferredLookup(SecureVault v, String id) async =>
      _contexts.of(id).deferredEmpty == true
      ? DeferredRecord.empty
      : _readDeferred(v, id);

  /// Step 7 of the one-message rules: the engine on [group], and what its
  /// answer means. Shared by first sight, a deferred retry and a final
  /// attempt, so a message is judged the same wherever it is tried. Called
  /// inside a write body only; writes nothing.
  Future<_Attempt> _attempt(
    SecureVault v,
    _Pass pass,
    String id,
    GroupRecord group,
    Uint8List deviceState, {
    required String mid,
    required int at,
    required Uint8List ciphertext,
    required Uint8List commitment,
    required bool fromSelf,
  }) async {
    final p = MlsPair(group.generation, group.epoch);
    final rowlessKey = '${pass.uid}|$id|$mid';
    StoredMessage undecryptable({bool mine = false}) => StoredMessage(
      conversationId: id,
      messageId: mid,
      createdAtMicros: at,
      mine: mine,
      state: StoredMessageState.undecryptable,
      generation: p.generation,
      epoch: p.epoch,
      content: null,
    );
    final ProcessResult result;
    try {
      result = await _counted(
        _engine().process(deviceState, group.state, ciphertext),
      );
    } on MlsException catch (err) {
      switch (err.code) {
        case MlsErrorCode.ownLeaf:
          if (!fromSelf) {
            // C3: unauthenticated; a forgery. Counted, never shown.
            if (_remember(rowlessKey)) _forgeries++;
            return const _Attempt.rowless();
          }
          if (await v.hasOutboxExpecting(mid) ||
              await v.hasSent(id, p, sentDigest(ciphertext))) {
            // Sent by this device (its echo comes, or came, by bytes).
            _remember(rowlessKey);
            return const _Attempt.rowless();
          }
          // R7: a lost send. The epoch must advance before the next
          // encrypt.
          return _Attempt.row(
            undecryptable(mine: true),
            epochMustAdvance: true,
          );
        case MlsErrorCode.internal:
        case MlsErrorCode.deadline:
        case MlsErrorCode.unavailable:
          return _Attempt.failed(err.code);
        case MlsErrorCode.duplicate:
        case MlsErrorCode.badInput:
        case MlsErrorCode.wrongEpoch:
        case MlsErrorCode.evicted:
        case MlsErrorCode.corruptState:
        case MlsErrorCode.pendingCommit:
        case MlsErrorCode.noPendingCommit:
          // Definitive: the group state is not changed.
          return _Attempt.row(undecryptable());
      }
    }
    final event = result.event;
    if (event is! MlsMessageEvent) {
      // A commit in a message slot: never applied outside catch-up.
      return _Attempt.row(undecryptable());
    }
    MemberRecord? sender;
    for (final pin in await v.members(id)) {
      if (_sameBytes(pin.deviceId, event.senderDeviceId)) sender = pin;
    }
    if (sender == null) {
      // Not a pinned member: not believed; the group state is kept.
      return _Attempt.row(undecryptable());
    }
    final plaintext = event.plaintext;
    final check = checkMessageContentDetail(plaintext, commitment);
    return _Attempt.row(
      StoredMessage(
        conversationId: id,
        messageId: mid,
        createdAtMicros: at,
        // Direction from the sender device's pinned side, never from the
        // server's from_self.
        mine: sender.side == MemberSide.mine,
        state: StoredMessageState.visible,
        generation: p.generation,
        epoch: p.epoch,
        content: plaintext,
        check: check.storedName,
        senderDeviceId: event.senderDeviceId,
      ),
      group: GroupRecord(
        conversationId: id,
        generation: group.generation,
        epoch: group.epoch,
        state: result.groupState,
        pending: group.pending,
      ),
    );
  }

  /// §7.1: the class of the answer [code] on a message tried on
  /// [groupState], from the probes. P1 = `describe(groupState)` (read-only,
  /// its result dropped); P2 = `randomBytes(1)`, only when P1 failed with
  /// something other than `unavailable`. `stamp` is the success count
  /// before P2 (an unwitnessed crash is promoted once it has grown, so a
  /// device probe that answers counts as a later success).
  Future<_Fail> _classify(MlsErrorCode code, Uint8List groupState) async {
    if (code == MlsErrorCode.unavailable) {
      return (kind: _FailKind.deviceDown, stamp: _okSeq);
    }
    final crash = code == MlsErrorCode.deadline;
    if (crash) _deadlineThisRun = true;
    if (await _probe1(groupState) case final p1?) {
      if (!p1) return (kind: _FailKind.deviceDown, stamp: _okSeq);
      return (
        kind: crash ? _FailKind.witnessedCrash : _FailKind.witnessed,
        stamp: _okSeq,
      );
    }
    final stamp = _okSeq;
    bool? p2;
    try {
      await _counted(_engine().randomBytes(1));
      p2 = true;
    } on MlsException catch (e) {
      p2 = e.code == MlsErrorCode.unavailable ? null : false;
    } on Object {
      p2 = false;
    }
    if (p2 == null) return (kind: _FailKind.deviceDown, stamp: stamp);
    if (crash) return (kind: _FailKind.unwitnessedCrash, stamp: stamp);
    return (kind: p2 ? _FailKind.groupLevel : _FailKind.breaker, stamp: stamp);
  }

  /// P1: true when `describe` answered, false when it answered
  /// `unavailable`, null when it failed any other way.
  Future<bool?> _probe1(Uint8List groupState) async {
    try {
      await _counted(_engine().describe(groupState));
      return true;
    } on MlsException catch (e) {
      return e.code == MlsErrorCode.unavailable ? false : null;
    } on Object {
      return null;
    }
  }

  /// One more group-level failure at [p] in the receive record read fresh
  /// with [v]: the record to write and whether the count reached
  /// [kGroupFailuresMax] (then the failing message becomes a row and the
  /// group is rowed for the run).
  Future<({ReceiveRecord record, bool broken})> _groupFailure(
    SecureVault v,
    String id,
    MlsPair p,
  ) async {
    final fresh = await _readReceive(v, id);
    final n = (fresh.gf?.pair == p ? fresh.gf!.n : 0) + 1;
    final broken = n >= kGroupFailuresMax;
    final context = _contexts.of(id)..groupFailuresNull = false;
    if (broken) _breakGroup(context, p);
    return (
      record: fresh.copyWith(
        gf: GroupFailures(p, broken ? kGroupFailuresMax : n),
      ),
      broken: broken,
    );
  }

  /// A process success in group [p]: the receive record to write so that
  /// its failure count is null (§7.2), or null when it already is.
  /// [riding]: the page's record this transaction writes anyway.
  Future<ReceiveRecord?> _groupFailuresCleared(
    SecureVault v,
    String id,
    MlsPair p,
    ReceiveRecord? riding,
  ) async {
    final context = _contexts.of(id)..breakerBackoff = null;
    if (riding == null && context.groupFailuresNull == true) return null;
    final base = riding ?? await _readReceive(v, id);
    if (base.gf == null) {
      context.groupFailuresNull = true;
      return null;
    }
    return base.gf!.pair == p ? base.copyWith(gf: null) : null;
  }

  /// The row a deferred [item] ends as when it is not decrypted: the
  /// tombstone state seen this run, else `undecryptable`. Null (no row):
  /// the id is stored already (any state), or the item is at or before
  /// [cleared].
  Future<StoredMessage?> _itemRow(
    SecureVault v,
    String id,
    int? cleared,
    DeferredItem item,
  ) async {
    if (await v.hasMessage(id, item.id)) return null;
    if (cleared != null && item.at <= cleared) return null;
    return StoredMessage(
      conversationId: id,
      messageId: item.id,
      createdAtMicros: item.at,
      mine: false,
      state:
          _contexts.of(id).tombstoned[item.id] ??
          StoredMessageState.undecryptable,
      generation: item.pair.generation,
      epoch: item.pair.epoch,
      content: null,
    );
  }

  // -------------------------------------------------------------------------
  // Retries (§7.4): step 6 of a pass

  /// Step 6 of a pass, after its fresh work (also after a pass that ended
  /// early): under the lock, the promotion of unwitnessed items (§7.2),
  /// then every deferred item oldest first, each in ONE `runWrite`. The
  /// checks that need no engine (§7.4 checks 1 to 6) run for every item in
  /// every pass, so an item whose row, tombstone, `cleared_at`, expiry or
  /// lost group ends it never waits for a retry to be due; the engine runs
  /// only for a due item, only when [engine] (the pass was not stopped or
  /// held) and no engine hold is set. Never throws.
  Future<void> _retryDeferred(String id, {required bool engine}) async {
    try {
      final pass = await _start();
      if (pass == null) return;
      final context = _contexts.of(id);
      // With no lock: only to see whether there is anything to do.
      final seen = await _deferred.read(pass.vault, id);
      if (seen.unreadable) return;
      context.deferredEmpty = seen.record.items.isEmpty;
      if (seen.record.items.isEmpty) {
        context.unwitnessed.clear();
        return;
      }
      final ids = [
        for (final i in [...seen.record.items]..sort(_oldestFirst)) i.id,
      ];
      var changed = false;
      await _locks.run(id, () async {
        if (!pass.live) return;
        if (await _promoteLocked(pass, id)) changed = true;
        var allow = engine;
        for (final mid in ids) {
          if (!pass.live) return;
          final end = await _retryOne(
            pass,
            id,
            mid,
            engine: allow && _engineHoldOf(context) == null,
          );
          if (end == _Retry.changed) changed = true;
          // An answer that stops the pass stops every later engine retry.
          if (end == _Retry.stop) allow = false;
        }
      });
      if (changed) _onChanged(id);
    } on _Stopped {
      return;
    } on _DeferredUnreadable {
      return;
    } on Object catch (e, s) {
      _reportIfBug(e, s, 'receive.deferred.retry');
    }
  }

  /// §7.2: every item deferred unwitnessed this run after which an engine
  /// call succeeded is promoted in ONE transaction: `cu - 1`, `cc + 1`,
  /// `k + 1`. True when something was written.
  Future<bool> _promoteLocked(_Pass pass, String id) async {
    final context = _contexts.of(id);
    final due = [
      for (final e in context.unwitnessed.entries)
        if (_okSeq > e.value) e.key,
    ];
    if (due.isEmpty) return false;
    final wrote = await _session.runWrite((v) async {
      pass.check(v);
      var d = await _readDeferred(v, id);
      var any = false;
      for (final mid in due) {
        final item = d.of(mid);
        if (item == null || item.cu < 1) continue;
        d = d.put(
          item.copyWith(cu: item.cu - 1, cc: item.cc + 1, k: item.k + 1),
        );
        any = true;
      }
      if (any) await v.transaction((tx) => _deferred.putIn(tx, id, d));
      return any;
    });
    due.forEach(context.unwitnessed.remove);
    return wrote;
  }

  /// A deferred item may be given to the engine now (§7.4): not attempted
  /// in this run, its last attempt at least [kDeferredRetrySpacing] away
  /// (either way: a local clock set back does not hold it for good), and
  /// for a crash-class item no crash-class retry and no `deadline` answer
  /// yet this run.
  bool _retryDue(DeferredItem item, int nowMicros) =>
      item.ru != _runId &&
      (nowMicros - item.la).abs() >= kDeferredRetrySpacing.inMicroseconds &&
      (!item.crashClass || (!_crashRetryUsed && !_deadlineThisRun));

  /// The outbox row [ciphertext] is the echo of (the same id AND the same
  /// bytes), or null (step 4 of the one-message rules).
  Future<OutboxItem?> _echoOf(
    SecureVault v,
    String id,
    String mid,
    Uint8List ciphertext,
  ) async {
    if (ciphertext.isEmpty || !await v.hasOutboxExpecting(mid)) return null;
    for (final item in (await v.outbox()).items) {
      if (item.expectedMessageId == mid &&
          item.stage == OutboxStage.encrypted &&
          (item.conversationId == null || item.conversationId == id) &&
          _sameBytes(item.ciphertext, ciphertext)) {
        return item;
      }
    }
    return null;
  }

  /// One deferred item, with the lock held, in ONE `runWrite`: read fresh
  /// (gone: nothing), then the checks IN THIS ORDER (§7.4): (1) a stored
  /// row in any state; (2) a tombstone seen this run; (3) `cleared_at`;
  /// (4) expiry; (5) its group gone, provisional or at another epoch; (6)
  /// the outbox echo and the sent log; (7) the engine, when [engine] and
  /// the item is due, under the §7.2 table. The item's removal or its new
  /// counters ride in the same transaction as the row and the group state.
  Future<_Retry> _retryOne(
    _Pass pass,
    String id,
    String mid, {
    required bool engine,
  }) => _session.runWrite<_Retry>((v) async {
    pass.check(v);
    final context = _contexts.of(id);
    final d = await _readDeferred(v, id);
    final item = d.of(mid);
    if (item == null) return _Retry.kept;
    final sync = (await v.conversation(id))?.sync ?? const ConversationSync();
    final cleared = sync.clearedAtMicros;
    final now = _now().microsecondsSinceEpoch;
    final rowlessKey = '${pass.uid}|$id|$mid';

    /// The item ends: its removal with [row], [group], the outbox delete,
    /// the receive [record] and "epoch must advance" in ONE transaction.
    Future<_Retry> end({
      StoredMessage? row,
      GroupRecord? group,
      String? deleteOutbox,
      ReceiveRecord? record,
      bool epochMustAdvance = false,
    }) async {
      final rest = d.without([mid]);
      await v.transaction((tx) async {
        if (group != null) await tx.putGroup(group);
        if (row != null) await tx.putMessage(row);
        if (deleteOutbox != null) await tx.deleteOutbox(deleteOutbox);
        await _deferred.putIn(tx, id, rest);
        if (record != null) await _records.putIn(tx, id, record);
        if (epochMustAdvance && !sync.epochMustAdvance) {
          await tx.putConversationSync(
            id,
            sync.copyWith(epochMustAdvance: true),
          );
        }
      });
      context.deferredEmpty = rest.items.isEmpty;
      context.unwitnessed.remove(mid);
      if (record != null) context.serial++;
      return _Retry.changed;
    }

    /// The item stays, with new counters.
    Future<void> keep(DeferredItem next) =>
        v.transaction((tx) => _deferred.putIn(tx, id, d.put(next)));

    // 1. A stored row (any state): the item goes, the row stays as it is.
    //    This stops a replayed record, and a tombstone row (§8.1).
    if (await v.hasMessage(id, mid)) return end();
    // 2. A tombstone seen this run, 3. cleared_at, 4. expiry: the row the
    //    item ends as (none at or before cleared_at); never the engine.
    final hidden = cleared != null && item.at <= cleared;
    if (context.tombstoned.containsKey(mid) || hidden || item.expired(now)) {
      return end(row: await _itemRow(v, id, cleared, item));
    }
    // 5. Its keys are gone.
    final group = await v.group(id, item.pair.generation);
    if (group == null || group.provisional || group.epoch != item.pair.epoch) {
      return end(row: await _itemRow(v, id, cleared, item));
    }
    // 6. The echo of an outbox row, or this device's own send.
    final echo = await _echoOf(v, id, mid, item.ct);
    if (echo != null) {
      return end(
        row: StoredMessage(
          conversationId: id,
          messageId: mid,
          createdAtMicros: item.at,
          mine: true,
          state: StoredMessageState.visible,
          generation: echo.generation,
          epoch: echo.epoch,
          content: echo.content,
          senderDeviceId: pass.deviceId,
        ),
        deleteOutbox: echo.idempotencyKey,
      );
    }
    if (await v.hasSent(id, item.pair, sentDigest(item.ct))) {
      _remember(rowlessKey);
      return end();
    }
    // 7. The engine: only for a due item.
    if (!engine || !_retryDue(item, now)) return _Retry.kept;
    final deviceState = await v.deviceState();
    if (deviceState == null) return _Retry.kept;
    if (item.crashClass) _crashRetryUsed = true;
    final a = await _attempt(
      v,
      pass,
      id,
      group,
      deviceState,
      mid: mid,
      at: item.at,
      ciphertext: item.ct,
      commitment: item.rc,
      fromSelf: item.fs,
    );
    final code = a.code;
    if (code == null) {
      // A success, a definitive answer (a retry past the 50-back window
      // answers `badInput`) or a message handled without a row.
      final advanced = a.group;
      return end(
        row: a.row,
        group: advanced,
        epochMustAdvance: a.epochMustAdvance,
        record: advanced == null
            ? null
            : await _groupFailuresCleared(v, id, item.pair, null),
      );
    }
    Future<StoredMessage?> undecryptable() => _itemRow(v, id, cleared, item);
    if (code != MlsErrorCode.unavailable && _groupBroken(context, item.pair)) {
      return end(row: await undecryptable());
    }
    final fail = await _classify(code, group.state);
    switch (fail.kind) {
      case _FailKind.deviceDown:
        // No strike, no attempt counted.
        _holdEngine(context);
        return _Retry.stop;
      case _FailKind.breaker:
        _holdEngine(context, breaker: true);
        return _Retry.stop;
      case _FailKind.groupLevel:
        final next = await _groupFailure(v, id, item.pair);
        if (next.broken) {
          return end(row: await undecryptable(), record: next.record);
        }
        await v.transaction((tx) => _records.putIn(tx, id, next.record));
        context.serial++;
        _holdEngine(context);
        return _Retry.stop;
      case _FailKind.witnessed:
      case _FailKind.witnessedCrash:
        final crash = fail.kind == _FailKind.witnessedCrash;
        final k = item.k + 1;
        final cc = item.cc + (crash ? 1 : 0);
        if (k >= kDeferredStrikes || cc >= kDeferredCrashStrikes) {
          return end(row: await undecryptable());
        }
        await keep(item.copyWith(k: k, cc: cc, la: now, ru: _runId));
        return _Retry.kept;
      case _FailKind.unwitnessedCrash:
        await keep(item.copyWith(cu: item.cu + 1, la: now, ru: _runId));
        context.unwitnessed[mid] = fail.stamp;
        _holdEngine(context);
        return _Retry.stop;
    }
  });

  /// §7.2 at first sight: the engine answered [code] on a message never
  /// tried before, inside its write body. Returns the step: `wrote` when
  /// the message was deferred (or became a row) in ONE transaction through
  /// [write] and the walk goes on; `stop` when the pass stops (a hold is
  /// set; at most a durable counter was written, never the page's record).
  Future<_Step> _firstSightFailure(
    SecureVault v,
    String id,
    _Write write,
    GroupRecord group,
    MlsErrorCode code, {
    required String mid,
    required int at,
    required Uint8List ciphertext,
    required Uint8List commitment,
    required bool fromSelf,
    required void Function() onDeferred,
  }) async {
    final context = _contexts.of(id);
    final p = MlsPair(group.generation, group.epoch);
    StoredMessage undecryptable() => StoredMessage(
      conversationId: id,
      messageId: mid,
      createdAtMicros: at,
      mine: false,
      state: StoredMessageState.undecryptable,
      generation: p.generation,
      epoch: p.epoch,
      content: null,
    );
    if (code != MlsErrorCode.unavailable && _groupBroken(context, p)) {
      return write.commit(row: undecryptable());
    }
    final fail = await _classify(code, group.state);
    final now = _now().microsecondsSinceEpoch;
    DeferredItem item({int k = 0, int cc = 0, int cu = 0}) => DeferredItem(
      id: mid,
      pair: p,
      at: at,
      da: now,
      ct: ciphertext,
      // A commitment the record does not hold never matches a real one:
      // kept as empty (the same check result).
      rc: commitment.length <= kMaxDeferredCommitmentBytes
          ? commitment
          : Uint8List(0),
      fs: fromSelf,
      k: k,
      cc: cc,
      cu: cu,
      la: now,
      ru: _runId,
    );
    switch (fail.kind) {
      case _FailKind.deviceDown:
        _holdEngine(context);
        return _Step.stop;
      case _FailKind.breaker:
        _holdEngine(context, breaker: true);
        return _Step.stop;
      case _FailKind.groupLevel:
        final next = await _groupFailure(v, id, p);
        if (next.broken) {
          final riding = write.record;
          return write.commit(
            row: undecryptable(),
            recordOverride: (riding ?? next.record).copyWith(
              gf: next.record.gf,
            ),
          );
        }
        // Durable before the pass stops; the page's record is not written.
        await v.transaction((tx) => _records.putIn(tx, id, next.record));
        context.serial++;
        _holdEngine(context);
        return _Step.stop;
      case _FailKind.witnessed:
      case _FailKind.witnessedCrash:
        final crash = fail.kind == _FailKind.witnessedCrash;
        // At or before cleared_at: processed, never stored, never held.
        if (write.hidden) return write.commit();
        final d = await _readDeferred(v, id);
        final added = item(k: 1, cc: crash ? 1 : 0);
        context.deferredEmpty = false;
        if (!d.full) {
          _deferredTotal++;
          return write.commit(deferred: d.put(added));
        }
        // §7.6 end 3: overflow never stops a walk while the engine works.
        final victim = d.evictable();
        if (victim == null) {
          // None of the 16 is witnessed: this one alone is known to be
          // message-specific, so it is the row.
          return write.commit(row: undecryptable());
        }
        final row = await _itemRow(v, id, write.sync.clearedAtMicros, victim);
        _deferredTotal++;
        _evictedTotal++;
        return write.commit(
          deferred: d.without([victim.id]).put(added),
          rows: [?row],
        );
      case _FailKind.unwitnessedCrash:
        final d = await _readDeferred(v, id);
        if (!d.full && !write.hidden) {
          // Durable, so a restart never loops on it; then the pass stops.
          await v.transaction(
            (tx) => _deferred.putIn(tx, id, d.put(item(cu: 1))),
          );
          context
            ..deferredEmpty = false
            ..unwitnessed[mid] = fail.stamp;
          _deferredTotal++;
          onDeferred();
        }
        _holdEngine(context);
        return _Step.stop;
    }
  }
}
