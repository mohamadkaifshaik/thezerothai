import 'package:drift/native.dart';
import 'package:dzeroth/core/storage/app_database.dart';
import 'package:dzeroth/features/engagement/data/post_history_repository.dart';
import 'package:dzeroth/features/engagement/domain/bookmark_history_feature_flag.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('migrates a v13 database to v14, keeping rows and adding post '
      'history', () async {
    final executor = NativeDatabase.memory(
      setup: (raw) {
        raw.execute('''
          CREATE TABLE app_setting_entries (
            setting_key TEXT NOT NULL, setting_value TEXT NOT NULL,
            PRIMARY KEY (setting_key)
          )''');
        raw.execute("INSERT INTO app_setting_entries VALUES ('theme', 'dark')");
        raw.execute('PRAGMA user_version = 13');
      },
    );
    final db = AppDatabase.forTesting(executor);
    addTearDown(db.close);

    expect(await db.readSetting('theme'), 'dark');
    final version = await db.customSelect('PRAGMA user_version').getSingle();
    expect(version.read<int>('user_version'), 14);

    final repo = PostHistoryRepository(db);
    await repo.recordOpen(uid: 'u1', postId: 'p1');
    expect(await repo.recentPostIds('u1'), ['p1']);
  });

  group('PostHistoryRepository', () {
    late AppDatabase db;
    late int tick;
    late PostHistoryRepository repo;

    setUp(() {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      tick = 0;
      repo = PostHistoryRepository(
        db,
        clock: () => DateTime.utc(2026, 11, 1).add(Duration(seconds: tick++)),
      );
    });

    tearDown(() async => db.close());

    test('newest first, and a re-open moves the post to the top', () async {
      await repo.recordOpen(uid: 'u1', postId: 'a');
      await repo.recordOpen(uid: 'u1', postId: 'b');
      await repo.recordOpen(uid: 'u1', postId: 'a');
      expect(await repo.recentPostIds('u1'), ['a', 'b']);
    });

    test(
      'keeps at most kBookmarkHistoryCap rows, dropping the oldest',
      () async {
        for (var i = 0; i <= kBookmarkHistoryCap; i++) {
          await repo.recordOpen(uid: 'u1', postId: 'p$i');
        }
        final ids = await repo.recentPostIds('u1');
        expect(ids.length, kBookmarkHistoryCap);
        expect(ids.first, 'p$kBookmarkHistoryCap');
        expect(ids, isNot(contains('p0')));
      },
    );

    test('each uid sees only its own rows', () async {
      await repo.recordOpen(uid: 'u1', postId: 'a');
      await repo.recordOpen(uid: 'u2', postId: 'b');
      expect(await repo.recentPostIds('u1'), ['a']);
      expect(await repo.recentPostIds('u2'), ['b']);
    });

    test('an open from an ended session writes nothing', () async {
      final stale = db.sessionEpoch.value;
      db.sessionEpoch.end();
      await repo.recordOpen(uid: 'u1', postId: 'a', epoch: stale);
      expect(await repo.recentPostIds('u1'), isEmpty);
    });

    test(
      'remove drops one post; clear drops one uid; clearSession drops all',
      () async {
        await repo.recordOpen(uid: 'u1', postId: 'a');
        await repo.recordOpen(uid: 'u1', postId: 'b');
        await repo.recordOpen(uid: 'u2', postId: 'c');

        await repo.remove(uid: 'u1', postId: 'a');
        expect(await repo.recentPostIds('u1'), ['b']);

        await repo.clear('u1');
        expect(await repo.recentPostIds('u1'), isEmpty);
        expect(await repo.recentPostIds('u2'), ['c']);

        await repo.clearSession();
        expect(await repo.recentPostIds('u2'), isEmpty);
      },
    );

    test('AppDatabase.clearAll wipes the history', () async {
      await repo.recordOpen(uid: 'u1', postId: 'a');
      await db.clearAll();
      expect(await repo.recentPostIds('u1'), isEmpty);
    });
  });

  test('the in-memory web fallback keeps the history rules too', () async {
    final db = AppDatabase.keepingNothing();
    addTearDown(db.close);
    var tick = 0;
    final repo = PostHistoryRepository(
      db,
      clock: () => DateTime.utc(2026, 11, 1).add(Duration(seconds: tick++)),
    );
    await repo.recordOpen(uid: 'u1', postId: 'a');
    await repo.recordOpen(uid: 'u1', postId: 'b');
    await repo.recordOpen(uid: 'u1', postId: 'a');
    expect(await repo.recentPostIds('u1'), ['a', 'b']);
    await repo.clear('u1');
    expect(await repo.recentPostIds('u1'), isEmpty);
  });
}
