import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:dzeroth/core/vault/vault_cipher.dart';
import 'package:dzeroth/core/vault/vault_cipher_web.dart';
import 'package:dzeroth/core/vault/web_interop.dart';

// Raw IndexedDB access for the test, beside the code under test: the vault's
// own record, and throwaway databases for the idbOpen / idbRun cases.

extension type _RawFactory(JSObject _) implements JSObject {
  external IDBOpenDBRequest deleteDatabase(String name);
}

IDBFactory get _idb => indexedDBOrNull()!;

Future<void> _withStore(
  String mode,
  void Function(IDBObjectStore store) body,
) async {
  final db = await idbOpen(
    _idb,
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

/// The record of [uid]: whether it exists (a record whose value is null
/// exists) and its value.
Future<(bool, JSAny?)> _readStored(String uid) async {
  var count = 0;
  JSAny? value;
  await _withStore('readonly', (store) {
    final counted = store.count(vaultKeyAlias(uid).toJS);
    counted.onsuccess = ((JSAny? _) {
      count = (counted.result as JSNumber).toDartInt;
    }).toJS;
    final request = store.get(vaultKeyAlias(uid));
    request.onsuccess = ((JSAny? _) {
      value = request.result;
    }).toJS;
  });
  return (count > 0, value);
}

/// Whether the stored key record of [uid] exists.
Future<bool> storedVaultKeyExists(String uid) async =>
    (await _readStored(uid)).$1;

/// The stored record of [uid] in words: `missing`, `null`,
/// `CryptoKey <algorithm> <length> extractable=<bool>` or `other`.
Future<String> describeStoredVaultKey(String uid) async {
  final (exists, value) = await _readStored(uid);
  if (!exists) return 'missing';
  if (value == null) return 'null';
  if (!value.isA<JSObject>()) return 'other';
  final object = value as JSObject;
  if (!object.instanceOfString('CryptoKey')) return 'other';
  final algorithm = object.getProperty<JSObject>('algorithm'.toJS);
  final name = algorithm.getProperty<JSString>('name'.toJS).toDart;
  final length = algorithm.getProperty<JSNumber>('length'.toJS).toDartInt;
  final extractable = object.getProperty<JSBoolean>('extractable'.toJS).toDart;
  return 'CryptoKey $name $length extractable=$extractable';
}

/// Whether `exportKey('raw', storedKey)` rejects (a non-extractable key).
Future<bool> storedVaultKeyExportRejects(String uid) async {
  final (_, stored) = await _readStored(uid);
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

/// Stores a record that is not the vault's kind of key under [uid]'s alias:
/// `extractable-gcm` (an extractable AES-256-GCM key), `aes-cbc` (a
/// non-extractable AES-256-CBC key) or `null` (a record whose value is null).
Future<void> storeWrongVaultKey(String uid, String kind) async {
  JSAny? value;
  if (kind != 'null') {
    final subtle = cryptoOrNull()!.subtle!;
    value = await settle(
      subtle.generateKey(
        JSObject()
          ..setProperty(
            'name'.toJS,
            (kind == 'aes-cbc' ? 'AES-CBC' : 'AES-GCM').toJS,
          )
          ..setProperty('length'.toJS, 256.toJS),
        kind == 'extractable-gcm',
        ['encrypt'.toJS, 'decrypt'.toJS].toJS,
      ),
    );
  }
  await _withStore(
    'readwrite',
    (store) => store.put(value, vaultKeyAlias(uid)),
  );
}

/// Makes the vault's key validation throw (true) or work (false).
void setVaultKeyCheckFault(bool fail) => debugFailWebVaultKeyCheck = fail;

/// Makes the read-back of a newly added key look like a non-key (true) or
/// leaves it alone (false).
void setVaultReadBackCorruption(bool corrupt) =>
    debugCorruptWebVaultReadBack = corrupt;

/// The global the key check resolves as the CryptoKey constructor
/// (`CryptoKey` normally; a missing name simulates an unresolvable one).
void setCryptoKeyConstructorName(String name) =>
    debugWebCryptoKeyConstructorName = name;

/// Runs [hook] in destroy just before the record is deleted (null: none).
void setBeforeVaultKeyDeleteHook(void Function()? hook) =>
    debugBeforeWebVaultKeyDelete = hook;

/// The cipher's `persisted` answer.
bool webCipherPersisted(VaultCipher cipher) =>
    (cipher as WebVaultCipher).persisted;

/// `navigator.storage.persisted()`, never throwing.
Future<bool> webStoragePersisted() => webVaultStoragePersisted();

// idbOpen / idbRun against throwaway databases -------------------------------

Future<void> _deleteDatabase(String name) {
  final done = Completer<void>();
  void finish(JSAny? _) {
    if (!done.isCompleted) done.complete();
  }

  final request = _RawFactory(_idb).deleteDatabase(name);
  request
    ..onsuccess = finish.toJS
    ..onerror = finish.toJS;
  // blocked: the delete still runs once the last connection closes.
  return done.future.timeout(const Duration(seconds: 5), onTimeout: () {});
}

/// Opens [name] at [version] without our wrapper and without a
/// versionchange handler. Completes with the connection, or with null as
/// soon as the open is blocked (that open stays queued; the caller must
/// close whatever blocks it).
Future<IDBDatabase?> _rawOpen(String name, int version) {
  final result = Completer<IDBDatabase?>();
  final request = _idb.open(name, version);
  request
    ..onupgradeneeded = ((JSAny? _) {
      final db = request.database;
      if (!db.objectStoreNames.contains('s')) db.createObjectStore('s');
    }).toJS
    ..onsuccess = ((JSAny? _) {
      if (result.isCompleted) {
        request.database.close();
      } else {
        result.complete(request.database);
      }
    }).toJS
    ..onerror = ((JSAny? _) {
      if (!result.isCompleted) {
        result.completeError(const WebOperationError('Error'));
      }
    }).toJS
    ..onblocked = ((JSAny? _) {
      if (!result.isCompleted) result.complete(null);
    }).toJS;
  return result.future;
}

Future<IDBDatabase> _ourOpen(String name, int version) =>
    idbOpen(_idb, name, version, (db) {
      if (!db.objectStoreNames.contains('s')) db.createObjectStore('s');
    });

/// A unique throwaway database name.
String _scratchName() =>
    'dzeroth-vault-it-${DateTime.now().microsecondsSinceEpoch}';

/// Blocked open, then a late success. Holds a raw v1 connection with no
/// versionchange handler and opens v2 through idbOpen: returns the error
/// name idbOpen completed with (`opened` if it did not fail). Then closes
/// the raw connection, which lets the v2 open succeed late; idbOpen must
/// close that late connection, so a raw v3 open is `opened`, not `blocked`.
Future<(String, String)> idbBlockedThenLateOutcome() async {
  final name = _scratchName();
  final raw1 = (await _rawOpen(name, 1))!;
  String first;
  try {
    final db = await idbOpen(_idb, name, 2, (_) {});
    db.close();
    first = 'opened';
  } on WebOperationError catch (e) {
    first = e.name;
  }
  raw1.close();
  final raw3 = await _rawOpen(name, 3);
  raw3?.close();
  await _deleteDatabase(name);
  return (first, raw3 == null ? 'blocked' : 'opened');
}

/// Our connection closes itself on versionchange: with an idbOpen
/// connection still held, a raw open at v2 is `opened`, not `blocked`.
Future<String> idbVersionChangeOutcome() async {
  final name = _scratchName();
  final ours = await _ourOpen(name, 1);
  final raw2 = await _rawOpen(name, 2);
  raw2?.close();
  ours.close();
  await _deleteDatabase(name);
  return raw2 == null ? 'blocked' : 'opened';
}

/// Runs [body] in an idbRun readwrite transaction on a throwaway store `s`.
/// Returns `completed` or the WebOperationError name, and how many records
/// the store holds afterwards.
Future<(String, int)> _idbRunOutcome(
  void Function(IDBTransaction tx, IDBObjectStore store) body,
) async {
  final name = _scratchName();
  final db = await _ourOpen(name, 1);
  String outcome;
  try {
    await idbRun(db, 's', 'readwrite', body, strict: true);
    outcome = 'completed';
  } on WebOperationError catch (e) {
    outcome = e.name;
  }
  var count = -1;
  await idbRun(db, 's', 'readonly', (tx, store) {
    final counted = store.count(null);
    counted.onsuccess = ((JSAny? _) {
      count = (counted.result as JSNumber).toDartInt;
    }).toJS;
  });
  db.close();
  await _deleteDatabase(name);
  return (outcome, count);
}

/// A body that throws after writing: the transaction is aborted.
Future<(String, int)> idbThrowingBodyOutcome() => _idbRunOutcome((tx, store) {
  store.put(1.toJS, 'a');
  throw StateError('body failed');
});

/// `add` of a duplicate key: the request error aborts the transaction.
Future<(String, int)> idbDuplicateAddOutcome() => _idbRunOutcome((tx, store) {
  store
    ..add(1.toJS, 'a')
    ..add(2.toJS, 'a');
});

/// `put` of a JS function (DataCloneError, thrown synchronously).
Future<(String, int)> idbUncloneablePutOutcome() => _idbRunOutcome((tx, store) {
  store
    ..put(1.toJS, 'a')
    ..put((() {}).toJS, 'b');
});

/// The overall idbOpen timeout. A raw v1 connection is held (no
/// versionchange handler) and a raw v2 open waits blocked behind it; an
/// idbOpen at v3 is queued behind that and gets no event at all, so only the
/// timeout (300 ms here) can end it. Returns the idbOpen error name, how long
/// it took in ms, and whether a raw v4 open afterwards is `opened` (the late
/// v3 connection was closed) or `blocked`.
Future<(String, int, String)> idbOpenTimeoutOutcome() async {
  final name = _scratchName();
  final raw1 = (await _rawOpen(name, 1))!;
  final raw2 = await _rawOpen(name, 2); // null: blocked, still queued
  final watch = Stopwatch()..start();
  String outcome;
  try {
    final db = await idbOpen(
      _idb,
      name,
      3,
      (_) {},
      timeout: const Duration(milliseconds: 300),
    );
    db.close();
    outcome = 'opened';
  } on WebOperationError catch (e) {
    outcome = e.name;
  }
  final ms = watch.elapsedMilliseconds;
  raw2?.close();
  // The queued v2 open now succeeds (and _rawOpen closes it), then the v3
  // open succeeds late and idbOpen must close it.
  raw1.close();
  final raw4 = await _rawOpen(name, 4);
  raw4?.close();
  await _deleteDatabase(name);
  return (outcome, ms, raw4 == null ? 'blocked' : 'opened');
}
