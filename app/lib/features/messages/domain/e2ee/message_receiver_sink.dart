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
  /// [SyncBudget.tryTake]. Returns once the walk has ended (the final
  /// transaction of an orphan walk, or of a close walk of a generation below
  /// the current one, deletes its group; a walk met already at its end takes
  /// that step here, [_releaseEndedLocked]); otherwise throws [_WalkPending].
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
    // §7.3: an unreadable deferred record is replaced (and the walks reset)
    // before this walk reads it.
    if ((await _deferred.read(pass.vault, id)).unreadable) {
      await _repairDeferredLocked(pass, id);
    }
    final current = await _currentPair(pass.vault, id);
    // The pair the waiting commit is due at (the sink's own pair when the
    // group's is not known: never null, so the marker is never lost).
    _WalkPending pending() => _pending(context, current ?? pair);

    // 1-3: read fresh; ended; create or resume.
    final record = await _readReceive(pass.vault, id);
    // M4: a pair the close slot already walks (its walk began before the
    // generation moved) stays in the close slot: no second slot lists it.
    final slot =
        current != null &&
            pair.generation < current.generation &&
            record.close?.pair != pair
        ? _Slot.orphan
        : _Slot.close;
    final w = _slotOf(record, slot);
    if (w != null && w.pair == pair && w.end) {
      // Ended before the generation moved: its kept group goes now, before
      // the caller records the pair as walked (which ends the slot at its
      // next read, leaving the group to the next join).
      if (current != null &&
          pair.generation < current.generation &&
          !await _releaseEndedLocked(pass, id, slot)) {
        // A deferred message of the generation is owed its final attempt
        // (§7.6 end 1): not walked yet for the caller, or the next join
        // would delete the group without it.
        throw pending();
      }
      return;
    }
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
    if (w != null && w.pair != pair && !w.end) throw pending();
    final wantMode = slot == _Slot.close ? mode : null;
    if (w == null ||
        w.pair != pair ||
        (wantMode == WalkMode.undecryptable && w.mode != wantMode)) {
      if (!await _createSlotLocked(pass, id, slot, pair, wantMode)) {
        throw pending();
      }
    }

    // 3-5: at most kSinkPagesPerHold pages per hold, never waiting.
    while (true) {
      final hold = _locks.holdToken(id);
      if (hold == null) throw pending();
      final used = _sinkPagesByHold[hold] ?? 0;
      final fresh = _slotOf(await _readReceive(pass.vault, id), slot);
      if (fresh == null || fresh.pair != pair) {
        // The orphan's final transaction ran.
        if (slot == _Slot.orphan) return;
        throw pending();
      }
      if (fresh.end) return;
      final backoff = context.walkBackoffUntil;
      // An engine hold (the receiver-wide one, or this conversation's own)
      // keeps a walk that decrypts from listing; a `u` walk goes on.
      if ((backoff != null && _now().isBefore(backoff)) ||
          (_engineHoldOf(context) != null &&
              await _needsEngine(pass.vault, id, slot, fresh)) ||
          used >= kSinkPagesPerHold ||
          !_syncBudget.tryTake(priority)) {
        throw pending();
      }
      _sinkPagesByHold[hold] = used + 1;
      final seq = ++_seq;
      final listed = await _listOrdered(id, fresh);
      if (listed.outcome != null) {
        if (listed.outcome!.kind == ReceiveOutcomeKind.stopped) {
          _backOff(context);
        }
        throw pending();
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
          throw pending();
      }
    }
  }

  /// The walk is left pending: the commit waits at [at], so the end of a
  /// later pass runs a catch-up once no walk of the current pair is left
  /// (also when the walk that blocked is an older pair's, whose end does not
  /// clear it). The marker keeps the higher of its pair and [at].
  _WalkPending _pending(ConversationContext context, MlsPair at) {
    final due = context.catchUpDueAt;
    if (due == null || at.compareTo(due) > 0) context.catchUpDueAt = at;
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
