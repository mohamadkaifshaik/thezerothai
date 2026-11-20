import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:dzeroth/core/vault/secure_vault.dart';
import 'package:dzeroth/core/vault/vault_database.dart';
import 'package:dzeroth/core/vault/vault_session.dart';
import 'package:dzeroth/core/vault/vault_status.dart';
import 'package:dzeroth/features/messages/domain/e2ee/daily_ledger.dart';
import 'package:dzeroth/features/messages/domain/e2ee/e2ee_types.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../support/fake_vault_cipher.dart';
import '../../../../support/fake_vault_world.dart';

const String _uid = 'user-a';
const String _conv = 'conv-secret-id-12345';

void main() {
  late Directory dir;
  late VaultDatabase db;
  late VaultSession session;
  late FakeVaultWorld world;
  late DateTime clock;
  late List<Object> reported;
  final List<String> sessionErrors = [];

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('daily_ledger_test');
    db = VaultDatabase.forTesting(
      NativeDatabase(File('${dir.path}${Platform.pathSeparator}v.sqlite')),
    );
    world = FakeVaultWorld();
    // Any day; only the IST day boundary matters (18:30 UTC).
    final year = DateTime.now().toUtc().year;
    clock = DateTime.utc(year, 3, 10, 12);
    reported = [];
    session = VaultSession(
      openCipher: (uid, {required create}) async => FakeVaultCipher(),
      openVault: ({
        required uid,
        required cipher,
        expectedStorage,
        required create,
      }) => openVaultOnDatabase(db, uid: uid, cipher: cipher),
      wipeVaultFile: ({required alias, expectedStorage}) async {},
      deleteVaultKey: ({required alias}) async {},
      createOwner: () => FakeVaultOwner(world),
      markers: world.markers,
      supported: true,
      launchId: 'launch-1',
      now: () => clock,
      onUnexpectedError: (e, s) => sessionErrors.add('$e $s'),
    );
    await session.start(restoredUid: null, restoreDefinitive: true);
    await session.onSignedIn(_uid, flag: E2eeFlag.on);
    expect(
      session.vault,
      isNotNull,
      reason: '${session.status.value} $sessionErrors',
    );
  });

  tearDown(() async {
    await session.close();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {
      // Windows can hold the file briefly; the OS temp dir is cleaned anyway.
    }
  });

  DailyLedger ledger() => DailyLedger(
    session: session,
    now: () => clock,
    onUnexpectedError: (e, _) => reported.add(e),
  );

  test('counts survive a new DailyLedger on the same vault', () async {
    final first = ledger();
    await first.addUndone(_conv);
    await first.addUndone(_conv);
    await first.markLostSendUpdate(_conv);
    final device = Uint8List.fromList([1, 2, 3]);
    await first.markEmptyClaim(device);

    final second = ledger();
    expect(await second.undone(_conv), 2);
    expect(await second.undone('other'), 0);
    expect(await second.lostSendUpdateDone(_conv), isTrue);
    expect(await second.lostSendUpdateDone('other'), isFalse);
    expect(await second.emptyClaimTried(device), isTrue);
    expect(await second.emptyClaimTried(Uint8List.fromList([9])), isFalse);
  });

  test('the record is replaced when the IST day changes', () async {
    final l = ledger();
    await l.addUndone(_conv);
    await l.markLostSendUpdate(_conv);
    // 18:29 UTC is still the same IST day; 18:31 UTC is the next one.
    clock = DateTime.utc(clock.year, 3, 10, 18, 29);
    expect(await l.undone(_conv), 1);
    clock = DateTime.utc(clock.year, 3, 10, 18, 31);
    expect(await l.undone(_conv), 0);
    expect(await l.lostSendUpdateDone(_conv), isFalse);
    expect((await l.read()).day, istDay(clock));
    await l.addUndone(_conv);
    expect(await l.undone(_conv), 1);
  });

  test('the raw settings value holds no conversation id in clear', () async {
    final l = ledger();
    await l.addUndone(_conv);
    await l.markLostSendUpdate(_conv);
    final rows = await db.select(db.vaultSettings).get();
    final row = rows.singleWhere((r) => r.settingKey == kVaultSettingE2eeDaily);
    expect(row.settingKey, 'messages.e2ee.daily');
    expect(
      utf8.decode(row.value, allowMalformed: true),
      isNot(contains(_conv)),
    );
    expect(
      utf8.decode(row.value, allowMalformed: true),
      isNot(contains('conv-secret')),
    );
    // The unsealed value is JSON with a version and the conversation id.
    final plain = utf8.decode(
      (await session.vault!.setting(kVaultSettingE2eeDaily))!,
    );
    expect(jsonDecode(plain)['v'], 1);
  });

  Future<void> store(Uint8List bytes) => session.runWrite(
    (v) => v.transaction((tx) => tx.putSetting(kVaultSettingE2eeDaily, bytes)),
  );

  Future<void> storeGarbage() =>
      store(Uint8List.fromList(utf8.encode('not json')));

  String dayOffset(int days) => istDay(clock.add(Duration(days: days)));

  test('an unreadable value reads every counter at its cap for the rest of '
      'the day and is reported once', () async {
    await storeGarbage();
    final l = ledger();
    expect(await l.undone(_conv), kAntiFlapUndosPerDay);
    expect(await l.undone('other'), kAntiFlapUndosPerDay);
    expect(await l.lostSendUpdateDone(_conv), isTrue);
    expect(await l.lostSendUpdateDone('other'), isTrue);
    expect(await l.emptyClaimTried(Uint8List.fromList([9])), isTrue);
    expect((await l.read()).exhausted, isTrue);
    expect(reported, hasLength(1));
    expect(reported.single, isA<E2eePipelineError>());
    // A write keeps the marker: the cap is not reopened.
    await l.addUndone(_conv);
    expect(await l.undone('other'), kAntiFlapUndosPerDay);
    expect(reported, hasLength(1));
  });

  test('another version of the value is unreadable too', () async {
    await store(Uint8List.fromList(utf8.encode('{"v":2,"day":"x"}')));
    expect(await ledger().lostSendUpdateDone(_conv), isTrue);
    expect(reported, hasLength(1));
  });

  test(
    'the exhausted marker survives a reopen and clears the next day',
    () async {
      await storeGarbage();
      expect(await ledger().undone(_conv), kAntiFlapUndosPerDay);
      final reopened = ledger();
      expect(await reopened.undone(_conv), kAntiFlapUndosPerDay);
      expect(await reopened.lostSendUpdateDone(_conv), isTrue);
      expect(reported, hasLength(1));
      clock = clock.add(const Duration(days: 1));
      expect(await reopened.undone(_conv), 0);
      expect(await reopened.lostSendUpdateDone(_conv), isFalse);
      expect((await reopened.read()).exhausted, isFalse);
    },
  );

  test('a record dated after today is kept and its counters apply', () async {
    await store(
      DailyRecord(
        day: dayOffset(1),
        undone: {_conv: 1},
        lostSendUpdate: {_conv},
      ).encode(),
    );
    final l = ledger();
    expect(await l.undone(_conv), 1);
    expect(await l.lostSendUpdateDone(_conv), isTrue);
    await l.addUndone(_conv);
    expect(await l.undone(_conv), 2);
    expect((await l.read()).day, dayOffset(1));
  });

  test('a record dated before today is replaced', () async {
    await store(
      DailyRecord(
        day: dayOffset(-1),
        undone: {_conv: 1},
        lostSendUpdate: {_conv},
      ).encode(),
    );
    final l = ledger();
    expect(await l.undone(_conv), 0);
    expect(await l.lostSendUpdateDone(_conv), isFalse);
    expect((await l.read()).day, dayOffset(0));
  });

  test('a counter outside 0..2^53-1 is refused on write', () async {
    final l = ledger();
    final current = await l.read();
    expect(
      session.runWrite(
        (v) => v.transaction(
          (tx) =>
              l.writeIn(tx, current, (r) => r.copyWith(undone: {_conv: -1})),
        ),
      ),
      throwsArgumentError,
    );
    expect(
      session.runWrite(
        (v) => v.transaction(
          (tx) => l.writeIn(
            tx,
            current,
            (r) => r.copyWith(undone: {_conv: 9007199254740992}),
          ),
        ),
      ),
      throwsArgumentError,
    );
  });

  test('writeIn applies the change through the caller transaction', () async {
    final l = ledger();
    final current = await l.read();
    await session.runWrite(
      (v) => v.transaction(
        (tx) => l.writeIn(
          tx,
          current,
          (r) => r.copyWith(lostSendUpdate: {...r.lostSendUpdate, _conv}),
        ),
      ),
    );
    expect(await l.lostSendUpdateDone(_conv), isTrue);
  });

  test('a write with the vault not ready fails with StateError', () async {
    final l = ledger();
    await session.close();
    expect(l.addUndone(_conv), throwsStateError);
  });
}
