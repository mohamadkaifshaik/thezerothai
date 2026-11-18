import 'dart:js_interop';

import 'package:dzeroth/core/vault/vault_cipher.dart';
import 'package:dzeroth/core/vault/vault_cipher_web.dart';
import 'package:dzeroth/core/vault/web_interop.dart';

Future<void> _withStore(
  String mode,
  void Function(IDBObjectStore store) body,
) async {
  final db = await idbOpen(
    indexedDBOrNull()!,
    webVaultKeyDatabase,
    webVaultKeyDatabaseVersion,
    (db) {
      if (!db.objectStoreNames.contains(webVaultKeyStore)) {
        db.createObjectStore(webVaultKeyStore);
      }
    },
  );
  try {
    await idbRun(db, webVaultKeyStore, mode, (tx, store) => body(store));
  } finally {
    db.close();
  }
}

Future<JSAny?> _readStored(String uid) async {
  JSAny? value;
  await _withStore('readonly', (store) {
    final request = store.get(vaultKeyAlias(uid));
    request.onsuccess = ((JSAny? _) {
      value = request.result;
    }).toJS;
  });
  return value;
}

/// Whether the stored key record of [uid] exists.
Future<bool> storedVaultKeyExists(String uid) async =>
    await _readStored(uid) != null;

/// Whether `exportKey('raw', storedKey)` rejects (a non-extractable key).
Future<bool> storedVaultKeyExportRejects(String uid) async {
  final stored = await _readStored(uid);
  if (stored == null || !stored.isA<JSObject>()) {
    throw StateError('no stored key for this uid');
  }
  final subtle = cryptoOrNull()!.subtle!;
  try {
    await settle(subtle.exportKey('raw', CryptoKey(stored as JSObject)));
    return false;
  } on WebOperationError {
    return true;
  }
}

/// Deletes the stored key record of [uid] (idempotent).
Future<void> deleteStoredVaultKey(String uid) =>
    _withStore('readwrite', (store) => store.delete(vaultKeyAlias(uid)));

/// Replaces the stored key record of [uid] with a string (not a key).
Future<void> storeJunkVaultKey(String uid) => _withStore(
  'readwrite',
  (store) => store.put('not a key'.toJS, vaultKeyAlias(uid)),
);

/// The cipher's `persisted` answer.
bool webCipherPersisted(VaultCipher cipher) =>
    (cipher as WebVaultCipher).persisted;

/// `navigator.storage.persisted()`, never throwing.
Future<bool> webStoragePersisted() => webVaultStoragePersisted();
