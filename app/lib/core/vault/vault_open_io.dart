import 'dart:async';
import 'dart:io' show File, Platform;
import 'dart:isolate' show ReceivePort, SendPort;

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift_flutter/drift_flutter.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import 'vault_database.dart';
import 'vault_open.dart'
    show VaultWipeStop, kVaultNativeStorage, wipeVaultDatabase;
import 'vault_status.dart';

/// Never set on native.
WasmStorageImplementation? get lastWebStorage => null;

/// The vault database [name] on this platform: Android only. The storage is
/// always `native`; [expectedStorage] (a web storage marker) is ignored.
Future<(DatabaseConnection, String)> openPlatformVaultConnection(
  String name, {
  String? expectedStorage,
  bool create = true,
}) async => (
  openIoVaultConnection(name, isAndroid: Platform.isAndroid, create: create),
  kVaultNativeStorage,
);

/// [openPlatformVaultConnection] with the platform check passed in.
///
/// Anything but Android throws [VaultOpenException] with
/// [VaultStatus.unsupported] before drift starts (so no file and no
/// path_provider call). On Android the file is `<name>.sqlite` in
/// drift_flutter's default directory, `getApplicationDocumentsDirectory()`
/// (the app-private `app_flutter` directory; the app disables Auto Backup
/// and device transfer in its manifest), opened on a background isolate.
/// A file that cannot be opened fails the first query, which `openVault`
/// maps to [VaultStatus.unavailable]; there is no in-memory fallback.
///
/// [reportPath] receives the main file path sqlite opened (see
/// [vaultNativeOptions]); the wipe uses it. [create] false: see
/// [vaultNativeOptions].
@visibleForTesting
DatabaseConnection openIoVaultConnection(
  String name, {
  required bool isAndroid,
  SendPort? reportPath,
  bool create = true,
}) {
  if (!isAndroid) throw const VaultOpenException(VaultStatus.unsupported);
  return driftDatabase(
    name: name,
    native: vaultNativeOptions(reportPath: reportPath, create: create),
  );
}

/// The vault's drift_flutter native options. [directory] and
/// [tempDirectory] are drift_flutter's own overrides, given only by tests
/// (null: drift_flutter's defaults, the app documents and temp
/// directories).
///
/// The `setup` runs on the database isolate right after sqlite opened the
/// file and before drift reads or creates anything. First, when
/// [reportPath] is given, it sends the main file path sqlite opened
/// (`PRAGMA database_list`). sqlite opens a file lazily, so this works even
/// for a file that is not a database at all: the path is known although the
/// first real statement fails ("file is not a database"). That is how the
/// wipe finds the file to delete when its rows cannot be deleted, with no
/// second source of truth for the directory and no path_provider import.
/// Then `secure_delete` is turned on: deleted rows are zeroed rather than
/// left in free pages.
///
/// With [create] false (the flag is not on, only an existing vault may be
/// opened) the setup refuses a file sqlite has just made empty (zero bytes:
/// no vault was ever stored there) by throwing before drift reads or creates
/// anything, so no schema, stamp or sentinel is written and the open fails
/// (`VaultStatus.unavailable`). sqlite itself makes the zero-byte file when
/// it opens a missing path; that empty file holds no data, and it is the
/// only trace: drift_flutter offers no open mode that refuses to create it,
/// and its directory lookup (path_provider) is not a dependency of the app.
///
/// The `setup` closure is sent to the database isolate, so it captures
/// nothing but [reportPath] (a [SendPort]) and [create] (a bool); never let
/// it reference a [ReceivePort], a Completer or other local state of this
/// function.
@visibleForTesting
DriftNativeOptions vaultNativeOptions({
  SendPort? reportPath,
  Future<Object> Function()? directory,
  Future<String?> Function()? tempDirectory,
  bool create = true,
}) => DriftNativeOptions(
  setup: (database) {
    if (!create) {
      String? mainFile;
      for (final row in database.select('PRAGMA database_list')) {
        if (row['name'] == 'main') {
          final file = row['file'];
          if (file is String) mainFile = file;
          break;
        }
      }
      if (mainFile == null || mainFile.isEmpty) {
        throw StateError('no vault file');
      }
      final stored = File(mainFile);
      if (!stored.existsSync() || stored.lengthSync() == 0) {
        throw StateError('no vault stored');
      }
    }
    if (reportPath != null) {
      try {
        for (final row in database.select('PRAGMA database_list')) {
          if (row['name'] == 'main') {
            reportPath.send(row['file']);
            break;
          }
        }
      } catch (_) {
        // No path then; the wipe stays unavailable if it needs one.
      }
    }
    database.execute('PRAGMA secure_delete = ON');
  },
  databaseDirectory: directory,
  tempDirectoryPath: tempDirectory,
);

/// Android: deletes every row, rebuilds the file, closes it, then deletes
/// the file and its sidecars. [expectedStorage] is ignored (one file, one
/// place). See [wipeIoVaultFile] for the order and [stop].
Future<void> wipePlatformVaultFile(
  String name, {
  String? expectedStorage,
  required VaultWipeStop stop,
}) async {
  final paths = ReceivePort();
  try {
    final reported = paths.first.then<String?>(
      (path) => path is String ? path : null,
      onError: (Object _) => null,
    );
    final db = VaultDatabase(
      openIoVaultConnection(
        name,
        isAndroid: Platform.isAndroid,
        reportPath: paths.sendPort,
      ),
    );
    await wipeIoVaultFile(db, reportedPath: reported, stop: stop);
  } finally {
    paths.close();
  }
}

/// How long the wipe waits for the setup's path report once the rows could
/// not be deleted (it is normally already there).
const Duration _pathReportWait = Duration(seconds: 2);

/// The Android wipe of [db] (a connection made by [openIoVaultConnection]
/// whose path reports arrive at [reportedPath], for this call only):
///
/// 1. [wipeVaultDatabase]: every row deleted, `VACUUM`, closed.
/// 2. The file and its sidecars deleted ([deleteVaultFilesAt]), at the path
///    sqlite reported. When the rows could NOT be deleted (a malformed file
///    fails at its first statement, so it never yields a path through a
///    query) the path the connection setup reported is used, so an owed
///    wipe of a damaged file can still finish: deleting the file is the
///    wipe. Without a reported path (the open failed before sqlite opened
///    the file) a failed row delete stays [VaultStatus.unavailable].
///
/// Succeeds when the rows are gone or the file is deleted. [stop] is asked
/// (after the database was closed) before any file is deleted and before
/// each file; true is [VaultStatus.unavailable] and nothing is deleted.
@visibleForTesting
Future<void> wipeIoVaultFile(
  VaultDatabase db, {
  required Future<String?> reportedPath,
  required VaultWipeStop stop,
}) async {
  String? path;
  var rowsGone = false;
  try {
    path = await wipeVaultDatabase(db, stop: stop);
    rowsGone = true;
  } on VaultOpenException {
    // The rows could not be deleted (or the wipe was stopped: checked next).
  }
  if (stop()) throw const VaultOpenException(VaultStatus.unavailable);
  if (path == null || path.isEmpty) {
    path = await reportedPath.timeout(_pathReportWait, onTimeout: () => null);
  }
  if (path == null || path.isEmpty) {
    if (rowsGone) return; // No file (nothing more to delete).
    throw const VaultOpenException(VaultStatus.unavailable);
  }
  try {
    await deleteVaultFilesAt(path, stop: stop);
  } catch (_) {
    // With the rows gone an empty, rebuilt file may stay; otherwise the
    // wipe has not happened.
    if (!rowsGone) throw const VaultOpenException(VaultStatus.unavailable);
  }
}

/// Deletes the database file at [path] and its `-journal`, `-wal` and
/// `-shm` sidecars; missing files are fine. [stop] is asked before each
/// file: true throws [StateError] and the rest stay.
@visibleForTesting
Future<void> deleteVaultFilesAt(String path, {VaultWipeStop? stop}) async {
  for (final suffix in const ['', '-journal', '-wal', '-shm']) {
    if (stop?.call() ?? false) throw StateError('vault wipe stopped');
    final file = File('$path$suffix');
    if (await file.exists()) {
      // The await above is a gap: ask again right before deleting.
      if (stop?.call() ?? false) throw StateError('vault wipe stopped');
      await file.delete();
    }
  }
}
