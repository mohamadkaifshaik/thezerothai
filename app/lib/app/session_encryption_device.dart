import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../core/storage/app_database.dart';
import '../core/vault/vault_session.dart';
import '../core/vault/vault_status.dart';
import '../features/keys/domain/device_keys_service.dart';
import '../features/messages/domain/e2ee/encryption_device.dart';

/// The cache-database device setting that remembers since when the vault has
/// been `unavailable` (second re-read R4). One key in the existing key-value
/// table: no vault read, no schema change. The `account:` prefix makes the
/// sign-out cache wipe (`AppDatabase.clearAll`) remove it with the account.
/// The value is `<launchId>|<atMicros>` and names no user.
const String kUnavailableSinceKey = 'account:e2ee_unavailable_since';

/// Plan 5b Task 14: the production [EncryptionDevice] over the foundations
/// objects. It forwards every fact and adds one of its own: [unavailableLong]
/// (R4, owner approved 2026-11-20).
///
/// [unavailableLong] rule: on each vault status, `unavailable` with no stored
/// value writes `<launchId>|<atMicros>`; `unavailable` with a value from
/// ANOTHER launch at least [kUnavailableNamesSignOutAfter] earlier sets it;
/// only `ready` deletes the key and clears it (the launch's first statuses are
/// `off`, then `opening`: clearing on any other status would restart the 24 h
/// at every launch). A failed read or write leaves it false (the short text,
/// which is today's), is reported as a fixed `StateError` and never blocks or
/// wipes anything. Stated limit: where the cache does not persist (in memory,
/// or a web storage the vault does not accept) it can never become true.
///
/// `vaultKnown` (plan checklist, PR 1 review): there is no listenable for it
/// (it lives in `core/vault`, which this change does not touch). It changes
/// together with a status change on every path but one (the sign-in marker
/// re-read failing into a status that may already be `unavailable`); there,
/// with the flag off, the access builder can show `hidden` instead of
/// `manage` until the next status change.
///
/// What this accepts, and what it does not. Accepted: only what is SHOWN can
/// lag (a screen drawing `hidden` for a moment, a Settings row missing); the
/// next status change (a retry, a resume, a sign-in) corrects it. NOT covered
/// by this acceptance: sends. A send never depends on `hidden`: the composer,
/// the draft and the share always go through the provided port, which fails
/// closed for a conversation that is encrypted (fix round A). The limit is
/// theirs to keep, not this comment's.
///
/// Never references `resetByUser`, `onSessionEnded` or `noteAccountDeleted`.
class SessionEncryptionDevice implements EncryptionDevice {
  SessionEncryptionDevice({
    required VaultSession session,
    required ValueListenable<DeviceKeysStatus> deviceKeys,
    required ValueListenable<bool> engineUnavailable,
    AppDatabase? database,
    DateTime Function()? now,
    String? launchId,
    void Function(Object error, StackTrace stack)? onUnexpectedError,
  }) : _session = session,
       _deviceKeys = deviceKeys,
       _engineUnavailable = engineUnavailable,
       _database = database,
       _now = now ?? DateTime.now,
       _launchId = launchId ?? _randomLaunchId(),
       _onUnexpectedError = onUnexpectedError {
    _session.status.addListener(_statusChanged);
    // The status may already be unavailable when this is built.
    _statusChanged();
  }

  final VaultSession _session;
  final ValueListenable<DeviceKeysStatus> _deviceKeys;
  final ValueListenable<bool> _engineUnavailable;
  final AppDatabase? _database;
  final DateTime Function() _now;
  final String _launchId;
  final void Function(Object error, StackTrace stack)? _onUnexpectedError;
  final ValueNotifier<bool> _unavailableLong = ValueNotifier(false);
  Future<void> _queue = Future<void>.value();
  bool _disposed = false;

  static String _randomLaunchId() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  @override
  ValueListenable<VaultStatus> get vaultStatus => _session.status;

  @override
  bool get vaultKnown => _session.vaultKnown;

  @override
  bool get mayStart => _session.mayStart;

  @override
  E2eeFlag get flag => _session.flag;

  @override
  bool get historyLostThisOpen => _session.historyLostThisOpen;

  @override
  ValueListenable<DeviceKeysStatus> get deviceKeys => _deviceKeys;

  @override
  bool get localRecordUnusable => _deviceKeys.value.localRecordUnusable;

  @override
  ValueListenable<bool> get engineUnavailable => _engineUnavailable;

  @override
  ValueListenable<bool> get unavailableLong => _unavailableLong;

  @override
  Future<void> retryOpen() => _session.retry();

  /// Resolves when every status seen so far was processed (tests).
  @visibleForTesting
  Future<void> get idle => _queue;

  /// Processes the current status again (tests: a later clock reading).
  @visibleForTesting
  Future<void> recheck() {
    _statusChanged();
    return _queue;
  }

  /// Per-account reset (fix round D): a switch to another account must not
  /// keep the previous one's "unavailable for long" or its queued work.
  /// Queued steps made before this call are dropped; the stored time is the
  /// cache wipe's business (the `account:` prefix).
  @override
  void resetForAccount() {
    if (_disposed) return;
    _generation++;
    _unavailableLong.value = false;
  }

  void _statusChanged() {
    final database = _database;
    if (database == null || _disposed) return;
    final status = _session.status.value;
    if (status != VaultStatus.unavailable && status != VaultStatus.ready) {
      // Any status but `unavailable` ends the "long" text (the unavailable
      // run is over); the stored time stays, only `ready` deletes it (the
      // launch's first statuses are `off`, then `opening`).
      _unavailableLong.value = false;
      return;
    }
    // Captured now, so a write that lands after a sign-out is dropped (R4).
    final epoch = database.sessionEpoch.value;
    final generation = _generation;
    _queue = _queue.then((_) async {
      if (_disposed || generation != _generation) return;
      try {
        await _process(database, status, epoch, generation);
      } on Object catch (_, stack) {
        // Fixed error: no value, no key, no clock reading is carried.
        _onUnexpectedError?.call(StateError('unavailableSince'), stack);
      }
    });
  }

  int _generation = 0;

  Future<void> _process(
    AppDatabase database,
    VaultStatus status,
    int epoch,
    int generation,
  ) async {
    if (_disposed) return;
    if (status == VaultStatus.ready) {
      try {
        await database.deleteSetting(kUnavailableSinceKey);
      } on Object catch (_, stack) {
        _onUnexpectedError?.call(StateError('unavailableSince.clear'), stack);
      }
      if (!_disposed && generation == _generation) {
        _unavailableLong.value = false;
      }
      return;
    }
    final String? stored;
    try {
      stored = await database.readSetting(kUnavailableSinceKey);
    } on Object catch (_, stack) {
      _onUnexpectedError?.call(StateError('unavailableSince.read'), stack);
      return;
    }
    final nowAt = _now();
    final parsed = _parse(stored, nowAt);
    if (parsed == null) {
      // Flag off and no vault here: nothing to wait for, so the clock does
      // not start and nothing is written (flag-off inertness).
      if (!(vaultKnown || mayStart)) return;
      try {
        await database.writeAccountSetting(
          kUnavailableSinceKey,
          '$_launchId|${nowAt.microsecondsSinceEpoch}',
          epoch: epoch,
        );
      } on Object catch (_, stack) {
        _onUnexpectedError?.call(StateError('unavailableSince.write'), stack);
      }
      return;
    }
    final since = DateTime.fromMicrosecondsSinceEpoch(
      parsed.micros,
      isUtc: true,
    );
    final long =
        parsed.launch != _launchId &&
        !nowAt.isBefore(since.add(kUnavailableNamesSignOutAfter));
    if (!_disposed && generation == _generation && long) {
      _unavailableLong.value = true;
    }
  }

  /// A stored value that is malformed, not positive or later than [now] is
  /// treated as absent (a clock set back, a damaged cache): it is replaced,
  /// never trusted.
  static ({String launch, int micros})? _parse(String? value, DateTime now) {
    if (value == null) return null;
    final at = value.indexOf('|');
    if (at <= 0) return null;
    final micros = int.tryParse(value.substring(at + 1));
    if (micros == null || micros <= 0) return null;
    if (micros > now.microsecondsSinceEpoch) return null;
    return (launch: value.substring(0, at), micros: micros);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _session.status.removeListener(_statusChanged);
    _unavailableLong.dispose();
  }
}
