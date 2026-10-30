import 'dart:convert';

import '../../../core/storage/app_database.dart';

/// Most recent searches kept per account.
const kRecentSearchesMax = 10;

/// The searches an account typed, newest first, on this device only.
/// Nothing is sent to a server. A later server-side history would implement
/// this interface and change no caller.
abstract interface class RecentSearchesStore {
  /// At most [kRecentSearchesMax] entries of [uid], newest first.
  Future<List<String>> read(String uid);

  /// Puts [query] first and drops an equal earlier entry and anything past
  /// [kRecentSearchesMax]. A blank [query] is ignored. Callers pass
  /// `SearchQuery.canonical`, so `#Go` and `#go` are one entry.
  Future<void> add(String uid, String query);

  /// Removes one entry (no-op when absent).
  Future<void> remove(String uid, String query);

  /// "Clear all" for [uid].
  Future<void> clear(String uid);
}

/// Keeps the list as JSON in `AppSettingEntries` under a per-uid key that
/// starts with [kAccountSettingPrefix]: sign-out (`wipeSessionData` ->
/// `AppDatabase.clearAll`) deletes it, so the next user on a shared device
/// starts empty (CLAUDE.md rule 10). Writes are guarded by the session epoch,
/// so a search typed just before sign-out cannot land after the wipe. 0 RPCs.
class DatabaseRecentSearchesStore implements RecentSearchesStore {
  DatabaseRecentSearchesStore(this._database);

  final AppDatabase _database;

  /// The `AppSettingEntries` key of [uid].
  static String key(String uid) =>
      '${kAccountSettingPrefix}recent_searches:$uid';

  @override
  Future<List<String>> read(String uid) => _load(uid);

  @override
  Future<void> add(String uid, String query) {
    final entry = query.trim();
    if (entry.isEmpty) return Future.value();
    return _update(uid, (list) => [entry, ...list.where((e) => e != entry)]);
  }

  @override
  Future<void> remove(String uid, String query) =>
      _update(uid, (list) => [...list.where((e) => e != query)]);

  @override
  Future<void> clear(String uid) => _database.deleteSetting(key(uid));

  Future<List<String>> _load(String uid) async {
    final raw = await _database.readSetting(key(uid));
    if (raw == null) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return [
        for (final e in decoded)
          if (e is String && e.isNotEmpty) e,
      ].take(kRecentSearchesMax).toList(growable: false);
    } on FormatException {
      return const [];
    }
  }

  // Read-modify-write under the epoch read first: if the session ends in
  // between, the guarded write is dropped.
  Future<void> _update(
    String uid,
    List<String> Function(List<String>) change,
  ) async {
    final epoch = _database.sessionEpoch.value;
    final next = change(await _load(uid)).take(kRecentSearchesMax).toList();
    if (!_database.sessionEpoch.allows(epoch)) return;
    if (next.isEmpty) {
      await _database.deleteSetting(key(uid));
      return;
    }
    await _database.writeAccountSetting(
      key(uid),
      jsonEncode(next),
      epoch: epoch,
    );
  }
}
