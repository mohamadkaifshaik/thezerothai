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
    final ranked = await _byRecentActivity(vault);
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
    final now = _now();
    _removed
      ..removeWhere(
        (m) => m.deviceId == deviceId || _older(m, now, kRemovedByUserLimit),
      )
      ..add(
        RemovalMark(
          deviceId: deviceId,
          atMicros: now.microsecondsSinceEpoch,
          signatureKey: signatureKey,
        ),
      );
    while (_removed.length > kMaxRemovalIntents) {
      _removed.removeAt(0);
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
  /// CR Minor 2 (fix round 2, ruling 4): a definite refusal drops the
  /// intent, as [removeDevice] does. A RATE_LIMITED answer keeps it and
  /// holds every intent until the server's retry time (the fallback minute
  /// when it named none, capped at [kMaxServerRetryWait]; memory only), on
  /// the runner's one timer; the queue's own pass goes on meanwhile.
  Future<void> _runIntents(SecureVault vault, BudgetPriority priority) async {
    final now = _now();
    final before = _intents.length;
    _intents.removeWhere((i) => _older(i, now, kRemovalIntentLimit));
    if (_intents.length != before) await _save(vault, queue: false);
    final held = _intentsNotBefore;
    if (held != null) {
      if (now.isBefore(held)) {
        if (_intents.isNotEmpty) _armTimer(held);
        return;
      }
      _intentsNotBefore = null;
    }
    for (final intent in List.of(_intents)) {
      if (_sending.contains(intent.deviceId)) continue;
      if (!identical(_session.vault, vault) || !_loaded) return;
      try {
        await _sendRemove(intent.deviceId);
      } on RateLimitedException catch (e) {
        if (!identical(_loadedFor, vault)) return;
        final at = _now().add(_retryWait(e));
        _intentsNotBefore = at;
        _armTimer(at);
        return;
      } on Object catch (e, s) {
        if (_definiteRefusal(e) && identical(_loadedFor, vault)) {
          _intents.removeWhere((i) => i.deviceId == intent.deviceId);
          try {
            await _save(vault, queue: false);
          } on Object catch (e, s) {
            _reportIfBug(e, s, 'removalQueue.intentWrite');
          }
        } else {
          _reportIfBug(e, s, 'removalQueue.intent');
        }
        continue;
      }
      if (!identical(_session.vault, vault) || !_loaded) return;
      await _queueRemoved(
        vault,
        intent.deviceId,
        intent.signatureKey,
        priority,
      );
    }
  }

  /// Loads the stored queue and the runner's record for [vault] when this
  /// image is not of it. False: either cannot be read (amendment 7:
  /// unknown, nothing changes; the stored values are left as they are) or
  /// the vault changed meanwhile.
  Future<bool> _ensureLoaded(SecureVault vault) async {
    if (identical(_loadedFor, vault)) return true;
    try {
      final raw = await vault.setting(kVaultSettingRemovalQueue);
      final queue = raw == null
          ? const RemovalQueue()
          : RemovalQueue.decode(raw);
      final rawRecord = await vault.setting(kVaultSettingRemovalRecord);
      final record = rawRecord == null
          ? const RemovalRecord()
          : RemovalRecord.decode(rawRecord);
      if (!identical(_session.vault, vault)) return false;
      if (identical(_loadedFor, vault)) return true;
      _entries
        ..clear()
        ..addAll(queue.entries);
      _intents
        ..clear()
        ..addAll(record.intents);
      _removed
        ..clear()
        ..addAll(record.removed);
      _notBeforeMicros = queue.notBeforeMicros;
      _loadedFor = vault;
      _unreadableFor = null;
      _lastKept.clear();
      _publish();
      return true;
    } on VaultCorruptException {
      if (!identical(_unreadableFor, vault)) {
        _unreadableFor = vault;
        _reportBug('removalQueue.read');
      }
      _loadedFor = null;
      _entries.clear();
      _intents.clear();
      _removed.clear();
      _publish();
      return false;
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
