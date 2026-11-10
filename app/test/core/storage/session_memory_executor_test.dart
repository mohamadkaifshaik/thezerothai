import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:dzeroth/core/storage/app_database.dart';
import 'package:dzeroth/core/storage/session_memory_executor.dart';
import 'package:flutter_test/flutter_test.dart';

/// The pure-Dart session cache behind `AppDatabase.keepingNothing`: the SQL
/// drift generates for the app's tables behaves as on sqlite. The stores'
/// own suites cover the merge rules; this pins the engine's edge cases.
void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase.forTesting(sessionMemoryExecutor()));
  tearDown(() => db.close());

  Future<List<String>> itemKeys(String feed) async => [
    for (final row
        in await (db.select(db.timelineItemEntries)
              ..where((t) => t.feedKey.equals(feed))
              ..orderBy([(t) => OrderingTerm.desc(t.sortKey)]))
            .get())
      row.itemKey,
  ];

  TimelineItemEntriesCompanion item(String feed, String key) =>
      TimelineItemEntriesCompanion.insert(
        feedKey: feed,
        itemKey: key,
        sortKey: key,
        payload: Value(Uint8List.fromList([1, 2, 3])),
      );

  test('the tables are created with their defaults', () async {
    // drift stores a DateTime as whole seconds.
    final now = DateTime.now();
    final at = now.subtract(
      Duration(microseconds: now.microsecond, milliseconds: now.millisecond),
    );
    await db.upsertProfile(
      ProfileCacheEntriesCompanion.insert(
        userId: 'u1',
        handle: 'h1',
        displayName: 'N',
        cachedAt: at,
      ),
      epoch: db.sessionEpoch.value,
    );

    final row = (await db.profileByUserId('u1'))!;
    expect(row.bio, '');
    expect(row.isPrivate, isFalse);
    expect(row.followersCount, 0);
    expect(row.cachedAt, at);
  });

  test('an upsert changes only the columns it names', () async {
    await db.into(db.timelineItemEntries).insert(item('home', '2'));
    await (db.update(db.timelineItemEntries)
          ..where((t) => t.itemKey.equals('2')))
        .write(const TimelineItemEntriesCompanion(pageToken: Value('p1')));

    await db
        .into(db.timelineItemEntries)
        .insertOnConflictUpdate(item('home', '2'));

    final row = await (db.select(
      db.timelineItemEntries,
    )..where((t) => t.itemKey.equals('2'))).getSingle();
    expect(row.pageToken, 'p1');
    expect(row.payload, [1, 2, 3]);
  });

  test('a plain insert of an existing key fails, as on sqlite', () async {
    await db.into(db.timelineItemEntries).insert(item('home', '1'));
    await expectLater(
      db.into(db.timelineItemEntries).insert(item('home', '1')),
      throwsA(anything),
    );
  });

  test('where, order by, limit, in, like and count', () async {
    for (final key in ['1', '3', '2']) {
      await db.into(db.timelineItemEntries).insert(item('home', key));
    }
    await db.into(db.timelineItemEntries).insert(item('other', '9'));
    await db
        .into(db.timelineItemEntries)
        .insert(
          TimelineItemEntriesCompanion.insert(
            feedKey: 'home',
            itemKey: 'gap:0',
            sortKey: '0',
            gapToken: const Value('g'),
          ),
        );

    expect(await itemKeys('home'), ['3', '2', '1', 'gap:0']);
    final newest =
        await (db.select(db.timelineItemEntries)
              ..where((t) => t.payload.isNotNull() & t.feedKey.equals('home'))
              ..orderBy([(t) => OrderingTerm.asc(t.sortKey)])
              ..limit(1))
            .getSingle();
    expect(newest.itemKey, '1');

    await (db.delete(db.timelineItemEntries)
          ..where((t) => t.feedKey.equals('home') & t.itemKey.isIn(['1', '3'])))
        .go();
    expect(await itemKeys('home'), ['2', 'gap:0']);

    final count = db.timelineItemEntries.itemKey.count();
    final total =
        await (db.selectOnly(db.timelineItemEntries)
              ..addColumns([count])
              ..where(db.timelineItemEntries.sortKey.isSmallerThanValue('3')))
            .map((r) => r.read(count))
            .getSingle();
    expect(total, 2);

    await db.writeSetting('account:x', '1');
    await db.writeSetting('device', '1');
    await (db.delete(
      db.appSettingEntries,
    )..where((t) => t.settingKey.like('account:%'))).go();
    expect(await db.readSetting('account:x'), isNull);
    expect(await db.readSetting('device'), '1');
  });

  test('update and delete report the rows they changed', () async {
    await db.into(db.timelineItemEntries).insert(item('home', '1'));
    await db.into(db.timelineItemEntries).insert(item('home', '2'));

    final updated =
        await (db.update(db.timelineItemEntries)
              ..where((t) => t.itemKey.equals('1')))
            .write(const TimelineItemEntriesCompanion(pageToken: Value('p')));
    final none =
        await (db.update(db.timelineItemEntries)
              ..where((t) => t.itemKey.equals('nope')))
            .write(const TimelineItemEntriesCompanion(pageToken: Value('p')));
    final deleted = await db.delete(db.timelineItemEntries).go();

    expect([updated, none, deleted], [1, 0, 2]);
  });

  test('a failed transaction is rolled back', () async {
    await db.into(db.timelineItemEntries).insert(item('home', '1'));

    await expectLater(
      db.transaction(() async {
        await db.delete(db.timelineItemEntries).go();
        await db.into(db.timelineItemEntries).insert(item('home', '2'));
        throw StateError('boom');
      }),
      throwsStateError,
    );

    expect(await itemKeys('home'), ['1']);
  });

  test('a failed nested transaction rolls back only its own work', () async {
    await db.transaction(() async {
      await db.into(db.timelineItemEntries).insert(item('home', '1'));
      try {
        await db.transaction(() async {
          await db.into(db.timelineItemEntries).insert(item('home', '2'));
          throw StateError('inner');
        });
      } on StateError {
        // The outer transaction goes on.
      }
      await db.into(db.timelineItemEntries).insert(item('home', '3'));
    });

    expect(await itemKeys('home'), ['3', '1']);
  });

  test('an account switch empties every account table', () async {
    await db.claimCacheFor('a');
    await db.into(db.timelineItemEntries).insert(item('home', '1'));
    await db.writeSetting('appearance', 'dark');

    expect(await db.claimCacheFor('b'), isTrue);

    expect(await itemKeys('home'), isEmpty);
    expect(await db.readSetting(kCacheOwnerKey), 'b');
    expect(await db.readSetting('appearance'), 'dark', reason: 'device');
  });

  test('a statement outside the subset fails loudly in debug', () async {
    await expectLater(
      db
          .customSelect(
            'SELECT * FROM timeline_item_entries a '
            'JOIN timeline_state_entries b ON a.feed_key = b.feed_key',
          )
          .get(),
      throwsUnsupportedError,
    );
  });
}
