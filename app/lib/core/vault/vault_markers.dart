import 'dart:convert';

import 'package:drift/drift.dart';

import '../storage/app_database.dart';
import 'vault_cipher.dart' show vaultKeyAlias;

/// A vault this device has (or had) for one user: the facts the session
/// needs to wipe it later without that user being signed in.
class KnownVault {
  const KnownVault({
    required this.uid,
    required this.storage,
    required this.createdAtMicros,
  });

  /// The user the vault belongs to. Kept in the marker's VALUE (never its
  /// key) because `wipeVaultFile` and `deleteVaultKey` need it to wipe the
  /// vault of a user who is no longer signed in. The marker is deleted with
  /// the vault.
  final String uid;

  /// [SecureVault.storageName] of the open that recorded it.
  final String storage;
  final int createdAtMicros;

  @override
  String toString() => 'KnownVault($storage)';
}

/// The vault's safety markers, kept OUTSIDE the vault (they must survive a
/// vault that cannot be opened) and keyed by the vault alias, never by a raw
/// uid:
///
/// - `vault.known.<alias>`: this device has a vault for that user.
/// - `vault.keyLostSeen.<alias>`: the launch id of the launch that first saw
///   the vault's key as lost (key loss is confirmed on a LATER launch only).
/// - `vault.wipeOwed.<alias>`: a wipe that started (or failed) and must be
///   completed before any vault is opened.
abstract interface class VaultMarkers {
  /// False when the markers do not outlive this launch (the cache database
  /// runs in memory): a vault whose markers cannot persist is not opened.
  bool get persistent;

  Future<KnownVault?> known(String uid);
  Future<List<KnownVault>> knownVaults();
  Future<void> writeKnown(KnownVault vault);

  Future<String?> keyLostSeen(String uid);
  Future<void> writeKeyLostSeen(String uid, String launchId);
  Future<void> clearKeyLostSeen(String uid);

  /// The wipes owed.
  Future<List<OwedWipe>> owedWipes();

  /// Records (or updates) the wipe owed for [uid]. [fileDone]: the vault
  /// file step already succeeded (a later attempt goes on with the key; the
  /// file may be gone, so the storage-marker check would refuse it).
  Future<void> writeWipeOwed(String uid, {bool fileDone = false});

  /// Removes every marker of [uid] (known, keyLostSeen, wipeOwed) at once.
  Future<void> clearAll(String uid);
}

/// A wipe that must be completed (`vault.wipeOwed.<alias>`).
class OwedWipe {
  const OwedWipe(this.uid, {this.fileDone = false});

  final String uid;

  /// The vault file step already succeeded.
  final bool fileDone;

  @override
  String toString() => 'OwedWipe(fileDone: $fileDone)';
}

const String kVaultKnownPrefix = 'vault.known.';
const String kVaultKeyLostSeenPrefix = 'vault.keyLostSeen.';
const String kVaultWipeOwedPrefix = 'vault.wipeOwed.';

/// The markers in the cache database's device settings
/// ([AppSettingEntries]). The keys do not start with
/// [kAccountSettingPrefix], so [AppDatabase.clearAll] (the sign-out cache
/// wipe) keeps them. Uses the table through drift directly for the prefix
/// listing ([AppDatabase] has no prefix read); nothing in the cache API
/// changes.
class DriftVaultMarkers implements VaultMarkers {
  DriftVaultMarkers(this._db, {required bool persistent})
    : persistent = persistent && !_db.keepsNothing;

  final AppDatabase _db;

  @override
  final bool persistent;

  static String _key(String prefix, String uid) =>
      '$prefix${vaultKeyAlias(uid)}';

  Future<List<String>> _values(String prefix) async {
    final rows = await (_db.select(
      _db.appSettingEntries,
    )..where((t) => t.settingKey.like('$prefix%'))).get();
    return [for (final r in rows) r.settingValue];
  }

  static KnownVault? _decodeKnown(String? value) {
    if (value == null) return null;
    try {
      final map = jsonDecode(value) as Map<String, Object?>;
      final uid = map['uid'];
      final storage = map['storage'];
      final at = map['createdAt'];
      if (uid is! String || uid.isEmpty || storage is! String || at is! int) {
        return null;
      }
      return KnownVault(uid: uid, storage: storage, createdAtMicros: at);
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }

  static OwedWipe? _decodeOwed(String value) {
    try {
      final map = jsonDecode(value) as Map<String, Object?>;
      final uid = map['uid'];
      if (uid is! String || uid.isEmpty) return null;
      return OwedWipe(uid, fileDone: map['fileDone'] == true);
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }

  @override
  Future<KnownVault?> known(String uid) async {
    final known = _decodeKnown(
      await _db.readSetting(_key(kVaultKnownPrefix, uid)),
    );
    // A value naming another uid is not this user's (only corruption).
    return known?.uid == uid ? known : null;
  }

  @override
  Future<List<KnownVault>> knownVaults() async => [
    for (final v in await _values(kVaultKnownPrefix)) ?_decodeKnown(v),
  ];

  @override
  Future<void> writeKnown(KnownVault vault) => _db.writeSetting(
    _key(kVaultKnownPrefix, vault.uid),
    jsonEncode({
      'uid': vault.uid,
      'storage': vault.storage,
      'createdAt': vault.createdAtMicros,
    }),
  );

  @override
  Future<String?> keyLostSeen(String uid) =>
      _db.readSetting(_key(kVaultKeyLostSeenPrefix, uid));

  @override
  Future<void> writeKeyLostSeen(String uid, String launchId) =>
      _db.writeSetting(_key(kVaultKeyLostSeenPrefix, uid), launchId);

  @override
  Future<void> clearKeyLostSeen(String uid) =>
      _db.deleteSetting(_key(kVaultKeyLostSeenPrefix, uid));

  @override
  Future<List<OwedWipe>> owedWipes() async => [
    for (final v in await _values(kVaultWipeOwedPrefix)) ?_decodeOwed(v),
  ];

  @override
  Future<void> writeWipeOwed(String uid, {bool fileDone = false}) =>
      _db.writeSetting(
        _key(kVaultWipeOwedPrefix, uid),
        jsonEncode({'uid': uid, 'fileDone': fileDone}),
      );

  @override
  Future<void> clearAll(String uid) => _db.transaction(() async {
    for (final prefix in const [
      kVaultKnownPrefix,
      kVaultKeyLostSeenPrefix,
      kVaultWipeOwedPrefix,
    ]) {
      await _db.deleteSetting(_key(prefix, uid));
    }
  });
}
