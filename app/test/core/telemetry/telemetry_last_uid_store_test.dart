import 'package:drift/native.dart';
import 'package:dzeroth/core/storage/app_database.dart';
import 'package:dzeroth/core/telemetry/telemetry_inputs.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase database;
  late DatabaseTelemetryLastUidStore store;

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    store = DatabaseTelemetryLastUidStore(database);
  });

  tearDown(() => database.close());

  test('nothing recorded reads as null; a write round-trips', () async {
    expect(await store.read(), isNull);
    await store.write('uid-a');
    expect(await store.read(), 'uid-a');
    expect(await database.readSetting('telemetry_last_uid'), 'uid-a');
    await store.write('uid-b');
    expect(await store.read(), 'uid-b');
  });

  test('forget drops the record only for the matching uid', () async {
    await store.write('uid-a');
    await store.forget('uid-b');
    expect(await store.read(), 'uid-a');
    await store.forget('uid-a');
    expect(await store.read(), isNull);
  });

  test('the record survives the sign-out wipe and a cache claim by another '
      'uid', () async {
    await store.write('uid-a');
    await database.clearAll();
    await database.claimCacheFor('uid-b');
    await database.claimCacheFor(null);
    expect(await store.read(), 'uid-a');
  });
}
