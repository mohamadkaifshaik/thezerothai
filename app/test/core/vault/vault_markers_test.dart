import 'package:drift/native.dart';
import 'package:dzeroth/core/storage/app_database.dart';
import 'package:dzeroth/core/vault/vault_cipher.dart';
import 'package:dzeroth/core/vault/vault_markers.dart';
import 'package:flutter_test/flutter_test.dart';

const _uid = 'firebase-uid-123';

void main() {
  late AppDatabase db;
  late DriftVaultMarkers markers;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    markers = DriftVaultMarkers(db, persistent: true);
  });
  tearDown(() => db.close());

  Future<Map<String, String>> settings() async => {
    for (final r in await db.select(db.appSettingEntries).get())
      r.settingKey: r.settingValue,
  };

  test('keys are device settings named by the vault alias, never the raw '
      'uid, and outside the account prefix', () async {
    await markers.writeKnown(
      const KnownVault(uid: _uid, storage: 'opfsLocks', createdAtMicros: 7),
    );
    await markers.writeKeyLostSeen(_uid, 'launch-1');
    await markers.writeWipeOwed(_uid);
    final alias = vaultKeyAlias(_uid);
    final keys = (await settings()).keys.toSet();
    expect(keys, {
      'vault.known.$alias',
      'vault.keyLostSeen.$alias',
      'vault.wipeOwed.$alias',
    });
    for (final k in keys) {
      expect(k, isNot(contains(_uid)));
      expect(k.startsWith(kAccountSettingPrefix), isFalse);
    }
  });

  test('round trip', () async {
    expect(await markers.known(_uid), isNull);
    await markers.writeKnown(
      const KnownVault(
        uid: _uid,
        storage: 'sharedIndexedDb',
        createdAtMicros: 42,
      ),
    );
    final known = (await markers.known(_uid))!;
    expect(known.uid, _uid);
    expect(known.storage, 'sharedIndexedDb');
    expect(known.createdAtMicros, 42);
    expect((await markers.knownVaults()).map((k) => k.uid), [_uid]);
    expect(known.toString(), isNot(contains(_uid)));

    await markers.writeKeyLostSeen(_uid, 'launch-9');
    expect(await markers.keyLostSeen(_uid), 'launch-9');
    await markers.clearKeyLostSeen(_uid);
    expect(await markers.keyLostSeen(_uid), isNull);

    await markers.writeWipeOwed(_uid);
    await markers.writeWipeOwed('other', fileDone: true);
    final owed = {for (final o in await markers.owedWipes()) o.uid: o.fileDone};
    expect(owed, {_uid: false, 'other': true});
    await markers.writeWipeOwed('other');
    expect(
      (await markers.owedWipes()).firstWhere((o) => o.uid == 'other').fileDone,
      isFalse,
    );
  });

  test('the sign-out cache wipe keeps every marker', () async {
    await markers.writeKnown(
      const KnownVault(uid: _uid, storage: 'native', createdAtMicros: 1),
    );
    await markers.writeKeyLostSeen(_uid, 'l');
    await markers.writeWipeOwed(_uid);
    await db.clearAll();
    expect(await markers.known(_uid), isNotNull);
    expect(await markers.keyLostSeen(_uid), 'l');
    expect((await markers.owedWipes()).map((o) => o.uid), [_uid]);
  });

  test('clearAll removes every marker of one user only', () async {
    for (final uid in [_uid, 'other']) {
      await markers.writeKnown(
        KnownVault(uid: uid, storage: 'native', createdAtMicros: 1),
      );
      await markers.writeKeyLostSeen(uid, 'l');
      await markers.writeWipeOwed(uid);
    }
    await db.writeSetting('appearance', 'dark');
    await markers.clearAll(_uid);
    expect(await markers.known(_uid), isNull);
    expect(await markers.keyLostSeen(_uid), isNull);
    expect((await markers.owedWipes()).map((o) => o.uid), ['other']);
    expect(await markers.known('other'), isNotNull);
    expect(await db.readSetting('appearance'), 'dark');
  });

  test('a damaged or foreign value reads as absent', () async {
    final alias = vaultKeyAlias(_uid);
    await db.writeSetting('vault.known.$alias', 'not json');
    expect(await markers.known(_uid), isNull);
    expect(await markers.knownVaults(), isEmpty);
    await db.writeSetting(
      'vault.known.$alias',
      '{"uid":"someone-else","storage":"native","createdAt":1}',
    );
    expect(await markers.known(_uid), isNull);
    await db.writeSetting('vault.wipeOwed.$alias', '[1]');
    expect(await markers.owedWipes(), isEmpty);
  });

  test('persistent only when the cache is on disk and keeps data', () {
    expect(DriftVaultMarkers(db, persistent: true).persistent, isTrue);
    expect(DriftVaultMarkers(db, persistent: false).persistent, isFalse);
    final nothing = AppDatabase.keepingNothing();
    addTearDown(nothing.close);
    expect(DriftVaultMarkers(nothing, persistent: true).persistent, isFalse);
  });
}
