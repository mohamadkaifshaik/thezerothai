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
//   error or `blocked`, any request or transaction error (quota, security,
//   abort), a key that cannot be generated or stored, a stored key that does
//   not read back                         -> VaultKeyException(unavailable)
//   no record (a successful read finds nothing) -> a new key, freshlyCreated
//   a record that is not a usable non-extractable AES-256-GCM CryptoKey
//                                         -> VaultKeyException(keyLost)
//   decrypt rejects with OperationError, or the value is too short
//                                         -> VaultRowException
//   any other encrypt/decrypt rejection   -> VaultKeyException(unavailable)
// A transient IndexedDB error is never keyLost.
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

const _nonceLength = 12;
const _tagLength = 16;
const _maxPlaintext = 1024 * 1024;
const _unavailable = VaultKeyException(VaultKeyFailure.unavailable);
const _keyLost = VaultKeyException(VaultKeyFailure.keyLost);

/// The web vault. [engine] is unused: WebCrypto seals directly.
Future<VaultCipher> openPlatformVaultCipher({
  required String uid,
  required CryptoEngine engine,
}) => WebVaultCipher._open(vaultKeyAlias(uid));

/// Deletes the stored vault key of [uid] without opening it (idempotent).
/// Rows sealed under it can never be opened again. Throws [VaultKeyException]
/// with [VaultKeyFailure.unavailable] when IndexedDB cannot be used.
Future<void> deleteWebVaultKey(String uid) async {
  final env = _Env.require();
  await _deleteRecord(env, vaultKeyAlias(uid));
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

/// Reads the record of [alias]: null when a successful read found nothing.
/// Any IndexedDB failure is [VaultKeyFailure.unavailable], never "missing".
Future<JSAny?> _readRecord(IDBDatabase db, String alias) async {
  JSAny? value;
  try {
    await idbRun(db, webVaultKeyStore, 'readonly', (tx, store) {
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
  return value;
}

/// In one readwrite transaction: reads the record of [alias] and, only if
/// there is none, stores [candidate]. Readwrite transactions on one store run
/// one at a time, so of two openers racing here exactly one stores its key and
/// the other adopts it. Returns null when [candidate] was stored, else the
/// record found.
Future<JSAny?> _storeIfAbsent(
  IDBDatabase db,
  String alias,
  CryptoKey candidate,
) async {
  JSAny? existing;
  try {
    await idbRun(db, webVaultKeyStore, 'readwrite', (tx, store) {
      final request = store.get(alias);
      request.onsuccess = ((JSAny? _) {
        try {
          final found = request.result;
          if (found == null) {
            // A CryptoKey that cannot be cloned (DataCloneError) throws here.
            store.put(candidate, alias);
          } else {
            existing = found;
          }
        } on Object {
          abortQuietly(tx);
        }
      }).toJS;
    });
  } on Object {
    throw _unavailable;
  }
  return existing;
}

Future<void> _deleteRecord(_Env env, String alias) async {
  final db = await _openDb(env);
  try {
    await idbRun(db, webVaultKeyStore, 'readwrite', (tx, store) {
      store.delete(alias);
    });
  } on Object {
    throw _unavailable;
  } finally {
    db.close();
  }
}

/// [value] as the vault key, or null when it is not a non-extractable
/// AES-256-GCM secret key that can encrypt and decrypt.
CryptoKey? _asVaultKey(JSAny? value) {
  try {
    if (value == null || !value.isA<JSObject>()) return null;
    final object = value as JSObject;
    if (!object.instanceOfString('CryptoKey')) return null;
    final key = CryptoKey(object);
    final type = key.type;
    if (type == null || !type.isA<JSString>()) return null;
    if ((type as JSString).toDart != 'secret') return null;
    final extractable = key.extractable;
    if (extractable == null || !extractable.isA<JSBoolean>()) return null;
    if ((extractable as JSBoolean).toDart) return null;
    final algorithm = key.algorithm;
    if (algorithm == null || !algorithm.isA<JSObject>()) return null;
    final name = (algorithm as JSObject).getProperty<JSAny?>('name'.toJS);
    final length = algorithm.getProperty<JSAny?>('length'.toJS);
    if (name == null || !name.isA<JSString>()) return null;
    if ((name as JSString).toDart != 'AES-GCM') return null;
    if (length == null || !length.isA<JSNumber>()) return null;
    if ((length as JSNumber).toDartInt != 256) return null;
    final usages = key.usages;
    if (usages == null || !usages.isA<JSArray>()) return null;
    final names = {
      for (final u in (usages as JSArray).toDart)
        if (u != null && u.isA<JSString>()) (u as JSString).toDart,
    };
    if (!names.containsAll(const ['encrypt', 'decrypt'])) return null;
    return key;
  } on Object {
    return null;
  }
}

/// The vault cipher whose key is a non-extractable WebCrypto key in
/// IndexedDB.
class WebVaultCipher implements VaultCipher {
  WebVaultCipher._(this._env, this._alias, this._key, this.freshlyCreated);

  final _Env _env;
  final String _alias;

  // The key handle. Only here; opaque (non-extractable). Dropped by destroy.
  CryptoKey? _key;

  // Set first by destroy: new calls are refused while in-flight ones finish.
  bool _closing = false;
  int _inFlight = 0;
  Completer<void>? _drained;

  @override
  final bool freshlyCreated;

  /// Whether the browser has granted persistent storage to this origin (the
  /// latest answer this page has). Asked for once per page at open.
  bool get persisted => _pagePersisted;

  static Future<WebVaultCipher> _open(String alias) async {
    final env = _Env.require();
    await _requestPersistence();
    final db = await _openDb(env);
    try {
      final stored = await _readRecord(db, alias);
      if (stored != null) {
        final key = _asVaultKey(stored);
        if (key == null) throw _keyLost;
        return WebVaultCipher._(env, alias, key, false);
      }

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
      final candidate = _asVaultKey(generated);
      if (candidate == null) throw _unavailable;

      final existing = await _storeIfAbsent(db, alias, candidate);
      if (existing != null) {
        // Another opener (another tab, or a concurrent open here) won.
        final key = _asVaultKey(existing);
        if (key == null) throw _keyLost;
        return WebVaultCipher._(env, alias, key, false);
      }

      // Never hand out a key that is not really stored: read it back and use
      // the stored copy (some private modes cannot keep a CryptoKey).
      final back = _asVaultKey(await _readRecord(db, alias));
      if (back == null) throw _unavailable;
      return WebVaultCipher._(env, alias, back, true);
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
    if (_inFlight == 0) _drained?.complete();
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

  @override
  Future<void> destroy() async {
    if (_closing || _key == null) {
      throw StateError('The vault cipher was destroyed.');
    }
    // Refuse new calls first, let the ones in flight finish under the key,
    // then delete the record and drop the key.
    _closing = true;
    if (_inFlight > 0) {
      final drained = _drained = Completer<void>();
      await drained.future;
    }
    _key = null;
    await _deleteRecord(_env, _alias);
  }
}

/// [deleteVaultKey] on the web: [deleteWebVaultKey].
Future<void> platformDeleteVaultKey(String uid) => deleteWebVaultKey(uid);

/// [vaultStoragePersisted] on the web: [webVaultStoragePersisted].
Future<bool> platformVaultStoragePersisted() => webVaultStoragePersisted();
