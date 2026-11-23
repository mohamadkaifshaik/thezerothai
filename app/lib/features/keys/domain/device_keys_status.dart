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
/// may succeed; `removedElsewhere`: this device is missing from the
/// account's key-device list (removed from another device); its behaviour
/// arrives in Task 12, and nothing is deleted until the user chooses.
@immutable
class DeviceKeysStatus {
  const DeviceKeysStatus._(this.phase) : retryable = false;
  const DeviceKeysStatus.failed({required this.retryable})
    : phase = DeviceKeysPhase.failed;

  static const idle = DeviceKeysStatus._(DeviceKeysPhase.idle);
  static const ready = DeviceKeysStatus._(DeviceKeysPhase.ready);
  static const dormant = DeviceKeysStatus._(DeviceKeysPhase.dormant);
  static const deviceLimitReached = DeviceKeysStatus._(
    DeviceKeysPhase.deviceLimitReached,
  );

  final DeviceKeysPhase phase;
  final bool retryable;

  @override
  bool operator ==(Object other) =>
      other is DeviceKeysStatus &&
      other.phase == phase &&
      other.retryable == retryable;

  @override
  int get hashCode => Object.hash(phase, retryable);

  @override
  String toString() => phase == DeviceKeysPhase.failed
      ? 'DeviceKeysStatus.failed(retryable: $retryable)'
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
