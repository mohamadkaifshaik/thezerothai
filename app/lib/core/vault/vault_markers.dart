import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart'
    show WasmStorageImplementation;

import '../storage/app_database.dart';
import 'vault_cipher.dart' show isVaultKeyAlias, requireVaultKeyAlias;
import 'vault_open.dart' show kVaultAcceptedWebStorages;

/// A vault this device has (or had) for one user, named by its key alias
/// (`vaultKeyAlias(uid)`), never by the uid.
class KnownVault {
  KnownVault({
    required String alias,
    required this.storage,
    required this.createdAtMicros,
  }) : alias = requireVaultKeyAlias(alias);

  final String alias;

  /// [SecureVault.storageName] of the open that recorded it.
  final String storage;
  final int createdAtMicros;

  @override
  String toString() => 'KnownVault($storage)';
}

/// The first observation of a lost key: which launch saw it, and when.
class KeyLostSeen {
  const KeyLostSeen({required this.launchId, required this.atMicros});

  final String launchId;
  final int atMicros;
}

/// A wipe that must be completed (`vault.wipeOwed.<alias>`).
class OwedWipe {
  OwedWipe(
    String alias, {
    this.fileStarted = false,
    this.fileDone = false,
    this.anyCopy = false,
  }) : alias = requireVaultKeyAlias(alias);

  final String alias;

  /// The file step began at least once: a retry erases whatever copy is
  /// listed (the marked copy may already be gone, or never listed).
  final bool fileStarted;

  /// The file step succeeded: a retry goes on with the key.
  final bool fileDone;

  /// An explicit reset: erase any listed copy, whatever the storage marker
  /// says.
  final bool anyCopy;

  OwedWipe copyWith({bool? fileStarted, bool? fileDone, bool? anyCopy}) =>
      OwedWipe(
        alias,
        fileStarted: fileStarted ?? this.fileStarted,
        fileDone: fileDone ?? this.fileDone,
        anyCopy: anyCopy ?? this.anyCopy,
      );

  @override
  String toString() =>
      'OwedWipe(fileStarted: $fileStarted, fileDone: $fileDone, '
      'anyCopy: $anyCopy)';
}

/// The vault's safety markers, kept OUTSIDE the vault (they must survive a
/// vault that cannot be opened). Keys AND values name a user only by the
/// vault key alias, never by the uid:
///
/// - `vault.known.<alias>`: this device has a vault for that user.
/// - `vault.keyLostSeen.<alias>`: the first observation of a lost key.
/// - `vault.wipeOwed.<alias>`: a wipe that started (or failed) and must be
///   completed before that user's vault is opened again.
/// - `vault.pendingEnd.<alias>`: an explicit sign-out was asked for; resolved
///   at the next start-up against the restored user if the app dies first.
abstract interface class VaultMarkers {
  /// False when the markers do not outlive this launch (an in-memory cache,
  /// or a web cache on a storage that is not durable and shared): a vault
  /// whose markers cannot persist is not opened.
  bool get persistent;

  Future<KnownVault?> known(String alias);
  Future<List<KnownVault>> knownVaults();
  Future<void> writeKnown(KnownVault vault);

  Future<KeyLostSeen?> keyLostSeen(String alias);
  Future<void> writeKeyLostSeen(String alias, KeyLostSeen seen);
  Future<void> clearKeyLostSeen(String alias);

  Future<List<OwedWipe>> owedWipes();

  /// Records (or replaces) the wipe owed for [wipe]'s alias.
  Future<void> writeWipeOwed(OwedWipe wipe);

  /// The aliases with an explicit sign-out not yet resolved.
  Future<List<String>> pendingEnds();
  Future<void> writePendingEnd(String alias);
  Future<void> clearPendingEnd(String alias);

  /// Removes every marker of [alias] at once.
  Future<void> clearAll(String alias);
}

const String kVaultKnownPrefix = 'vault.known.';
const String kVaultKeyLostSeenPrefix = 'vault.keyLostSeen.';
const String kVaultWipeOwedPrefix = 'vault.wipeOwed.';
const String kVaultPendingEndPrefix = 'vault.pendingEnd.';

const List<String> _allPrefixes = [
  kVaultKnownPrefix,
  kVaultKeyLostSeenPrefix,
  kVaultWipeOwedPrefix,
  kVaultPendingEndPrefix,
];

/// Whether the vault markers in the cache database outlive this launch: never
/// for the in-memory fallback; on native when the cache is on disk; on the
/// web only when drift put the cache on a storage the vault itself accepts
/// ([kVaultAcceptedWebStorages]: durable and shared by every tab). A web
/// cache in memory, or on the per-tab unsafe IndexedDB, would lose an owed
/// wipe or let tabs disagree.
bool vaultMarkersPersistent({
  required bool cacheInMemory,
  required bool isWeb,
  required WasmStorageImplementation? cacheWebStorage,
}) {
  if (cacheInMemory) return false;
  if (!isWeb) return true;
  return cacheWebStorage != null &&
      kVaultAcceptedWebStorages.contains(cacheWebStorage);
}

/// The markers in the cache database's device settings
/// ([AppSettingEntries]). The keys do not start with
/// [kAccountSettingPrefix], so [AppDatabase.clearAll] (the sign-out cache
/// wipe) keeps them. Every value repeats its alias; a value whose alias is
/// not its key's (or garbage, or a known marker with malformed fields) is
/// corrupt: [onCorrupt] gets the key prefix (nothing else), the row is
/// deleted, and the marker reads as absent. Residual limit: a corrupt
/// `wipeOwed` / `pendingEnd` row drops that wipe until another user signs
/// in (whose sign-in wipes every known vault) or the `known` marker drives
/// it. Prefix listing uses the table through drift directly
/// ([AppDatabase] has no prefix read).
class DriftVaultMarkers implements VaultMarkers {
  DriftVaultMarkers(
    this._db, {
    required bool persistent,
    void Function(String prefix)? onCorrupt,
  }) : persistent = persistent && !_db.keepsNothing,
       _onCorrupt = onCorrupt;

  final AppDatabase _db;
  final void Function(String prefix)? _onCorrupt;

  @override
  final bool persistent;

  static String _key(String prefix, String alias) =>
      '$prefix${requireVaultKeyAlias(alias)}';

  /// The JSON object stored under [key] when its `alias` matches the key;
  /// otherwise null, and a present row is corrupt ([_drop]).
  Future<Map<String, Object?>?> _decode(
    String prefix,
    String key,
    String? value,
  ) async {
    if (value == null) return null;
    try {
      final map = jsonDecode(value) as Map<String, Object?>;
      final alias = key.substring(prefix.length);
      if (isVaultKeyAlias(alias) && map['alias'] == alias) return map;
    } on FormatException {
      // Corrupt below.
    } on TypeError {
      // Corrupt below.
    }
    await _drop(prefix, key);
    return null;
  }

  /// A corrupt row: reported once (the prefix only), then deleted, so it is
  /// neither acted on nor reported again. A failed delete is ignored (it is
  /// reported again on the next read).
  Future<void> _drop(String prefix, String key) async {
    _onCorrupt?.call(prefix);
    try {
      await _db.deleteSetting(key);
    } catch (_) {}
  }

  Future<Map<String, Object?>?> _read(String prefix, String alias) async {
    final key = _key(prefix, alias);
    return _decode(prefix, key, await _db.readSetting(key));
  }

  /// The valid rows under [prefix], with their keys.
  Future<List<(String, Map<String, Object?>)>> _list(String prefix) async {
    final rows = await (_db.select(
      _db.appSettingEntries,
    )..where((t) => t.settingKey.like('$prefix%'))).get();
    final valid = <(String, Map<String, Object?>)>[];
    for (final r in rows) {
      final map = await _decode(prefix, r.settingKey, r.settingValue);
      if (map != null) valid.add((r.settingKey, map));
    }
    return valid;
  }

  /// [m] as a [KnownVault]; a row with a valid alias but malformed fields is
  /// corrupt too.
  Future<KnownVault?> _knownOrDrop(String key, Map<String, Object?>? m) async {
    if (m == null) return null;
    final known = _known(m);
    if (known == null) await _drop(kVaultKnownPrefix, key);
    return known;
  }

  Future<void> _write(String prefix, String alias, Map<String, Object?> v) =>
      _db.writeSetting(_key(prefix, alias), jsonEncode({...v, 'alias': alias}));

  static KnownVault? _known(Map<String, Object?>? m) {
    if (m == null) return null;
    final storage = m['storage'];
    final at = m['createdAt'];
    if (storage is! String || at is! int) return null;
    return KnownVault(
      alias: m['alias']! as String,
      storage: storage,
      createdAtMicros: at,
    );
  }

  static OwedWipe _owed(Map<String, Object?> m) => OwedWipe(
    m['alias']! as String,
    fileStarted: m['fileStarted'] == true,
    fileDone: m['fileDone'] == true,
    anyCopy: m['anyCopy'] == true,
  );

  @override
  Future<KnownVault?> known(String alias) async => _knownOrDrop(
    _key(kVaultKnownPrefix, alias),
    await _read(kVaultKnownPrefix, alias),
  );

  @override
  Future<List<KnownVault>> knownVaults() async => [
    for (final (key, m) in await _list(kVaultKnownPrefix))
      ?await _knownOrDrop(key, m),
  ];

  @override
  Future<void> writeKnown(KnownVault vault) => _write(
    kVaultKnownPrefix,
    vault.alias,
    {'storage': vault.storage, 'createdAt': vault.createdAtMicros},
  );

  @override
  Future<KeyLostSeen?> keyLostSeen(String alias) async {
    final m = await _read(kVaultKeyLostSeenPrefix, alias);
    final launch = m?['launchId'];
    final at = m?['at'];
    if (launch is! String || at is! int) return null;
    return KeyLostSeen(launchId: launch, atMicros: at);
  }

  @override
  Future<void> writeKeyLostSeen(String alias, KeyLostSeen seen) => _write(
    kVaultKeyLostSeenPrefix,
    alias,
    {'launchId': seen.launchId, 'at': seen.atMicros},
  );

  @override
  Future<void> clearKeyLostSeen(String alias) =>
      _db.deleteSetting(_key(kVaultKeyLostSeenPrefix, alias));

  @override
  Future<List<OwedWipe>> owedWipes() async => [
    for (final (_, m) in await _list(kVaultWipeOwedPrefix)) _owed(m),
  ];

  @override
  Future<void> writeWipeOwed(OwedWipe wipe) =>
      _write(kVaultWipeOwedPrefix, wipe.alias, {
        'fileStarted': wipe.fileStarted,
        'fileDone': wipe.fileDone,
        'anyCopy': wipe.anyCopy,
      });

  @override
  Future<List<String>> pendingEnds() async => [
    for (final (_, m) in await _list(kVaultPendingEndPrefix))
      m['alias']! as String,
  ];

  @override
  Future<void> writePendingEnd(String alias) =>
      _write(kVaultPendingEndPrefix, alias, const {});

  @override
  Future<void> clearPendingEnd(String alias) =>
      _db.deleteSetting(_key(kVaultPendingEndPrefix, alias));

  @override
  Future<void> clearAll(String alias) async {
    requireVaultKeyAlias(alias);
    await _db.transaction(() async {
      for (final prefix in _allPrefixes) {
        await _db.deleteSetting(_key(prefix, alias));
      }
    });
  }
}
