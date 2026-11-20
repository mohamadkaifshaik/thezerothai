import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/vault/vault_status.dart';
import '../../../keys/domain/device_keys_service.dart'
    show DeviceKeysPhase, DeviceKeysStatus;
import '../../domain/e2ee/encrypted_messaging.dart';
import '../../domain/e2ee/encryption_access.dart';
import '../../domain/e2ee/encryption_device.dart';

/// What the encryption status surface shows (Plan 5b, Task 3).
enum EncryptionStatusKind {
  /// Nothing to show (access hidden or unsupported, or everything is fine).
  none,
  opening,

  /// VaultStatus.keyLost.
  keyLostPending,
  storageChanged,
  unavailable,
  heldElsewhere,

  /// R16.
  engineUnavailable,

  /// R17.
  removedElsewhere,
  deviceLimitReached,

  /// Failed and not retryable, from a LOCAL unusable device record (security read M5), vault ready.
  deviceRecordUnusable,

  /// Failed otherwise (retryable, or a server refusal), vault ready.
  setupFailed,

  /// Vault ready, flag off.
  dormant,

  /// Vault ready, flag unknown.
  offline,
}

/// One status for the screens. Holds enums and booleans only: no ids, nothing readable.
@immutable
class EncryptionStatus {
  const EncryptionStatus({
    this.kind = EncryptionStatusKind.none,
    this.historyLost = false,
    this.mayStart = false,
    this.access = EncryptionAccess.hidden,
    this.vault = VaultStatus.off,
    this.unavailableLong = false,
  });

  final EncryptionStatusKind kind;
  final bool historyLost;
  final bool mayStart;
  final EncryptionAccess access;

  /// The vault status this was computed from (an enum, nothing readable). It only keeps [vaultNotOpen] truthful
  /// when removed-elsewhere outranks a vault status that is not open; a hand-built status leaves it `off`.
  final VaultStatus vault;

  /// The vault on this device is not open: its kind is opening, keyLostPending, storageChanged, unavailable
  /// (long or not) or heldElsewhere, OR the underlying [vault] status is one of those while a higher-precedence
  /// kind (removed-elsewhere) is shown. False for engine-unavailable on an open vault. Tasks 5 and 6 read "the
  /// vault is not open" only from here, never from the vault status or from [blocksMessaging].
  bool get vaultNotOpen =>
      switch (kind) {
        EncryptionStatusKind.opening ||
        EncryptionStatusKind.keyLostPending ||
        EncryptionStatusKind.storageChanged ||
        EncryptionStatusKind.unavailable ||
        EncryptionStatusKind.heldElsewhere => true,
        EncryptionStatusKind.none ||
        EncryptionStatusKind.engineUnavailable ||
        EncryptionStatusKind.removedElsewhere ||
        EncryptionStatusKind.deviceLimitReached ||
        EncryptionStatusKind.deviceRecordUnusable ||
        EncryptionStatusKind.setupFailed ||
        EncryptionStatusKind.dormant ||
        EncryptionStatusKind.offline => false,
      } ||
      switch (vault) {
        VaultStatus.opening ||
        VaultStatus.keyLost ||
        VaultStatus.storageChanged ||
        VaultStatus.unavailable ||
        VaultStatus.heldElsewhere => true,
        VaultStatus.off ||
        VaultStatus.unsupported ||
        VaultStatus.ready => false,
      };

  /// Second re-read R4: meaningful only for [EncryptionStatusKind.unavailable].
  final bool unavailableLong;

  /// Encrypted threads are read-only or unreadable.
  bool get blocksMessaging => switch (kind) {
    EncryptionStatusKind.opening ||
    EncryptionStatusKind.keyLostPending ||
    EncryptionStatusKind.storageChanged ||
    EncryptionStatusKind.unavailable ||
    EncryptionStatusKind.heldElsewhere ||
    EncryptionStatusKind.engineUnavailable ||
    EncryptionStatusKind.removedElsewhere => true,
    EncryptionStatusKind.none ||
    EncryptionStatusKind.deviceLimitReached ||
    EncryptionStatusKind.deviceRecordUnusable ||
    EncryptionStatusKind.setupFailed ||
    EncryptionStatusKind.dormant ||
    EncryptionStatusKind.offline => false,
  };

  /// R15's three cases.
  bool get offersReset => switch (kind) {
    EncryptionStatusKind.keyLostPending ||
    EncryptionStatusKind.storageChanged ||
    EncryptionStatusKind.deviceRecordUnusable => true,
    EncryptionStatusKind.none ||
    EncryptionStatusKind.opening ||
    EncryptionStatusKind.unavailable ||
    EncryptionStatusKind.heldElsewhere ||
    EncryptionStatusKind.engineUnavailable ||
    EncryptionStatusKind.removedElsewhere ||
    EncryptionStatusKind.deviceLimitReached ||
    EncryptionStatusKind.setupFailed ||
    EncryptionStatusKind.dormant ||
    EncryptionStatusKind.offline => false,
  };

  bool get offersRetry => switch (kind) {
    EncryptionStatusKind.unavailable ||
    EncryptionStatusKind.heldElsewhere ||
    EncryptionStatusKind.keyLostPending => true,
    EncryptionStatusKind.none ||
    EncryptionStatusKind.opening ||
    EncryptionStatusKind.storageChanged ||
    EncryptionStatusKind.engineUnavailable ||
    EncryptionStatusKind.removedElsewhere ||
    EncryptionStatusKind.deviceLimitReached ||
    EncryptionStatusKind.deviceRecordUnusable ||
    EncryptionStatusKind.setupFailed ||
    EncryptionStatusKind.dormant ||
    EncryptionStatusKind.offline => false,
  };

  @override
  bool operator ==(Object other) =>
      other is EncryptionStatus &&
      other.kind == kind &&
      other.historyLost == historyLost &&
      other.mayStart == mayStart &&
      other.access == access &&
      other.vault == vault &&
      other.unavailableLong == unavailableLong;

  @override
  int get hashCode =>
      Object.hash(kind, historyLost, mayStart, access, vault, unavailableLong);
}

/// Pure. Precedence (first match): access hidden or unsupported => none; removedElsewhere; then by vault status
/// (opening, keyLost, storageChanged, unavailable, heldElsewhere); then, vault ready: engineUnavailable,
/// deviceLimitReached, deviceRecordUnusable, setupFailed, flag unknown => offline, flag off => dormant; else none.
EncryptionStatus encryptionStatusOf({
  required EncryptionAccess access,
  required VaultStatus vault,
  required E2eeFlag flag,
  required bool mayStart,
  required bool historyLost,
  required DeviceKeysStatus deviceKeys,
  required bool localRecordUnusable,
  required bool engineUnavailable,
  required bool removedElsewhere,
  bool unavailableLong = false,
}) => encryptionStatusOfPhase(
  access: access,
  vault: vault,
  flag: flag,
  mayStart: mayStart,
  historyLost: historyLost,
  phase: deviceKeys.phase,
  phaseRetryable: deviceKeys.retryable,
  localRecordUnusable: localRecordUnusable,
  engineUnavailable: engineUnavailable,
  removedElsewhere: removedElsewhere,
  unavailableLong: unavailableLong,
);

/// [encryptionStatusOf] at the level where the device-keys phase is an input (a `DeviceKeysStatus` with the
/// `removedElsewhere` phase cannot be built outside the service). The removed-elsewhere phase is treated exactly
/// like the port's boolean: either one gives [EncryptionStatusKind.removedElsewhere].
EncryptionStatus encryptionStatusOfPhase({
  required EncryptionAccess access,
  required VaultStatus vault,
  required E2eeFlag flag,
  required bool mayStart,
  required bool historyLost,
  required DeviceKeysPhase phase,
  required bool phaseRetryable,
  required bool localRecordUnusable,
  required bool engineUnavailable,
  required bool removedElsewhere,
  bool unavailableLong = false,
}) {
  EncryptionStatus make(EncryptionStatusKind kind) => EncryptionStatus(
    kind: kind,
    historyLost: historyLost,
    mayStart: mayStart,
    access: access,
    vault: vault,
    unavailableLong:
        kind == EncryptionStatusKind.unavailable && unavailableLong,
  );

  switch (access) {
    case EncryptionAccess.hidden:
    case EncryptionAccess.unsupported:
      return EncryptionStatus(access: access);
    case EncryptionAccess.manage:
    case EncryptionAccess.full:
      break;
  }
  if (removedElsewhere || phase == DeviceKeysPhase.removedElsewhere) {
    return make(EncryptionStatusKind.removedElsewhere);
  }
  switch (vault) {
    case VaultStatus.off:
    case VaultStatus.unsupported:
      return make(EncryptionStatusKind.none);
    case VaultStatus.opening:
      return make(EncryptionStatusKind.opening);
    case VaultStatus.keyLost:
      return make(EncryptionStatusKind.keyLostPending);
    case VaultStatus.storageChanged:
      return make(EncryptionStatusKind.storageChanged);
    case VaultStatus.unavailable:
      return make(EncryptionStatusKind.unavailable);
    case VaultStatus.heldElsewhere:
      return make(EncryptionStatusKind.heldElsewhere);
    case VaultStatus.ready:
      break;
  }
  if (engineUnavailable) return make(EncryptionStatusKind.engineUnavailable);
  switch (phase) {
    case DeviceKeysPhase.deviceLimitReached:
      return make(EncryptionStatusKind.deviceLimitReached);
    case DeviceKeysPhase.failed:
      return make(
        !phaseRetryable && localRecordUnusable
            ? EncryptionStatusKind.deviceRecordUnusable
            : EncryptionStatusKind.setupFailed,
      );
    // The flag decides dormant and offline below; these phases add nothing of
    // their own (removedElsewhere was handled before the vault status).
    case DeviceKeysPhase.idle:
    case DeviceKeysPhase.ready:
    case DeviceKeysPhase.dormant:
    case DeviceKeysPhase.removedElsewhere:
      break;
  }
  switch (flag) {
    case E2eeFlag.unknown:
      return make(EncryptionStatusKind.offline);
    case E2eeFlag.off:
      return make(EncryptionStatusKind.dormant);
    case E2eeFlag.on:
      return make(EncryptionStatusKind.none);
  }
}

/// Folds the device facts and the port's `removedElsewhere` into one [EncryptionStatus]. It holds no timer and
/// makes no call except `retryOpen` on the user's tap.
class EncryptionStatusCubit extends Cubit<EncryptionStatus> {
  EncryptionStatusCubit({
    required EncryptionDevice device,
    EncryptedMessaging? messaging,
    required bool Function() flagOn,
    void Function(Object error, StackTrace stack)? onUnexpectedError,
  }) : _device = device,
       _messaging = messaging,
       _flagOn = flagOn,
       _onUnexpectedError = onUnexpectedError,
       super(_compute(device, messaging, flagOn, false)) {
    device.vaultStatus.addListener(_changed);
    device.deviceKeys.addListener(_changed);
    device.engineUnavailable.addListener(_changed);
    device.unavailableLong.addListener(_changed);
    messaging?.removedElsewhere.addListener(_changed);
  }

  final EncryptionDevice _device;
  final EncryptedMessaging? _messaging;
  final bool Function() _flagOn;
  final void Function(Object error, StackTrace stack)? _onUnexpectedError;
  bool _historyDismissed = false;
  bool _retrying = false;

  static EncryptionStatus _compute(
    EncryptionDevice device,
    EncryptedMessaging? messaging,
    bool Function() flagOn,
    bool historyDismissed,
  ) {
    final vault = device.vaultStatus.value;
    return encryptionStatusOf(
      access: encryptionAccessOf(
        flagOn: flagOn(),
        vaultKnown: device.vaultKnown,
        status: vault,
      ),
      vault: vault,
      flag: device.flag,
      mayStart: device.mayStart,
      historyLost: device.historyLostThisOpen && !historyDismissed,
      deviceKeys: device.deviceKeys.value,
      localRecordUnusable: device.localRecordUnusable,
      engineUnavailable: device.engineUnavailable.value,
      removedElsewhere: messaging?.removedElsewhere.value ?? false,
      unavailableLong: device.unavailableLong.value,
    );
  }

  void _changed() {
    if (isClosed) return;
    emit(_compute(_device, _messaging, _flagOn, _historyDismissed));
  }

  /// Re-reads the plain getters (flag, mayStart, vaultKnown); called on a flag-set change.
  void refresh() => _changed();

  /// The user's "Try again". Ignored while one runs or while the vault opens.
  Future<void> retry() async {
    if (_retrying || isClosed || state.kind == EncryptionStatusKind.opening) {
      return;
    }
    _retrying = true;
    try {
      await _device.retryOpen();
    } catch (_, stack) {
      _onUnexpectedError?.call(StateError('retryOpen'), stack);
    } finally {
      _retrying = false;
    }
  }

  /// Hides the history-lost line for this cubit's lifetime.
  void dismissHistoryLost() {
    _historyDismissed = true;
    _changed();
  }

  @override
  Future<void> close() {
    _device.vaultStatus.removeListener(_changed);
    _device.deviceKeys.removeListener(_changed);
    _device.engineUnavailable.removeListener(_changed);
    _device.unavailableLong.removeListener(_changed);
    _messaging?.removedElsewhere.removeListener(_changed);
    return super.close();
  }
}
