import 'package:drift/native.dart';
import 'package:dzeroth/core/storage/app_database.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'migrates a v3 database to v4, adding the account export table',
    () async {
      // The schema exactly as v3 shipped it (posts plan T14), with data.
      final executor = NativeDatabase.memory(
        setup: (raw) {
          raw.execute('''
          CREATE TABLE profile_cache_entries (
            user_id TEXT NOT NULL, handle TEXT NOT NULL,
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
          )''');
          raw.execute('''
          CREATE TABLE following_cache_entries (
            user_id TEXT NOT NULL, cached_at INTEGER NOT NULL,
            PRIMARY KEY (user_id)
          )''');
          raw.execute('''
          CREATE TABLE timeline_item_entries (
            feed_key TEXT NOT NULL, item_key TEXT NOT NULL,
            sort_key TEXT NOT NULL, payload BLOB NULL,
            gap_token TEXT NULL, page_token TEXT NULL,
            PRIMARY KEY (feed_key, item_key)
          )''');
          raw.execute('''
          CREATE TABLE timeline_state_entries (
            feed_key TEXT NOT NULL,
            since_token TEXT NOT NULL DEFAULT '',
            older_page_token TEXT NOT NULL DEFAULT '',
            updated_at INTEGER NOT NULL,
            PRIMARY KEY (feed_key)
          )''');
          raw.execute("INSERT INTO following_cache_entries VALUES ('u7', 1)");
          raw.execute('PRAGMA user_version = 3');
        },
      );
      final db = AppDatabase.forTesting(executor);
      addTearDown(db.close);

      expect(await db.cachedFollowingIds(), ['u7']);
      expect(await db.savedExport('u1'), isNull);
      final at = DateTime(2026, 10, 7);
      await db.saveExport(
        exportId: 'e1',
        uid: 'u1',
        requestedAt: at,
        expiresAt: at.add(const Duration(days: 7)),
        epoch: db.sessionEpoch.value,
      );
      expect((await db.savedExport('u1'))?.exportId, 'e1');
    },
  );

  test('saveExport keeps one row, drops stale-session writes, and clearAll '
      'wipes it', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final at = DateTime(2026, 10, 7);
    final epoch = db.sessionEpoch.value;
    Future<void> save(String id, int epoch) => db.saveExport(
      exportId: id,
      uid: 'u1',
      requestedAt: at,
      expiresAt: at,
      epoch: epoch,
    );
    await save('a', epoch);
    await save('b', epoch);
    expect((await db.savedExport('u1'))?.exportId, 'b');

    db.sessionEpoch.end();
    await save('late', epoch);
    expect((await db.savedExport('u1'))?.exportId, 'b');

    await db.clearAll();
    expect(await db.savedExport('u1'), isNull);
  });

  test('a row of another uid is absent and gets deleted', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final at = DateTime(2026, 10, 7);
    await db.saveExport(
      exportId: 'mine',
      uid: 'u1',
      requestedAt: at,
      expiresAt: at,
      epoch: db.sessionEpoch.value,
    );

    expect(await db.savedExport('u2'), isNull);
    expect(await db.savedExport('u1'), isNull);
  });
}
