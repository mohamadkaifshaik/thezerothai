import '../../../core/storage/app_database.dart';
import '../domain/plan_quick_start.dart';

/// [PlanFormStore] over the drift settings table. The key starts with
/// `account:` so sign-out and an account switch wipe it with the cache; the
/// write is guarded by the session epoch read when it starts.
class DatabasePlanFormStore implements PlanFormStore {
  DatabasePlanFormStore(this._database);

  final AppDatabase _database;

  @override
  Future<String?> read() => _database.readSetting(kPlanFormMemoryKey);

  @override
  Future<void> write(String json) => _database.writeAccountSetting(
    kPlanFormMemoryKey,
    json,
    epoch: _database.sessionEpoch.value,
  );
}
