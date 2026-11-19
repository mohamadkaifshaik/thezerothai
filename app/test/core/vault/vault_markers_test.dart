import 'package:drift/native.dart';
import 'package:drift_flutter/drift_flutter.dart'
    show WasmStorageImplementation;
import 'package:dzeroth/core/storage/app_database.dart';
import 'package:dzeroth/core/vault/vault_cipher.dart';
import 'package:dzeroth/core/vault/vault_markers.dart';
import 'package:flutter_test/flutter_test.dart';

const _uid = 'firebase-uid-123';
final _alias = vaultKeyAlias(_uid);
final _other = vaultKeyAlias('other-user');

void main() {
  late AppDatabase db;
  late DriftVaultMarkers markers;
  late List<String> corrupt;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    corrupt = [];
    markers = DriftVaultMarkers(db, persistent: true, onCorrupt: corrupt.add);
  });
  tearDown(() => db.close());

  Future<Map<String, String>> settings() async => {
    for (final r in await db.select(db.appSettingEntries).get())
      r.settingKey: r.settingValue,
  };

  Future<void> writeEverything(String alias) async {
    await markers.writeKnown(
      KnownVault(alias: alias, storage: 'opfsLocks', createdAtMicros: 7),
    );
    await markers.writeKeyLostSeen(
      alias,
      const KeyLostSeen(launchId: 'launch-1', atMicros: 9),
    );
    await markers.writeWipeOwed(OwedWipe(alias, fileStarted: true));
    await markers.writePendingEnd(alias);
  }

  test('keys are device settings named by the vault alias, outside the '
      'account prefix; NO key and NO value holds the uid', () async {
    await writeEverything(_alias);
    final all = await settings();
    expect(all.keys.toSet(), {
      'vault.known.$_alias',
      'vault.keyLostSeen.$_alias',
      'vault.wipeOwed.$_alias',
      'vault.pendingEnd.$_alias',
    });
    for (final MapEntry(:key, :value) in all.entries) {
      expect(key, isNot(contains(_uid)));
      expect(value, isNot(contains(_uid)));
      expect(key.startsWith(kAccountSettingPrefix), isFalse);
    }
  });

  test('round trip', () async {
    expect(await markers.known(_alias), isNull);
    await writeEverything(_alias);
    final known = (await markers.known(_alias))!;
    expect(known.alias, _alias);
    expect(known.storage, 'opfsLocks');
    expect(known.createdAtMicros, 7);
    expect((await markers.knownVaults()).map((k) => k.alias), [_alias]);

    final seen = (await markers.keyLostSeen(_alias))!;
    expect(seen.launchId, 'launch-1');
    expect(seen.atMicros, 9);
    await markers.clearKeyLostSeen(_alias);
    expect(await markers.keyLostSeen(_alias), isNull);

    await markers.writeWipeOwed(
      OwedWipe(_other, fileDone: true, anyCopy: true),
    );
    final owed = {for (final o in await markers.owedWipes()) o.alias: o};
    expect(owed[_alias]!.fileStarted, isTrue);
    expect(owed[_alias]!.fileDone, isFalse);
    expect(owed[_other]!.fileDone, isTrue);
    expect(owed[_other]!.anyCopy, isTrue);

    expect(await markers.pendingEnds(), [_alias]);
    await markers.clearPendingEnd(_alias);
    expect(await markers.pendingEnds(), isEmpty);
  });

  test('the sign-out cache wipe keeps every marker', () async {
    await writeEverything(_alias);
    await db.clearAll();
    expect(await markers.known(_alias), isNotNull);
    expect(await markers.keyLostSeen(_alias), isNotNull);
    expect((await markers.owedWipes()).map((o) => o.alias), [_alias]);
    expect(await markers.pendingEnds(), [_alias]);
  });

  test('clearAll removes every marker of one user only', () async {
    await writeEverything(_alias);
    await writeEverything(_other);
    await db.writeSetting('appearance', 'dark');
    await markers.clearAll(_alias);
    expect(await markers.known(_alias), isNull);
    expect(await markers.keyLostSeen(_alias), isNull);
    expect((await markers.owedWipes()).map((o) => o.alias), [_other]);
    expect(await markers.pendingEnds(), [_other]);
    expect(await markers.known(_other), isNotNull);
    expect(await db.readSetting('appearance'), 'dark');
  });

  test('a value whose alias is not its key\'s alias is corrupt: reported, '
      'never acted on', () async {
    // Copy B's values under A's keys.
    await writeEverything(_other);
    final all = await settings();
    for (final MapEntry(:key, :value) in all.entries) {
      await db.writeSetting(key.replaceAll(_other, _alias), value);
    }
    expect(await markers.known(_alias), isNull);
    expect(await markers.keyLostSeen(_alias), isNull);
    final owed = await markers.owedWipes();
    expect(owed.map((o) => o.alias), [_other]);
    expect(await markers.pendingEnds(), [_other]);
    expect(corrupt, isNotEmpty);
    // Garbage too.
    corrupt.clear();
    await db.writeSetting('vault.known.$_alias', 'not json');
    expect(await markers.known(_alias), isNull);
    expect(corrupt, ['vault.known.']);
  });

  test('a non-alias argument is refused', () async {
    await expectLater(markers.known(_uid), throwsArgumentError);
    await expectLater(markers.clearAll(_uid), throwsArgumentError);
    expect(
      () => KnownVault(alias: _uid, storage: 'native', createdAtMicros: 0),
      throwsArgumentError,
    );
  });

  group('persistent', () {
    test('the drift markers are persistent only when told so and keeping '
        'data', () {
      expect(DriftVaultMarkers(db, persistent: true).persistent, isTrue);
      expect(DriftVaultMarkers(db, persistent: false).persistent, isFalse);
      final nothing = AppDatabase.keepingNothing();
      addTearDown(nothing.close);
      expect(DriftVaultMarkers(nothing, persistent: true).persistent, isFalse);
    });

    test('the decision: an in-memory cache never; native when on disk; the '
        'web only on a storage the vault itself accepts', () {
      bool decide({
        bool inMemory = false,
        bool isWeb = true,
        WasmStorageImplementation? storage,
      }) => vaultMarkersPersistent(
        cacheInMemory: inMemory,
        isWeb: isWeb,
        cacheWebStorage: storage,
      );
      expect(decide(isWeb: false), isTrue);
      expect(decide(isWeb: false, inMemory: true), isFalse);
      const expected = {
        WasmStorageImplementation.opfsShared: true,
        WasmStorageImplementation.opfsLocks: true,
        WasmStorageImplementation.sharedIndexedDb: true,
        WasmStorageImplementation.unsafeIndexedDb: false,
        WasmStorageImplementation.inMemory: false,
      };
      expect(expected.keys.toSet(), WasmStorageImplementation.values.toSet());
      for (final MapEntry(:key, :value) in expected.entries) {
        expect(decide(storage: key), value, reason: '$key');
        expect(decide(storage: key, inMemory: true), isFalse);
      }
      expect(decide(), isFalse, reason: 'web storage never reported');
    });
  });
}
