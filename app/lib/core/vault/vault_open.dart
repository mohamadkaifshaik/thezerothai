import 'dart:async';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift_flutter/drift_flutter.dart'
    show
        ExistingDatabase,
        MissingBrowserFeature,
        WasmStorageImplementation,
        WebStorageApi;
import 'package:flutter/foundation.dart' show visibleForTesting;

import 'secure_vault.dart';
import 'vault_cipher.dart';
import 'vault_database.dart';
import 'vault_open_io.dart'
    if (dart.library.js_interop) 'vault_open_web.dart'
    as impl;
import 'vault_status.dart';

/// The drift web storages the vault accepts: only those that keep data
/// across reloads AND are safe when more than one tab opens the database.
///
/// - [WasmStorageImplementation.opfsShared], [WasmStorageImplementation.opfsLocks]:
///   the origin-private file system, behind one shared worker or with Web
///   Locks around every access.
/// - [WasmStorageImplementation.sharedIndexedDb]: IndexedDB behind one
///   shared worker that serialises every tab. Its writes reach IndexedDB
///   asynchronously after a commit (no durability guarantee at commit).
///
/// Refused:
/// - [WasmStorageImplementation.inMemory]: keeps nothing.
/// - [WasmStorageImplementation.unsafeIndexedDb]: a per-tab copy of the file
///   over IndexedDB with no cross-tab coordination; drift documents it as
///   unable to prevent data races between tabs. Single-tab ownership of the
///   vault comes from a Web Lock taken by a later task, which this open
///   cannot verify; without it two tabs could overwrite each other's MLS
///   state, which is not recoverable. Widen this set only together with
///   that guarantee (the vault session holding the lock before opening).
const Set<WasmStorageImplementation> kVaultAcceptedWebStorages = {
  WasmStorageImplementation.opfsShared,
  WasmStorageImplementation.opfsLocks,
  WasmStorageImplementation.sharedIndexedDb,
};

/// Whether the vault may live on the web storage drift chose.
bool isAcceptedVaultWebStorage(WasmStorageImplementation chosen) =>
    kVaultAcceptedWebStorages.contains(chosen);

/// False when drift's probe reported a failed worker
/// ([MissingBrowserFeature.workerError], which drift swallows): such a
/// probe is refused before both opening and wiping on the web.
///
/// True does NOT mean every existing copy was listed. Other gaps can also
/// hide an existing copy and are NOT detected here: a missing
/// [MissingBrowserFeature.fileSystemAccess] or
/// [MissingBrowserFeature.indexedDb], missing dedicated workers together
/// with missing nested workers, and a silent false answer from drift's
/// existence check. The storage-marker task (outside the vault) covers
/// those.
bool isTrustedVaultWebProbe(Set<MissingBrowserFeature> missingFeatures) =>
    !missingFeatures.contains(MissingBrowserFeature.workerError);

/// The web storage the vault database [name] opens on, from drift's probe:
/// the storages this browser offers ([available]), the drift databases
/// that already exist ([existing], as `(storage API, name)`) and what the
/// probe could not check ([missingFeatures]).
///
/// - [missingFeatures] contains [MissingBrowserFeature.workerError]: the
///   probe is refused and the result is [VaultOpenException] with
///   [VaultStatus.unavailable]. drift swallows a failed worker and only
///   records this flag; the databases that worker would have listed (an
///   OPFS vault, say) are then missing from [existing], and opening would
///   create an empty vault next to the real one.
///
/// Otherwise this mirrors drift's own choice in `WasmDatabase.open`: a
/// database that already exists stays in its storage API while some
/// storage of that API is available (the best one is used); otherwise the
/// best available storage. Then:
///
/// - a database named [name] exists under another storage API than the
///   choice (or under two): [VaultStatus.storageChanged]. Opening would
///   show an empty vault as ready while the real one sits in the other
///   storage.
/// - the choice is not in [kVaultAcceptedWebStorages]:
///   [VaultStatus.unavailable].
///
/// - [expectedStorage] (the storage marker the vault session keeps outside
///   the vault: the [WasmStorageImplementation.name] the vault was created
///   in) is given and no copy of [name] is listed under that storage's API,
///   or the storage this would choose is of another API:
///   [VaultStatus.storageChanged], decided BEFORE anything is opened or
///   created. This closes the probe gaps listed below: a copy the probe
///   cannot see is never answered with a new, empty vault. Storages are
///   compared by API ([WebStorageApi]): `opfsShared` and `opfsLocks` reach
///   the same OPFS file. A name that is not an accepted web storage is
///   [VaultStatus.unavailable] (fail closed). Null: no marker (a first run).
///
/// Never [VaultStatus.keyLost]. Pure, so the VM tests cover every case.
///
/// Known limit without [expectedStorage]: only `workerError` is detected. A
/// copy can also be missing from [existing] without it: when
/// `fileSystemAccess` or `indexedDb` is missing, when dedicated workers are
/// missing together with nested workers, or when drift's existence check
/// silently answers "not present". The storage marker ([expectedStorage])
/// closes them.
WasmStorageImplementation chooseVaultWebStorage({
  required Iterable<WasmStorageImplementation> available,
  required Iterable<ExistingDatabase> existing,
  required Set<MissingBrowserFeature> missingFeatures,
  required String name,
  String? expectedStorage,
}) {
  if (!isTrustedVaultWebProbe(missingFeatures)) {
    throw const VaultOpenException(VaultStatus.unavailable);
  }
  final ranked = [...available]..sort((a, b) => a.index - b.index);
  final mine = [
    for (final (api, existingName) in existing)
      if (existingName == name) api,
  ];
  var chosen = ranked.isEmpty
      ? WasmStorageImplementation.inMemory
      : ranked.first;
  for (final api in mine) {
    final sameApi = ranked.where((s) => s.storageApi == api);
    if (sameApi.isNotEmpty) {
      chosen = sameApi.first;
      break;
    }
  }
  if (expectedStorage != null) {
    final expectedApi = vaultWebStorageApi(expectedStorage);
    if (expectedApi == null) {
      throw const VaultOpenException(VaultStatus.unavailable);
    }
    if (!mine.contains(expectedApi) || chosen.storageApi != expectedApi) {
      throw const VaultOpenException(VaultStatus.storageChanged);
    }
  }
  if (mine.any((api) => api != chosen.storageApi)) {
    throw const VaultOpenException(VaultStatus.storageChanged);
  }
  if (!isAcceptedVaultWebStorage(chosen)) {
    throw const VaultOpenException(VaultStatus.unavailable);
  }
  return chosen;
}

/// The storage API of an accepted web storage name
/// ([WasmStorageImplementation.name] in [kVaultAcceptedWebStorages]); null
/// for any other name (`native`, `inMemory`, `unsafeIndexedDb`, garbage).
WebStorageApi? vaultWebStorageApi(String storageName) {
  for (final s in kVaultAcceptedWebStorages) {
    if (s.name == storageName) return s.storageApi;
  }
  return null;
}

/// The web wipe's marker check: throws [VaultOpenException] with
/// [VaultStatus.unavailable] when [expectedStorage] is given and no copy of
/// [name] is listed under its storage API (or the name is not an accepted
/// web storage). Null passes. Pure, for the VM tests.
void checkVaultWipeListed({
  required Iterable<ExistingDatabase> existing,
  required String name,
  required String? expectedStorage,
}) {
  if (expectedStorage == null) return;
  final api = vaultWebStorageApi(expectedStorage);
  final listed = existing.any((e) => e.$1 == api && e.$2 == name);
  if (api == null || !listed) {
    throw const VaultOpenException(VaultStatus.unavailable);
  }
}

/// The value of [SecureVault.storageName] for a vault on Android.
const String kVaultNativeStorage = 'native';

/// The storage chosen for the last vault database opened on the web; null
/// elsewhere or before any open.
@visibleForTesting
WasmStorageImplementation? get lastVaultWebStorage => impl.lastWebStorage;

/// How long opening or wiping the platform storage may take.
const Duration _platformTimeout = Duration(seconds: 30);

Future<void> _closeConnection(DatabaseConnection connection) async {
  try {
    await connection.executor.close();
  } catch (_) {
    // Dropped either way.
  }
}

/// Opens the platform connection of [uid]'s vault and names the storage it
/// is on; failures are [VaultOpenException]. A connection that arrives
/// after the timeout is closed.
Future<(VaultDatabase, String)> _openDatabase(
  String uid,
  String? expectedStorage,
) async {
  if (uid.isEmpty) throw ArgumentError.value(uid, 'uid', 'empty');
  final pending = impl.openPlatformVaultConnection(
    vaultDatabaseName(uid),
    expectedStorage: expectedStorage,
  );
  try {
    final (connection, storage) = await pending.timeout(_platformTimeout);
    return (VaultDatabase(connection), storage);
  } on VaultOpenException {
    rethrow;
  } on TimeoutException {
    unawaited(
      pending.then((r) => _closeConnection(r.$1), onError: (Object _) {}),
    );
    throw const VaultOpenException(VaultStatus.unavailable);
  } catch (_) {
    throw const VaultOpenException(VaultStatus.unavailable);
  }
}

/// Opens [uid]'s vault with [cipher] (the cipher of the same [uid]).
///
/// One database per user, `vaultDatabaseName(uid)`: on Android
/// `<name>.sqlite` in the app's private documents directory; on the web an
/// OPFS file or a shared-worker IndexedDB database (see
/// [chooseVaultWebStorage]). Never in memory. Never deletes a row.
///
/// [expectedStorage] is the storage marker the session keeps outside the
/// vault ([SecureVault.storageName] of the open that created it). On the web
/// it is checked by [chooseVaultWebStorage] before anything is opened or
/// created; null keeps the plain probe decision. Ignored on Android.
///
/// Throws [VaultOpenException]: [VaultStatus.unsupported] on any platform
/// but Android and the web; [VaultStatus.storageChanged] on the web when
/// the vault exists in another storage than this browser would use now, or
/// is not listed under [expectedStorage];
/// [VaultStatus.unavailable] when the storage cannot be opened or is not
/// durable, or the cipher cannot run; [VaultStatus.keyLost] when the
/// sentinel shows the key no longer opens this vault (the file is left
/// untouched). See [openVaultOnDatabase].
Future<SecureVault> openVault({
  required String uid,
  required VaultCipher cipher,
  String? expectedStorage,
}) async {
  final (db, storage) = await _openDatabase(uid, expectedStorage);
  return openVaultOnDatabase(
    db,
    uid: uid,
    cipher: cipher,
    registerAs: vaultDatabaseName(uid),
    storageName: storage,
  );
}

/// Erases every copy of [uid]'s vault that the platform can find: on
/// Android the one file; on the web every copy drift's storage probe LISTS
/// (OPFS and IndexedDB). A web copy in a storage the probe cannot list
/// survives, and without [expectedStorage] this call still succeeds; with
/// it, an unlisted marked copy makes the wipe refuse instead. No cipher is
/// needed (so it works when the key is lost or unavailable). Delete the
/// platform key separately (`deleteVaultKey`), after this succeeds.
///
/// Call it ONLY for an explicit user reset or sign-out, for a previous user
/// when a different user signs in, or after a key loss the session has
/// confirmed. NEVER call it because of [VaultStatus.storageChanged]: that
/// status means the history exists in another storage, and this would
/// destroy it.
///
/// Throws [StateError] while a vault of [uid] opened by [openVault] is open
/// in this process (close it first). Another tab is not seen by that check.
///
/// Every row is deleted and the file rebuilt (`VACUUM`, with
/// `secure_delete` on), then the storage itself is removed where the
/// platform allows it:
/// - Android: the `.sqlite` file and its `-journal`/`-wal`/`-shm` sidecars.
/// - Web: an OPFS copy is deleted (best effort: a file still held by a
///   worker is refused; its rows are already gone). An IndexedDB copy
///   stays as an empty, rebuilt vault schema, because a blocked IndexedDB
///   delete cannot be cancelled and could later delete a vault reopened in
///   the meantime (see `vault_open_web.dart`).
///
/// Must not run while a [SecureVault] of [uid] is open. Throws
/// [VaultOpenException] ([VaultStatus.unsupported],
/// [VaultStatus.unavailable] when the rows could not be deleted).
///
/// [expectedStorage] (the session's storage marker): on the web, when no
/// copy is listed under that storage's API the wipe throws
/// [VaultStatus.unavailable] and deletes nothing, so it never reports
/// success while the real copy is unlisted. Null (the explicit reset of a
/// `storageChanged` vault) erases whatever is listed. Ignored on Android.
Future<void> wipeVaultFile({
  required String uid,
  String? expectedStorage,
}) async {
  if (uid.isEmpty) throw ArgumentError.value(uid, 'uid', 'empty');
  return wipeVaultFileForAlias(
    alias: vaultKeyAlias(uid),
    expectedStorage: expectedStorage,
  );
}

/// [wipeVaultFile] by the vault's key [alias] ([vaultKeyAlias] of the uid),
/// for a caller that keeps no uid (the vault session's markers). A value
/// that is not an alias fails with [ArgumentError]; otherwise the same
/// contract as [wipeVaultFile].
Future<void> wipeVaultFileForAlias({
  required String alias,
  String? expectedStorage,
}) async {
  final name = vaultDatabaseNameForAlias(alias);
  if (isVaultOpenInProcess(name)) {
    throw StateError('wipeVaultFile while the vault is open; close it first.');
  }
  try {
    await impl
        .wipePlatformVaultFile(name, expectedStorage: expectedStorage)
        .timeout(_platformTimeout * 2);
  } on VaultOpenException {
    rethrow;
  } catch (_) {
    throw const VaultOpenException(VaultStatus.unavailable);
  }
}

/// Deletes every row of [db], rebuilds the file, closes [db] and returns the
/// main file path sqlite reported (null or empty when there is no file).
/// The common part of [wipeVaultFile]; a failed row delete is
/// [VaultOpenException] with [VaultStatus.unavailable]. The rebuild
/// (`VACUUM`) is best effort, as in [SecureVault.wipe]: once the rows are
/// deleted (and zeroed by `secure_delete`) a failed VACUUM neither fails the
/// wipe nor stops the file deletion that follows on Android.
Future<String?> wipeVaultDatabase(
  VaultDatabase db, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  try {
    return await () async {
      await db.deleteAllRows();
      try {
        await db.vacuum();
      } catch (_) {
        // Best effort; see above.
      }
      return db.mainFilePath();
    }().timeout(timeout);
  } catch (_) {
    throw const VaultOpenException(VaultStatus.unavailable);
  } finally {
    await db.closeQuietly();
  }
}
