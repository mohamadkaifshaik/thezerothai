import 'package:drift/native.dart';
import 'package:dzeroth/core/storage/app_database.dart';
import 'package:dzeroth/core/telemetry/telemetry_consent_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase database;
  late TelemetryConsentStore store;

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    store = TelemetryConsentStore(database);
  });

  tearDown(() async {
    await store.dispose();
    await database.close();
  });

  test(
    'nothing recorded reads as unasked, and unasked never consents',
    () async {
      await store.load('uid-a');

      expect(store.isLoaded('uid-a'), isTrue);
      expect(store.choice('uid-a', TelemetryKind.crash), ConsentChoice.unasked);
      expect(store.choice('uid-a', TelemetryKind.usage), ConsentChoice.unasked);
      expect(store.crashConsented('uid-a'), isFalse);
      expect(store.usageConsented('uid-a'), isFalse);
    },
  );

  test('a uid that was never loaded does not consent', () {
    expect(store.isLoaded('uid-a'), isFalse);
    expect(store.crashConsented('uid-a'), isFalse);
  });

  test('answers use the documented keys and survive a new store', () async {
    await store.load('uid-a');
    await store.set('uid-a', TelemetryKind.crash, ConsentChoice.on);
    await store.set('uid-a', TelemetryKind.usage, ConsentChoice.off);

    expect(await database.readSetting('telemetry_consent:crash:uid-a'), 'on');
    expect(await database.readSetting('telemetry_consent:usage:uid-a'), 'off');

    final relaunched = TelemetryConsentStore(database);
    addTearDown(relaunched.dispose);
    await relaunched.load('uid-a');
    expect(relaunched.crashConsented('uid-a'), isTrue);
    expect(relaunched.usageConsented('uid-a'), isFalse);
    expect(relaunched.choice('uid-a', TelemetryKind.usage), ConsentChoice.off);
  });

  test('two accounts on one device do not share an answer', () async {
    await store.load('uid-a');
    await store.load('uid-b');
    await store.setAll('uid-a', {
      TelemetryKind.crash: ConsentChoice.on,
      TelemetryKind.usage: ConsentChoice.on,
    });

    expect(store.crashConsented('uid-a'), isTrue);
    expect(store.crashConsented('uid-b'), isFalse);
    expect(store.choice('uid-b', TelemetryKind.usage), ConsentChoice.unasked);
    expect(await database.readSetting('telemetry_consent:crash:uid-b'), isNull);
    expect(await database.readSetting('telemetry_consent:usage:uid-b'), isNull);
  });

  test('the cache is updated and announced before the disk write', () async {
    await store.load('uid-a');
    final seen = <bool>[];
    store.changes.listen((_) => seen.add(store.crashConsented('uid-a')));

    final write = store.set('uid-a', TelemetryKind.crash, ConsentChoice.on);
    expect(seen, [true]); // already announced, write still pending
    await write;

    final off = store.set('uid-a', TelemetryKind.crash, ConsentChoice.off);
    expect(seen, [true, false]);
    await off;
    expect(await database.readSetting('telemetry_consent:crash:uid-a'), 'off');
  });

  test('setAll is one change event', () async {
    await store.load('uid-a');
    var events = 0;
    store.changes.listen((_) => events++);

    await store.setAll('uid-a', {
      TelemetryKind.crash: ConsentChoice.on,
      TelemetryKind.usage: ConsentChoice.off,
    });

    expect(events, 1);
  });

  test('forget drops one account only; sign-out keeps the keys', () async {
    await store.load('uid-a');
    await store.load('uid-b');
    await store.setAll('uid-a', {
      TelemetryKind.crash: ConsentChoice.on,
      TelemetryKind.usage: ConsentChoice.on,
    });
    await store.setAll('uid-b', {TelemetryKind.crash: ConsentChoice.on});

    await store.forget('uid-a');

    expect(await database.readSetting('telemetry_consent:crash:uid-a'), isNull);
    expect(await database.readSetting('telemetry_consent:usage:uid-a'), isNull);
    expect(store.crashConsented('uid-a'), isFalse);
    expect(store.crashConsented('uid-b'), isTrue);
    expect(await database.readSetting('telemetry_consent:crash:uid-b'), 'on');
  });

  test('load announces, so the controller re-decides', () async {
    var events = 0;
    store.changes.listen((_) => events++);
    await store.load('uid-a');
    expect(events, 1);
  });
}
