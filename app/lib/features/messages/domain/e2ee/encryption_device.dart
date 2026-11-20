import 'package:flutter/foundation.dart';

import '../../../../core/vault/vault_status.dart';
import '../../../keys/domain/device_keys_service.dart';

/// How long the vault may stay `unavailable` across two launches before the
/// screens name sign-out as the way out (second re-read R4).
const Duration kUnavailableNamesSignOutAfter = Duration(hours: 24);

/// Read-only device facts for screens. The production adapter is Task 14's.
abstract interface class EncryptionDevice {
  /// VaultSession.status.
  ValueListenable<VaultStatus> get vaultStatus;

  /// VaultSession.vaultKnown.
  bool get vaultKnown;

  /// VaultSession.mayStart (flag known to be on).
  bool get mayStart;

  /// VaultSession.flag.
  E2eeFlag get flag;

  /// VaultSession.historyLostThisOpen.
  bool get historyLostThisOpen;

  /// DeviceKeysService.status.
  ValueListenable<DeviceKeysStatus> get deviceKeys;

  /// Security read M5: true only when the current device-keys failure is a LOCAL unusable record (5a Task 12's
  /// `DeviceKeysStatus.localRecordUnusable`), never for a server answer. Read together with [deviceKeys] (it changes
  /// only when that listenable does). A 5b-side bool so that Task 3 does not wait for 5a's Task 12.
  bool get localRecordUnusable;

  /// GuardedCryptoEngine.unavailable.
  ValueListenable<bool> get engineUnavailable;

  /// Second re-read R4 (owner approved 2026-11-20): true when [vaultStatus] has been `unavailable` on two
  /// different launches at least [kUnavailableNamesSignOutAfter] (24 h) apart with no other status in between.
  /// Kept OUTSIDE the vault (Task 14): it never needs the unavailable vault to be readable.
  ValueListenable<bool> get unavailableLong;

  /// VaultSession.retry(); user-pressed only.
  Future<void> retryOpen();
}
