import 'package:drift/native.dart';
import 'package:dzeroth/core/storage/app_database.dart';
import 'package:dzeroth/features/notifications/data/push_opt_in_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase database;
  late DatabasePushOptInStore store;

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    store = DatabasePushOptInStore(database);
  });

  tearDown(() => database.close());

  test('nothing recorded reads as null', () async {
    expect(await store.readNotNow('uid-a'), isNull);
  });

  test('the record round-trips to the millisecond', () async {
    final at = DateTime.now().toUtc();
    await store.writeNotNow('uid-a', at);

    final read = await store.readNotNow('uid-a');
    expect(read!.millisecondsSinceEpoch, at.millisecondsSinceEpoch);
  });

  test('two accounts do not share the record', () async {
    await store.writeNotNow('uid-a', DateTime.now().toUtc());

    expect(await store.readNotNow('uid-b'), isNull);
    expect(await database.readSetting('push_opt_in_not_now:uid-a'), isNotNull);
    expect(await database.readSetting('push_opt_in_not_now:uid-b'), isNull);
  });

  test('a later "Not now" replaces the earlier one', () async {
    final first = DateTime.now().toUtc();
    final second = first.add(const Duration(days: 31));
    await store.writeNotNow('uid-a', first);
    await store.writeNotNow('uid-a', second);

    expect(
      (await store.readNotNow('uid-a'))!.millisecondsSinceEpoch,
      second.millisecondsSinceEpoch,
    );
  });

  test('an unreadable value reads as no record', () async {
    await database.writeSetting('push_opt_in_not_now:uid-a', 'not-a-number');

    expect(await store.readNotNow('uid-a'), isNull);
  });

  test(
    'clearing the session cache keeps the record (a device setting)',
    () async {
      await store.writeNotNow('uid-a', DateTime.now().toUtc());
      await database.clearAll();

      expect(await store.readNotNow('uid-a'), isNotNull);
    },
  );

  test(
    'forget removes that uid only; a sign-out wipe keeps both (L-6)',
    () async {
      await store.writeNotNow('uid-a', DateTime.now().toUtc());
      await store.writeNotNow('uid-b', DateTime.now().toUtc());

      // Plain sign-out: both stay.
      await database.clearAll();
      expect(await store.readNotNow('uid-a'), isNotNull);
      expect(await store.readNotNow('uid-b'), isNotNull);

      // Account deletion: the deleted uid's key is gone from the table.
      await store.forget('uid-a');
      expect(await store.readNotNow('uid-a'), isNull);
      expect(await database.readSetting('push_opt_in_not_now:uid-a'), isNull);
      expect(await store.readNotNow('uid-b'), isNotNull);
    },
  );

  test('forgetting a uid with no record is a no-op', () async {
    await store.forget('uid-a');
    expect(await store.readNotNow('uid-a'), isNull);
  });
}
