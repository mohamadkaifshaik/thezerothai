import 'package:dzeroth/core/vault/vault_cipher.dart';
import 'package:dzeroth/core/vault/vault_owner_io.dart'
    if (dart.library.js_interop) 'package:dzeroth/core/vault/vault_owner_web.dart'
    as impl;

/// Which context may write the vault of one user.
///
/// On the web only one tab at a time may own a user's vault (an exclusive Web
/// Lock held for as long as the owner holds it); the others are refused and
/// the caller reports the vault as unavailable. On Android one process owns
/// the file, so ownership is always granted. Fails closed: a browser without
/// Web Locks cannot enforce ownership, so [acquire] returns false there.
abstract interface class VaultOwner {
  /// False when ownership cannot be enforced here (a browser without
  /// `navigator.locks`); [acquire] then returns false.
  bool get supported;

  /// Takes ownership of the vault of [uid] if no other tab holds it. Returns
  /// false when another tab holds it, or when ownership cannot be enforced.
  /// A second call for the same uid while owned returns true without asking
  /// again. A call for another uid while owning throws [StateError]
  /// synchronously (a caller bug, not a failed future): call [release] first.
  /// A caller waiting behind a [release] can receive an asynchronous
  /// [StateError] instead, if a different uid acquired first. A pending
  /// acquire that is released before the browser grants it returns false.
  Future<bool> acquire(String uid);

  /// Gives ownership up (the lock is free when this completes). A no-op when
  /// not owning.
  Future<void> release();

  /// Emits when ownership was taken away from this owner (another context
  /// requested the lock with `steal`). Ownership is then released; [acquire]
  /// may be tried again. Never emits on Android.
  ///
  /// A non-replaying broadcast stream: an event with no listener is dropped,
  /// so subscribe right after a successful [acquire]. On an event the owner
  /// must stop writing the vault immediately.
  Stream<void> get lost;
}

/// The owner for this platform.
VaultOwner createVaultOwner() => impl.createPlatformVaultOwner();

/// The Web Lock name for [uid]: `dzeroth-vault-` and the vault key alias.
String vaultLockName(String uid) => 'dzeroth-vault-${vaultKeyAlias(uid)}';
