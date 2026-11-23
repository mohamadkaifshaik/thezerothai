import 'package:flutter/foundation.dart';

enum DeviceKeysPhase {
  idle,
  ready,
  deviceLimitReached,
  failed,
  dormant,
  removedElsewhere,
}

/// Where this device stands in the key directory. [idle]: nothing to do or
/// not allowed now (no vault, signed out, cancelled, or the flag is not on
/// and the vault holds no device); [dormant]: a device exists in the vault
/// and the flag is not on: nothing is sent, nothing is generated; [ready]: the
/// device is registered with a full pool; [deviceLimitReached]: the user
/// has 5 devices and must remove one (UI in a later plan); failed: the last
/// attempt failed, [retryable] when a later attempt (hourly or on resume)
/// may succeed; [removedElsewhere]: the key directory answered
/// DEVICE_REMOVED to this device's Register or Upload (the user removed it
/// from another device, Plan 5a Task 12): runs are read only from then on,
/// and nothing is deleted until the user chooses "set up again".
@immutable
class DeviceKeysStatus {
  const DeviceKeysStatus._(this.phase)
    : retryable = false,
      localRecordUnusable = false;
  const DeviceKeysStatus.failed({
    required this.retryable,
    this.localRecordUnusable = false,
  }) : phase = DeviceKeysPhase.failed;

  static const idle = DeviceKeysStatus._(DeviceKeysPhase.idle);
  static const ready = DeviceKeysStatus._(DeviceKeysPhase.ready);
  static const dormant = DeviceKeysStatus._(DeviceKeysPhase.dormant);
  static const deviceLimitReached = DeviceKeysStatus._(
    DeviceKeysPhase.deviceLimitReached,
  );
  static const removedElsewhere = DeviceKeysStatus._(
    DeviceKeysPhase.removedElsewhere,
  );

  final DeviceKeysPhase phase;
  final bool retryable;

  /// Security read M5: true ONLY when the vault's own device record cannot
  /// be used (a device row of another shape, no state or no key) or does
  /// not open (`VaultCorruptException`): a local fact. False for every
  /// server answer (a VALIDATION refusal is `failed(retryable: false)` with
  /// this false), so 5b offers the vault reset only for a local fact.
  final bool localRecordUnusable;

  @override
  bool operator ==(Object other) =>
      other is DeviceKeysStatus &&
      other.phase == phase &&
      other.retryable == retryable &&
      other.localRecordUnusable == localRecordUnusable;

  @override
  int get hashCode => Object.hash(phase, retryable, localRecordUnusable);

  @override
  String toString() => phase == DeviceKeysPhase.failed
      ? 'DeviceKeysStatus.failed(retryable: $retryable'
            '${localRecordUnusable ? ', localRecordUnusable: true' : ''})'
      : 'DeviceKeysStatus.${phase.name}';
}

/// A device-keys step failed unexpectedly. Names the step only: never a
/// device id, a key, a package, state or the original message.
class DeviceKeysError implements Exception {
  const DeviceKeysError(this.step);

  final String step;

  @override
  String toString() => 'DeviceKeysError($step)';
}
