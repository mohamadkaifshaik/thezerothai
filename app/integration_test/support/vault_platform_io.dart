import 'package:dzeroth/core/vault/vault_cipher.dart';

Never _webOnly() => throw UnsupportedError('web vault helpers are web-only');

/// Web only: whether the stored key record of [uid] exists.
Future<bool> storedVaultKeyExists(String uid) async => _webOnly();

/// Web only: whether `exportKey('raw', storedKey)` rejects.
Future<bool> storedVaultKeyExportRejects(String uid) async => _webOnly();

/// Web only: deletes the stored key record of [uid] (idempotent).
Future<void> deleteStoredVaultKey(String uid) async => _webOnly();

/// Web only: replaces the stored key record of [uid] with a string.
Future<void> storeJunkVaultKey(String uid) async => _webOnly();

/// Web only: the cipher's `persisted` answer.
bool webCipherPersisted(VaultCipher cipher) => _webOnly();

/// Web only: `navigator.storage.persisted()`, never throwing.
Future<bool> webStoragePersisted() async => _webOnly();
