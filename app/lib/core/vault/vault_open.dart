import 'dart:async';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift_flutter/drift_flutter.dart'
    show ExistingDatabase, WasmStorageImplementation;
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

/// The web storage the vault database [name] opens on, from drift's probe:
/// the storages this browser offers ([available]) and the drift databases
/// that already exist ([existing], as `(storage API, name)`).
///
/// Mirrors drift's own choice in `WasmDatabase.open`: a database that
/// already exists stays in its storage API while some storage of that API
/// is available (the best one is used); otherwise the best available
/// storage. Then:
///
/// - a database named [name] exists under another storage API than the
///   choice (or under two): [VaultOpenException] with
///   [VaultStatus.storageChanged]. Opening would show an empty vault as
///   ready while the real one sits in the other storage.
/// - the choice is not in [kVaultAcceptedWebStorages]:
///   [VaultStatus.unavailable].
///
/// Never [VaultStatus.keyLost]. Pure, so the VM tests cover every case.
///
/// Known limit: drift lists an IndexedDB database only when probed with its
/// name (the vault always passes it) and always lists OPFS databases; a
/// browser whose storage cannot be listed at all (the probe's workers fail)
/// offers only in-memory storage, which is refused anyway.
WasmStorageImplementation chooseVaultWebStorage({
  required Iterable<WasmStorageImplementation> available,
  required Iterable<ExistingDatabase> existing,
  required String name,
}) {
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
  return openVaultOnDatabase(db, uid: uid, cipher: cipher);
}

/// Erases [uid]'s vault without a cipher (so it works when the key is lost
/// or unavailable): after confirmed key loss, on an explicit sign-out, or
/// for a previous user when another user signs in. Delete the platform key
/// separately (`deleteVaultKey`), after this succeeds.
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
/// The common part of [wipeVaultFile]; failures are [VaultOpenException]
/// with [VaultStatus.unavailable].
Future<String?> wipeVaultDatabase(
  VaultDatabase db, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  try {
    return await () async {
      await db.deleteAllRows();
      await db.vacuum();
      return db.mainFilePath();
    }().timeout(timeout);
  } catch (_) {
    throw const VaultOpenException(VaultStatus.unavailable);
  } finally {
    await db.closeQuietly();
  }
}
