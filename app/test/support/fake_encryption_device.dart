import 'package:dzeroth/core/vault/vault_status.dart';
import 'package:dzeroth/features/keys/domain/device_keys_service.dart';
import 'package:dzeroth/features/messages/domain/e2ee/encryption_device.dart';
import 'package:flutter/foundation.dart';

class FakeEncryptionDevice implements EncryptionDevice {
  FakeEncryptionDevice({
    VaultStatus status = VaultStatus.ready,
    this.vaultKnown = true,
    this.flag = E2eeFlag.on,
    this.historyLostThisOpen = false,
  }) : vaultStatus = ValueNotifier(status);

  @override
  final ValueNotifier<VaultStatus> vaultStatus;
  @override
  final ValueNotifier<DeviceKeysStatus> deviceKeys = ValueNotifier(
    DeviceKeysStatus.dormant,
  );
  @override
  final ValueNotifier<bool> engineUnavailable = ValueNotifier(false);
  @override
  bool vaultKnown;
  @override
  E2eeFlag flag;
  @override
  bool historyLostThisOpen;

  /// Security read M5.
  @override
  bool localRecordUnusable = false;

  /// Second re-read R4.
  @override
  final ValueNotifier<bool> unavailableLong = ValueNotifier(false);

  @override
  bool get mayStart => flag == E2eeFlag.on;

  int retryOpenCalls = 0;

  @override
  Future<void> retryOpen() async {
    retryOpenCalls++;
  }
}
