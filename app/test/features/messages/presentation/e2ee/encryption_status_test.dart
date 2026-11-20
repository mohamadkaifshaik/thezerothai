import 'package:dzeroth/core/vault/vault_status.dart';
import 'package:dzeroth/features/keys/domain/device_keys_service.dart';
import 'package:dzeroth/features/messages/domain/e2ee/encryption_access.dart';
import 'package:dzeroth/features/messages/presentation/e2ee/encryption_status.dart';
import 'package:flutter_test/flutter_test.dart';

EncryptionStatus of({
  EncryptionAccess access = EncryptionAccess.full,
  VaultStatus vault = VaultStatus.ready,
  E2eeFlag flag = E2eeFlag.on,
  bool mayStart = true,
  bool historyLost = false,
  DeviceKeysStatus deviceKeys = DeviceKeysStatus.ready,
  bool localRecordUnusable = false,
  bool engineUnavailable = false,
  bool removedElsewhere = false,
  bool unavailableLong = false,
}) => encryptionStatusOf(
  access: access,
  vault: vault,
  flag: flag,
  mayStart: mayStart,
  historyLost: historyLost,
  deviceKeys: deviceKeys,
  localRecordUnusable: localRecordUnusable,
  engineUnavailable: engineUnavailable,
  removedElsewhere: removedElsewhere,
  unavailableLong: unavailableLong,
);

void main() {
  group('one row per kind', () {
    final rows = <String, (EncryptionStatus, EncryptionStatusKind)>{
      'none (healthy)': (of(), EncryptionStatusKind.none),
      'opening': (of(vault: VaultStatus.opening), EncryptionStatusKind.opening),
      'keyLostPending': (
        of(vault: VaultStatus.keyLost),
        EncryptionStatusKind.keyLostPending,
      ),
      'storageChanged': (
        of(vault: VaultStatus.storageChanged),
        EncryptionStatusKind.storageChanged,
      ),
      'unavailable': (
        of(vault: VaultStatus.unavailable),
        EncryptionStatusKind.unavailable,
      ),
      'heldElsewhere': (
        of(vault: VaultStatus.heldElsewhere),
        EncryptionStatusKind.heldElsewhere,
      ),
      'engineUnavailable': (
        of(engineUnavailable: true),
        EncryptionStatusKind.engineUnavailable,
      ),
      'removedElsewhere': (
        of(removedElsewhere: true),
        EncryptionStatusKind.removedElsewhere,
      ),
      'deviceLimitReached': (
        of(deviceKeys: DeviceKeysStatus.deviceLimitReached),
        EncryptionStatusKind.deviceLimitReached,
      ),
      'deviceRecordUnusable': (
        of(
          deviceKeys: const DeviceKeysStatus.failed(retryable: false),
          localRecordUnusable: true,
        ),
        EncryptionStatusKind.deviceRecordUnusable,
      ),
      'setupFailed (retryable)': (
        of(deviceKeys: const DeviceKeysStatus.failed(retryable: true)),
        EncryptionStatusKind.setupFailed,
      ),
      'dormant (flag off)': (
        of(
          flag: E2eeFlag.off,
          mayStart: false,
          deviceKeys: DeviceKeysStatus.dormant,
        ),
        EncryptionStatusKind.dormant,
      ),
      'offline (flag unknown)': (
        of(flag: E2eeFlag.unknown, mayStart: false),
        EncryptionStatusKind.offline,
      ),
    };
    rows.forEach((name, row) {
      test(name, () => expect(row.$1.kind, row.$2));
    });
    test('every kind has a row', () {
      final covered = rows.values.map((r) => r.$2).toSet();
      expect(covered, EncryptionStatusKind.values.toSet());
    });
  });

  test('access hidden or unsupported is none whatever else is true', () {
    for (final access in [
      EncryptionAccess.hidden,
      EncryptionAccess.unsupported,
    ]) {
      for (final vault in VaultStatus.values) {
        final s = of(
          access: access,
          vault: vault,
          historyLost: true,
          removedElsewhere: true,
          engineUnavailable: true,
          deviceKeys: DeviceKeysStatus.deviceLimitReached,
        );
        expect(s.kind, EncryptionStatusKind.none, reason: '$access $vault');
        expect(s.historyLost, isFalse);
        expect(s.blocksMessaging, isFalse);
      }
    }
  });

  test(
    'removedElsewhere wins over a ready vault and over deviceLimitReached',
    () {
      expect(
        of(
          removedElsewhere: true,
          deviceKeys: DeviceKeysStatus.deviceLimitReached,
          engineUnavailable: true,
        ).kind,
        EncryptionStatusKind.removedElsewhere,
      );
    },
  );

  test('a vault status wins over device-key and engine facts', () {
    expect(
      of(
        vault: VaultStatus.keyLost,
        engineUnavailable: true,
        deviceKeys: DeviceKeysStatus.deviceLimitReached,
      ).kind,
      EncryptionStatusKind.keyLostPending,
    );
    expect(
      of(
        vault: VaultStatus.heldElsewhere,
        engineUnavailable: true,
        deviceKeys: const DeviceKeysStatus.failed(retryable: true),
        flag: E2eeFlag.unknown,
      ).kind,
      EncryptionStatusKind.heldElsewhere,
    );
  });

  test('flag unknown with a ready vault is offline, flag off is dormant', () {
    expect(
      of(flag: E2eeFlag.unknown, mayStart: false).kind,
      EncryptionStatusKind.offline,
    );
    expect(
      of(flag: E2eeFlag.off, mayStart: false).kind,
      EncryptionStatusKind.dormant,
    );
  });

  test('historyLost is carried beside any kind', () {
    for (final vault in VaultStatus.values) {
      final s = of(vault: vault, historyLost: true);
      if (vault == VaultStatus.off || vault == VaultStatus.unsupported) {
        continue;
      }
      expect(s.historyLost, isTrue, reason: '$vault');
    }
    expect(of(historyLost: true).kind, EncryptionStatusKind.none);
    expect(of(historyLost: true).historyLost, isTrue);
  });

  test('offersReset is true exactly for keyLostPending, storageChanged and '
      'deviceRecordUnusable', () {
    final resetKinds = {
      EncryptionStatusKind.keyLostPending,
      EncryptionStatusKind.storageChanged,
      EncryptionStatusKind.deviceRecordUnusable,
    };
    for (final kind in EncryptionStatusKind.values) {
      expect(
        EncryptionStatus(kind: kind).offersReset,
        resetKinds.contains(kind),
        reason: '$kind',
      );
    }
  });

  test('offersRetry is true exactly for unavailable, heldElsewhere and '
      'keyLostPending', () {
    final retryKinds = {
      EncryptionStatusKind.unavailable,
      EncryptionStatusKind.heldElsewhere,
      EncryptionStatusKind.keyLostPending,
    };
    for (final kind in EncryptionStatusKind.values) {
      expect(
        EncryptionStatus(kind: kind).offersRetry,
        retryKinds.contains(kind),
        reason: '$kind',
      );
    }
  });

  test('blocksMessaging is true exactly for the seven blocking kinds', () {
    final blocking = {
      EncryptionStatusKind.opening,
      EncryptionStatusKind.keyLostPending,
      EncryptionStatusKind.storageChanged,
      EncryptionStatusKind.unavailable,
      EncryptionStatusKind.heldElsewhere,
      EncryptionStatusKind.engineUnavailable,
      EncryptionStatusKind.removedElsewhere,
    };
    for (final kind in EncryptionStatusKind.values) {
      expect(
        EncryptionStatus(kind: kind).blocksMessaging,
        blocking.contains(kind),
        reason: '$kind',
      );
    }
  });

  test('a server validation refusal never offers the reset', () {
    // failed, not retryable, localRecordUnusable false: a server answer.
    final server = of(
      deviceKeys: const DeviceKeysStatus.failed(retryable: false),
    );
    expect(server.kind, EncryptionStatusKind.setupFailed);
    expect(server.offersReset, isFalse);
    final local = of(
      deviceKeys: const DeviceKeysStatus.failed(retryable: false),
      localRecordUnusable: true,
    );
    expect(local.kind, EncryptionStatusKind.deviceRecordUnusable);
    // A retryable failure is never an unusable record.
    expect(
      of(
        deviceKeys: const DeviceKeysStatus.failed(retryable: true),
        localRecordUnusable: true,
      ).kind,
      EncryptionStatusKind.setupFailed,
    );
  });

  test('a healthy ready vault with the flag on is none', () {
    for (final phase in [
      DeviceKeysStatus.ready,
      DeviceKeysStatus.idle,
      DeviceKeysStatus.dormant,
    ]) {
      expect(of(deviceKeys: phase).kind, EncryptionStatusKind.none);
    }
  });

  test('unavailableLong is carried only for unavailable', () {
    expect(
      of(vault: VaultStatus.unavailable, unavailableLong: true).unavailableLong,
      isTrue,
    );
    expect(of(vault: VaultStatus.unavailable).unavailableLong, isFalse);
    for (final vault in VaultStatus.values) {
      if (vault == VaultStatus.unavailable) continue;
      expect(
        of(vault: vault, unavailableLong: true).unavailableLong,
        isFalse,
        reason: '$vault',
      );
    }
    expect(
      of(removedElsewhere: true, unavailableLong: true).unavailableLong,
      isFalse,
    );
  });

  test('the removedElsewhere device phase alone yields the removed-elsewhere '
      'status', () {
    // No DeviceKeysStatus with that phase can be built outside the service,
    // so the phase-level function is tested.
    for (final vault in [VaultStatus.ready, VaultStatus.unavailable]) {
      final s = encryptionStatusOfPhase(
        access: EncryptionAccess.full,
        vault: vault,
        flag: E2eeFlag.on,
        mayStart: true,
        historyLost: false,
        phase: DeviceKeysPhase.removedElsewhere,
        phaseRetryable: false,
        localRecordUnusable: false,
        engineUnavailable: false,
        removedElsewhere: false,
      );
      expect(s.kind, EncryptionStatusKind.removedElsewhere, reason: '$vault');
      expect(s.blocksMessaging, isTrue);
    }
    // Hidden access still wins.
    expect(
      encryptionStatusOfPhase(
        access: EncryptionAccess.hidden,
        vault: VaultStatus.ready,
        flag: E2eeFlag.on,
        mayStart: true,
        historyLost: false,
        phase: DeviceKeysPhase.removedElsewhere,
        phaseRetryable: false,
        localRecordUnusable: false,
        engineUnavailable: false,
        removedElsewhere: false,
      ).kind,
      EncryptionStatusKind.none,
    );
  });

  test('vaultNotOpen is true exactly for opening, keyLostPending, '
      'storageChanged, unavailable and heldElsewhere', () {
    final notOpen = {
      EncryptionStatusKind.opening,
      EncryptionStatusKind.keyLostPending,
      EncryptionStatusKind.storageChanged,
      EncryptionStatusKind.unavailable,
      EncryptionStatusKind.heldElsewhere,
    };
    for (final kind in EncryptionStatusKind.values) {
      expect(
        EncryptionStatus(kind: kind).vaultNotOpen,
        notOpen.contains(kind),
        reason: '$kind',
      );
    }
    expect(
      EncryptionStatus(
        kind: EncryptionStatusKind.unavailable,
        unavailableLong: true,
      ).vaultNotOpen,
      isTrue,
    );
  });

  test('vaultNotOpen stays true when removed-elsewhere outranks a vault '
      'status that is not open', () {
    for (final vault in VaultStatus.values) {
      final s = of(vault: vault, removedElsewhere: true);
      expect(s.kind, EncryptionStatusKind.removedElsewhere);
      final open =
          vault == VaultStatus.ready ||
          vault == VaultStatus.off ||
          vault == VaultStatus.unsupported;
      expect(s.vaultNotOpen, !open, reason: '$vault');
    }
    // Engine unavailable on a ready vault: the vault is open.
    expect(of(engineUnavailable: true).vaultNotOpen, isFalse);
  });

  test('mayStart and access are carried', () {
    final s = of(
      access: EncryptionAccess.manage,
      mayStart: false,
      vault: VaultStatus.keyLost,
      flag: E2eeFlag.off,
    );
    expect(s.mayStart, isFalse);
    expect(s.access, EncryptionAccess.manage);
  });

  test('value equality', () {
    expect(const EncryptionStatus(), const EncryptionStatus());
    expect(
      const EncryptionStatus(kind: EncryptionStatusKind.opening).hashCode,
      const EncryptionStatus(kind: EncryptionStatusKind.opening).hashCode,
    );
    expect(
      const EncryptionStatus(historyLost: true) == const EncryptionStatus(),
      isFalse,
    );
  });

  test('the flag matrix: flag {on, off, unknown} x vault on this device', () {
    // Access hidden (flag not on, no vault) shows nothing, whatever the
    // status; with a vault the same inputs show the status.
    for (final flag in E2eeFlag.values) {
      for (final vaultKnown in [true, false]) {
        final access = encryptionAccessOf(
          flagOn: flag == E2eeFlag.on,
          vaultKnown: vaultKnown,
          status: VaultStatus.keyLost,
        );
        final s = of(access: access, flag: flag, vault: VaultStatus.keyLost);
        final visible = flag == E2eeFlag.on || vaultKnown;
        expect(
          s.kind,
          visible
              ? EncryptionStatusKind.keyLostPending
              : EncryptionStatusKind.none,
          reason: '$flag vaultKnown=$vaultKnown',
        );
      }
    }
  });
}
