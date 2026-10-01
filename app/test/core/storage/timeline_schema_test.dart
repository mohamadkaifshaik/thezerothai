import 'package:drift/native.dart';
import 'package:dzeroth/core/storage/app_database.dart';
import 'package:dzeroth/features/timeline/data/timeline_store.dart';
import 'package:dzeroth/features/timeline/domain/feed_key.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/posts_fixtures.dart';

void main() {
  test('migrates a v2 database to v3, keeping data and adding the timeline '
      'tables', () async {
    // Build the schema exactly as v2 shipped it (graph plan T12), with data.
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
        raw.execute("INSERT INTO following_cache_entries VALUES ('u7', 1)");
        raw.execute('PRAGMA user_version = 2');
      },
    );
    final db = AppDatabase.forTesting(executor);
    addTearDown(db.close);

    expect(await db.cachedFollowingIds(), ['u7']);

    final store = TimelineStore(db);
    await store.applyColdOpen(
      const FeedKey.home(),
      posts: [postView(2), postView(1)],
      sinceToken: 's',
      nextPageToken: 'n',
    );
    final snap = await store.read(const FeedKey.home());
    expect(snap.posts, hasLength(2));
    expect(snap.sinceToken, 's');
    expect(snap.olderPageToken, 'n');

    final cols = await db
        .customSelect('PRAGMA table_info(timeline_item_entries)')
        .get();
    expect(cols.map((r) => r.read<String>('name')), contains('page_token'));
  });

  test('clearAll wipes timeline feeds on sign-out', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final store = TimelineStore(db);
    await store.applyColdOpen(
      const FeedKey.home(),
      posts: [postView(2)],
      sinceToken: 's',
      nextPageToken: '',
    );

    await db.clearAll();

    final snap = await store.read(const FeedKey.home());
    expect(snap.entries, isEmpty);
    expect(snap.sinceToken, isEmpty);
  });

  test('sortKeyBelow stays a padded 19-digit string', () {
    expect(sortKeyBelow(postId(10)), postId(9));
    expect(sortKeyBelow('7234567890123456789'), '7234567890123456788');
    expect(sortKeyBelow('not-a-number'), 'not-a-number');
  });
}
