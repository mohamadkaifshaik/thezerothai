/// Where the encrypted vault stands for the signed-in user.
enum VaultStatus {
  /// Encrypted messaging is off (the `e2ee_dm` flag is not enabled).
  off,

  /// This platform has no vault (anything but Android and the web).
  unsupported,

  /// The vault is being opened.
  opening,

  /// The vault is open and its key verified.
  ready,

  /// Another tab owns the vault (web).
  heldElsewhere,

  /// The vault's key no longer opens the vault's rows (the sentinel row
  /// failed to authenticate, or the file holds rows but no sentinel). The
  /// file is left untouched; wiping is decided elsewhere.
  keyLost,

  /// The vault could not be opened right now (storage, key store or browser
  /// failure, or a storage that would not keep the data).
  unavailable,

  /// Web only: this vault already exists in another browser storage than
  /// the one this browser would use now (for example OPFS, after the page
  /// lost cross-origin isolation). Nothing was opened or written, because
  /// the new storage would show an empty vault. The data is intact; it
  /// becomes reachable again when the old storage is available. Never treat
  /// this as key loss: deleting the key would make that data unreadable.
  /// Never answer it with `wipeVaultFile`: that erases every copy, the
  /// hidden history included. When copies exist under two storages at once
  /// this state never clears on its own; only an explicit user reset (which
  /// destroys both) or restoring the old storage ends it.
  storageChanged,
}

/// [openVault] or [wipeVaultFile] failed. Carries only the [status].
class VaultOpenException implements Exception {
  const VaultOpenException(this.status);

  final VaultStatus status;

  @override
  String toString() => 'VaultOpenException(${status.name})';
}

/// A row of [table] that is not recoverable on its own (the device state, a
/// group, an outbox item or a setting) failed to authenticate under the
/// vault key. Names the table only, never a value.
class VaultCorruptException implements Exception {
  const VaultCorruptException(this.table);

  final String table;

  @override
  String toString() => 'VaultCorruptException($table)';
}
