// The web vault key: a non-extractable WebCrypto AES-256-GCM CryptoKey, kept
// as a CryptoKey object (structured clone) in IndexedDB database
// `dzeroth-vault-keys` (version 1), object store `keys`, record key = the
// alias from vaultKeyAlias. Rows are sealed and opened by crypto.subtle
// directly, so the key never exists in JavaScript-readable form.
//
// Sealed format, the same as the engine's: nonce (12, crypto.getRandomValues)
// || ciphertext || tag (16); associated data utf8("$table|$rowKey").
//
// Failure mapping (mirrors the Android cipher):
//   no secure context, no crypto.subtle, no indexedDB, an IndexedDB open
//   error, `blocked` or 10 s timeout, any request or transaction error
//   (quota, security, abort), a key that cannot be generated or stored, a
//   new key that does not read back, a key check that throws
//                                         -> VaultKeyException(unavailable)
//   no record (a successful count finds none) -> a new key, freshlyCreated
//   a record that exists (its value may be null) and is observably not a
//   non-extractable AES-256-GCM CryptoKey with encrypt and decrypt
//                                         -> VaultKeyException(keyLost)
//   decrypt rejects with OperationError, or the value is too short
//                                         -> VaultRowException
//   any other encrypt/decrypt rejection   -> VaultKeyException(unavailable)
// A transient or environmental failure is never keyLost: a later task wipes
// message history on key loss. An existing record is never overwritten (the
// create transaction uses `add`).
//
// Only idbOpen is time-bounded (10 s). A generateKey promise or an
// IndexedDB transaction that never settles would leave the open pending; it
// never turns into keyLost.
//
// A newly added key that reads back as an observable non-key is deleted
// again (best effort) before the open reports unavailable, so a browser that
// cannot keep a CryptoKey never reaches keyLost on the next launch. A check
// that throws leaves the record alone.
//
// freshlyCreated is not a key-loss detector on its own. Of two concurrent
// openers exactly one normally reports it, but zero is possible: a tab that
// dies between the commit of its new key and its return leaves a key that
// every later opener adopts as not fresh. Callers must also check the vault's
// own data (a sentinel row) to detect key loss.
//
// Web only (dart:js_interop); reached through the conditional import in
// vault_cipher.dart. Nothing here logs.
import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:dzeroth/core/crypto/crypto_engine.dart';
import 'package:dzeroth/core/vault/vault_cipher.dart';
import 'package:dzeroth/core/vault/web_interop.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

/// The IndexedDB database that holds the vault keys.
@visibleForTesting
const webVaultKeyDatabase = 'dzeroth-vault-keys';

/// Its schema version.
@visibleForTesting
const webVaultKeyDatabaseVersion = 1;

/// Its one object store (out-of-line keys: the alias).
@visibleForTesting
const webVaultKeyStore = 'keys';

/// Tests only: makes key validation throw.
@visibleForTesting
bool debugFailWebVaultKeyCheck = false;

/// Tests only: makes the read-back of a newly added key a non-key value.
@visibleForTesting
bool debugCorruptWebVaultReadBack = false;

/// Tests only: the global resolved as the CryptoKey constructor.
@visibleForTesting
String debugWebCryptoKeyConstructorName = 'CryptoKey';

/// Tests only: runs in [WebVaultCipher.destroy] after the wait for calls in
/// flight, just before the key is dropped and the record deleted.
@visibleForTesting
void Function()? debugBeforeWebVaultKeyDelete;

const _destroyWait = Duration(seconds: 5);
const _nonceLength = 12;
const _tagLength = 16;
const _maxPlaintext = 1024 * 1024;
const _unavailable = VaultKeyException(VaultKeyFailure.unavailable);
const _keyLost = VaultKeyException(VaultKeyFailure.keyLost);

/// The web vault. [engine] is unused: WebCrypto seals directly.
Future<VaultCipher> openPlatformVaultCipher({
  required String uid,
  required CryptoEngine engine,
  bool create = true,
}) => WebVaultCipher._open(vaultKeyAlias(uid), create);

/// Deletes the stored vault key of [uid] without opening it (idempotent).
/// Rows sealed under it can never be opened again. Throws [VaultKeyException]
/// with [VaultKeyFailure.unavailable] when IndexedDB cannot be used.
Future<void> deleteWebVaultKey(String uid) =>
    deleteWebVaultKeyForAlias(vaultKeyAlias(uid));

/// [deleteWebVaultKey] by alias.
Future<void> deleteWebVaultKeyForAlias(String alias) async {
  final env = _Env.require();
  await _deleteRecord(env, requireVaultKeyAlias(alias));
}

/// Whether the browser has granted persistent storage to this origin
/// (`navigator.storage.persisted()`), so the vault key is not evicted under
/// storage pressure. False when it cannot be told. Never throws, never asks
/// the user.
Future<bool> webVaultStoragePersisted() async {
  final storage = storageManagerOrNull();
  if (storage == null) return false;
  try {
    final answer = _isTrue(
      await settle(storage.persisted()).timeout(const Duration(seconds: 2)),
    );
    if (answer) _pagePersisted = true;
    return answer;
  } on Object {
    return false;
  }
}

// The latest persistence answer for this page, and whether persist() has
// been asked for (once per page: Firefox shows a prompt).
bool _pagePersisted = false;
bool _persistRequested = false;

/// Asks for persistent storage once per page; never throws and never makes
/// the open wait on a prompt.
Future<void> _requestPersistence() async {
  if (await webVaultStoragePersisted() || _persistRequested) return;
  _persistRequested = true;
  final storage = storageManagerOrNull();
  if (storage == null) return;
  try {
    unawaited(
      settle(storage.persist()).then(
        (answer) {
          if (_isTrue(answer)) _pagePersisted = true;
        },
        onError: (Object _) {
          // Refused or not supported: the answer stays false.
        },
      ),
    );
  } on Object {
    // persist() missing or throwing synchronously: the answer stays false.
  }
}

bool _isTrue(JSAny? value) =>
    value != null && value.isA<JSBoolean>() && (value as JSBoolean).toDart;

/// What the web vault needs from the page; [require] throws
/// [VaultKeyFailure.unavailable] when any of it is missing.
class _Env {
  _Env._(this.crypto, this.subtle, this.idb);

  final WebCrypto crypto;
  final SubtleCrypto subtle;
  final IDBFactory idb;

  static _Env require() {
    if (!webSecureContext) throw _unavailable;
    final crypto = cryptoOrNull();
    final subtle = crypto?.subtle;
    final idb = indexedDBOrNull();
    if (crypto == null || subtle == null || idb == null) throw _unavailable;
    return _Env._(crypto, subtle, idb);
  }
}

Future<IDBDatabase> _openDb(_Env env) async {
  try {
    return await idbOpen(
      env.idb,
      webVaultKeyDatabase,
      webVaultKeyDatabaseVersion,
      (db) {
        if (!db.objectStoreNames.contains(webVaultKeyStore)) {
          db.createObjectStore(webVaultKeyStore);
        }
      },
    );
  } on Object {
    throw _unavailable;
  }
}

/// A record as read: whether it exists (counted, so a record whose value is
/// null or undefined still exists) and its value.
typedef _Record = ({bool exists, JSAny? value});

/// Reads the record of [alias] in one readonly transaction. Any IndexedDB
/// failure is [VaultKeyFailure.unavailable], never "missing".
Future<_Record> _readRecord(IDBDatabase db, String alias) async {
  int? count;
  JSAny? value;
  try {
    await idbRun(db, webVaultKeyStore, 'readonly', (tx, store) {
      final counted = store.count(alias.toJS);
      counted.onsuccess = ((JSAny? _) {
        try {
          final n = counted.result;
          if (n == null || !n.isA<JSNumber>()) throw StateError('count');
          count = (n as JSNumber).toDartInt;
        } on Object {
          abortQuietly(tx);
        }
      }).toJS;
      final request = store.get(alias);
      request.onsuccess = ((JSAny? _) {
        try {
          value = request.result;
        } on Object {
          abortQuietly(tx);
        }
      }).toJS;
    });
  } on Object {
    throw _unavailable;
  }
  final n = count;
  if (n == null) throw _unavailable;
  return (exists: n > 0, value: value);
}

/// Stores [candidate] under [alias] with `add`, which never overwrites: true
/// when it was stored, false when a record already existed (ConstraintError;
/// another opener won). Durability strict. Any other failure, including a
/// CryptoKey that cannot be cloned (DataCloneError), is
/// [VaultKeyFailure.unavailable].
Future<bool> _addRecord(
  IDBDatabase db,
  String alias,
  CryptoKey candidate,
) async {
  try {
    await idbRun(db, webVaultKeyStore, 'readwrite', (tx, store) {
      store.add(candidate, alias);
    }, strict: true);
    return true;
  } on WebOperationError catch (e) {
    if (e.name == 'ConstraintError') return false;
    throw _unavailable;
  } on Object {
    throw _unavailable;
  }
}

/// Deletes [alias] on an open [db], strict durability, ignoring failure.
Future<void> _deleteQuietly(IDBDatabase db, String alias) async {
  try {
    await idbRun(db, webVaultKeyStore, 'readwrite', (tx, store) {
      store.delete(alias);
    }, strict: true);
  } on Object {
    // Best effort: the open reports unavailable either way.
  }
}

Future<void> _deleteRecord(_Env env, String alias) async {
  final db = await _openDb(env);
  try {
    await idbRun(db, webVaultKeyStore, 'readwrite', (tx, store) {
      store.delete(alias);
    }, strict: true);
  } on Object {
    throw _unavailable;
  } finally {
    db.close();
  }
}

/// The outcome of checking a stored value: the key, a positive mismatch
/// (observably not the vault's kind of key: keyLost), or a check that threw
/// (environmental: unavailable).
sealed class _KeyCheck {
  const _KeyCheck();
}

final class _ValidKey extends _KeyCheck {
  const _ValidKey(this.key);
  final CryptoKey key;
}

final class _Mismatch extends _KeyCheck {
  const _Mismatch();
}

final class _CheckFailed extends _KeyCheck {
  const _CheckFailed();
}

/// Checks that [value] is a non-extractable AES-256-GCM secret CryptoKey
/// that can encrypt and decrypt.
_KeyCheck _checkKey(JSAny? value) {
  const mismatch = _Mismatch();
  try {
    if (debugFailWebVaultKeyCheck) throw StateError('test fault');
    if (value == null || !value.isA<JSObject>()) return mismatch;
    final object = value as JSObject;
    // instanceOfString would answer false (a mismatch: keyLost) when the
    // global cannot be resolved; an unresolvable constructor is an
    // environment failure, so it throws here (unavailable).
    final constructor = globalContext.getProperty<JSAny?>(
      debugWebCryptoKeyConstructorName.toJS,
    );
    if (constructor == null || !constructor.isA<JSFunction>()) {
      throw StateError('CryptoKey is not available');
    }
    if (!object.instanceof(constructor as JSFunction)) return mismatch;
    final key = CryptoKey(object);
    final type = key.type;
    if (type == null || !type.isA<JSString>()) return mismatch;
    if ((type as JSString).toDart != 'secret') return mismatch;
    final extractable = key.extractable;
    if (extractable == null || !extractable.isA<JSBoolean>()) return mismatch;
    if ((extractable as JSBoolean).toDart) return mismatch;
    final algorithm = key.algorithm;
    if (algorithm == null || !algorithm.isA<JSObject>()) return mismatch;
    final name = (algorithm as JSObject).getProperty<JSAny?>('name'.toJS);
    final length = algorithm.getProperty<JSAny?>('length'.toJS);
    if (name == null || !name.isA<JSString>()) return mismatch;
    if ((name as JSString).toDart != 'AES-GCM') return mismatch;
    if (length == null || !length.isA<JSNumber>()) return mismatch;
    if ((length as JSNumber).toDartInt != 256) return mismatch;
    final usages = key.usages;
    if (usages == null || !usages.isA<JSArray>()) return mismatch;
    final names = {
      for (final u in (usages as JSArray).toDart)
        if (u != null && u.isA<JSString>()) (u as JSString).toDart,
    };
    if (!names.containsAll(const ['encrypt', 'decrypt'])) return mismatch;
    return _ValidKey(key);
  } on Object {
    return const _CheckFailed();
  }
}

/// The key of a record that exists: valid, else keyLost for a mismatch and
/// unavailable for a check that threw.
CryptoKey _existingKey(JSAny? value) => switch (_checkKey(value)) {
  _ValidKey(:final key) => key,
  _Mismatch() => throw _keyLost,
  _CheckFailed() => throw _unavailable,
};

/// The key we just made or stored: anything but valid is unavailable.
CryptoKey _ownKey(JSAny? value) => switch (_checkKey(value)) {
  _ValidKey(:final key) => key,
  _ => throw _unavailable,
};

/// The vault cipher whose key is a non-extractable WebCrypto key in
/// IndexedDB.
class WebVaultCipher implements VaultCipher {
  WebVaultCipher._(this._env, this._alias, this._key, this.freshlyCreated);

  final _Env _env;
  final String _alias;

  // The key handle. Only here; opaque (non-extractable). Dropped by destroy.
  CryptoKey? _key;

  // Set first by close or destroy: new calls are refused while in-flight ones
  // finish. [_destroyed] is set by destroy only (close after it is a no-op;
  // destroy after close still deletes the stored record).
  bool _closing = false;
  bool _destroyed = false;
  int _inFlight = 0;
  Completer<void>? _drained;

  @override
  final bool freshlyCreated;

  /// True once the browser has granted persistent storage to this origin in
  /// this page (persistence is asked for once per page, at open, without
  /// waiting for a prompt). False until then, so it can turn true later.
  /// For a fresh answer call `vaultStoragePersisted()` in vault_cipher.dart.
  bool get persisted => _pagePersisted;

  static Future<WebVaultCipher> _open(String alias, bool create) async {
    final env = _Env.require();
    await _requestPersistence();
    final db = await _openDb(env);
    try {
      final stored = await _readRecord(db, alias);
      if (stored.exists) {
        return WebVaultCipher._(env, alias, _existingKey(stored.value), false);
      }

      // No record and not allowed to make a key (create false): nothing is
      // generated or stored; the vault existed, so its key is gone.
      if (!create) throw _keyLost;

      // No record: first use for this user in this browser profile. The key
      // is made before the transaction (a transaction cannot wait on it).
      final JSAny? generated;
      try {
        generated = await settle(
          env.subtle.generateKey(
            JSObject()
              ..setProperty('name'.toJS, 'AES-GCM'.toJS)
              ..setProperty('length'.toJS, 256.toJS),
            false,
            ['encrypt'.toJS, 'decrypt'.toJS].toJS,
          ),
        );
      } on Object {
        throw _unavailable;
      }
      final candidate = _ownKey(generated);

      final added = await _addRecord(db, alias, candidate);
      final back = await _readRecord(db, alias);
      if (!back.exists) throw _unavailable;
      if (!added) {
        // Another opener (another tab, or a concurrent open here) won: adopt
        // its record under the same rules as any existing record.
        return WebVaultCipher._(env, alias, _existingKey(back.value), false);
      }
      // Never hand out a key that is not really stored: use the stored copy
      // (some private modes cannot keep a CryptoKey).
      final check = _checkKey(
        debugCorruptWebVaultReadBack ? 'not a key'.toJS : back.value,
      );
      switch (check) {
        case _ValidKey(:final key):
          return WebVaultCipher._(env, alias, key, true);
        case _Mismatch():
          // The record we just added reads back as something unusable (a
          // browser that cannot keep a CryptoKey). Remove it, so the next
          // open again finds no record instead of reporting keyLost (which
          // would wipe the vault on every launch).
          await _deleteQuietly(db, alias);
          throw _unavailable;
        case _CheckFailed():
          // Possibly transient, and another opener may already use this
          // record: leave it.
          throw _unavailable;
      }
    } finally {
      db.close();
    }
  }

  /// The key for a call that starts now; counts it in flight.
  CryptoKey _enter() {
    final key = _key;
    if (_closing || key == null) {
      throw StateError('The vault cipher was destroyed.');
    }
    _inFlight++;
    return key;
  }

  void _leave() {
    _inFlight--;
    final drained = _drained;
    if (_inFlight == 0 && drained != null && !drained.isCompleted) {
      drained.complete();
    }
  }

  JSObject _gcm(JSUint8Array nonce, Uint8List aad) => JSObject()
    ..setProperty('name'.toJS, 'AES-GCM'.toJS)
    ..setProperty('iv'.toJS, nonce)
    ..setProperty('additionalData'.toJS, aad.toJS)
    ..setProperty('tagLength'.toJS, (_tagLength * 8).toJS);

  static Uint8List _bytes(JSAny? buffer) {
    if (buffer == null || !buffer.isA<JSArrayBuffer>()) throw _unavailable;
    return (buffer as JSArrayBuffer).toDart.asUint8List();
  }

  @override
  Future<Uint8List> seal(
    String table,
    String rowKey,
    Uint8List plaintext,
  ) async {
    // Errors (destroyed, a bad table) come back as a failed future.
    final key = _enter();
    try {
      final aad = vaultRowAad(table, rowKey);
      if (plaintext.length > _maxPlaintext) {
        throw ArgumentError.value(
          plaintext.length,
          'plaintext.length',
          'more than 1 MiB',
        );
      }
      // A JS-side array: under dart2wasm a converted Dart list is a copy, and
      // getRandomValues would fill the copy.
      final nonce = JSUint8Array.withLength(_nonceLength);
      final JSAny? out;
      try {
        _env.crypto.getRandomValues(nonce);
        out = await settle(
          _env.subtle.encrypt(_gcm(nonce, aad), key, plaintext.toJS),
        );
      } on Object {
        throw _unavailable;
      }
      final body = _bytes(out);
      return Uint8List(_nonceLength + body.length)
        ..setAll(0, nonce.toDart)
        ..setAll(_nonceLength, body);
    } finally {
      _leave();
    }
  }

  @override
  Future<Uint8List> open(String table, String rowKey, Uint8List sealed) async {
    final key = _enter();
    try {
      final aad = vaultRowAad(table, rowKey);
      if (sealed.length < _nonceLength + _tagLength) {
        throw const VaultRowException();
      }
      final nonce = Uint8List.sublistView(sealed, 0, _nonceLength).toJS;
      final body = Uint8List.sublistView(sealed, _nonceLength).toJS;
      final JSAny? out;
      try {
        out = await settle(_env.subtle.decrypt(_gcm(nonce, aad), key, body));
      } on WebOperationError catch (e) {
        // OperationError is the authentication failure of this value; any
        // other rejection is not about this row.
        if (e.name == 'OperationError') throw const VaultRowException();
        throw _unavailable;
      } on Object {
        throw _unavailable;
      }
      return _bytes(out);
    } finally {
      _leave();
    }
  }

  // The one end of the in-memory key, shared by close and destroy: refuse new
  // calls first (synchronously), let the ones in flight finish under the key
  // (waiting at most 5 s), then drop the handle. A call still running after
  // 5 s holds its own reference to the handle, so it still completes
  // correctly.
  Future<void>? _ending;

  Future<void> _end() => _ending ??= _endNow();

  Future<void> _endNow() async {
    _closing = true;
    if (_inFlight > 0) {
      final drained = _drained = Completer<void>();
      await drained.future.timeout(_destroyWait, onTimeout: () {});
    }
    _key = null;
  }

  /// Ends the cipher and drops the key handle; the stored record stays, so
  /// the same key opens again.
  @override
  Future<void> close() async {
    if (_destroyed) return;
    await _end();
  }

  /// Ends the cipher (as [close] does, when it has not been closed yet),
  /// then deletes the stored record.
  @override
  Future<void> destroy() async {
    if (_destroyed) throw StateError('The vault cipher was destroyed.');
    _destroyed = true;
    await _end();
    debugBeforeWebVaultKeyDelete?.call();
    await _deleteRecord(_env, _alias);
  }
}

/// [deleteVaultKey] on the web: [deleteWebVaultKey].
Future<void> platformDeleteVaultKey(String uid) => deleteWebVaultKey(uid);

/// [deleteVaultKeyForAlias] on the web: [deleteWebVaultKeyForAlias].
Future<void> platformDeleteVaultKeyForAlias(String alias) =>
    deleteWebVaultKeyForAlias(alias);

/// [vaultStoragePersisted] on the web: [webVaultStoragePersisted].
Future<bool> platformVaultStoragePersisted() => webVaultStoragePersisted();
