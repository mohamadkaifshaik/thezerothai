import 'dart:io' show Platform;

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift_flutter/drift_flutter.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import 'vault_status.dart';

/// The vault database [name] on this platform: Android only.
Future<DatabaseConnection> openPlatformVaultConnection(String name) async =>
    openIoVaultConnection(name, isAndroid: Platform.isAndroid);

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
  return driftDatabase(name: name, native: const DriftNativeOptions());
}
