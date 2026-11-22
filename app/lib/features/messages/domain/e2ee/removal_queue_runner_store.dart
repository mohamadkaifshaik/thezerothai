part of 'removal_queue_runner.dart';

/// The removal queue's storage and its intents (review M1, M2, concern 1):
/// loading and writing the stored queue and the runner's own record,
/// sending RemoveKeyDevice, and turning a removed device into queue
/// entries.
extension _RemovalStore on RemovalQueueRunner {
  /// One `RemoveKeyDevice` with a fresh key, bounded by [kMlsRpcTimeout].
  Future<void> _sendRemove(String deviceId) async {
    final key = hexOf(await randomOf(_engine(), 16));
    await _keys
        .removeDevice(deviceId: deviceId, idempotencyKey: key)
        .timeout(
          kMlsRpcTimeout,
          onTimeout: () => throw const NetworkException('timed out'),
        );
  }

  /// [deviceId] was removed from the directory: it is queued for every
  /// conversation with group state, most recently active first, it is
  /// remembered as removed by the user (concern 1), and its intent goes,
  /// in one write.
  Future<void> _queueRemoved(
    SecureVault vault,
    String deviceId,
    Uint8List? signatureKey,
    BudgetPriority priority,
  ) async {
    final id = Uint8List.fromList(utf8.encode(deviceId));
    // Fix round 5, ruling 2 (R1): RemoveKeyDevice of it succeeded by now.
    _lastRemovedAt = _now();
    final ranked = await _byRecentActivity(vault);
    // SA N1 (fix round 4, ruling 10): the ids pinned anywhere, read only
    // when the marks are at their cap (to find one that carries no weight).
    final now = _now();
    final atCap =
        _removed
            .where(
              (m) =>
                  m.deviceId != deviceId &&
                  !_older(m, now, kRemovedByUserLimit),
            )
            .length >=
        kMaxRemovalIntents;
    final pinned = <Uint8List>[];
    if (atCap) {
      for (final c in ranked) {
        for (final m in await vault.members(c)) {
          pinned.add(m.deviceId);
        }
      }
    }
    if (!identical(_session.vault, vault) || !_loaded) {
      throw StateError('The vault changed.');
    }
    for (final c in ranked) {
      final already = _entries.any(
        (e) => e.conversationId == c && _same(e.deviceId, id),
      );
      if (already) continue;
      _entries.add(RemovalQueueEntry(deviceId: id, conversationId: c));
    }
    _removed.removeWhere(
      (m) => m.deviceId == deviceId || _older(m, now, kRemovedByUserLimit),
    );
    // SA N1 (fix round 4, ruling 10): the mark cap never refuses a
    // removal (20 junk devices a stolen session registered must not keep
    // the real lost device in). At the cap the oldest mark that carries no
    // weight goes: no queue entry and no pin anywhere names its device.
    // When every mark is still needed, the device is queued without one
    // (`removalQueue.markCap`): its removal still reaches every group, but
    // [wasRemovedByUser] does not answer for it.
    if (_removed.length >= kMaxRemovalIntents) {
      final byAge = List.of(_removed)
        ..sort((a, b) => a.atMicros.compareTo(b.atMicros));
      for (final m in byAge) {
        final d = utf8.encode(m.deviceId);
        if (_entries.any((e) => _same(e.deviceId, d))) continue;
        if (pinned.any((p) => _same(p, d))) continue;
        _removed.remove(m);
        break;
      }
    }
    if (_removed.length < kMaxRemovalIntents) {
      _removed.add(
        RemovalMark(
          deviceId: deviceId,
          atMicros: now.microsecondsSinceEpoch,
          signatureKey: signatureKey,
        ),
      );
    } else {
      _reportBug('removalQueue.markCap');
    }
    _intents.removeWhere((i) => i.deviceId == deviceId);
    await _save(vault);
    // Review M2: the reused own list (up to 30 minutes) still names the
    // device; read it fresh, so reconcile does not try to add it back. A
    // paused budget keeps the old list (stated limit: the add then fails
    // at its claim, which finds no key package).
    await _directory.own(fresh: true, priority: priority);
  }

  /// Review M1: every intent left from a call whose outcome is unknown is
  /// sent again (RemoveKeyDevice of a removed device answers success), then
  /// queued. An unknown outcome keeps it for the next pass; one older than
  /// [kRemovalIntentLimit] is dropped. An intent [removeDevice] is sending
  /// is left to it.
  ///
  /// CR Minor 2 (fix round 2, ruling 4, changed by fix round 4, ruling 2):
  /// a definite refusal is settled by a fresh own list
  /// ([_settleRefusedRetry]). A RATE_LIMITED answer keeps it and
  /// holds every intent until the server's retry time (the fallback minute
  /// when it named none, capped at [kMaxServerRetryWait]; memory only), on
  /// the runner's one timer; the queue's own pass goes on meanwhile.
  Future<void> _runIntents(
    SecureVault vault,
    BudgetPriority priority,
    int resets,
  ) async {
    final now = _now();
    final before = _intents.length;
    _intents.removeWhere((i) => _older(i, now, kRemovalIntentLimit));
    if (_intents.length != before) await _save(vault, queue: false);
    final held = _intentsNotBefore;
    if (held != null) {
      if (now.isBefore(held)) {
        if (_intents.isNotEmpty) _armTimer(held, resets);
        return;
      }
      _intentsNotBefore = null;
    }
    for (final intent in List.of(_intents)) {
      if (_sending.contains(intent.deviceId)) continue;
      if (!_current(vault, resets)) return;
      try {
        await _sendRemove(intent.deviceId);
      } on RateLimitedException catch (e) {
        // Ruling 7: nothing is held or armed after a reset().
        if (!_current(vault, resets)) return;
        final at = _now().add(_retryWait(e));
        _intentsNotBefore = at;
        _armTimer(at, resets);
        return;
      } on Object catch (e, s) {
        if (_definiteRefusal(e) && _current(vault, resets)) {
          await _settleRefusedRetry(vault, intent, priority, resets);
        } else {
          _reportIfBug(e, s, 'removalQueue.intent');
        }
        continue;
      }
      if (!_current(vault, resets)) return;
      await _queueRemoved(
        vault,
        intent.deviceId,
        intent.signatureKey,
        priority,
      );
    }
  }

  /// Fix round 4, ruling 2 (CR2 I-2; it changes fix round 2's ruling 4):
  /// the RemoveKeyDevice retry of the stored [intent] met a definite
  /// refusal. That refusal proves nothing about the first call: the server
  /// may already have removed the device (an answer lost on the way). So a
  /// fresh own list decides:
  /// - it still names the id: not removed, the intent goes;
  /// - it is readable, non-empty and does not name the id: removed, so the
  ///   device is queued with the intent's key ([_queueRemoved], which also
  ///   drops the intent);
  /// - it cannot be read (or is empty, which no list of this user can
  ///   honestly be: this device is in it): the intent stays for the next
  ///   pass.
  /// True when the device was queued. A failed intent write is reported if
  /// it is a bug; the intent then stays. [resets]: the run the caller
  /// started in (fix round 5, ruling 3: nothing is decided for a queue a
  /// reset() and a reload replaced meanwhile).
  Future<bool> _settleRefusedRetry(
    SecureVault vault,
    RemovalMark intent,
    BudgetPriority priority,
    int resets,
  ) async {
    final own = await _directory.own(fresh: true, priority: priority);
    if (!_current(vault, resets)) return false;
    if (!own.readableNonEmpty) return false;
    final id = utf8.encode(intent.deviceId);
    if (own.devices.any((d) => _same(d.deviceId, id))) {
      _intents.removeWhere((i) => i.deviceId == intent.deviceId);
      try {
        await _save(vault, queue: false);
      } on Object catch (e, s) {
        _reportIfBug(e, s, 'removalQueue.intentWrite');
      }
      return false;
    }
    await _queueRemoved(vault, intent.deviceId, intent.signatureKey, priority);
    return true;
  }

  /// SA M2 (fix round 2, ruling 11): on every own device, each `mine` pin
  /// (never this device) that a fresh own list does not show is queued, in
  /// every conversation with group state, most recently active first: the
  /// M3 condition ([mayRemoveOwnDevice]; a list that is not readable and
  /// non-empty queues nothing). This covers a removal made on another own
  /// device, where [removeDevice] never ran here, so a conversation that is
  /// never opened does not keep the lost device with no time limit. Such an
  /// entry is not user-queued: it has no removed mark, so it has no pause
  /// exemption and [wasRemovedByUser] does not answer from it. The own list
  /// is read only when such a pin exists.
  ///
  /// Fix round 3 (the ruling 1 gap, option B): each `unattributed` pin
  /// whose unexpired removed mark carries the pin's key (the match rule of
  /// round 2's ruling 1) is queued too, with no list read. A prune on pins
  /// at the last listed pair may have dropped its entry before a peer's add
  /// of the device landed; this queues it again once the add is applied.
  /// A mark whose key differs is not queued and is reported
  /// (`removalQueue.keyMismatch`, once per conversation and run).
  ///
  /// Answers the own list it read (fix round 4, ruling 3: the pass's
  /// attempts drop an unmarked entry whose device it names), or null.
  Future<DeviceList?> _queueLostOwn(
    SecureVault vault,
    Uint8List thisDevice,
    BudgetPriority priority,
    int resets,
  ) async {
    final pins = <String, List<MemberRecord>>{};
    final marked = <String, List<MemberRecord>>{};
    for (final c in await vault.groupConversationIds()) {
      final mine = <MemberRecord>[];
      final ours = <MemberRecord>[];
      for (final m in await vault.members(c)) {
        if (_same(m.deviceId, thisDevice)) continue;
        if (m.side == MemberSide.mine) {
          mine.add(m);
        } else if (m.side == MemberSide.unattributed) {
          final key = _removedKeyOf(m.deviceId);
          if (key == null) continue;
          if (!_same(key, m.signatureKey)) {
            if (_mismatchReported.add(c)) {
              _reportBug('removalQueue.keyMismatch');
            }
            continue;
          }
          ours.add(m);
        }
      }
      if (mine.isNotEmpty) pins[c] = mine;
      if (ours.isNotEmpty) marked[c] = ours;
    }
    if ((pins.isEmpty && marked.isEmpty) || !_current(vault, resets)) {
      return null;
    }
    // Fix round 4, ruling 6 (CR2 M-4): an own list younger than
    // [kLostOwnListReuse] is reused (no call); otherwise one fresh read.
    // It is read whenever a `mine` pin exists, queued or not: the attempts
    // drop an unmarked entry whose device it names (ruling 3).
    // Fix round 5, ruling 2 (R1): a young list fetched before the last
    // removal is not reused (it may still name the removed device).
    final young = _directory.ownYoungerThan(kLostOwnListReuse);
    final own = pins.isEmpty
        ? null
        : young != null && !_beforeLastRemoval(young)
        ? young
        : await _directory.own(fresh: true, priority: priority);
    if (!_current(vault, resets)) return own;
    bool queuedIn(String c, Uint8List d) =>
        _entries.any((e) => e.conversationId == c && _same(e.deviceId, d));
    // The candidates first; the ranking (a sealed read per conversation)
    // only when one of them is not queued yet.
    final add = <String, List<Uint8List>>{};
    void candidate(String c, Uint8List d) {
      if (!queuedIn(c, d)) (add[c] ??= []).add(d);
    }

    for (final MapEntry(key: c, value: ms) in marked.entries) {
      for (final m in ms) {
        candidate(c, m.deviceId);
      }
    }
    if (own != null && own.readableNonEmpty) {
      for (final MapEntry(key: c, value: ms) in pins.entries) {
        for (final m in ms) {
          if (mayRemoveOwnDevice(
            member: m,
            ownList: own,
            thisDeviceId: thisDevice,
          )) {
            candidate(c, m.deviceId);
          }
        }
      }
    }
    if (add.isEmpty) return own;
    final ranked = await _byRecentActivity(vault);
    if (!_current(vault, resets)) return own;
    var changed = false;
    for (final c in ranked) {
      for (final d in add[c] ?? const <Uint8List>[]) {
        if (queuedIn(c, d)) continue;
        _entries.add(RemovalQueueEntry(deviceId: d, conversationId: c));
        changed = true;
      }
    }
    if (changed) await _save(vault);
    return own;
  }

  /// Loads the stored queue and the runner's record for [vault] when this
  /// image is not of it. False: either cannot be read (amendment 7:
  /// unknown, nothing changes; the stored values are left as they are) or
  /// the vault changed meanwhile.
  ///
  /// SA N3 (fix round 4, ruling 12): the queue and the record are read and
  /// decoded each on its own. When one cannot be read, the other's values
  /// are still put in the image (unused while nothing is loaded: every
  /// reader checks `_loaded`), so a rebuild ([removeDevice]) replaces only
  /// the value that cannot be read and keeps the one that can.
  Future<bool> _ensureLoaded(SecureVault vault) async {
    if (identical(_loadedFor, vault)) return true;
    try {
      Future<T?> readOne<T>(
        String key,
        T empty,
        T Function(Uint8List) decode,
      ) async {
        try {
          final raw = await vault.setting(key);
          return raw == null ? empty : decode(raw);
        } on VaultCorruptException {
          return null;
        }
      }

      final queue = await readOne(
        kVaultSettingRemovalQueue,
        const RemovalQueue(),
        RemovalQueue.decode,
      );
      final record = await readOne(
        kVaultSettingRemovalRecord,
        const RemovalRecord(),
        RemovalRecord.decode,
      );
      if (!identical(_session.vault, vault)) return false;
      if (identical(_loadedFor, vault)) return true;
      _entries
        ..clear()
        ..addAll(queue?.entries ?? const []);
      _notBeforeMicros = queue?.notBeforeMicros;
      _intents
        ..clear()
        ..addAll(record?.intents ?? const []);
      // SA L4 (ruling 6): expired marks go on load; the next pass writes it.
      final now = _now();
      final live = [
        for (final m in record?.removed ?? const <RemovalMark>[])
          if (!_older(m, now, kRemovedByUserLimit)) m,
      ];
      _recordPruned = record != null && live.length != record.removed.length;
      _removed
        ..clear()
        ..addAll(live);
      _queueUnreadable = queue == null;
      _recordUnreadable = record == null;
      if (queue == null || record == null) {
        if (!identical(_unreadableFor, vault)) {
          _unreadableFor = vault;
          _reportBug('removalQueue.read');
        }
        _loadedFor = null;
        _publish();
        return false;
      }
      _loadedFor = vault;
      _unreadableFor = null;
      _publish();
      return true;
    } on Object catch (e, s) {
      _reportIfBug(e, s, 'removalQueue.load');
      return false;
    }
  }

  /// Writes the image to [vault] in one transaction: the runner's record,
  /// and the queue unless [queue] is false (an intent change only). The
  /// image stays as it is when the write fails (a removal is kept rather
  /// than lost; the next change writes it again).
  Future<void> _save(SecureVault vault, {bool queue = true}) async {
    _publish();
    final image = queue
        ? RemovalQueue(
            entries: List.of(_entries),
            notBeforeMicros: _notBeforeMicros,
          ).encode()
        : null;
    final record = RemovalRecord(
      intents: List.of(_intents),
      removed: List.of(_removed),
    ).encode();
    await _session.runWrite((v) async {
      if (!identical(v, vault) || !identical(_loadedFor, vault)) {
        throw StateError('The vault changed.');
      }
      await v.transaction((tx) async {
        if (image != null) {
          await tx.putSetting(kVaultSettingRemovalQueue, image);
        }
        await tx.putSetting(kVaultSettingRemovalRecord, record);
      });
    });
  }

  /// Fix round 5, ruling 2 (R1): [list] was fetched before the last
  /// successful RemoveKeyDevice of this run ([_lastRemovedAt]), so it may
  /// still name the device removed then.
  bool _beforeLastRemoval(DeviceList list) {
    final last = _lastRemovedAt;
    if (last == null) return false;
    final at = list.fetchedAt;
    return at == null || at.isBefore(last);
  }

  void _publish() {
    final ids = <String>{for (final e in _entries) e.conversationId};
    _pending.value = _loaded ? ids.length : 0;
  }
}

/// An answer that says RemoveKeyDevice was not carried out. A network
/// failure, a timeout, an unknown server error and anything that is not an
/// [AppException] leave the outcome unknown.
bool _definiteRefusal(Object e) =>
    e is AppException && e is! NetworkException && e is! UnknownApiException;

/// How long a RATE_LIMITED answer holds: the server's retry time, else
/// [kDeviceKeysRateLimitFallback] (Open question 7), capped at
/// [kMaxServerRetryWait] (24 h, security read L1).
Duration _retryWait(RateLimitedException limit) {
  var wait = limit.retryAfter;
  if (wait == null || wait <= Duration.zero) {
    wait = kDeviceKeysRateLimitFallback;
  }
  return wait > kMaxServerRetryWait ? kMaxServerRetryWait : wait;
}

bool _older(RemovalMark m, DateTime now, Duration limit) =>
    now.microsecondsSinceEpoch - m.atMicros > limit.inMicroseconds;
