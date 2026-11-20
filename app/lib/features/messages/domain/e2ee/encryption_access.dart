import '../../../../core/vault/vault_status.dart';

/// What the encryption UI may show on this device (the visibility rule).
enum EncryptionAccess {
  /// Nothing new: exactly today's app.
  hidden,

  /// This platform has no vault: no entry points, only the notice in an
  /// encrypted conversation.
  unsupported,

  /// Flag off or unknown, vault on this device: read, send and manage, but
  /// nothing that starts encryption.
  manage,

  /// Flag on: everything.
  full,
}

/// status == unsupported => unsupported; else flagOn => full; else vaultKnown
/// => manage; else hidden. Pure.
EncryptionAccess encryptionAccessOf({
  required bool flagOn,
  required bool vaultKnown,
  required VaultStatus status,
}) {
  if (status == VaultStatus.unsupported) return EncryptionAccess.unsupported;
  if (flagOn) return EncryptionAccess.full;
  if (vaultKnown) return EncryptionAccess.manage;
  return EncryptionAccess.hidden;
}
