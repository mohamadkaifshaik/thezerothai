// The native vault owner: one process owns the vault file on Android, so
// ownership is always granted. Reached through the conditional import in
// vault_owner.dart (also the default, so no stub is needed).
import 'dart:async';

import 'package:dzeroth/core/vault/vault_owner.dart';

VaultOwner createPlatformVaultOwner() => IoVaultOwner();

/// Always owns; never loses ownership.
class IoVaultOwner implements VaultOwner {
  @override
  bool get supported => true;

  @override
  Future<bool> acquire(String uid) async => true;

  @override
  Future<void> release() async {}

  @override
  Stream<void> get lost => const Stream<void>.empty();
}
