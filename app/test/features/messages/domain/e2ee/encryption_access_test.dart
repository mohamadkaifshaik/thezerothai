import 'package:dzeroth/core/vault/vault_status.dart';
import 'package:dzeroth/features/messages/domain/e2ee/encryption_access.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // flag {on, off, unknown}: the rule sees only "on or not".
  const flags = <E2eeFlag, bool>{
    E2eeFlag.on: true,
    E2eeFlag.off: false,
    E2eeFlag.unknown: false,
  };
  const vaults = [true, false];

  test('unsupported status is unsupported whatever the flag and vault say', () {
    for (final f in flags.entries) {
      for (final known in vaults) {
        expect(
          encryptionAccessOf(
            flagOn: f.value,
            vaultKnown: known,
            status: VaultStatus.unsupported,
          ),
          EncryptionAccess.unsupported,
          reason: '${f.key} known=$known',
        );
      }
    }
  });

  final others = VaultStatus.values.where((s) => s != VaultStatus.unsupported);

  test('flag on is full', () {
    for (final s in others) {
      for (final known in vaults) {
        expect(
          encryptionAccessOf(flagOn: true, vaultKnown: known, status: s),
          EncryptionAccess.full,
          reason: '$s known=$known',
        );
      }
    }
  });

  test('flag off or unknown with a vault on this device is manage', () {
    for (final f in flags.entries.where((e) => e.key != E2eeFlag.on)) {
      for (final s in others) {
        expect(
          encryptionAccessOf(flagOn: f.value, vaultKnown: true, status: s),
          EncryptionAccess.manage,
          reason: '${f.key} $s',
        );
      }
    }
  });

  test('flag off or unknown with no vault is hidden', () {
    for (final f in flags.entries.where((e) => e.key != E2eeFlag.on)) {
      for (final s in others) {
        expect(
          encryptionAccessOf(flagOn: f.value, vaultKnown: false, status: s),
          EncryptionAccess.hidden,
          reason: '${f.key} $s',
        );
      }
    }
  });
}
