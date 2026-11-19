// Hand-written JS interop for the web vault key: exactly the parts of
// WebCrypto (`crypto.subtle`, `crypto.getRandomValues`), IndexedDB and
// `navigator.storage` that vault_cipher_web.dart uses, plus Future wrappers
// for IndexedDB requests and transactions and for promises.
//
// Web only (imports dart:js_interop); reached through the conditional import
// in vault_cipher.dart. Nothing here logs anything.
import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

// Globals ---------------------------------------------------------------------

@JS('isSecureContext')
external JSAny? get _isSecureContext;

@JS('crypto')
external JSAny? get _crypto;

@JS('indexedDB')
external JSAny? get _indexedDB;

@JS('navigator')
external JSAny? get _navigator;

JSObject? _objectOrNull(JSAny? Function() read) {
  try {
    final value = read();
    return value != null && value.isA<JSObject>() ? value as JSObject : null;
  } on Object {
    // Some browsers throw (SecurityError) on access instead of hiding it.
    return null;
  }
}

/// True only when the page is a secure context (https or localhost).
bool get webSecureContext {
  try {
    final value = _isSecureContext;
    return value != null &&
        value.isA<JSBoolean>() &&
        (value as JSBoolean).toDart;
  } on Object {
    return false;
  }
}

/// `globalThis.crypto`, or null when it is missing or cannot be read.
WebCrypto? cryptoOrNull() {
  final o = _objectOrNull(() => _crypto);
  return o == null ? null : WebCrypto(o);
}

/// `globalThis.indexedDB`, or null when it is missing or cannot be read.
IDBFactory? indexedDBOrNull() {
  final o = _objectOrNull(() => _indexedDB);
  return o == null ? null : IDBFactory(o);
}

/// `navigator.storage`, or null when it is missing or cannot be read.
StorageManager? storageManagerOrNull() {
  final navigator = _objectOrNull(() => _navigator);
  if (navigator == null) return null;
  final o = _objectOrNull(() => navigator.getProperty<JSAny?>('storage'.toJS));
  return o == null ? null : StorageManager(o);
}

// WebCrypto -------------------------------------------------------------------

extension type WebCrypto(JSObject _) implements JSObject {
  /// Null outside a secure context.
  SubtleCrypto? get subtle {
    final o = _objectOrNull(() => getProperty<JSAny?>('subtle'.toJS));
    return o == null ? null : SubtleCrypto(o);
  }

  /// Fills [array] in place (and returns it). [array] must be a JS-side array:
  /// under dart2wasm a converted Dart list is a copy.
  external JSUint8Array getRandomValues(JSUint8Array array);
}

extension type SubtleCrypto(JSObject _) implements JSObject {
  external JSPromise<JSAny?> generateKey(
    JSObject algorithm,
    bool extractable,
    JSArray<JSString> keyUsages,
  );

  external JSPromise<JSAny?> encrypt(
    JSObject algorithm,
    CryptoKey key,
    JSUint8Array data,
  );

  external JSPromise<JSAny?> decrypt(
    JSObject algorithm,
    CryptoKey key,
    JSUint8Array data,
  );

  /// Used only by tests, to show the vault key cannot be exported.
  external JSPromise<JSAny?> exportKey(String format, CryptoKey key);
}

/// A WebCrypto `CryptoKey`. Opaque: its bytes are never readable here.
extension type CryptoKey(JSObject _) implements JSObject {
  external JSAny? get type;
  external JSAny? get extractable;
  external JSAny? get algorithm;
  external JSAny? get usages;
}

// IndexedDB -------------------------------------------------------------------

extension type IDBFactory(JSObject _) implements JSObject {
  external IDBOpenDBRequest open(String name, int version);
}

extension type IDBRequest(JSObject _) implements JSObject {
  /// Readable only after `success` (it throws before, and after `error`).
  external JSAny? get result;
  external set onsuccess(JSFunction? handler);
  external set onerror(JSFunction? handler);
}

extension type IDBOpenDBRequest(JSObject _) implements IDBRequest {
  /// The database, after `success` or inside `upgradeneeded`.
  @JS('result')
  external IDBDatabase get database;

  /// The versionchange transaction, inside `upgradeneeded`.
  external IDBTransaction? get transaction;
  external set onupgradeneeded(JSFunction? handler);
  external set onblocked(JSFunction? handler);
}

extension type IDBDatabase(JSObject _) implements JSObject {
  external DOMStringList get objectStoreNames;
  external IDBObjectStore createObjectStore(String name);
  external IDBTransaction transaction(String storeNames, String mode);

  /// [transaction] with options (`{durability: 'strict'}`); browsers ignore
  /// members they do not know.
  @JS('transaction')
  external IDBTransaction transactionWith(
    String storeNames,
    String mode,
    JSObject options,
  );
  external void close();
  external set onversionchange(JSFunction? handler);
}

extension type DOMStringList(JSObject _) implements JSObject {
  external bool contains(String value);
}

extension type IDBTransaction(JSObject _) implements JSObject {
  external IDBObjectStore objectStore(String name);
  external void abort();
  external set oncomplete(JSFunction? handler);
  external set onabort(JSFunction? handler);
}

extension type IDBObjectStore(JSObject _) implements JSObject {
  external IDBRequest get(String key);
  external IDBRequest put(JSAny? value, String key);

  /// Fails with ConstraintError when [key] already has a record.
  external IDBRequest add(JSAny? value, String key);

  /// The number of records with [key] (all records for null).
  external IDBRequest count(JSAny? key);
  external IDBRequest delete(String key);
}

// navigator.storage -----------------------------------------------------------

extension type StorageManager(JSObject _) implements JSObject {
  external JSPromise<JSAny?> persist();
  external JSPromise<JSAny?> persisted();
}

// Futures ---------------------------------------------------------------------

/// A rejected promise or a failed IndexedDB operation. [name] is the
/// DOMException name when there was one (`OperationError`, `QuotaExceededError`,
/// `AbortError`, ...). Carries no data.
class WebOperationError implements Exception {
  const WebOperationError(this.name);

  final String name;

  @override
  String toString() => 'WebOperationError($name)';
}

String _errorName(JSAny? reason) {
  try {
    if (reason != null && reason.isA<JSObject>()) {
      final name = (reason as JSObject).getProperty<JSAny?>('name'.toJS);
      if (name != null && name.isA<JSString>()) {
        return (name as JSString).toDart;
      }
    }
  } on Object {
    // Fall through.
  }
  return 'Error';
}

/// [promise] as a Future; a rejection becomes [WebOperationError] with the
/// rejection's `name`, the same under dart2js and dart2wasm.
Future<JSAny?> settle(JSPromise<JSAny?> promise) {
  final completer = Completer<JSAny?>();
  try {
    promise.callMethod<JSAny?>(
      'then'.toJS,
      ((JSAny? value) {
        completer.complete(value);
      }).toJS,
      ((JSAny? reason) {
        completer.completeError(WebOperationError(_errorName(reason)));
      }).toJS,
    );
  } on Object {
    return Future.error(const WebOperationError('Error'));
  }
  return completer.future;
}

/// Opens database [name] at [version]. [onUpgrade] runs inside the
/// versionchange transaction (create stores there); if it throws, the upgrade
/// is aborted. An error, an abort, a `blocked` open or no answer within
/// [timeout] completes with [WebOperationError]; a connection that opens
/// after such a failure is closed at once. The connection closes itself when
/// another one needs a version change, so it never blocks one.
Future<IDBDatabase> idbOpen(
  IDBFactory factory,
  String name,
  int version,
  void Function(IDBDatabase db) onUpgrade, {
  Duration timeout = const Duration(seconds: 10),
}) {
  final completer = Completer<IDBDatabase>();
  final IDBOpenDBRequest request;
  try {
    request = factory.open(name, version);
  } on Object {
    return Future.error(const WebOperationError('Error'));
  }
  final timer = Timer(timeout, () {
    if (!completer.isCompleted) {
      completer.completeError(const WebOperationError('TimeoutError'));
    }
  });
  completer.future
      .then<void>((_) {}, onError: (Object _) {})
      .whenComplete(timer.cancel);
  request
    ..onupgradeneeded = ((JSAny? _) {
      try {
        onUpgrade(request.database);
      } on Object {
        try {
          request.transaction?.abort();
        } on Object {
          // Already finished; the request's error event follows.
        }
      }
    }).toJS
    ..onsuccess = ((JSAny? _) {
      final IDBDatabase db;
      try {
        db = request.database;
      } on Object {
        if (!completer.isCompleted) {
          completer.completeError(const WebOperationError('Error'));
        }
        return;
      }
      if (completer.isCompleted) {
        // We already gave up on this open (blocked, timed out or failed).
        db.close();
        return;
      }
      db.onversionchange = ((JSAny? _) => db.close()).toJS;
      completer.complete(db);
    }).toJS
    ..onerror = ((JSAny? event) {
      if (!completer.isCompleted) {
        completer.completeError(WebOperationError(_requestErrorName(request)));
      }
    }).toJS
    ..onblocked = ((JSAny? _) {
      if (!completer.isCompleted) {
        completer.completeError(const WebOperationError('BlockedError'));
      }
    }).toJS;
  return completer.future;
}

String _requestErrorName(JSObject target) {
  try {
    return _errorName(target.getProperty<JSAny?>('error'.toJS));
  } on Object {
    return 'Error';
  }
}

/// Runs one transaction on [store] of [db] in [mode] (`readonly` or
/// `readwrite`) and completes when the transaction has committed (its
/// `complete` event), not when its requests succeed. With the browser's
/// default durability a commit is not necessarily flushed to disk yet.
///
/// [body] runs synchronously and issues the requests; request callbacks it
/// sets also run synchronously inside the transaction, so a read followed by
/// a conditional write stays in one transaction (no Dart `await` between
/// them). A request error that is not handled aborts the transaction. Any
/// abort, a failure to start the transaction or an exception in [body]
/// completes with [WebOperationError].
Future<void> idbRun(
  IDBDatabase db,
  String store,
  String mode,
  void Function(IDBTransaction tx, IDBObjectStore store) body, {
  bool strict = false,
}) {
  final completer = Completer<void>();
  final IDBTransaction tx;
  try {
    tx = strict
        ? db.transactionWith(
            store,
            mode,
            JSObject()..setProperty('durability'.toJS, 'strict'.toJS),
          )
        : db.transaction(store, mode);
    tx
      ..oncomplete = ((JSAny? _) {
        if (!completer.isCompleted) completer.complete();
      }).toJS
      ..onabort = ((JSAny? _) {
        if (!completer.isCompleted) {
          completer.completeError(WebOperationError(_requestErrorName(tx)));
        }
      }).toJS;
  } on Object {
    return Future.error(const WebOperationError('Error'));
  }
  try {
    body(tx, tx.objectStore(store));
  } on Object {
    abortQuietly(tx);
  }
  return completer.future;
}

/// Aborts [tx], ignoring an already finished transaction. The transaction's
/// `abort` event then fails the [idbRun] future.
void abortQuietly(IDBTransaction tx) {
  try {
    tx.abort();
  } on Object {
    // Already committing or finished.
  }
}
