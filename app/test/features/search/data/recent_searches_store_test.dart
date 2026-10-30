import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dzeroth/core/storage/app_database.dart';
import 'package:dzeroth/features/search/data/recent_searches_store.dart';

void main() {
  late AppDatabase db;
  late DatabaseRecentSearchesStore store;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    store = DatabaseRecentSearchesStore(db);
  });
  tearDown(() => db.close());

  test('starts empty', () async {
    expect(await store.read('u1'), isEmpty);
  });

  test('newest first and de-duplicated (moves to the front)', () async {
    await store.add('u1', 'a1');
    await store.add('u1', '#go');
    await store.add('u1', 'a1');
    expect(await store.read('u1'), ['a1', '#go']);
  });

  test('blank queries are ignored', () async {
    await store.add('u1', '   ');
    expect(await store.read('u1'), isEmpty);
  });

  test('11 searches drop the oldest', () async {
    for (var i = 1; i <= 11; i++) {
      await store.add('u1', 'q$i');
    }
    final list = await store.read('u1');
    expect(list, hasLength(kRecentSearchesMax));
    expect(list.first, 'q11');
    expect(list.last, 'q2');
    expect(list, isNot(contains('q1')));
  });

  test('remove drops one entry; clear drops all', () async {
    await store.add('u1', 'aa');
    await store.add('u1', 'bb');
    await store.add('u1', 'cc');
    await store.remove('u1', 'bb');
    await store.remove('u1', 'missing');
    expect(await store.read('u1'), ['cc', 'aa']);
    await store.clear('u1');
    expect(await store.read('u1'), isEmpty);
    expect(await db.readSetting(DatabaseRecentSearchesStore.key('u1')), isNull);
  });

  test('removing the last entry leaves no row behind', () async {
    await store.add('u1', 'aa');
    await store.remove('u1', 'aa');
    expect(await db.readSetting(DatabaseRecentSearchesStore.key('u1')), isNull);
  });

  test('accounts do not share a list', () async {
    await store.add('u1', 'aa');
    await store.add('u2', 'bb');
    expect(await store.read('u1'), ['aa']);
    expect(await store.read('u2'), ['bb']);
  });

  test('sign-out (clearAll) leaves the next user an empty list', () async {
    await store.add('u1', 'aa');
    await db.clearAll();
    expect(await store.read('u1'), isEmpty);
    expect(await store.read('u2'), isEmpty);
  });

  test('a write that started before sign-out is dropped', () async {
    await store.add('u1', 'aa');
    final late = store.add('u1', 'bb');
    db.sessionEpoch.end();
    await db.clearAll();
    await late;
    expect(await store.read('u1'), isEmpty);
  });

  test('a corrupt value reads as empty and heals on the next add', () async {
    await db.writeSetting(DatabaseRecentSearchesStore.key('u1'), 'not json');
    expect(await store.read('u1'), isEmpty);
    await store.add('u1', 'aa');
    expect(await store.read('u1'), ['aa']);
  });
}
