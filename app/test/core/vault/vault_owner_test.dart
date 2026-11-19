// The platform-independent part of vault ownership on the VM: the lock name
// by alias and the native (always granted) owner. The Web Lock owner is
// covered in Chrome by integration_test/vault_owner_test.dart.
import 'package:dzeroth/core/vault/vault_cipher.dart';
import 'package:dzeroth/core/vault/vault_owner.dart';
import 'package:dzeroth/core/vault/vault_owner_io.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the lock name by alias is the lock name by uid, and names no uid', () {
    expect(
      vaultLockNameForAlias(vaultKeyAlias('user-1')),
      vaultLockName('user-1'),
    );
    expect(vaultLockName('user-1'), isNot(contains('user-1')));
    expect(() => vaultLockNameForAlias('user-1'), throwsArgumentError);
  });

  test('the native owner grants by alias as by uid', () async {
    final owner = IoVaultOwner();
    expect(await owner.acquireForAlias(vaultKeyAlias('user-1')), isTrue);
    expect(await owner.acquire('user-1'), isTrue);
    await owner.release();
  });
}
