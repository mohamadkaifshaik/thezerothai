import 'dart:io';

import 'package:dzeroth/core/vault/vault_database.dart';
import 'package:dzeroth/core/vault/vault_open_io.dart';

/// Not on the web: nothing listed.
Future<List<String>> existingWebStorageApis(String name) async => const [];

/// Not on the web: no IndexedDB copy can be made.
Future<bool> createIndexedDbCopy(String name) async => false;

/// The vault database [name] on Android as the production connection opens
/// it (same drift options and setup callback): its file path and the
/// connection's `PRAGMA secure_delete`. Opening creates the file when it is
/// missing, so call it only for a vault that exists. Null off Android.
Future<({String path, int secureDelete})?> inspectNativeVaultFile(
  String name,
) async {
  if (!Platform.isAndroid) return null;
  final db = VaultDatabase(openIoVaultConnection(name, isAndroid: true));
  try {
    final path = await db.mainFilePath();
    final row = await db.customSelect('PRAGMA secure_delete').getSingle();
    return (path: path ?? '', secureDelete: row.data.values.single as int);
  } finally {
    await db.close();
  }
}

/// Which of the database file at [path] and its `-journal`, `-wal` and
/// `-shm` sidecars exist.
Future<List<String>> existingFilesOf(String path) async => [
  for (final suffix in const ['', '-journal', '-wal', '-shm'])
    if (await File('$path$suffix').exists()) '$path$suffix',
];
