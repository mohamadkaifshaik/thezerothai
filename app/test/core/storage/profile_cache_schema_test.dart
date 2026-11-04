import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:dzeroth/core/storage/app_database.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/legacy_profile_cache.dart';

void main() {
  // Relative to the real clock, whole seconds (the column stores seconds).
  final cachedAt = DateTime.fromMillisecondsSinceEpoch(
    DateTime.now().millisecondsSinceEpoch ~/ 1000 * 1000,
  );

  test('migrates a v12 database to v13, keeping cached profiles with '
      'subscriptionVerified false', () async {
    final executor = NativeDatabase.memory(
      setup: (raw) {
        raw.execute(kLegacyProfileCacheTableSql);
        raw.execute(
          legacyProfileCacheRowSql(
            cachedAtSeconds: cachedAt.millisecondsSinceEpoch ~/ 1000,
          ),
        );
        raw.execute('PRAGMA user_version = 12');
      },
    );
    final db = AppDatabase.forTesting(executor);
    addTearDown(db.close);

    final rows = await db.select(db.profileCacheEntries).get();
    expect(rows, hasLength(1));
    final row = rows.single;
    expect(row.userId, 'u1');
    expect(row.handle, 'alice');
    expect(row.displayName, 'Alice A');
    expect(row.bio, 'hi');
    expect(row.isPrivate, isTrue);
    expect(row.verified, isTrue);
    expect(row.followersCount, 10);
    expect(row.followingCount, 20);
    expect(row.postsCount, 30);
    expect(
      row.cachedAt.millisecondsSinceEpoch,
      cachedAt.millisecondsSinceEpoch,
    );
    expect(row.subscriptionVerified, isFalse);

    // The column is real: a migrated row can be rewritten with it set.
    await db.upsertProfile(
      ProfileCacheEntriesCompanion.insert(
        userId: 'u1',
        handle: 'alice',
        displayName: 'Alice A',
        cachedAt: cachedAt,
        subscriptionVerified: const Value(true),
      ),
      epoch: db.sessionEpoch.value,
    );
    expect(
      (await db.select(db.profileCacheEntries).getSingle())
          .subscriptionVerified,
      isTrue,
    );
  });
}
