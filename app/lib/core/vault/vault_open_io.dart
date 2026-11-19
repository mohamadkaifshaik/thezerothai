import 'dart:io' show File, Platform;

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift_flutter/drift_flutter.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import 'vault_database.dart';
import 'vault_open.dart' show kVaultNativeStorage, wipeVaultDatabase;
import 'vault_status.dart';

/// Never set on native.
WasmStorageImplementation? get lastWebStorage => null;

/// The vault database [name] on this platform: Android only. The storage is
/// always `native`; [expectedStorage] (a web storage marker) is ignored.
Future<(DatabaseConnection, String)> openPlatformVaultConnection(
  String name, {
  String? expectedStorage,
}) async => (
  openIoVaultConnection(name, isAndroid: Platform.isAndroid),
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
@visibleForTesting
DatabaseConnection openIoVaultConnection(
  String name, {
  required bool isAndroid,
}) {
  if (!isAndroid) throw const VaultOpenException(VaultStatus.unsupported);
  return driftDatabase(
    name: name,
    native: DriftNativeOptions(
      // Runs on the database isolate before drift creates or reads
      // anything: deleted rows are zeroed rather than left in free pages.
      setup: (database) => database.execute('PRAGMA secure_delete = ON'),
    ),
  );
}

/// Android: deletes every row, rebuilds the file, closes it, then deletes
/// the file and its sidecars (best effort once the rows are gone).
/// [expectedStorage] is ignored (one file, one place).
Future<void> wipePlatformVaultFile(
  String name, {
  String? expectedStorage,
}) async {
  final db = VaultDatabase(
    openIoVaultConnection(name, isAndroid: Platform.isAndroid),
  );
  final path = await wipeVaultDatabase(db);
  if (path != null && path.isNotEmpty) {
    try {
      await deleteVaultFilesAt(path);
    } catch (_) {
      // The rows are gone and the file rebuilt; an empty file may stay.
    }
  }
}

/// Deletes the database file at [path] and its `-journal`, `-wal` and
/// `-shm` sidecars; missing files are fine.
@visibleForTesting
Future<void> deleteVaultFilesAt(String path) async {
  for (final suffix in const ['', '-journal', '-wal', '-shm']) {
    final file = File('$path$suffix');
    if (await file.exists()) await file.delete();
  }
}
