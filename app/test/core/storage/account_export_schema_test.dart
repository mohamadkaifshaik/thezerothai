import 'package:drift/native.dart';
import 'package:dzeroth/core/storage/app_database.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'migrates a v3 database to v4, adding the account export table',
    () async {
      final executor = NativeDatabase.memory(
        setup: (raw) {
          raw.execute('''
          CREATE TABLE following_cache_entries (
            user_id TEXT NOT NULL, cached_at INTEGER NOT NULL,
            PRIMARY KEY (user_id)
          )''');
          raw.execute("INSERT INTO following_cache_entries VALUES ('u7', 1)");
          raw.execute('PRAGMA user_version = 3');
        },
      );
      final db = AppDatabase.forTesting(executor);
      addTearDown(db.close);

      expect(await db.cachedFollowingIds(), ['u7']);
      expect(await db.savedExport(), isNull);
      final at = DateTime(2026, 10, 7);
      await db.saveExport(
        exportId: 'e1',
        requestedAt: at,
        expiresAt: at.add(const Duration(days: 7)),
        epoch: db.sessionEpoch.value,
      );
      expect((await db.savedExport())?.exportId, 'e1');
    },
  );

  test('saveExport keeps one row, drops stale-session writes, and clearAll '
      'wipes it', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final at = DateTime(2026, 10, 7);
    final epoch = db.sessionEpoch.value;
    await db.saveExport(
      exportId: 'a',
      requestedAt: at,
      expiresAt: at,
      epoch: epoch,
    );
    await db.saveExport(
      exportId: 'b',
      requestedAt: at,
      expiresAt: at,
      epoch: epoch,
    );
    expect((await db.savedExport())?.exportId, 'b');

    db.sessionEpoch.end();
    await db.saveExport(
      exportId: 'late',
      requestedAt: at,
      expiresAt: at,
      epoch: epoch,
    );
    expect((await db.savedExport())?.exportId, 'b');

    await db.clearAll();
    expect(await db.savedExport(), isNull);
  });
}
