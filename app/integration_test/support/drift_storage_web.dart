import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:drift/drift.dart';
import 'package:drift/wasm.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:dzeroth/core/storage/app_database.dart';

/// The storage a web open settled on, filled in once the database opens.
class OpenedStorage {
  String? implementation;
  List<String> missingFeatures = const [];
}

/// The production open (`AppDatabase._openConnection`): `driftDatabase` with
/// the same worker and wasm URIs, so drift picks the storage exactly as it does
/// for users. Only the name differs (a throwaway one), and `onResult` records
/// the choice instead of drift's default print.
QueryExecutor openLikeProduction(String name, OpenedStorage report) {
  return driftDatabase(
    name: name,
    web: DriftWebOptions(
      sqlite3Wasm: AppDatabase.sqlite3WasmUri,
      driftWorker: AppDatabase.driftWorkerUri,
      onResult: (result) {
        report
          ..implementation = result.chosenImplementation.name
          ..missingFeatures = [
            for (final feature in result.missingFeatures) feature.name,
          ];
      },
    ),
  );
}

/// The same worker and wasm, with drift's public API told to use
/// `sharedIndexedDb` (sqlite in the shared worker, persisted to IndexedDB):
/// what Chrome gets on the production site, which sends no cross-origin
/// isolation headers. Forced so the check holds whatever headers the test
/// server sends.
QueryExecutor openSharedIndexedDb(String name, OpenedStorage report) {
  return DatabaseConnection.delayed(
    Future(() async {
      final probed = await WasmDatabase.probe(
        sqlite3Uri: AppDatabase.sqlite3WasmUri,
        driftWorkerUri: AppDatabase.driftWorkerUri,
        databaseName: name,
      );
      const storage = WasmStorageImplementation.sharedIndexedDb;
      if (!probed.availableStorages.contains(storage)) {
        throw StateError(
          'sharedIndexedDb unavailable; drift offers '
          '${probed.availableStorages}, missing ${probed.missingFeatures}',
        );
      }
      report
        ..implementation = storage.name
        ..missingFeatures = [
          for (final feature in probed.missingFeatures) feature.name,
        ];
      return probed.open(storage, name);
    }),
  );
}

@JS('crossOriginIsolated')
external bool get _crossOriginIsolated;

/// Whether the page is cross-origin isolated (decides whether drift may use
/// OPFS with locks).
bool? get crossOriginIsolated => _crossOriginIsolated;

@JS('indexedDB')
external _IdbFactory get _indexedDB;

extension type _IdbFactory._(JSObject _) implements JSObject {
  external _IdbRequest open(String name);
  external _IdbRequest deleteDatabase(String name);
  external JSPromise<JSArray<_DatabaseInfo>> databases();
}

extension type _DatabaseInfo._(JSObject _) implements JSObject {
  external String get name;
}

extension type _IdbRequest._(JSObject _) implements JSObject {
  external JSAny? get result;
  external JSAny? get error;
  external _IdbTransaction? get transaction;
  external set onsuccess(JSFunction handler);
  external set onerror(JSFunction handler);
  external set onblocked(JSFunction handler);
  external set onupgradeneeded(JSFunction handler);
}

extension type _IdbDatabase._(JSObject _) implements JSObject {
  external _IdbTransaction transaction(JSArray<JSString> stores, String mode);
  external void close();
}

extension type _IdbTransaction._(JSObject _) implements JSObject {
  external _IdbStore objectStore(String name);
  external void abort();
}

extension type _IdbStore._(JSObject _) implements JSObject {
  external _IdbRequest getAll();
  external _IdbRequest getAllKeys();
}

extension type _Blob._(JSObject _) implements JSObject {
  external JSPromise<JSArrayBuffer> arrayBuffer();
}

Future<JSAny?> _complete(_IdbRequest request) {
  final completer = Completer<JSAny?>();
  request
    ..onsuccess = ((JSAny? _) => completer.complete(request.result)).toJS
    ..onerror = ((JSAny? _) => completer.completeError(
      StateError('IndexedDB request failed: ${request.error}'),
    )).toJS;
  return completer.future;
}

/// The bytes of [path] in the IndexedDB database drift keeps for
/// [databaseName], read on the page through a separate IndexedDB connection,
/// never through drift or sqlite. Null while that database or file does not
/// exist yet.
///
/// The layout is package:sqlite3's IndexedDB file system (the one drift
/// persists to): object store `files` (auto-increment id -> `{name, length}`)
/// and `blocks` (`[fileId, offset]` -> 4096-byte ArrayBuffer or Blob).
Future<Uint8List?> readPersistedFile(String databaseName, String path) async {
  // Never open a name that does not exist: a bare open would create an empty
  // version-1 database, and drift's own upgrade would then never run.
  final existing = (await _indexedDB.databases().toDart).toDart;
  if (!existing.any((info) => info.name == databaseName)) return null;

  final request = _indexedDB.open(databaseName);
  request.onupgradeneeded = ((JSAny? _) => request.transaction?.abort()).toJS;
  final database = (await _complete(request))! as _IdbDatabase;
  try {
    final transaction = database.transaction(
      ['files'.toJS, 'blocks'.toJS].toJS,
      'readonly',
    );
    final files = transaction.objectStore('files');
    final blocks = transaction.objectStore('blocks');
    // All four requests go out before the first await: a transaction with no
    // pending request commits at the end of the task.
    final fileIds = _complete(files.getAllKeys());
    final fileEntries = _complete(files.getAll());
    final blockKeys = _complete(blocks.getAllKeys());
    final blockValues = _complete(blocks.getAll());

    final ids = (await fileIds)! as JSArray<JSNumber>;
    final entries = (await fileEntries)! as JSArray<JSObject>;
    final keys = (await blockKeys)! as JSArray<JSArray<JSNumber>>;
    final values = (await blockValues)! as JSArray<JSObject>;

    int? fileId;
    var length = 0;
    for (var i = 0; i < ids.length; i++) {
      final entry = entries[i];
      if ((entry['name']! as JSString).toDart == path) {
        fileId = ids[i].toDartInt;
        length = (entry['length']! as JSNumber).toDartInt;
      }
    }
    if (fileId == null) return null;

    final bytes = Uint8List(length);
    for (var i = 0; i < keys.length; i++) {
      final key = keys[i];
      if (key[0].toDartInt != fileId) continue;
      final offset = key[1].toDartInt;
      if (offset >= length) continue;
      // A block is an ArrayBuffer, or a Blob in databases written by older
      // package:sqlite3 versions; read either way, as package:sqlite3 does.
      final value = values[i];
      final buffer = value.instanceOfString('Blob')
          ? await (value as _Blob).arrayBuffer().toDart
          : value as JSArrayBuffer;
      final block = buffer.toDart.asUint8List();
      final end = offset + block.length > length
          ? length
          : offset + block.length;
      bytes.setRange(offset, end, block);
    }
    return bytes;
  } finally {
    database.close();
  }
}

/// Deletes [databaseName]'s IndexedDB database; gives up quietly after a few
/// seconds when another connection (the shared worker) still holds it open.
Future<void> deletePersisted(String databaseName) async {
  final request = _indexedDB.deleteDatabase(databaseName);
  final done = Completer<void>();
  request
    ..onsuccess = ((JSAny? _) => done.complete()).toJS
    ..onerror = ((JSAny? _) => done.complete()).toJS
    ..onblocked = ((JSAny? _) => done.complete()).toJS;
  await done.future.timeout(const Duration(seconds: 3), onTimeout: () {});
}
