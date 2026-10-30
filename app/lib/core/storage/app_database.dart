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

/// One row of the signed-in user's cached notification list (P6 T9,
/// ADR-0017): a notification (serialized `Notification`) or a "gap" marker
/// holding the `gap_page_token` of a refresh gap. Rows sort by [sortKey]
/// descending: the zero-padded `created_at` microseconds, `|`, the id (a
/// collapsed like is rewritten in place with a newer `created_at`, so the id
/// is the identity and the key is rebuilt on every upsert). Wiped on sign-out
/// ([AppDatabase.clearAll]).
@DataClassName('CachedNotification')
class NotificationEntries extends Table {
  /// The notification id, or `gap:{sortKey}` for a gap row.
  TextColumn get itemKey => text()();
  TextColumn get sortKey => text()();

  /// Serialized `Notification`; null for a gap row.
  BlobColumn get payload => blob().nullable()();

  /// `gap_page_token`; null for a notification row.
  TextColumn get gapToken => text().nullable()();

  /// For a row that ended a fetched page: that page's `next_page_token`
  /// (lets retention trim at a page boundary and resume scrolling).
  TextColumn get pageToken => text().nullable()();

  @override
  Set<Column> get primaryKey => {itemKey};
}

/// The notification list's refresh state (at most one row, key `main`): the
/// `since_token` of the last response, the `next_page_token` below the oldest
/// cached row and the caller's `seen_at` (unread = `created_at > seen_at`).
@DataClassName('CachedNotificationState')
class NotificationStateEntries extends Table {
  TextColumn get stateKey => text()();
  TextColumn get sinceToken => text().withDefault(const Constant(''))();
  TextColumn get olderPageToken => text().withDefault(const Constant(''))();

  /// `seen_at` in microseconds since the epoch; null = never marked seen.
  IntColumn get seenAtMicros => integer().nullable()();

  /// This installation's random device id for RegisterDevice (stable until
  /// sign-out wipes the cache; '' = not generated yet). Never the FCM token.
  TextColumn get deviceId => text().withDefault(const Constant(''))();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {stateKey};
}

/// One conversation of the signed-in user's cached inbox or requests list
/// (W7-13, ADR-0027 D14): the serialized `Conversation` of the caller's entry.
/// Rows sort by [sortKey] descending (zero-padded `updated_at` microseconds,
/// `|`, the id), per [folder] (`Folder.value`: 1 inbox, 2 requests). Wiped on
/// sign-out ([AppDatabase.clearAll]).
@DataClassName('CachedConversation')
class ConversationEntries extends Table {
  /// 32-character lower-case hex id (opaque, ADR-0027 D2).
  TextColumn get conversationId => text()();
  IntColumn get folder => integer()();
  TextColumn get sortKey => text()();

  /// Serialized `Conversation`.
  BlobColumn get payload => blob()();

  @override
  Set<Column> get primaryKey => {conversationId};
}

/// One cached message (W7-13, ADR-0027 D14): the newest 200 per conversation.
/// Rows sort by [sortKey] descending (zero-padded `created_at` microseconds,
/// `|`, the id). The payload is a serialized `Message`: it carries `from_self`
/// and no sender uid (D5). Wiped on sign-out ([AppDatabase.clearAll]).
@DataClassName('CachedMessage')
class MessageEntries extends Table {
  TextColumn get conversationId => text()();
  TextColumn get messageId => text()();
  TextColumn get sortKey => text()();

  /// Serialized `Message`.
  BlobColumn get payload => blob()();

  /// For a row that ended a fetched page: that page's `next_page_token`
  /// (lets the 200-row trim cut at a page boundary and resume scrolling).
  TextColumn get pageToken => text().nullable()();

  @override
  Set<Column> get primaryKey => {conversationId, messageId};
}

/// Refresh state of one cached messaging list: the `since_token` of the last
/// response and the `next_page_token` below the oldest cached row. [stateKey]
/// is `inbox`, `requests` or `thread:{conversationId}`. Tokens live 30 days
/// server-side (ADR-0027 D7). Wiped on sign-out ([AppDatabase.clearAll]).
@DataClassName('CachedMessagingState')
class MessagingStateEntries extends Table {
  TextColumn get stateKey => text()();
  TextColumn get sinceToken => text().withDefault(const Constant(''))();

  /// Token for scrolling older than the oldest cached row; '' = none/end.
  TextColumn get olderPageToken => text().withDefault(const Constant(''))();
  DateTimeColumn get updatedAt => dateTime()();

  /// Last known pending message-request count, on the `inbox` row only (v8).
  /// Null = never received (unknown), which is not the same as 0.
  IntColumn get requestCount => integer().nullable()();

  @override
  Set<Column> get primaryKey => {stateKey};
}

/// Prefix of the [AppSettingEntries] keys that hold data derived from one
/// account's graph (for example the cached "Who to follow" list). Unlike the
/// other device settings these are wiped on sign-out ([AppDatabase.clearAll]),
/// so the next user on a shared device never sees them and a deleted account
/// leaves nothing behind (CLAUDE.md rule 10).
const kAccountSettingPrefix = 'account:';

/// The uid whose data the cache tables hold (W7-35, L-4). It is an account
/// setting, so [AppDatabase.clearAll] removes it with the data it describes.
const kCacheOwnerKey = '${kAccountSettingPrefix}owner';

/// A device-level setting (key -> value text), e.g. the appearance choice.
///
/// Unlike every other table this one is **not** wiped on sign-out
/// ([AppDatabase.clearAll]): it describes the device, not the account, and
/// holds no personal data (CLAUDE.md rule 10 is about user data). The one
/// exception is a key that starts with [kAccountSettingPrefix]: that is
/// account-derived data and is wiped on sign-out.
@DataClassName('DeviceSetting')
class AppSettingEntries extends Table {
  TextColumn get settingKey => text()();
  TextColumn get settingValue => text()();

  @override
  Set<Column> get primaryKey => {settingKey};
}

@DriftDatabase(
  tables: [
    ProfileCacheEntries,
    FollowingCacheEntries,
    TimelineItemEntries,
    TimelineStateEntries,
    AccountExportEntries,
    NotificationEntries,
    NotificationStateEntries,
    ConversationEntries,
    MessageEntries,
    MessagingStateEntries,
    AppSettingEntries,
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
  int get schemaVersion => 8;

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
      // v4 -> v5 (notifications plan T9): the cached notification list.
      if (from < 5) {
        await m.createTable(notificationEntries);
        await m.createTable(notificationStateEntries);
      }
      // v5 -> v6 (UI wave W0-8): device-level settings (appearance).
      if (from < 6) {
        await m.createTable(appSettingEntries);
      }
      // v6 -> v7 (UI wave W7-13): the cached direct-message inbox, threads
      // and their tokens.
      if (from < 7) {
        await m.createTable(conversationEntries);
        await m.createTable(messageEntries);
        await m.createTable(messagingStateEntries);
      }
      // v7 -> v8 (W7-14): the last known message-request count. A database
      // older than v7 just got the table above, already with the column.
      if (from == 7) {
        await m.addColumn(
          messagingStateEntries,
          messagingStateEntries.requestCount,
        );
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

  /// The device setting [key], or null when it was never set.
  Future<String?> readSetting(String key) async {
    final row = await (select(
      appSettingEntries,
    )..where((t) => t.settingKey.equals(key))).getSingleOrNull();
    return row?.settingValue;
  }

  /// Sets the device setting [key]. Unguarded on purpose: it is not account
  /// data, so a sign-out in between cannot leak anything.
  Future<void> writeSetting(String key, String value) {
    return into(appSettingEntries).insertOnConflictUpdate(
      AppSettingEntriesCompanion.insert(settingKey: key, settingValue: value),
    );
  }

  /// Removes the device setting [key] (no-op when absent). For settings keyed
  /// by an account (e.g. the push opt-in "Not now"), when that account is
  /// deleted.
  Future<void> deleteSetting(String key) {
    return (delete(
      appSettingEntries,
    )..where((t) => t.settingKey.equals(key))).go();
  }

  /// Sets an account-derived setting ([key] starts with
  /// [kAccountSettingPrefix]). Guarded like every cache write: dropped when the
  /// session ended since [epoch] was read, so a response of a signed-out user
  /// can never land after [clearAll] wiped it.
  Future<void> writeAccountSetting(
    String key,
    String value, {
    required int epoch,
  }) {
    assert(key.startsWith(kAccountSettingPrefix));
    return transaction(() async {
      if (!sessionEpoch.allows(epoch)) return;
      await into(appSettingEntries).insertOnConflictUpdate(
        AppSettingEntriesCompanion.insert(settingKey: key, settingValue: value),
      );
    });
  }

  /// Makes the cache belong to [uid] (W7-35, L-4), before any cache read.
  ///
  /// The wipe on sign-out can be missed (the process dies first, or the auth
  /// stream goes from one user straight to another), so the cache says whose it
  /// is. When the owner stamp differs from [uid], or there is none, the session
  /// epoch ends (late writes of the old session are dropped), every cache table
  /// is cleared and the stamp is written, all in one transaction. A null [uid]
  /// (nobody signed in) wipes a cache that still carries a stamp. Returns true
  /// when it wiped.
  Future<bool> claimCacheFor(String? uid) async {
    final stamp = await readSetting(kCacheOwnerKey);
    if (uid == null ? stamp == null : stamp == uid) return false;
    sessionEpoch.end();
    await transaction(() async {
      await clearAll();
      if (uid != null) await writeSetting(kCacheOwnerKey, uid);
    });
    return true;
  }

  /// Wipes all cached data. Called on sign-out so the next user on a shared
  /// device never sees a stale profile or follow list (privacy: CLAUDE.md
  /// rule 10). Device settings ([AppSettingEntries]) are kept on purpose,
  /// except the account-derived ones under [kAccountSettingPrefix].
  Future<void> clearAll() async {
    await transaction(() async {
      await delete(profileCacheEntries).go();
      await delete(followingCacheEntries).go();
      await delete(timelineItemEntries).go();
      await delete(timelineStateEntries).go();
      await delete(accountExportEntries).go();
      await delete(notificationEntries).go();
      await delete(notificationStateEntries).go();
      await delete(conversationEntries).go();
      await delete(messageEntries).go();
      await delete(messagingStateEntries).go();
      await (delete(
        appSettingEntries,
      )..where((t) => t.settingKey.like('$kAccountSettingPrefix%'))).go();
    });
  }

  static QueryExecutor _openConnection() {
    return driftDatabase(
      name: 'dzeroth',
      web: DriftWebOptions(
        // These two files must be built/copied into `app/web/` before a web
        // release build — see the "manual steps" note in the Phase 0 report.
        // Root-absolute: with path URLs (W2-9) the page can be /post/<id>, and
        // the main-thread fallback resolves these against the page URL.
        sqlite3Wasm: Uri.parse('/sqlite3.wasm'),
        driftWorker: Uri.parse('/drift_worker.js'),
      ),
      native: const DriftNativeOptions(),
    );
  }
}
