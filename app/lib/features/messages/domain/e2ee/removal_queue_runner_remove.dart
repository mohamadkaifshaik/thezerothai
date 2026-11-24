part of 'removal_queue_runner.dart';

/// The body of [RemovalQueueRunner.removeDevice] (its contract is written
/// there), moved here unchanged from `removal_queue_runner.dart` (a pure
/// move, port-additions review: the file was past the 900-line split
/// point). The public entry and its `_removing` map stay in the class.
extension _Remove on RemovalQueueRunner {
  Future<bool?> _removeDevice(String deviceId) async {
    // Fix wave 2 (SA M2): a device the account removed elsewhere removes no
    // other device: no own-list read, no RemoveKeyDevice, no intent stored
    // (a stored one would go out once the fact clears).
    if (_removedDefinitely()) {
      throw StateError('This device was removed elsewhere.');
    }
    if (deviceId.isEmpty) throw ArgumentError.value('', 'deviceId');
    final id = Uint8List.fromList(utf8.encode(deviceId));
    final vault = _session.vault;
    if (vault == null) throw StateError('The vault is not ready.');
    // Fix round 5, ruling 3: the run this call started in.
    final resets = _resets;
    final own = await vault.deviceId();
    if (own == null) throw StateError('This device has no id yet.');
    if (_same(own, id)) {
      throw ArgumentError('This device is removed by signing out.');
    }
    // CR Minor 8 and SA M1 (fix round 2, ruling 10): a stored queue or
    // record that cannot be read must not keep a lost device in: failing
    // closed here would keep the attacker in. With the fresh own-list check
    // below, RemoveKeyDevice is still sent; nothing is written before it
    // (the unreadable values stay as they are if it fails), and on success
    // the unreadable value is rebuilt fresh (an empty queue plus this
    // device's entries, or an empty record plus its mark), written over it
    // (`removalQueue.rebuilt`); a readable one keeps its values (ruling 12).
    // Reconcile's M3 rule still removes the device wherever a readable own
    // list no longer shows it.
    final rebuild = !await _ensureLoaded(vault) && unreadable;
    if (!rebuild && !_loaded) {
      throw StateError('The removal queue cannot be read.');
    }
    // CR Minor 1 (fix round 2, ruling 3): a stored intent for the id is a
    // removal the user already asked for whose outcome is unknown. The
    // server may have carried it out, so the own list may no longer name
    // the device: the own-list check was made when the intent was stored,
    // and this call finishes it (RemoveKeyDevice again, then queue).
    final waiting = _intents.where((i) => i.deviceId == deviceId).firstOrNull;
    final Uint8List? key;
    if (waiting != null) {
      key = waiting.signatureKey;
    } else {
      // CR Minor 4 and SA L1 (fix round 2, ruling 6): at the intent cap
      // the new removal is refused, before anything is sent; no intent is
      // dropped to make room (a hostile own list must not push out the
      // user's real removals). Expired marks go first. SA N1 (fix round 4,
      // ruling 10): the removed-mark cap never refuses; [_queueRemoved]
      // makes room or queues the device without a mark.
      final now = _now();
      _removed.removeWhere((m) => _older(m, now, kRemovedByUserLimit));
      if (_intents.length >= kMaxRemovalIntents) {
        _reportBug('removalQueue.intentCap');
        throw StateError('Too many device removals are stored.');
      }
      // Review I1: only this user's own devices. RemoveKeyDevice of an id
      // the caller does not own answers success too (the server deletes
      // under the caller's uid only), so the call proves nothing: a fresh
      // own list decides, before anything is sent. A failed read rethrows.
      final mine = await _keys.listMine().timeout(
        kMlsRpcTimeout,
        onTimeout: () => throw const NetworkException('timed out'),
      );
      final listed = mine.devices.where((d) => d.deviceId == deviceId);
      if (listed.isEmpty) {
        throw ArgumentError('Not one of this user\'s devices.');
      }
      // Ruling 1 (fix round 2): the key the own list shows now, kept with
      // the intent and then the removed mark.
      key = Uint8List.fromList(listed.first.signaturePublicKey);
    }
    if (!identical(_session.vault, vault) || (!rebuild && !_loaded)) {
      throw StateError('The vault changed.');
    }
    // CR Minor 3 (fix round 2, ruling 5): marked as being sent BEFORE the
    // intent's write, and until it is queued, so a pass that starts while
    // either is in flight never sends the same intent a second time.
    _sending.add(deviceId);
    bool? ended;
    try {
      if (waiting == null && !rebuild) {
        // Review M1: the intent is stored BEFORE the call, so a crash or a
        // vault change between the call and the queue's write leaves it,
        // and the next pass sends it again and queues. (Not while
        // rebuilding: that write would replace the unreadable values before
        // the call succeeded.)
        _intents.add(
          RemovalMark(
            deviceId: deviceId,
            atMicros: _now().microsecondsSinceEpoch,
            signatureKey: key,
          ),
        );
        await _save(vault, queue: false);
      }
      Object? failure;
      StackTrace? failureStack;
      try {
        ended = await _sendRemove(deviceId);
      } on Object catch (e, s) {
        failure = e;
        failureStack = s;
      }
      if (failure != null) {
        if (failure is ReauthRequiredException) {
          // Brief amendment 3: parked, never dropped (the intent stored
          // above stays, now marked so: fix wave 9). Fix round 1, M3: a
          // rebuild stored no intent, but the ask is raised all the same;
          // the user's next call for the id sends it and clears it.
          if (rebuild) {
            _parkRebuild(deviceId);
          } else {
            await _parkStored(vault, deviceId);
          }
          Error.throwWithStackTrace(failure, failureStack!);
        }
        var settled = false;
        if (_definiteRefusal(failure) && identical(_loadedFor, vault)) {
          if (waiting == null) {
            // A new removal: not removed, the intent goes. When this write
            // fails the intent stays and a pass sends it again; that is the
            // user's own ask.
            _intents.removeWhere((i) => i.deviceId == deviceId);
            try {
              await _save(vault, queue: false);
            } on Object catch (e, s) {
              _reportIfBug(e, s, 'removalQueue.intentWrite');
            }
          } else {
            // Fix round 4, ruling 2: the retry of a stored intent proves
            // nothing about the first call; a fresh own list decides.
            settled = await _settleRefusedRetry(
              vault,
              waiting,
              BudgetPriority.live,
              resets,
            );
          }
        }
        if (!settled) Error.throwWithStackTrace(failure, failureStack!);
        // Removed by the first call, and queued: the user's ask is done.
        // No answer of this call says whether other sessions ended.
        _startPass(BudgetPriority.live);
        return null;
      }
      _unparkReauth(deviceId);
      if (!identical(_session.vault, vault)) {
        throw StateError('The vault changed.');
      }
      if (rebuild && !_loaded) {
        // SA N3 (fix round 4, ruling 12): only the value that cannot be
        // read is rebuilt; the readable one, loaded into the image, stays.
        if (_queueUnreadable) {
          _entries.clear();
          _notBeforeMicros = null;
        }
        if (_recordUnreadable) {
          _intents.clear();
          _removed.clear();
          _recordPruned = false;
        }
        _holds.clear();
        _intentsNotBefore = null;
        _loadedFor = vault;
        _unreadableFor = null;
        _reportBug('removalQueue.rebuilt');
      }
      if (!_loaded) throw StateError('The vault changed.');
      await _queueRemoved(vault, deviceId, key, BudgetPriority.live);
    } finally {
      _sending.remove(deviceId);
    }
    _startPass(BudgetPriority.live);
    return ended;
  }
}
