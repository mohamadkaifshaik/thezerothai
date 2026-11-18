import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/wasm.dart';

import '../storage/app_database.dart' show AppDatabase;
import 'vault_open.dart' show checkVaultWebResult;

/// The vault database [name] in this browser, on the same checked-in
/// `sqlite3.wasm` and drift worker as the cache (the worker serves any
/// number of database names).
///
/// This calls `WasmDatabase.open` (what drift_flutter's `driftDatabase`
/// wraps) and checks its result with [checkVaultWebResult], the vault's
/// `onResult`, BEFORE a database object exists. drift_flutter would hand
/// the same result to `DriftWebOptions.onResult`, but inside
/// `DatabaseConnection.delayed`, where a refusal also fails two internal
/// futures nobody listens to (reported as uncaught errors). A refused
/// storage is closed and never queried, so no schema is written to it.
Future<DatabaseConnection> openPlatformVaultConnection(String name) async {
  final result = await WasmDatabase.open(
    databaseName: name,
    sqlite3Uri: AppDatabase.sqlite3WasmUri,
    driftWorkerUri: AppDatabase.driftWorkerUri,
  );
  checkVaultWebResult(result);
  return result.resolvedExecutor;
}
