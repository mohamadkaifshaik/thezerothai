import 'package:dzeroth/core/vault/vault_status.dart';
import 'package:dzeroth/features/keys/domain/device_keys_service.dart';
import 'package:dzeroth/features/messages/domain/e2ee/encryption_device.dart';
import 'package:flutter/foundation.dart';

/// A [ValueNotifier] that counts the listeners currently registered.
class CountingNotifier<T> extends ValueNotifier<T> {
  CountingNotifier(super.value);

  int listenerCount = 0;

  @override
  void addListener(VoidCallback listener) {
    listenerCount++;
    super.addListener(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    listenerCount--;
    super.removeListener(listener);
  }
}

class FakeEncryptionDevice implements EncryptionDevice {
  FakeEncryptionDevice({
    VaultStatus status = VaultStatus.ready,
    this.vaultKnown = true,
    this.flag = E2eeFlag.on,
    this.historyLostThisOpen = false,
  }) : vaultStatus = CountingNotifier(status);

  @override
  final CountingNotifier<VaultStatus> vaultStatus;
  @override
  final CountingNotifier<DeviceKeysStatus> deviceKeys = CountingNotifier(
    DeviceKeysStatus.dormant,
  );
  @override
  final CountingNotifier<bool> engineUnavailable = CountingNotifier(false);
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
  final CountingNotifier<bool> unavailableLong = CountingNotifier(false);

  @override
  bool get mayStart => flag == E2eeFlag.on;

  int retryOpenCalls = 0;

  @override
  Future<void> retryOpen() async {
    retryOpenCalls++;
  }
}
