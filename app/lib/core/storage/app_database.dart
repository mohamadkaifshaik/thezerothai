import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

import 'session_epoch.dart';

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

/// One row of a cached timeline feed (posts-and-timeline plan T14): either a
/// post (serialized `PostView`) or a "gap" marker row that holds the
/// `gap_page_token` needed to fill the hole between newer and older cached
/// posts (ADR-0004 / ADR-0010 D13-D14).
///
/// Rows sort by [sortKey] descending (newest first). For a post it is the
/// zero-padded 19-digit Snowflake `post_id` (text, never `int`: a 19-digit id
/// does not survive Dart-on-web numbers); for a gap it is the id just below
/// the oldest item above it, so the marker lands in the right position.
/// Wiped on sign-out with the rest of the cache ([AppDatabase.clearAll]).
@DataClassName('CachedTimelineItem')
class TimelineItemEntries extends Table {
  /// `home` or `user:{userId}:{posts|replies}` (see `FeedKey`).
  TextColumn get feedKey => text()();

  /// The `post_id` for a post row, `gap:{sortKey}` for a gap row. Together
  /// with [feedKey] this makes `post_id` unique per feed (dedupe on merge).
  TextColumn get itemKey => text()();
  TextColumn get sortKey => text()();

  /// Serialized `PostView`; null for a gap row.
  BlobColumn get payload => blob().nullable()();

  /// `gap_page_token`; null for a post row.
  TextColumn get gapToken => text().nullable()();

  /// For a post row that ended a fetched page: that page's
  /// `next_page_token`. Lets retention trim at a page boundary and resume
  /// scrolling from the cut.
  TextColumn get pageToken => text().nullable()();

  @override
  Set<Column> get primaryKey => {feedKey, itemKey};
}

/// Per-feed refresh state: the `since_token` of the last response and the
/// `next_page_token` below the oldest cached item. Tokens live 30 days
/// server-side (ADR-0010 D14), so they persist across days.
@DataClassName('CachedTimelineState')
class TimelineStateEntries extends Table {
  TextColumn get feedKey => text()();
  TextColumn get sinceToken => text().withDefault(const Constant(''))();

  /// Token for scrolling older than the oldest cached item; '' = none/end.
  TextColumn get olderPageToken => text().withDefault(const Constant(''))();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {feedKey};
}

/// The signed-in user's pending/ready data export (account plan T15): just
/// the id and its lifetime, so "Download my data" can resume polling after
/// the screen or app was closed. Never holds the signed download URL. At most
/// one row; wiped on sign-out ([AppDatabase.clearAll]).
@DataClassName('SavedAccountExport')
class AccountExportEntries extends Table {
  TextColumn get exportId => text()();

  /// Firebase uid the export belongs to; another account never sees it.
  TextColumn get uid => text()();
  DateTimeColumn get requestedAt => dateTime()();

  /// Server `expireAt` (request time + 7 days); after it GetAccountExport
  /// answers NOT_FOUND (plan Q6).
  DateTimeColumn get expiresAt => dateTime()();

  @override
  Set<Column> get primaryKey => {exportId};
}

@DriftDatabase(
  tables: [
    ProfileCacheEntries,
    FollowingCacheEntries,
    TimelineItemEntries,
    TimelineStateEntries,
    AccountExportEntries,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase([QueryExecutor? executor]) : super(executor ?? _openConnection());

  /// Test-only in-memory database.
  AppDatabase.forTesting(super.executor);

  /// The one session epoch every cache writer checks inside its write
  /// transaction; ended on sign-out before [clearAll].
  final SessionEpoch sessionEpoch = SessionEpoch();

  @override
  int get schemaVersion => 4;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) => m.createAll(),
    onUpgrade: (m, from, to) async {
      // v1 -> v2 (graph plan T12): additive table, no data migration needed.
      if (from < 2) {
        await m.createTable(followingCacheEntries);
      }
      // v2 -> v3 (posts plan T14): additive timeline tables.
      if (from < 3) {
        await m.createTable(timelineItemEntries);
        await m.createTable(timelineStateEntries);
      }
      // v3 -> v4 (account plan T15): the pending data export.
      if (from < 4) {
        await m.createTable(accountExportEntries);
      }
    },
  );

  /// The saved export of [uid], if any. A row of another uid is treated as
  /// absent and deleted (a shared device must never resume someone else's).
  Future<SavedAccountExport?> savedExport(String uid) async {
    final rows = await select(accountExportEntries).get();
    SavedAccountExport? mine;
    for (final row in rows) {
      if (row.uid == uid) {
        mine = row;
      } else {
        await (delete(
          accountExportEntries,
        )..where((t) => t.exportId.equals(row.exportId))).go();
      }
    }
    return mine;
  }

  /// Replaces the saved export (one row). Guarded like every cache write.
  Future<void> saveExport({
    required String exportId,
    required String uid,
    required DateTime requestedAt,
    required DateTime expiresAt,
    required int epoch,
  }) {
    return transaction(() async {
      if (!sessionEpoch.allows(epoch)) return;
      await delete(accountExportEntries).go();
      await into(accountExportEntries).insert(
        AccountExportEntriesCompanion.insert(
          exportId: exportId,
          uid: uid,
          requestedAt: requestedAt,
          expiresAt: expiresAt,
        ),
      );
    });
  }

  /// Unguarded on purpose: removing a row can never leak data.
  Future<void> clearSavedExport() => delete(accountExportEntries).go();

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

  /// Guarded writes: the write is dropped when the session ended since
  /// [epoch] was read (see [SessionEpoch]); pass [SessionEpoch.unguarded] to
  /// bypass on purpose.
  Future<void> upsertProfile(
    ProfileCacheEntriesCompanion entry, {
    required int epoch,
  }) {
    return transaction(() async {
      if (!sessionEpoch.allows(epoch)) return;
      await into(profileCacheEntries).insertOnConflictUpdate(entry);
    });
  }

  /// Deletes are intentionally unguarded: removing a row can never leak one
  /// user's data into another's cache.
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

  Future<void> upsertFollowing(String userId, {required int epoch}) {
    return transaction(() async {
      if (!sessionEpoch.allows(epoch)) return;
      await into(followingCacheEntries).insertOnConflictUpdate(
        FollowingCacheEntriesCompanion.insert(
          userId: userId,
          cachedAt: DateTime.now(),
        ),
      );
    });
  }

  Future<void> removeFollowing(String userId, {required int epoch}) {
    return transaction(() async {
      if (!sessionEpoch.allows(epoch)) return;
      await (delete(
        followingCacheEntries,
      )..where((t) => t.userId.equals(userId))).go();
    });
  }

  /// Wipes all cached data. Called on sign-out so the next user on a shared
  /// device never sees a stale profile or follow list (privacy: CLAUDE.md
  /// rule 10).
  Future<void> clearAll() async {
    await transaction(() async {
      await delete(profileCacheEntries).go();
      await delete(followingCacheEntries).go();
      await delete(timelineItemEntries).go();
      await delete(timelineStateEntries).go();
      await delete(accountExportEntries).go();
    });
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
