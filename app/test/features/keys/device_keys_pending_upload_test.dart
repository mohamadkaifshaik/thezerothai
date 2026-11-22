import 'dart:convert';
import 'dart:typed_data';

import 'package:connectrpc/connect.dart' as connect;
import 'package:dzeroth/core/vault/vault_database.dart';
import 'package:dzeroth/core/vault/vault_records.dart' show istDay;
import 'package:dzeroth/core/vault/vault_session.dart';
import 'package:dzeroth/core/vault/vault_status.dart';
import 'package:dzeroth/features/keys/domain/device_keys_service.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:flutter_test/flutter_test.dart';

import '../../support/device_keys_rig.dart';
import '../../support/fake_key_server.dart';

// The pending upload record and the daily batch cap of DeviceKeysService
// (split from device_keys_service_test.dart for size).

const _a = 'user-a';
const _b = 'user-b';
const _hour = Duration(hours: 1);
const _day = Duration(days: 1);

void main() {
  late DeviceKeysRig rig;

  setUp(() {
    rig = DeviceKeysRig()..launch();
  });

  group('pending upload', () {
    const setting = 'keys.device.pendingUpload';
    Future<void> nextRun() async {
      rig.advance(_hour);
      await rig.service.onAppResumed();
    }

    Map<String, dynamic> saved() =>
        jsonDecode(rig.setting(setting)) as Map<String, dynamic>;
    connect.ConnectException refused() => keyServerError(
      connect.Code.resourceExhausted,
      common.ErrorReason.ERROR_REASON_RATE_LIMITED,
    );
    connect.ConnectException timeout() =>
        connect.ConnectException(connect.Code.deadlineExceeded, 'timeout');

    (VaultDatabase, VaultSession) realVault() => rig.realVault();

    const rejectPending =
        'CREATE TRIGGER reject_pending BEFORE INSERT ON vault_settings '
        "WHEN NEW.setting_key = 'keys.device.pendingUpload' "
        "BEGIN SELECT RAISE(ABORT, 'injected'); END";

    test('a failed "failed" record write does not replace the typed refusal: '
        'RATE_LIMITED still backs off', () async {
      final (db, session) = realVault();
      rig.launch(realSession: session);
      await rig.signIn(_a);
      final vault = session.vault!;
      addTearDown(vault.close);
      rig.devices.values.single.pool.clear();
      // The batch is saved; the write after the refusal is rejected.
      rig.server.onCall['upload'] = () => db.customStatement(rejectPending);
      rig.server.failNext['upload'] = [
        keyServerError(
          connect.Code.resourceExhausted,
          common.ErrorReason.ERROR_REASON_RATE_LIMITED,
          retryAfter: const Duration(hours: 4),
        ),
      ];
      await nextRun();
      expect(
        rig.service.status.value,
        const DeviceKeysStatus.failed(retryable: true),
      );
      expect(rig.reported.map((e) => e.toString()), [
        'DeviceKeysError(pendingUploadWrite)',
      ]);
      final record =
          jsonDecode(utf8.decode((await vault.setting(setting))!)) as Map;
      expect(record['outcome'], 'unknown', reason: 'the armed record stays');

      await db.customStatement('DROP TRIGGER reject_pending');
      rig.server.onCall.remove('upload');
      rig.advance(const Duration(hours: 2));
      final before = rig.server.calls.length;
      await rig.service.onAppResumed();
      expect(rig.rpcs(before), isEmpty, reason: 'still backing off');
    });

    test('a refusal after the user changed cancels the run: the "failed" '
        'record write is not reported as a write failure', () async {
      await rig.signIn(_a);
      rig.devices.values.single.pool.clear();
      rig.server.onCall['upload'] = () async => rig.uid = _b;
      rig.server.failNext['upload'] = [refused()];
      await nextRun();
      expect(rig.reported, isEmpty);
      expect(rig.service.status.value, DeviceKeysStatus.idle);
      final record = jsonDecode(rig.setting(setting, _a)) as Map;
      expect(record['outcome'], 'unknown');
    });

    test('a RATE_LIMITED upload while a removal starts keeps the back-off and '
        'writes no "failed" record', () async {
      await rig.signIn(_a);
      rig.devices.values.single.pool.clear();
      // The sign-out hook runs while the upload is at the server.
      rig.server.onCall['upload'] = () => rig.service.removeThisDevice(_a);
      rig.server.failNext['upload'] = [
        keyServerError(
          connect.Code.resourceExhausted,
          common.ErrorReason.ERROR_REASON_RATE_LIMITED,
          retryAfter: const Duration(hours: 4),
        ),
      ];
      await nextRun();
      expect(
        rig.service.status.value,
        const DeviceKeysStatus.failed(retryable: true),
      );
      expect(saved()['outcome'], 'unknown', reason: 'no "failed" record');
      rig.server.onCall.remove('upload');

      // The sign-out failed: the re-register waits for the back-off.
      final before = rig.server.calls.length;
      await rig.service.onSignOutFailed(_a);
      expect(rig.rpcs(before), isEmpty, reason: 'still backing off');
      rig.advance(const Duration(hours: 4));
      await rig.service.onAppResumed();
      expect(rig.rpcs(before), ['list', 'register', 'upload']);
    });

    test(
      'three refused runs grow state once, then upload the saved batch',
      () async {
        rig.server.failNext['upload'] = List.generate(3, (_) => refused());
        await rig.signIn(_a);
        final initial = rig.file()!.deviceState!;
        final first = rig.server.uploads.first;
        expect(saved()['outcome'], 'failed');
        expect(
          saved()['oneTime'],
          first.keyPackages.map(base64Encode).toList(),
        );
        expect(saved()['lastResort'], base64Encode(first.lastResortKeyPackage));
        for (var i = 0; i < 3; i++) {
          await nextRun();
          expect(rig.file()!.deviceState, initial);
          expect(rig.server.uploads.last.keyPackages, first.keyPackages);
          expect(
            rig.server.uploads.last.lastResortKeyPackage,
            first.lastResortKeyPackage,
          );
        }
        expect(rig.server.uploads, hasLength(4));
        expect(rig.engine.generated, hasLength(1));
        expect(saved()['oneTime'], isEmpty);
        expect(saved()['lastResort'], isNull);
      },
    );

    test('a resent last-resort package keeps its generation time: the resend '
        'does not restart its 30 days', () async {
      rig.server.failNext['upload'] = [refused()];
      await rig.signIn(_a);
      final generatedAt = rig.now.microsecondsSinceEpoch;
      expect(saved()['outcome'], 'failed');
      expect(saved()['lastResortAt'], generatedAt);
      await nextRun();
      expect(rig.server.uploads.last.lastResortKeyPackage, isNotEmpty);
      expect(saved()['lastResort'], isNull);
      expect(rig.setting(kVaultSettingLastResortAt), '$generatedAt');

      // 30 days after it was generated (not after the resend): rotated.
      rig.advance(const Duration(days: 30) - _hour);
      await rig.service.ensureReady();
      expect(rig.engine.generated.last, (0, true));
    });

    test('a saved batch without a last-resort package gets one when the '
        'server reports none: generated, counted, sent with the saved '
        'one-time packages', () async {
      rig.toNextIstDay(); // the three batches fall on one IST day
      await rig.signIn(_a);
      final device = rig.devices.values.single;
      device.pool.removeRange(0, 40); // 10 left: a top-up of 40, no LR
      rig.server.failNext['upload'] = [refused()];
      await nextRun();
      expect(saved()['outcome'], 'failed');
      expect(saved()['lastResort'], isNull);
      final oneTime = rig.server.uploads.last.keyPackages;
      expect(oneTime, hasLength(40));
      device.lastResort = null;

      await nextRun();
      final up = rig.server.uploads.last;
      expect(up.keyPackages, oneTime);
      expect(up.lastResortKeyPackage, isNotEmpty);
      expect(device.lastResort, up.lastResortKeyPackage);
      expect(rig.engine.generated, [(50, true), (40, false), (0, true)]);
      expect(rig.stateAtUpload.last, rig.engine.lastGenerated!.deviceState);
      final day = jsonDecode(rig.setting(kVaultSettingKeyBatchDay)) as Map;
      expect(day['n'], 3);
      expect(saved()['oneTime'], isEmpty);
      expect(rig.service.status.value, DeviceKeysStatus.ready);
    });

    // A counter of today at the last-resort-only bound.
    void atLastResortBound() =>
        rig.file()!.rows[kVaultSettingKeyBatchDay] = jsonEncode({
          'v': 1,
          'day': istDay(rig.now),
          'n': kMaxKeyBatchesPerDay + kMaxLastResortOnlyPerDay,
          'reported': false,
        });

    test('past the last-resort-only bound, a saved batch without a '
        'last-resort package is sent as it is (nothing generated), then the '
        'cap', () async {
      await rig.signIn(_a);
      final device = rig.devices.values.single;
      device.pool.removeRange(0, 40);
      rig.server.failNext['upload'] = [refused()];
      await nextRun();
      final oneTime = rig.server.uploads.last.keyPackages;
      expect(oneTime, hasLength(40));
      device.lastResort = null;
      atLastResortBound();
      final generated = rig.engine.generated.length;

      await nextRun();
      final up = rig.server.uploads.last;
      expect(up.keyPackages, oneTime);
      expect(up.lastResortKeyPackage, isEmpty);
      expect(rig.engine.generated, hasLength(generated));
      expect(saved()['oneTime'], isEmpty);
      expect(
        rig.service.status.value,
        const DeviceKeysStatus.failed(retryable: true),
      );
      expect(rig.reported.map((e) => e.toString()), [
        'DeviceKeysError(batchCap)',
      ]);
    });

    test('past the last-resort-only bound, a cleared batch gets no fresh '
        'last-resort package: the cap', () async {
      await rig.signIn(_a);
      final device = rig.devices.values.single;
      device.pool.removeRange(10, device.pool.length);
      rig.server.failAfterApply['upload'] = [timeout(), timeout()];
      await nextRun();
      expect(saved()['outcome'], 'unknown');
      expect(saved()['lastResort'], isNull);
      device
        ..pool.removeRange(0, 5)
        ..lastResort = null;
      atLastResortBound();
      final generated = rig.engine.generated.length;
      final uploads = rig.server.uploads.length;

      await nextRun();
      expect(rig.engine.generated, hasLength(generated));
      expect(rig.server.uploads, hasLength(uploads));
      expect(
        rig.service.status.value,
        const DeviceKeysStatus.failed(retryable: true),
      );
      expect(rig.reported.map((e) => e.toString()), [
        'DeviceKeysError(batchCap)',
      ]);
    });

    test('after a timeout an unchanged count reuses the saved bytes', () async {
      rig.server.failNext['upload'] = [timeout(), timeout()];
      await rig.signIn(_a);
      expect(saved()['outcome'], 'unknown');
      await nextRun();
      expect(rig.server.uploads, hasLength(3));
      expect(
        rig.server.uploads.last.keyPackages,
        rig.server.uploads.first.keyPackages,
      );
      expect(rig.engine.generated, hasLength(1));
    });

    test('after a timeout, a lower pool count clears the saved batch, uploads none of its one-time packages, and the next run generates a fresh batch', () async {
      await rig.signIn(_a);
      final pool = rig.devices.values.single.pool;
      pool.removeRange(10, pool.length);
      rig.server.failAfterApply['upload'] = [timeout(), timeout()];
      await nextRun();
      expect(saved()['countBefore'], 10);
      final old = rig.server.uploads.last.keyPackages.map(base64Encode).toSet();
      final privateState = rig.file()!.deviceState!;
      pool.removeRange(0, pool.length - 8);
      await nextRun();
      expect(rig.server.uploads, hasLength(3));
      expect(saved()['oneTime'], isEmpty);
      expect(rig.file()!.deviceState, privateState);
      await nextRun();
      expect(rig.server.uploads, hasLength(4));
      final fresh = rig.server.uploads.last.keyPackages;
      expect(fresh, hasLength(42));
      expect(fresh.map(base64Encode).where(old.contains), isEmpty);
    });

    for (final claimed in [0, 5]) {
      test('after a timeout, a grown pool count clears the saved batch and no '
          'one-time package of it is uploaded again (claimed between runs: '
          '$claimed)', () async {
        await rig.signIn(_a);
        final pool = rig.devices.values.single.pool;
        pool.removeRange(10, pool.length);
        // Both attempts land, both answers are lost: the pool is at 50.
        rig.server.failAfterApply['upload'] = [timeout(), timeout()];
        await nextRun();
        expect(saved()['outcome'], 'unknown');
        expect(saved()['countBefore'], 10);
        expect(pool, hasLength(50));
        final old = rig.server.uploads.last.keyPackages
            .map(base64Encode)
            .toSet();
        final privateState = rig.file()!.deviceState!;
        // The sign-in batch and the one top-up batch.
        expect(rig.engine.generated, hasLength(2));
        pool.removeRange(0, claimed);

        final uploads = rig.server.uploads.length;
        await nextRun();
        expect(rig.server.uploads, hasLength(uploads), reason: 'no upload');
        expect(saved()['oneTime'], isEmpty);
        expect(rig.file()!.deviceState, privateState);
        expect(rig.engine.generated, hasLength(2));

        // A later top-up sends fresh packages only.
        pool.removeRange(0, pool.length - 15);
        await nextRun();
        final fresh = rig.server.uploads.last.keyPackages;
        expect(fresh, hasLength(35));
        expect(fresh.map(base64Encode).where(old.contains), isEmpty);
      });
    }

    test('after a timeout, a changed pool count resends only the saved '
        'last-resort package and generates nothing in that run', () async {
      // The sign-in batch (50 + a last-resort package) lands twice, both
      // answers are lost: the count went from 0 to 50.
      rig.server.failAfterApply['upload'] = [timeout(), timeout()];
      await rig.signIn(_a);
      final generatedAt = rig.now.microsecondsSinceEpoch;
      final first = rig.server.uploads.first;
      expect(saved()['lastResort'], base64Encode(first.lastResortKeyPackage));
      final state = rig.file()!.deviceState!;
      rig.devices.values.single.pool.removeRange(0, 40); // 10 left

      await nextRun();
      expect(rig.server.uploads, hasLength(3));
      final resent = rig.server.uploads.last;
      expect(resent.keyPackages, isEmpty);
      expect(resent.lastResortKeyPackage, first.lastResortKeyPackage);
      expect(rig.engine.generated, hasLength(1), reason: 'no fresh batch');
      expect(rig.file()!.deviceState, state);
      expect(saved()['oneTime'], isEmpty);
      expect(saved()['lastResort'], isNull);
      expect(rig.service.status.value, DeviceKeysStatus.ready);
      expect(
        rig.setting(kVaultSettingLastResortAt),
        '$generatedAt',
        reason: 'the time it was generated, not the resend time',
      );
    });

    test('a resent last-resort package whose answer is lost stays saved and '
        'is sent again', () async {
      rig.server.failAfterApply['upload'] = List.generate(4, (_) => timeout());
      await rig.signIn(_a);
      final first = rig.server.uploads.first;
      rig.devices.values.single.pool.removeRange(0, 5);
      await nextRun();
      expect(saved()['oneTime'], isEmpty);
      expect(saved()['lastResort'], base64Encode(first.lastResortKeyPackage));
      expect(saved()['outcome'], 'unknown');
      await nextRun();
      expect(rig.server.uploads, hasLength(5));
      expect(
        rig.server.uploads.last.lastResortKeyPackage,
        first.lastResortKeyPackage,
      );
      expect(rig.server.uploads.last.keyPackages, isEmpty);
      expect(saved()['lastResort'], isNull);
      expect(rig.engine.generated, hasLength(1));
    });

    test('a pool count over 100 (MaxPoolSize) is refused: nothing is '
        'generated, saved or sent, and it is reported every run', () async {
      await rig.signIn(_a);
      rig.devices.values.single.pool.addAll(
        List.generate(51, (i) => Uint8List.fromList([9, 9, i])),
      );
      final state = rig.file()!.deviceState;
      final record = rig.setting(setting);
      for (var run = 1; run <= 2; run++) {
        await nextRun();
        expect(
          rig.service.status.value,
          const DeviceKeysStatus.failed(retryable: true),
        );
        expect(rig.reported.map((e) => e.toString()), [
          for (var i = 0; i < run; i++) 'DeviceKeysError(poolCount)',
        ]);
      }
      expect(rig.engine.generated, hasLength(1));
      expect(rig.server.uploads, hasLength(1));
      expect(rig.file()!.deviceState, state);
      expect(rig.setting(setting), record);
    });

    test('a RegisterKeyDevice answer over 100 is refused too: nothing is '
        'generated or sent, and it is reported', () async {
      await rig.signIn(_a);
      final device = rig.devices.values.single..lastResort = null;
      // The list answers 50; the register (stay active) answers 101.
      rig.server.onCall['register'] = () async => device.pool.addAll(
        List.generate(51, (i) => Uint8List.fromList([9, 9, i])),
      );
      final state = rig.file()!.deviceState;
      final record = rig.setting(setting);
      rig.advance(kDeviceStayActiveAfter + _hour);
      final before = rig.server.calls.length;
      await rig.service.onAppResumed();
      expect(rig.rpcs(before), ['list', 'register']);
      expect(
        rig.service.status.value,
        const DeviceKeysStatus.failed(retryable: true),
      );
      expect(rig.reported.map((e) => e.toString()), [
        'DeviceKeysError(poolCount)',
      ]);
      expect(rig.engine.generated, hasLength(1));
      expect(rig.server.uploads, hasLength(1));
      expect(rig.file()!.deviceState, state);
      expect(rig.setting(setting), record);
    });

    test('a refusal on the retry does not resolve the first timeout', () async {
      await rig.signIn(_a);
      final pool = rig.devices.values.single.pool;
      pool.removeRange(10, pool.length);
      var calls = 0;
      rig.server.onCall['upload'] = () async {
        if (++calls == 2) rig.server.failNext['upload'] = [refused()];
      };
      rig.server.failAfterApply['upload'] = [timeout()];
      await nextRun();
      expect(saved()['outcome'], 'unknown');
      await nextRun();
      expect(rig.server.uploads, hasLength(3));
      expect(saved()['oneTime'], isEmpty);
    });

    test('an unreadable saved batch is replaced and reported once', () async {
      await rig.signIn(_a);
      final pool = rig.devices.values.single.pool..clear();
      rig.file()!.rows[setting] = '{';
      await nextRun();
      expect(pool, hasLength(50));
      // Still unreadable on the next run of the same vault: not reported
      // again.
      rig.file()!.rows[setting] = '{';
      await nextRun();
      expect(rig.reported.map((e) => e.toString()), [
        'DeviceKeysError(pendingUpload)',
      ]);
      expect(saved()['oneTime'], isEmpty);
    });

    test(
      'private state and sealed pending packages commit together before upload',
      () async {
        final (db, session) = realVault();
        rig.launch(realSession: session);
        await rig.signIn(_a);
        final vault = session.vault!;
        addTearDown(vault.close);
        final original = await vault.deviceState();
        final day = await vault.setting(kVaultSettingKeyBatchDay);
        expect(day, isNotNull);
        rig.devices.values.single.pool.clear();
        await db.customStatement(
          "CREATE TRIGGER reject_pending BEFORE INSERT ON vault_settings "
          "WHEN NEW.setting_key = 'keys.device.pendingUpload' "
          "BEGIN SELECT RAISE(ABORT, 'injected'); END",
        );
        await nextRun();
        expect(
          await vault.deviceState(),
          original,
          reason: 'private write rolls back',
        );
        expect(
          await vault.setting(kVaultSettingKeyBatchDay),
          day,
          reason: 'the batch is not counted either',
        );
        expect(rig.server.uploads, hasLength(1));
        await db.customStatement('DROP TRIGGER reject_pending');
        rig.server.failNext['upload'] = [refused()];
        await nextRun();
        final plain = (await vault.setting(setting))!;
        final raw =
            (await db
                    .customSelect(
                      "SELECT value FROM vault_settings WHERE setting_key = 'keys.device.pendingUpload'",
                    )
                    .getSingle())
                .read<Uint8List>('value');
        final encoded = base64Encode(rig.server.uploads.last.keyPackages.first);
        expect(utf8.decode(plain), contains(encoded));
        expect(latin1.decode(raw), isNot(contains(encoded)));
        expect(
          latin1.decode(raw),
          isNot(
            contains(latin1.decode(rig.server.uploads.last.keyPackages.first)),
          ),
        );
      },
    );
  });

  group('daily batch cap', () {
    const ist = Duration(hours: 5, minutes: 30);
    Future<void> nextRun() async {
      rig.advance(_hour);
      await rig.service.onAppResumed();
    }

    void toNextIstDay() => rig.toNextIstDay();

    List<String> reported() => rig.reported.map((e) => e.toString()).toList();

    test('at $kMaxKeyBatchesPerDay batches in an IST day nothing more is '
        'generated or sent, reported once that day; the next day generates '
        'again', () async {
      toNextIstDay();
      await rig.signIn(_a); // batch 1
      final pool = rig.devices.values.single.pool;
      for (var i = 2; i <= kMaxKeyBatchesPerDay; i++) {
        pool.clear();
        await nextRun();
        expect(rig.engine.generated, hasLength(i));
        expect(pool, hasLength(50));
      }
      final state = rig.file()!.deviceState;
      final uploads = rig.server.uploads.length;

      pool.clear();
      await nextRun();
      expect(rig.engine.generated, hasLength(kMaxKeyBatchesPerDay));
      expect(rig.server.uploads, hasLength(uploads));
      expect(rig.file()!.deviceState, state);
      expect(
        rig.service.status.value,
        const DeviceKeysStatus.failed(retryable: true),
      );
      expect(reported(), ['DeviceKeysError(batchCap)']);

      // Later the same day, and after a restart: still capped, not
      // reported again.
      await nextRun();
      rig.launch();
      await rig.signIn(_a);
      expect(rig.engine.generated, hasLength(kMaxKeyBatchesPerDay));
      expect(rig.server.uploads, hasLength(uploads));
      expect(reported(), ['DeviceKeysError(batchCap)']);

      toNextIstDay();
      await rig.service.onAppResumed();
      expect(rig.engine.generated, hasLength(kMaxKeyBatchesPerDay + 1));
      expect(rig.server.uploads.last.keyPackages, hasLength(50));
      expect(pool, hasLength(50));
      expect(rig.service.status.value, DeviceKeysStatus.ready);
    });

    test(
      'at the cap a server without a last-resort package still gets one: '
      'a last-resort-only batch, saved and counted; the pool stays capped',
      () async {
        toNextIstDay();
        await rig.signIn(_a);
        final device = rig.devices.values.single;
        for (var i = 2; i <= kMaxKeyBatchesPerDay; i++) {
          device.pool.clear();
          await nextRun();
        }
        expect(rig.engine.generated, hasLength(kMaxKeyBatchesPerDay));
        // A re-registered device: no pool, no last-resort package.
        device
          ..pool.clear()
          ..lastResort = null;
        final state = rig.file()!.deviceState;
        final uploads = rig.server.uploads.length;

        await nextRun();
        expect(rig.engine.generated, hasLength(kMaxKeyBatchesPerDay + 1));
        expect(rig.engine.generated.last, (0, true));
        expect(rig.server.uploads, hasLength(uploads + 1));
        final up = rig.server.uploads.last;
        expect(up.keyPackages, isEmpty);
        expect(up.lastResortKeyPackage, isNotEmpty);
        expect(device.lastResort, up.lastResortKeyPackage);
        expect(device.pool, isEmpty);
        // Saved before the upload, as every generated batch is.
        expect(rig.file()!.deviceState, isNot(state));
        expect(rig.stateAtUpload.last, rig.engine.lastGenerated!.deviceState);
        final day = jsonDecode(rig.setting(kVaultSettingKeyBatchDay)) as Map;
        expect(day['n'], kMaxKeyBatchesPerDay + 1);
        expect(
          rig.service.status.value,
          const DeviceKeysStatus.failed(retryable: true),
          reason: 'the one-time pool is still capped',
        );
        expect(reported(), ['DeviceKeysError(batchCap)']);

        // The server now holds one: nothing more today.
        await nextRun();
        expect(rig.engine.generated, hasLength(kMaxKeyBatchesPerDay + 1));
        expect(rig.server.uploads, hasLength(uploads + 1));
        expect(reported(), ['DeviceKeysError(batchCap)']);
      },
    );

    test('at the cap, a server that keeps dropping its last-resort package '
        'gets at most $kMaxLastResortOnlyPerDay last-resort-only batches a '
        'day, however often the run is started', () async {
      toNextIstDay();
      await rig.signIn(_a);
      final device = rig.devices.values.single;
      for (var i = 2; i <= kMaxKeyBatchesPerDay; i++) {
        device.pool.clear();
        await nextRun();
      }
      expect(rig.engine.generated, hasLength(kMaxKeyBatchesPerDay));
      const bound = kMaxKeyBatchesPerDay + kMaxLastResortOnlyPerDay;
      // The first run at the cap is an hour on; the rest are not throttled
      // (a capped run is a failure, as vault-ready and a failed sign-out).
      rig.advance(_hour);
      for (var i = 0; i < kMaxLastResortOnlyPerDay + 6; i++) {
        device
          ..pool.clear()
          ..lastResort = null;
        await rig.service.ensureReady();
        expect(
          rig.service.status.value,
          const DeviceKeysStatus.failed(retryable: true),
        );
      }
      expect(rig.engine.generated, hasLength(bound));
      expect(
        rig.engine.generated.skip(kMaxKeyBatchesPerDay),
        everyElement((0, true)),
      );
      final day = jsonDecode(rig.setting(kVaultSettingKeyBatchDay)) as Map;
      expect(day['n'], bound);
      final uploads = rig.server.uploads.length;
      device.lastResort = null;
      await rig.service.ensureReady();
      expect(rig.engine.generated, hasLength(bound));
      expect(rig.server.uploads, hasLength(uploads));
      expect(reported(), ['DeviceKeysError(batchCap)']);
    });

    test('at the cap, a cleared batch without a last-resort package still '
        'gets one when the server reports none (counted)', () async {
      toNextIstDay();
      await rig.signIn(_a);
      final device = rig.devices.values.single;
      for (var i = 2; i < kMaxKeyBatchesPerDay; i++) {
        device.pool.clear();
        await nextRun();
      }
      // The last batch of the day (no last-resort package): both answers
      // are lost.
      device.pool.clear();
      rig.server.failAfterApply['upload'] = [
        connect.ConnectException(connect.Code.deadlineExceeded, 'timeout'),
        connect.ConnectException(connect.Code.deadlineExceeded, 'timeout'),
      ];
      await nextRun();
      expect(rig.engine.generated, hasLength(kMaxKeyBatchesPerDay));
      expect(rig.engine.generated.last, (50, false));

      // Claims moved the count, and the server lost its last-resort one.
      device
        ..pool.removeRange(0, 5)
        ..lastResort = null;
      final uploads = rig.server.uploads.length;
      await nextRun();
      expect(rig.engine.generated, hasLength(kMaxKeyBatchesPerDay + 1));
      expect(rig.engine.generated.last, (0, true));
      expect(rig.server.uploads, hasLength(uploads + 1));
      expect(rig.server.uploads.last.keyPackages, isEmpty);
      expect(device.lastResort, rig.server.uploads.last.lastResortKeyPackage);
      final day = jsonDecode(rig.setting(kVaultSettingKeyBatchDay)) as Map;
      expect(day['n'], kMaxKeyBatchesPerDay + 1);
      expect(rig.service.status.value, DeviceKeysStatus.ready);
    });

    test('at the cap a saved last-resort package is still sent', () async {
      toNextIstDay();
      await rig.signIn(_a);
      final device = rig.devices.values.single;
      for (var i = 2; i < kMaxKeyBatchesPerDay; i++) {
        device.pool.clear();
        await nextRun();
      }
      // The last batch of the day carries a last-resort package (the
      // server lost its one); both answers are lost.
      device
        ..pool.clear()
        ..lastResort = null;
      rig.server.failAfterApply['upload'] = [
        connect.ConnectException(connect.Code.deadlineExceeded, 'timeout'),
        connect.ConnectException(connect.Code.deadlineExceeded, 'timeout'),
      ];
      await nextRun();
      expect(rig.engine.generated, hasLength(kMaxKeyBatchesPerDay));
      final lastResort = rig.server.uploads.last.lastResortKeyPackage;
      expect(lastResort, isNotEmpty);

      // The count changed (claims): the one-time packages are dropped, the
      // saved last-resort package alone is sent, at the cap.
      device.pool.removeRange(0, 45);
      final uploads = rig.server.uploads.length;
      await nextRun();
      expect(rig.server.uploads, hasLength(uploads + 1));
      expect(rig.server.uploads.last.keyPackages, isEmpty);
      expect(rig.server.uploads.last.lastResortKeyPackage, lastResort);
      expect(rig.engine.generated, hasLength(kMaxKeyBatchesPerDay));

      // The pool is low and nothing else is saved: capped.
      await nextRun();
      expect(rig.server.uploads, hasLength(uploads + 1));
      expect(reported(), ['DeviceKeysError(batchCap)']);
    });

    test('the cap follows the IST day, not the UTC day: capped across 00:00 '
        'UTC, reset only at IST midnight', () async {
      toNextIstDay();
      rig.advance(const Duration(hours: 4, minutes: 29)); // 04:30 IST
      expect(rig.now.hour, 23, reason: '23:00 UTC, the day before');
      await rig.signIn(_a); // batch 1
      final pool = rig.devices.values.single.pool;
      // Restarts (no clock move) reach the cap before 05:30 IST.
      for (var i = 2; i <= kMaxKeyBatchesPerDay; i++) {
        pool.clear();
        rig.launch();
        await rig.signIn(_a);
      }
      expect(rig.engine.generated, hasLength(kMaxKeyBatchesPerDay));

      // 05:35 IST = 00:05 UTC: a new UTC day, the same IST day.
      pool.clear();
      rig.advance(const Duration(hours: 1, minutes: 5));
      expect(rig.now.hour, 0);
      await rig.service.ensureReady();
      expect(rig.engine.generated, hasLength(kMaxKeyBatchesPerDay));
      expect(reported(), ['DeviceKeysError(batchCap)']);

      // 23:59 IST: still capped.
      final local = rig.now.add(ist);
      final midnight = DateTime.utc(
        local.year,
        local.month,
        local.day,
      ).add(_day).subtract(ist);
      rig.advance(midnight.difference(rig.now) - const Duration(minutes: 1));
      await rig.service.ensureReady();
      expect(rig.engine.generated, hasLength(kMaxKeyBatchesPerDay));

      // 00:01 IST: the next IST day generates again.
      rig.advance(const Duration(minutes: 2));
      await rig.service.ensureReady();
      expect(rig.engine.generated, hasLength(kMaxKeyBatchesPerDay + 1));
      expect(pool, hasLength(50));
    });

    test('a counter row that does not open (corrupt) counts as the cap for '
        'today; the next IST day starts over', () async {
      toNextIstDay();
      final (db, session) = rig.realVault();
      rig.launch(realSession: session);
      await rig.signIn(_a);
      final vault = session.vault!;
      addTearDown(vault.close);
      await db.customStatement(
        "UPDATE vault_settings SET value = X'00' "
        "WHERE setting_key = '$kVaultSettingKeyBatchDay'",
      );
      await expectLater(
        vault.setting(kVaultSettingKeyBatchDay),
        throwsA(isA<VaultCorruptException>()),
      );
      rig.devices.values.single.pool.clear();
      final uploads = rig.server.uploads.length;
      await nextRun();
      expect(rig.engine.generated, hasLength(1));
      expect(rig.server.uploads, hasLength(uploads));
      expect(
        rig.service.status.value,
        const DeviceKeysStatus.failed(retryable: true),
      );
      expect(reported(), ['DeviceKeysError(batchDay)']);
      // The marked record replaced the corrupt row: not reported again.
      await nextRun();
      expect(reported(), ['DeviceKeysError(batchDay)']);
      toNextIstDay();
      await rig.service.onAppResumed();
      expect(rig.engine.generated, hasLength(2));
      expect(rig.service.status.value, DeviceKeysStatus.ready);
    });

    test('setting the clock back a day does not reset the cap', () async {
      toNextIstDay();
      await rig.signIn(_a);
      final pool = rig.devices.values.single.pool;
      for (var i = 2; i <= kMaxKeyBatchesPerDay + 1; i++) {
        pool.clear();
        await nextRun();
      }
      expect(rig.engine.generated, hasLength(kMaxKeyBatchesPerDay));
      expect(reported(), ['DeviceKeysError(batchCap)']);
      final uploads = rig.server.uploads.length;

      rig.advance(const Duration(days: -1));
      rig.launch();
      await rig.signIn(_a);
      expect(rig.engine.generated, hasLength(kMaxKeyBatchesPerDay));
      expect(rig.server.uploads, hasLength(uploads));
      expect(
        rig.service.status.value,
        const DeviceKeysStatus.failed(retryable: true),
      );
      // The report was made on the later day: the earlier day reports
      // again, once.
      expect(reported(), [
        'DeviceKeysError(batchCap)',
        'DeviceKeysError(batchCap)',
      ]);
      await nextRun();
      expect(reported(), hasLength(2));
    });

    test('a counter dated more than a day ahead counts as the cap for today '
        'only, reported as batchDay', () async {
      toNextIstDay();
      await rig.signIn(_a);
      rig.file()!.rows[kVaultSettingKeyBatchDay] = jsonEncode({
        'v': 1,
        'day': istDay(rig.now.add(const Duration(days: 2))),
        'n': 0,
        'reported': false,
      });
      rig.devices.values.single.pool.clear();
      final uploads = rig.server.uploads.length;
      await nextRun();
      expect(rig.engine.generated, hasLength(1));
      expect(rig.server.uploads, hasLength(uploads));
      expect(reported(), ['DeviceKeysError(batchDay)']);
      await nextRun();
      expect(reported(), ['DeviceKeysError(batchDay)']);
      toNextIstDay();
      await rig.service.onAppResumed();
      expect(rig.engine.generated, hasLength(2));
    });

    test('an unreadable counter counts as the cap for today', () async {
      toNextIstDay();
      await rig.signIn(_a);
      rig.file()!.rows[kVaultSettingKeyBatchDay] = '{';
      rig.devices.values.single.pool.clear();
      final uploads = rig.server.uploads.length;
      await nextRun();
      expect(rig.engine.generated, hasLength(1));
      expect(rig.server.uploads, hasLength(uploads));
      expect(reported(), ['DeviceKeysError(batchDay)']);
      toNextIstDay();
      await rig.service.onAppResumed();
      expect(rig.engine.generated, hasLength(2));
    });
  });
}
