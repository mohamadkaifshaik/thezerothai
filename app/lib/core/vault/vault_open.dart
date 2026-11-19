import 'dart:async';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift_flutter/drift_flutter.dart'
    show ExistingDatabase, MissingBrowserFeature, WasmStorageImplementation;
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

/// Whether drift's probe can be trusted to have listed every existing
/// database: false when one of its workers failed
/// ([MissingBrowserFeature.workerError]), which drift swallows. Used before
/// both opening and wiping on the web.
bool isTrustedVaultWebProbe(Set<MissingBrowserFeature> missingFeatures) =>
    !missingFeatures.contains(MissingBrowserFeature.workerError);

/// The web storage the vault database [name] opens on, from drift's probe:
/// the storages this browser offers ([available]), the drift databases
/// that already exist ([existing], as `(storage API, name)`) and what the
/// probe could not check ([missingFeatures]).
///
/// - [missingFeatures] contains [MissingBrowserFeature.workerError]: the
///   probe is not trusted and the result is [VaultOpenException] with
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
/// Never [VaultStatus.keyLost]. Pure, so the VM tests cover every case.
///
/// Known limit: a probe that reports "not present" WITHOUT an error (a
/// database that exists but is not listed, with no worker failure) cannot
/// be detected here; a storage marker kept outside the vault (a later
/// task) closes that case.
WasmStorageImplementation chooseVaultWebStorage({
  required Iterable<WasmStorageImplementation> available,
  required Iterable<ExistingDatabase> existing,
  required Set<MissingBrowserFeature> missingFeatures,
  required String name,
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
  if (mine.any((api) => api != chosen.storageApi)) {
    throw const VaultOpenException(VaultStatus.storageChanged);
  }
  if (!isAcceptedVaultWebStorage(chosen)) {
    throw const VaultOpenException(VaultStatus.unavailable);
  }
  return chosen;
}

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

/// Opens the platform connection of [uid]'s vault; failures are
/// [VaultOpenException]. A connection that arrives after the timeout is
/// closed.
Future<VaultDatabase> _openDatabase(String uid) async {
  if (uid.isEmpty) throw ArgumentError.value(uid, 'uid', 'empty');
  final pending = impl.openPlatformVaultConnection(vaultDatabaseName(uid));
  try {
    return VaultDatabase(await pending.timeout(_platformTimeout));
  } on VaultOpenException {
    rethrow;
  } on TimeoutException {
    unawaited(pending.then(_closeConnection, onError: (Object _) {}));
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
/// Throws [VaultOpenException]: [VaultStatus.unsupported] on any platform
/// but Android and the web; [VaultStatus.storageChanged] on the web when
/// the vault exists in another storage than this browser would use now;
/// [VaultStatus.unavailable] when the storage cannot be opened or is not
/// durable, or the cipher cannot run; [VaultStatus.keyLost] when the
/// sentinel shows the key no longer opens this vault (the file is left
/// untouched). See [openVaultOnDatabase].
Future<SecureVault> openVault({
  required String uid,
  required VaultCipher cipher,
}) async {
  final db = await _openDatabase(uid);
  return openVaultOnDatabase(
    db,
    uid: uid,
    cipher: cipher,
    registerAs: vaultDatabaseName(uid),
  );
}

/// Erases EVERY copy of [uid]'s vault, under every storage, including a
/// copy this browser cannot open right now; no cipher is needed (so it
/// works when the key is lost or unavailable). Delete the platform key
/// separately (`deleteVaultKey`), after this succeeds.
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
Future<void> wipeVaultFile({required String uid}) async {
  if (uid.isEmpty) throw ArgumentError.value(uid, 'uid', 'empty');
  if (isVaultOpenInProcess(vaultDatabaseName(uid))) {
    throw StateError('wipeVaultFile while the vault is open; close it first.');
  }
  try {
    await impl
        .wipePlatformVaultFile(vaultDatabaseName(uid))
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
