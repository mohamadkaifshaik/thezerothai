import 'dart:async';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift_flutter/drift_flutter.dart'
    show WasmDatabaseResult, WasmStorageImplementation;
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
///   shared worker that serialises every tab.
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

WasmStorageImplementation? _lastWebStorage;

/// The storage drift chose for the last vault database opened on the web
/// (accepted or not); null elsewhere or before any open.
@visibleForTesting
WasmStorageImplementation? get lastVaultWebStorage => _lastWebStorage;

/// The web opener's check of drift's result (`vault_open_web.dart`): records
/// the choice and, for a storage outside [kVaultAcceptedWebStorages], starts
/// closing its connection and throws [VaultOpenException] with
/// [VaultStatus.unavailable]. Nothing has been written to it at that point
/// (drift runs the schema on the first query, which never happens).
void checkVaultWebResult(WasmDatabaseResult result) {
  _lastWebStorage = result.chosenImplementation;
  if (isAcceptedVaultWebStorage(result.chosenImplementation)) return;
  unawaited(_closeConnection(result.resolvedExecutor));
  throw const VaultOpenException(VaultStatus.unavailable);
}

Future<void> _closeConnection(DatabaseConnection connection) async {
  try {
    await connection.executor.close();
  } catch (_) {
    // Dropped either way.
  }
}

/// How long opening the platform connection may take.
const Duration _connectTimeout = Duration(seconds: 30);

/// Opens the platform connection of [uid]'s vault; failures are
/// [VaultOpenException]. A connection that arrives after the timeout is
/// closed.
Future<VaultDatabase> _openDatabase(String uid) async {
  if (uid.isEmpty) throw ArgumentError.value(uid, 'uid', 'empty');
  final pending = impl.openPlatformVaultConnection(vaultDatabaseName(uid));
  try {
    return VaultDatabase(await pending.timeout(_connectTimeout));
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
/// [kVaultAcceptedWebStorages]). Never in memory.
///
/// Throws [VaultOpenException]: [VaultStatus.unsupported] on any platform
/// but Android and the web; [VaultStatus.unavailable] when the storage
/// cannot be opened or is not durable, or the cipher cannot run;
/// [VaultStatus.keyLost] when the sentinel shows the key no longer opens
/// this vault (the file is left untouched). See [openVaultOnDatabase].
Future<SecureVault> openVault({
  required String uid,
  required VaultCipher cipher,
}) async {
  final db = await _openDatabase(uid);
  return openVaultOnDatabase(db, uid: uid, cipher: cipher);
}

/// Deletes every row of [uid]'s vault without a cipher (so it works when
/// the key is lost or unavailable): after confirmed key loss, on an
/// explicit sign-out, or for a previous user when another user signs in.
/// The empty file stays. Delete the platform key separately
/// (`deleteVaultKey`), after this succeeds.
///
/// Must not run while a [SecureVault] of [uid] is open. Throws
/// [VaultOpenException] like [openVault] ([VaultStatus.unsupported],
/// [VaultStatus.unavailable]).
Future<void> wipeVaultFile({required String uid}) async {
  final db = await _openDatabase(uid);
  await wipeVaultDatabase(db);
}

/// [wipeVaultFile] on [db], which it closes.
@visibleForTesting
Future<void> wipeVaultDatabase(
  VaultDatabase db, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  try {
    await db.deleteAllRows().timeout(timeout);
  } catch (_) {
    throw const VaultOpenException(VaultStatus.unavailable);
  } finally {
    await db.closeQuietly();
  }
}
