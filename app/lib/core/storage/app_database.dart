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

/// Local cache of the signed-in user's own `following` set (ADR-0008 /
/// graph plan T12), so `FollowButton` and follow lists can render
/// "Following" instantly on a warm start, before `GetRelationships` or a
/// list RPC ever runs (the client is our cheapest cache — CLAUDE.md prime
/// directive). Only ever holds the *current* signed-in user's own follows;
/// wiped on sign-out along with [ProfileCacheEntries] (see [clearAll]).
@DataClassName('CachedFollowing')
class FollowingCacheEntries extends Table {
  /// Uid of an account the signed-in user follows. Primary key.
  TextColumn get userId => text()();

  /// When this row was written, so it can be pruned or judged stale later.
  DateTimeColumn get cachedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {userId};
}

@DriftDatabase(tables: [ProfileCacheEntries, FollowingCacheEntries])
class AppDatabase extends _$AppDatabase {
  AppDatabase([QueryExecutor? executor]) : super(executor ?? _openConnection());

  /// Test-only in-memory database.
  AppDatabase.forTesting(super.executor);

  @override
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) => m.createAll(),
    onUpgrade: (m, from, to) async {
      // v1 -> v2 (graph plan T12): additive table, no data migration needed.
      if (from < 2) {
        await m.createTable(followingCacheEntries);
      }
    },
  );

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

  /// All uids the signed-in user is cached as following.
  Future<List<String>> cachedFollowingIds() async {
    final rows = await select(followingCacheEntries).get();
    return [for (final row in rows) row.userId];
  }

  Future<void> upsertFollowing(String userId) {
    return into(followingCacheEntries).insertOnConflictUpdate(
      FollowingCacheEntriesCompanion.insert(
        userId: userId,
        cachedAt: DateTime.now(),
      ),
    );
  }

  Future<void> removeFollowing(String userId) {
    return (delete(
      followingCacheEntries,
    )..where((t) => t.userId.equals(userId))).go();
  }

  /// Wipes all cached data. Called on sign-out so the next user on a shared
  /// device never sees a stale profile or follow list (privacy: CLAUDE.md
  /// rule 10).
  Future<void> clearAll() async {
    await delete(profileCacheEntries).go();
    await delete(followingCacheEntries).go();
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
