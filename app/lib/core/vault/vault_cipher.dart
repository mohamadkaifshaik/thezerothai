import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:dzeroth/core/crypto/crypto_engine.dart';
import 'package:dzeroth/core/vault/vault_cipher_stub.dart'
    if (dart.library.io) 'package:dzeroth/core/vault/vault_cipher_android.dart'
    if (dart.library.js_interop) 'package:dzeroth/core/vault/vault_cipher_web.dart'
    as impl;

/// Seals and opens the rows of the encrypted local vault for one user.
///
/// Rows are AES-256-GCM under a random 32-byte data key that lives only in
/// memory; the platform keeps it wrapped by a non-exportable key (Android
/// Keystore). The associated data is `utf8("$table|$rowKey")`, so a value
/// moved to another row or table fails to open.
///
/// The data key never appears in an error, a log or [Object.toString].
abstract interface class VaultCipher {
  /// True when [openVaultCipher] found no stored key for this user and made a
  /// new one. The vault treats "existing vault data + a fresh key" as key loss.
  bool get freshlyCreated;

  /// Seals [plaintext] for the row [rowKey] of [table].
  ///
  /// A [plaintext] over 1 MiB or a [table] containing `|` throws
  /// [ArgumentError]. An engine that cannot run throws [VaultKeyException]
  /// with [VaultKeyFailure.unavailable]. Throws [StateError] after [destroy].
  Future<Uint8List> seal(String table, String rowKey, Uint8List plaintext);

  /// Opens a value made by [seal] for the same [table] and [rowKey].
  ///
  /// A value that does not authenticate (another row, another key, altered
  /// bytes) throws [VaultRowException]: one bad row is not a lost key. An
  /// engine that cannot run throws [VaultKeyException] with
  /// [VaultKeyFailure.unavailable]. Throws [StateError] after [destroy].
  Future<Uint8List> open(String table, String rowKey, Uint8List sealed);

  /// Zeroes the in-memory key, then deletes the platform key and the stored
  /// wrapped key for this user. Every later call, [destroy] included, throws
  /// [StateError]. If the platform delete fails the cipher is still ended and
  /// this throws [VaultKeyException] with [VaultKeyFailure.unavailable].
  Future<void> destroy();
}

/// Why the vault key could not be opened.
enum VaultKeyFailure {
  /// A stored key exists but can no longer be unwrapped (the platform key was
  /// invalidated or is missing, or the wrapped bytes do not authenticate).
  /// Everything sealed under it is unreadable.
  keyLost,

  /// The platform key store could not be used right now.
  unavailable,
}

/// The vault key could not be opened or deleted. Carries no key material.
class VaultKeyException implements Exception {
  const VaultKeyException(this.failure);

  final VaultKeyFailure failure;

  @override
  String toString() => 'VaultKeyException(${failure.name})';
}

/// One sealed row did not authenticate under the current key. Carries no row
/// data. The vault decides from a sentinel row whether this means key loss.
class VaultRowException implements Exception {
  const VaultRowException();

  @override
  String toString() => 'VaultRowException';
}

/// The platform key alias for [uid]: `dzeroth.vault.` and the first 32 hex
/// digits of SHA-256(utf8(uid)), so the alias does not reveal the uid.
String vaultKeyAlias(String uid) =>
    'dzeroth.vault.${sha256.convert(utf8.encode(uid)).toString().substring(0, 32)}';

/// The associated data for a row: `utf8("$table|$rowKey")`.
Uint8List vaultRowAad(String table, String rowKey) {
  if (table.contains('|')) {
    throw ArgumentError.value(table, 'table', 'must not contain "|"');
  }
  return Uint8List.fromList(utf8.encode('$table|$rowKey'));
}

/// Opens (or, on first use, creates) the vault cipher of [uid].
///
/// Android: the Keystore-wrapped key. Web: added by a later task in
/// `vault_cipher_web.dart`. Every other platform throws [UnsupportedError].
/// Failures throw [VaultKeyException]; a lost key is never silently replaced.
Future<VaultCipher> openVaultCipher({
  required String uid,
  required CryptoEngine engine,
}) => impl.openPlatformVaultCipher(uid: uid, engine: engine);
