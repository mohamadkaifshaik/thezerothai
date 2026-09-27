import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

part 'app_database.g.dart';

/// Local cache of profiles (own profile + anyone looked up), so the client
/// can render instantly and only re-fetch what changed. This is the
/// "cheapest cache" CLAUDE.md talks about: every profile served from here is
/// a Firestore read (and a Cloud Run request) the API never sees.
@DataClassName('CachedProfile')
class ProfileCacheEntries extends Table {
  /// Firebase uid. Primary key.
  TextColumn get userId => text()();
  TextColumn get handle => text()();
  TextColumn get displayName => text()();
  TextColumn get bio => text().withDefault(const Constant(''))();
  TextColumn get avatarUrl => text().withDefault(const Constant(''))();
  TextColumn get avatarThumbUrl => text().withDefault(const Constant(''))();
  BoolColumn get isPrivate => boolean().withDefault(const Constant(false))();
  BoolColumn get verified => boolean().withDefault(const Constant(false))();
  IntColumn get followersCount => integer().withDefault(const Constant(0))();
  IntColumn get followingCount => integer().withDefault(const Constant(0))();
  IntColumn get postsCount => integer().withDefault(const Constant(0))();

  /// When this row was written, so callers can decide whether it is fresh
  /// enough to render without a refresh (see the `timeline` skill).
  DateTimeColumn get cachedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {userId};
}

@DriftDatabase(tables: [ProfileCacheEntries])
class AppDatabase extends _$AppDatabase {
  AppDatabase([QueryExecutor? executor]) : super(executor ?? _openConnection());

  /// Test-only in-memory database.
  AppDatabase.forTesting(super.executor);

  @override
  int get schemaVersion => 1;

  Future<CachedProfile?> profileByUserId(String userId) {
    return (select(
      profileCacheEntries,
    )..where((t) => t.userId.equals(userId))).getSingleOrNull();
  }

  Future<CachedProfile?> profileByHandle(String handle) {
    return (select(
      profileCacheEntries,
    )..where((t) => t.handle.equals(handle))).getSingleOrNull();
  }

  Future<void> upsertProfile(ProfileCacheEntriesCompanion entry) {
    return into(profileCacheEntries).insertOnConflictUpdate(entry);
  }

  Future<void> deleteProfile(String userId) {
    return (delete(
      profileCacheEntries,
    )..where((t) => t.userId.equals(userId))).go();
  }

  /// Wipes all cached data. Called on sign-out so the next user on a shared
  /// device never sees a stale profile (privacy: CLAUDE.md rule 10).
  Future<void> clearAll() {
    return delete(profileCacheEntries).go();
  }

  static QueryExecutor _openConnection() {
    return driftDatabase(
      name: 'dzeroth',
      web: DriftWebOptions(
        // These two files must be built/copied into `app/web/` before a web
        // release build — see the "manual steps" note in the Phase 0 report.
        sqlite3Wasm: Uri.parse('sqlite3.wasm'),
        driftWorker: Uri.parse('drift_worker.js'),
      ),
      native: const DriftNativeOptions(),
    );
  }
}
