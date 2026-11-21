part of 'message_receiver.dart';

/// The sink left its walk unfinished (no budget unit now, the page cap of
/// this hold, a failed or refused call, a page out of order): catch-up ends
/// `interrupted`, the commit waits, and the next pass continues the walk
/// without the lock. Carries nothing.
class _WalkPending implements Exception {
  const _WalkPending();
}

extension _Sink on MessageReceiver {
  /// §5.1 "the sink": with [id]'s lock held, the close walk of [pair] (the
  /// orphan walk for a pair below the current generation) is created or
  /// resumed and listed at most [kSinkPagesPerHold] pages per lock hold with
  /// [SyncBudget.tryTake]. Returns once the walk has ended (an orphan's
  /// final transaction deletes its group); otherwise throws [_WalkPending].
  Future<void> _sinkWalk(
    String id,
    MlsPair pair,
    BudgetPriority priority,
    WalkMode mode,
  ) async {
    assert(_locks.isHeld(id), 'The caller must hold the conversation lock.');
    // No member can have sent in epoch 0 (the contract lists pairs >= 1).
    if (pair.generation < 1 || pair.epoch < 1) return;
    final pass = await _start();
    if (pass == null) throw const _Stopped();
    final context = _contexts.of(id);
    final current = await _currentPair(pass.vault, id);
    final slot = current != null && pair.generation < current.generation
        ? _Slot.orphan
        : _Slot.close;

    // 1-3: read fresh; ended; create or resume.
    final record = await _readReceive(pass.vault, id);
    final w = _slotOf(record, slot);
    if (w != null && w.pair == pair && w.end) return;
    if (slot == _Slot.orphan &&
        (w == null || w.pair != pair) &&
        (await pass.vault.group(id, pair.generation) == null ||
            ((await pass.vault.conversation(id))?.sync.completedEpochs ??
                    const <MlsPair>[])
                .contains(pair))) {
      // Its final transaction ran (the group is deleted) or it is done.
      return;
    }
    // One slot per kind: an unfinished walk of another pair (a `u` walk
    // whose group is gone, or a kept generation's) is finished first, by
    // the passes; it is never replaced and its unlisted rest never dropped.
    if (w != null && w.pair != pair && !w.end) throw _pending(context);
    final wantMode = slot == _Slot.close ? mode : null;
    if (w == null ||
        w.pair != pair ||
        (wantMode == WalkMode.undecryptable && w.mode != wantMode)) {
      if (!await _createSlotLocked(pass, id, slot, pair, wantMode)) {
        throw _pending(context);
      }
    }

    // 3-5: at most kSinkPagesPerHold pages per hold, never waiting.
    while (true) {
      final hold = _locks.holdToken(id);
      if (hold == null) throw _pending(context);
      final used = _sinkPagesByHold[hold] ?? 0;
      final fresh = _slotOf(await _readReceive(pass.vault, id), slot);
      if (fresh == null || fresh.pair != pair) {
        // The orphan's final transaction ran.
        if (slot == _Slot.orphan) return;
        throw _pending(context);
      }
      if (fresh.end) return;
      final backoff = context.walkBackoffUntil;
      if ((backoff != null && _now().isBefore(backoff)) ||
          used >= kSinkPagesPerHold ||
          !_syncBudget.tryTake(priority)) {
        throw _pending(context);
      }
      _sinkPagesByHold[hold] = used + 1;
      final seq = ++_seq;
      final listed = await _listOrdered(id, fresh);
      if (listed.outcome != null) {
        if (listed.outcome!.kind == ReceiveOutcomeKind.stopped) {
          _backOff(context);
        }
        throw _pending(context);
      }
      final _StepEnd step;
      if (listed.page == null) {
        step = await _restartLocked(pass, id, slot, fresh);
      } else {
        step = await _applyPageLocked(
          pass,
          id,
          slot,
          fresh,
          listed.page!,
          listSeq: seq,
        );
      }
      switch (step.kind) {
        case _StepKind.applied:
          if (step.ended) return;
        case _StepKind.restarted:
          break;
        case _StepKind.stale:
        case _StepKind.stop:
          throw _pending(context);
      }
    }
  }

  _WalkPending _pending(ConversationContext context) {
    context.epochWalkPending = true;
    return const _WalkPending();
  }

  /// Creates [slot] for [pair] in its own transaction (§5.2): `open` is
  /// adopted when it is for [pair] (a new listing from its settle token;
  /// `open` becomes null), otherwise a walk from the start. False (nothing
  /// written): the slot holds an unfinished walk of another pair.
  Future<bool> _createSlotLocked(
    _Pass pass,
    String id,
    _Slot slot,
    MlsPair pair,
    WalkMode? mode,
  ) async {
    final created = await _session.runWrite((v) async {
      pass.check(v);
      final record = await _readReceive(v, id);
      final existing = _slotOf(record, slot);
      if (existing != null && existing.pair != pair && !existing.end) {
        return false;
      }
      final ReceiveRecord next;
      if (existing != null && existing.pair == pair) {
        // Only the mode changes (a close marked undecryptable).
        next = _withSlot(record, slot, existing.copyWith(mode: mode));
      } else if (record.open != null && record.open!.pair == pair) {
        next = _withSlot(
          record.copyWith(open: null),
          slot,
          record.open!.adopted(mode),
        );
      } else {
        next = _withSlot(record, slot, WalkEntry(pair: pair, mode: mode));
      }
      await v.transaction((tx) => _records.putIn(tx, id, next));
      return true;
    });
    if (created) _contexts.of(id).serial++;
    return created;
  }
}
