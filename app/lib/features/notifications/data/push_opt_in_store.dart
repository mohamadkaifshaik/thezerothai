import '../../../core/storage/app_database.dart';

/// Where "Not now" is remembered, per account.
abstract interface class PushOptInStore {
  /// When [uid] last tapped "Not now", or null.
  Future<DateTime?> readNotNow(String uid);

  Future<void> writeNotNow(String uid, DateTime at);

  /// Drops the record of [uid]. Called when that account is deleted (W2-14
  /// L-6: the uid must not outlive the account); a plain sign-out keeps it.
  Future<void> forget(String uid);
}

/// Keeps the record in `AppSettingEntries` under a per-uid key, so two
/// accounts on one device do not share it. Sign-out keeps device settings, so
/// the same account signing back in is still not nagged. 0 RPCs.
class DatabasePushOptInStore implements PushOptInStore {
  DatabasePushOptInStore(this._database);

  final AppDatabase _database;

  /// The `AppSettingEntries` key of [uid].
  static String key(String uid) => 'push_opt_in_not_now:$uid';

  @override
  Future<DateTime?> readNotNow(String uid) async {
    final raw = await _database.readSetting(key(uid));
    final millis = raw == null ? null : int.tryParse(raw);
    if (millis == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true);
  }

  @override
  Future<void> writeNotNow(String uid, DateTime at) => _database.writeSetting(
    key(uid),
    at.toUtc().millisecondsSinceEpoch.toString(),
  );

  @override
  Future<void> forget(String uid) => _database.deleteSetting(key(uid));
}
