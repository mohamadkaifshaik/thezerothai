/// The `profile_cache_entries` table as devices have had it since v1 up to
/// v12: every column except `subscription_verified`, which v13 adds.
///
/// Migration tests hand-build old databases; every upgrade from before v13
/// runs the v13 `addColumn` on this table, so the old database must have it.
const kLegacyProfileCacheTableSql = '''
  CREATE TABLE profile_cache_entries (
    user_id TEXT NOT NULL,
    handle TEXT NOT NULL,
    display_name TEXT NOT NULL,
    bio TEXT NOT NULL DEFAULT '',
    avatar_url TEXT NOT NULL DEFAULT '',
    avatar_thumb_url TEXT NOT NULL DEFAULT '',
    is_private INTEGER NOT NULL DEFAULT 0 CHECK (is_private IN (0, 1)),
    verified INTEGER NOT NULL DEFAULT 0 CHECK (verified IN (0, 1)),
    followers_count INTEGER NOT NULL DEFAULT 0,
    following_count INTEGER NOT NULL DEFAULT 0,
    posts_count INTEGER NOT NULL DEFAULT 0,
    cached_at INTEGER NOT NULL,
    PRIMARY KEY (user_id)
  )''';

/// A cached profile written by an old version (private and verified, so a
/// migration that reset flags would show).
String legacyProfileCacheRowSql({required int cachedAtSeconds}) =>
    "INSERT INTO profile_cache_entries (user_id, handle, display_name, bio, "
    'is_private, verified, followers_count, following_count, posts_count, '
    "cached_at) VALUES ('u1', 'alice', 'Alice A', 'hi', 1, 1, 10, 20, 30, "
    '$cachedAtSeconds)';
