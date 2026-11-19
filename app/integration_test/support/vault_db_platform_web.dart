import 'package:drift/wasm.dart';
import 'package:dzeroth/core/storage/app_database.dart';
import 'package:dzeroth/core/vault/vault_database.dart';

/// Not on Android: there is no vault file.
Future<({String path, int secureDelete})?> inspectNativeVaultFile(
  String name,
) async => null;

/// Not on Android: no files.
Future<List<String>> existingFilesOf(String path) async => const [];

Future<WasmProbeResult> _probe(String name) => WasmDatabase.probe(
  sqlite3Uri: AppDatabase.sqlite3WasmUri,
  driftWorkerUri: AppDatabase.driftWorkerUri,
  databaseName: name,
);

/// The storage APIs (`indexedDb`, `opfs`) under which drift's probe lists a
/// database called [name], sorted.
Future<List<String>> existingWebStorageApis(String name) async {
  final probed = await _probe(name);
  return [
    for (final (api, existing) in probed.existingDatabases)
      if (existing == name) api.name,
  ]..sort();
}

/// Creates an (empty) vault schema called [name] in IndexedDB through the
/// shared worker, next to whatever exists already. False when that storage
/// is missing in this browser.
Future<bool> createIndexedDbCopy(String name) async {
  final probed = await _probe(name);
  if (!probed.availableStorages.contains(
    WasmStorageImplementation.sharedIndexedDb,
  )) {
    return false;
  }
  final db = VaultDatabase(
    await probed.open(WasmStorageImplementation.sharedIndexedDb, name),
  );
  try {
    await db.customStatement('CREATE TABLE IF NOT EXISTS copy (x INTEGER)');
    await db.customStatement('INSERT INTO copy VALUES (1)');
  } finally {
    await db.close();
  }
  return true;
}
