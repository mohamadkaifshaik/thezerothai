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

/// Web only: the stored record of [uid] in words.
Future<String> describeStoredVaultKey(String uid) async => _webOnly();

/// Web only: stores a record that is not the vault's kind of key.
Future<void> storeWrongVaultKey(String uid, String kind) async => _webOnly();

/// Web only: makes the vault's key validation throw.
void setVaultKeyCheckFault(bool fail) => _webOnly();

/// Web only: idbOpen blocked, then a late success.
Future<(String, String)> idbBlockedThenLateOutcome() async => _webOnly();

/// Web only: our connection closes itself on versionchange.
Future<String> idbVersionChangeOutcome() async => _webOnly();

/// Web only: idbRun with a throwing body.
Future<(String, int)> idbThrowingBodyOutcome() async => _webOnly();

/// Web only: idbRun with a duplicate add.
Future<(String, int)> idbDuplicateAddOutcome() async => _webOnly();

/// Web only: idbRun with an uncloneable put.
Future<(String, int)> idbUncloneablePutOutcome() async => _webOnly();

/// Web only: runs a hook in destroy just before the record is deleted.
void setBeforeVaultKeyDeleteHook(void Function()? hook) => _webOnly();

/// Web only: corrupts the read-back of a newly added key.
void setVaultReadBackCorruption(bool corrupt) => _webOnly();

/// Web only: the global the key check resolves as the CryptoKey constructor.
void setCryptoKeyConstructorName(String name) => _webOnly();

/// Web only: the idbOpen overall timeout path.
Future<(String, int, String)> idbOpenTimeoutOutcome() async => _webOnly();
