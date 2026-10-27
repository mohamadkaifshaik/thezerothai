import 'package:drift/native.dart';
import 'package:dzeroth/core/storage/app_database.dart';
import 'package:dzeroth/features/notifications/data/push_opt_in_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase database;
  const key = '${kAccountSettingPrefix}suggestions:uid-1';

  setUp(() => database = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => database.close());

  test('an account setting is written and read like any setting', () async {
    await database.writeAccountSetting(
      key,
      'v',
      epoch: database.sessionEpoch.value,
    );

    expect(await database.readSetting(key), 'v');
  });

  test('the write is dropped when the session ended since the epoch was '
      'read', () async {
    final started = database.sessionEpoch.value;
    database.sessionEpoch.end();

    await database.writeAccountSetting(key, 'late', epoch: started);

    expect(await database.readSetting(key), isNull);
  });

  test('sign-out wipes account settings and keeps device settings', () async {
    final epoch = database.sessionEpoch.value;
    await database.writeAccountSetting(key, 'v', epoch: epoch);
    await database.writeSetting('theme_mode', 'dark');
    await database.writeSetting(DatabasePushOptInStore.key('uid-1'), '1');

    await database.clearAll();

    expect(await database.readSetting(key), isNull);
    expect(await database.readSetting('theme_mode'), 'dark');
    expect(
      await database.readSetting(DatabasePushOptInStore.key('uid-1')),
      '1',
    );
  });
}
