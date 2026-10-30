import 'package:drift/native.dart';
import 'package:dzeroth/core/storage/app_database.dart';
import 'package:flutter_test/flutter_test.dart';

/// W7-35 (L-4): the cache says whose it is, and a different or missing owner
/// is wiped before anything reads it.
void main() {
  late AppDatabase database;

  setUp(() => database = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => database.close());

  Future<void> seedProfile(String uid) => database.upsertProfile(
    ProfileCacheEntriesCompanion.insert(
      userId: uid,
      handle: 'h$uid',
      displayName: 'N',
      cachedAt: DateTime.now(),
    ),
    epoch: database.sessionEpoch.value,
  );

  test('no stamp (first run, or a cache from before the stamp): wiped and '
      'claimed', () async {
    await seedProfile('a');

    expect(await database.claimCacheFor('a'), isTrue);

    expect(await database.profileByUserId('a'), isNull);
    expect(await database.readSetting(kCacheOwnerKey), 'a');
  });

  test('the same owner keeps the cache', () async {
    await database.claimCacheFor('a');
    await seedProfile('a');

    expect(await database.claimCacheFor('a'), isFalse);

    expect(await database.profileByUserId('a'), isNotNull);
  });

  test('another user (sign-out missed, or A straight to B) gets an empty '
      'cache and the stamp moves', () async {
    await database.claimCacheFor('a');
    await seedProfile('a');
    final epoch = database.sessionEpoch.value;

    expect(await database.claimCacheFor('b'), isTrue);

    expect(await database.profileByUserId('a'), isNull);
    expect(await database.readSetting(kCacheOwnerKey), 'b');
    expect(database.sessionEpoch.allows(epoch), isFalse);
  });

  test('nobody signed in: a stamped cache is wiped, an unstamped one is '
      'left', () async {
    await database.claimCacheFor('a');
    await seedProfile('a');

    expect(await database.claimCacheFor(null), isTrue);
    expect(await database.profileByUserId('a'), isNull);
    expect(await database.readSetting(kCacheOwnerKey), isNull);
    expect(await database.claimCacheFor(null), isFalse);
  });

  test(
    'sign-out clears the stamp with the data; device settings stay',
    () async {
      await database.writeSetting('theme_mode', 'dark');
      await database.claimCacheFor('a');

      await database.clearAll();

      expect(await database.readSetting(kCacheOwnerKey), isNull);
      expect(await database.readSetting('theme_mode'), 'dark');
    },
  );
}
