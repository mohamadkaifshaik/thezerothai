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

  Future<void> writeInBody(
    DailyLedger l,
    DailyRecord current,
    DailyRecord Function(DailyRecord) change,
  ) => session.runWrite(
    (v) => v.transaction((tx) => l.writeIn(tx, current, change)),
  );

  test('writeIn keeps a count another conversation wrote after the caller '
      'read', () async {
    final l = ledger();
    final current = await l.read();
    // Another conversation's change lands between the read and the write.
    await l.addUndone('other');
    await l.markEmptyClaim(Uint8List.fromList([4]));
    await writeInBody(
      l,
      current,
      (r) => r.copyWith(lostSendUpdate: {...r.lostSendUpdate, _conv}),
    );
    expect(await l.undone('other'), 1);
    expect(await l.emptyClaimTried(Uint8List.fromList([4])), isTrue);
    expect(await l.lostSendUpdateDone(_conv), isTrue);
  });

  test('a stale copy never clears the exhausted marker', () async {
    final l = ledger();
    final current = await l.read();
    expect(current.exhausted, isFalse);
    await store(DailyRecord.capped(dayOffset(0)).encode());
    await writeInBody(
      l,
      current,
      (r) => r.copyWith(lostSendUpdate: {...r.lostSendUpdate, _conv}),
    );
    expect((await l.read()).exhausted, isTrue);
    expect(await l.undone('other'), kAntiFlapUndosPerDay);
  });

  test(
    'a change that builds a new record keeps the exhausted marker',
    () async {
      final l = ledger();
      final current = await l.read();
      await store(DailyRecord.capped(dayOffset(0)).encode());
      // A change that ignores copyWith and builds a fresh (not exhausted)
      // record, through writeIn ...
      await writeInBody(
        l,
        current,
        (r) => DailyRecord(day: r.day, lostSendUpdate: {_conv}),
      );
      var after = await l.read();
      expect(after.exhausted, isTrue);
      expect(await l.undone('other'), kAntiFlapUndosPerDay);
      expect(await l.lostSendUpdateDone('other'), isTrue);
      expect(await l.emptyClaimTried(Uint8List.fromList([9])), isTrue);
      // ... and through the ledger's own writes.
      await l.addUndone(_conv);
      after = await l.read();
      expect(after.exhausted, isTrue);
      expect(await l.undone('other'), kAntiFlapUndosPerDay);
    },
  );

  test('writeIn over an unreadable value stores the capped record through '
      'the caller transaction', () async {
    final l = ledger();
    final current = await l.read();
    await storeGarbage();
    await writeInBody(l, current, (r) => r);
    expect((await l.read()).exhausted, isTrue);
    expect(reported, hasLength(1));
  });

  test('readLocked reads the record inside a runWrite body', () async {
    final l = ledger();
    await l.addUndone(_conv);
    final r = await session.runWrite((v) => l.readLocked(v));
    expect(r.undone[_conv], 1);
  });

  test('a record dated far after today reads capped for today only', () async {
    await store(DailyRecord(day: dayOffset(30), undone: {_conv: 0}).encode());
    final l = ledger();
    expect(await l.undone(_conv), kAntiFlapUndosPerDay);
    expect(await l.lostSendUpdateDone(_conv), isTrue);
    final r = await l.read();
    expect(r.day, dayOffset(0));
    expect(r.exhausted, isTrue);
    clock = clock.add(const Duration(days: 1));
    expect(await l.undone(_conv), 0);
    expect((await l.read()).exhausted, isFalse);
  });

  test('a record dated one day ahead is kept', () async {
    await store(DailyRecord(day: dayOffset(1), undone: {_conv: 1}).encode());
    final l = ledger();
    expect(await l.undone(_conv), 1);
    expect((await l.read()).day, dayOffset(1));
    expect((await l.read()).exhausted, isFalse);
  });

  test('a day that is not a date is an unreadable value', () async {
    // Built, not written as a date literal: '9999-99-99' sorts after any
    // real day, and 'not-a-day' is not a date at all.
    final bad = ['${'9' * 4}-99-99', 'not-a-day', '${'9' * 4}-12-1'];
    for (final day in bad) {
      final bytes = Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'v': 1,
            'day': day,
            'undone': <String, int>{},
            'did': <String, Object>{},
            'lostSendUpdate': <String>[],
            'emptyClaim': <String>[],
          }),
        ),
      );
      expect(
        () => DailyRecord.decode(bytes),
        throwsA(isA<VaultCorruptException>()),
        reason: day,
      );
    }
    await store(
      Uint8List.fromList(
        utf8.encode(
          '{"v":1,"day":"${'9' * 4}-99-99","undone":{},"did":{},'
          '"lostSendUpdate":[],"emptyClaim":[]}',
        ),
      ),
    );
    final l = ledger();
    expect(await l.undone(_conv), kAntiFlapUndosPerDay);
    expect(reported, hasLength(1));
    expect((await l.read()).day, dayOffset(0));
  });

  test(
    'an exhausted ledger refuses a reversal even when did is empty',
    () async {
      final device = Uint8List.fromList([7, 7]);
      final l = ledger();
      // Not exhausted, nothing done today: a reversal is not an undo.
      final fresh = await l.read();
      expect(fresh.isUndoOfOwnChange(_conv, device, removing: true), isFalse);
      expect(
        await l.isUndoOfOwnChange(_conv, device, removing: false),
        isFalse,
      );
      // A change this device made today is an undo when reversed.
      final did = DailyRecord(
        day: dayOffset(0),
        did: {
          _conv: DailyDevices(added: {vaultDeviceIdHex(device)}),
        },
      );
      expect(did.isUndoOfOwnChange(_conv, device, removing: true), isTrue);
      expect(did.isUndoOfOwnChange(_conv, device, removing: false), isFalse);
      // Exhausted: did is empty, and every reversal counts as an undo (the
      // undo cap then refuses it).
      await storeGarbage();
      final capped = await l.read();
      expect(capped.exhausted, isTrue);
      expect(capped.did, isEmpty);
      expect(capped.isUndoOfOwnChange(_conv, device, removing: true), isTrue);
      expect(capped.isUndoOfOwnChange(_conv, device, removing: false), isTrue);
      expect(await l.isUndoOfOwnChange(_conv, device, removing: true), isTrue);
    },
  );

  test('a write with the vault not ready fails with StateError', () async {
    final l = ledger();
    await session.close();
    expect(l.addUndone(_conv), throwsStateError);
  });

  group('own changes and their undos (M5)', () {
    final a = Uint8List.fromList([1, 2, 3]);
    final b = Uint8List.fromList([4, 5, 6]);

    test('noteOwnChange records what this device added and removed '
        'today', () async {
      final l = ledger();
      await l.noteOwnChange(_conv, added: [a], removed: [b]);

      final second = ledger();
      expect(await second.isUndoOfOwnChange(_conv, a, removing: true), isTrue);
      expect(await second.isUndoOfOwnChange(_conv, b, removing: false), isTrue);
      // The same direction is no undo, and another conversation knows nothing.
      expect(
        await second.isUndoOfOwnChange(_conv, a, removing: false),
        isFalse,
      );
      expect(await second.isUndoOfOwnChange(_conv, b, removing: true), isFalse);
      expect(
        await second.isUndoOfOwnChange('other', a, removing: true),
        isFalse,
      );
    });

    test('the last own change of a device is the one that counts', () async {
      final l = ledger();
      await l.noteOwnChange(_conv, removed: [a]);
      await l.noteOwnChange(_conv, added: [a]);

      expect(await l.isUndoOfOwnChange(_conv, a, removing: true), isTrue);
      expect(await l.isUndoOfOwnChange(_conv, a, removing: false), isFalse);
    });

    test('an own change is forgotten on the next IST day', () async {
      final l = ledger();
      await l.noteOwnChange(_conv, added: [a]);
      clock = DateTime.utc(clock.year, 3, 10, 18, 31);
      expect(await l.isUndoOfOwnChange(_conv, a, removing: true), isFalse);
    });

    test('undoesOwnChange is true when any device of the commit reverses an '
        'own change', () async {
      final l = ledger();
      await l.noteOwnChange(_conv, added: [a]);
      final r = await l.read();

      expect(r.undoesOwnChange(_conv, added: const [], removed: [a]), isTrue);
      expect(r.undoesOwnChange(_conv, added: [b], removed: [b, a]), isTrue);
      expect(r.undoesOwnChange(_conv, added: [a], removed: [b]), isFalse);
      expect(
        r.undoesOwnChange(_conv, added: const [], removed: const []),
        isFalse,
      );
      expect(
        r.undoesOwnChange('other', added: const [], removed: [a]),
        isFalse,
      );
    });

    test('withUndoCounted raises the count once and uses the own change '
        'up', () async {
      final l = ledger();
      await l.noteOwnChange(_conv, added: [a, b]);
      final counted = (await l.read()).withUndoCounted(
        _conv,
        added: const [],
        removed: [a],
      );

      expect(counted.undoneIn(_conv), 1);
      // The reversed change is used up: the same removal is no second undo.
      expect(counted.isUndoOfOwnChange(_conv, a, removing: true), isFalse);
      // The other own change of the day still stands.
      expect(counted.isUndoOfOwnChange(_conv, b, removing: true), isTrue);
      // A commit that reverses nothing changes nothing.
      final same = counted.withUndoCounted(
        _conv,
        added: const [],
        removed: [a],
      );
      expect(same.undoneIn(_conv), 1);
    });

    test('an exhausted record: every reversal is an undo and the count reads '
        'at its cap', () async {
      const capped = DailyRecord.capped('2026-03-10');
      expect(capped.undoneIn(_conv), kAntiFlapUndosPerDay);
      expect(
        capped.undoesOwnChange(_conv, added: [a], removed: const []),
        isTrue,
      );
      expect(
        capped.undoesOwnChange(_conv, added: const [], removed: const []),
        isFalse,
      );
      // An own change noted on an exhausted record never lowers the count.
      expect(
        capped.withOwnChange(_conv, added: [a]).undoneIn(_conv),
        kAntiFlapUndosPerDay,
      );
    });
  });
}
