import 'package:drift/drift.dart';
import 'package:drift/wasm.dart';

import 'app_database.dart';

/// Drift's in-memory WebAssembly storage, chosen explicitly instead of the
/// best one the browser offers. Touches neither OPFS nor IndexedDB.
QueryExecutor inMemoryCacheExecutor() => DatabaseConnection.delayed(
  Future(() async {
    final probed = await WasmDatabase.probe(
      sqlite3Uri: AppDatabase.sqlite3WasmUri,
      driftWorkerUri: AppDatabase.driftWorkerUri,
    );
    return probed.open(WasmStorageImplementation.inMemory, 'dzeroth_memory');
  }),
);
