import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/wasm.dart';

import '../storage/app_database.dart' show AppDatabase;
import 'vault_database.dart';
import 'vault_open.dart'
    show
        VaultWipeStop,
        checkVaultWipeListed,
        chooseVaultWebStorage,
        isTrustedVaultWebProbe,
        wipeVaultDatabase;
import 'vault_status.dart';

WasmStorageImplementation? _lastWebStorage;

/// The storage chosen for the last vault database opened here.
WasmStorageImplementation? get lastWebStorage => _lastWebStorage;

Future<WasmProbeResult> _probe(String name) => WasmDatabase.probe(
  sqlite3Uri: AppDatabase.sqlite3WasmUri,
  driftWorkerUri: AppDatabase.driftWorkerUri,
  databaseName: name,
);

/// The vault database [name] in this browser, on the same checked-in
/// `sqlite3.wasm` and drift worker as the cache (the worker serves any
/// number of database names).
///
/// It probes first (`WasmDatabase.probe` with the name, so IndexedDB and
/// OPFS copies of this database are both listed) and decides with
/// [chooseVaultWebStorage] BEFORE anything is opened: a refused storage, or
/// a vault that exists under another storage than the one this browser
/// would use now, throws [VaultOpenException] and nothing is opened or
/// written. drift_flutter's `onResult` is not used: it only runs after
/// drift has already picked and opened a storage, and a throw there fails
/// two internal futures nobody listens to (uncaught errors).
///
/// A probe whose worker failed (`MissingBrowserFeature.workerError`) may
/// not list an existing vault, so it is refused ([VaultStatus.unavailable])
/// and nothing is opened. Other gaps that can hide a copy are not detected
/// (see `isTrustedVaultWebProbe`).
///
/// A refused probe's workers are not closed: drift 2.35.4's
/// `WasmProbeResult` exposes no way to dispose of them (its workers are
/// private to drift's opener). The shared worker is the one the cache
/// database uses anyway; each refused open can leave one idle dedicated
/// worker until the page unloads, so callers must not retry in a loop.
///
/// [expectedStorage] (the session's storage marker) goes to the chooser:
/// a marked vault that is not listed there is refused before anything is
/// created. Returns the connection and the chosen storage's name.
Future<(DatabaseConnection, String)> openPlatformVaultConnection(
  String name, {
  String? expectedStorage,
}) async {
  final probed = await _probe(name);
  final chosen = chooseVaultWebStorage(
    available: probed.availableStorages,
    existing: probed.existingDatabases,
    missingFeatures: probed.missingFeatures,
    name: name,
    expectedStorage: expectedStorage,
  );
  _lastWebStorage = chosen;
  return (await probed.open(chosen, name), chosen.name);
}

/// Web: every drift database named [name] loses its rows (opened with any
/// storage of its API, the unsafe IndexedDB one included, for this one
/// short operation) and is rebuilt (`VACUUM`, `secure_delete` on). Then:
///
/// - an OPFS copy is deleted with drift's `deleteDatabase` (best effort: a
///   file still held by a worker is refused at once, never deleted later);
/// - an IndexedDB copy is NOT deleted and stays as an empty vault schema.
///   An IndexedDB delete that is blocked by a connection (drift's shared
///   worker keeps one until its last client has gone) cannot be cancelled:
///   it would run later and could delete a vault opened again in the
///   meantime. drift's own helper also throws an uncaught error when
///   blocked.
///
/// A copy whose rows cannot be deleted fails with
/// [VaultStatus.unavailable] (an OPFS copy that could be deleted instead
/// is fine).
///
/// A probe whose worker failed is refused ([VaultStatus.unavailable]) and
/// nothing is deleted: it may not list every copy, and a wipe that reports
/// success while a copy survives would be wrong. Likewise when
/// [expectedStorage] is given and no copy is listed under it
/// ([checkVaultWipeListed]).
///
/// [stop] (see `runAbandonableVaultWipe`): the probe and the opens are
/// unbounded here, so a wipe can resume long after its caller gave up and
/// the session opened a fresh vault. [stop] is asked after the probe, after
/// each open (a connection that arrives then is closed unused), inside the
/// row delete, before `VACUUM` and before each `deleteDatabase`; true is
/// [VaultStatus.unavailable] and nothing more is deleted.
Future<void> wipePlatformVaultFile(
  String name, {
  String? expectedStorage,
  required VaultWipeStop stop,
}) async {
  void halt() {
    if (stop()) throw const VaultOpenException(VaultStatus.unavailable);
  }

  final probed = await _probe(name);
  halt();
  if (!isTrustedVaultWebProbe(probed.missingFeatures)) {
    throw const VaultOpenException(VaultStatus.unavailable);
  }
  checkVaultWipeListed(
    existing: probed.existingDatabases,
    name: name,
    expectedStorage: expectedStorage,
  );
  final ranked = [...probed.availableStorages]
    ..sort((a, b) => a.index - b.index);
  final mine = {
    for (final (api, existingName) in probed.existingDatabases)
      if (existingName == name) api,
  };
  for (final api in mine) {
    halt();
    var rowsGone = false;
    final storages = ranked.where((s) => s.storageApi == api);
    if (storages.isNotEmpty) {
      try {
        // A connection that arrives after [stop] turned true is closed
        // unused by wipeVaultDatabase (it asks [stop] first, then closes).
        await wipeVaultDatabase(
          VaultDatabase(await probed.open(storages.first, name)),
          stop: stop,
        );
        rowsGone = true;
      } catch (_) {
        // An OPFS copy may still be deleted below (unless stopped).
      }
    }
    halt();
    var deleted = false;
    if (api == WebStorageApi.opfs) {
      try {
        await probed
            .deleteDatabase((api, name))
            .timeout(const Duration(seconds: 10));
        deleted = true;
      } catch (_) {
        // Rows are gone (or not: checked below); the empty file stays.
      }
    }
    if (!rowsGone && !deleted) {
      throw const VaultOpenException(VaultStatus.unavailable);
    }
  }
}
