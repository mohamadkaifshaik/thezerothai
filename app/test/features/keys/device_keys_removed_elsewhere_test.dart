import 'dart:async';
import 'dart:typed_data';

import 'package:connectrpc/connect.dart' as connect;
import 'package:dzeroth/core/vault/vault_records.dart'
    show kVaultSettingRegisteredOnce;
import 'package:dzeroth/features/keys/domain/device_keys_service.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/keys/v1/keys.pb.dart' as pb;
import 'package:flutter_test/flutter_test.dart';

import '../../support/device_keys_rig.dart';
import '../../support/fake_key_server.dart';

// Plan 5a Task 12 (R17, R12) with lane D PR 2: the removal reasons, a
// device removed elsewhere (the server's DEVICE_REMOVED answer: brief
// amendment 1 replaces the plan's two-miss rule), the status split (M5),
// retryNow and recreateDevice.

const _a = 'user-a';
const _hour = Duration(hours: 1);

void main() {
  late DeviceKeysRig rig;

  setUp(() {
    rig = DeviceKeysRig()..launch();
  });

  /// The server removed this device with REMOTE from another device: the
  /// doc is gone and the id is marked.
  void removeRemotely(String id) {
    rig.devices.remove(id);
    rig.server.removedMarks.add(id);
  }

  /// Signed in, then removed elsewhere and found so by the next run's
  /// Register (DEVICE_REMOVED). Answers this device's id.
  Future<String> removedElsewhere() async {
    await rig.signIn(_a);
    final id = rig.storedId()!;
    removeRemotely(id);
    rig.advance(_hour);
    await rig.service.ensureReady();
    expect(rig.service.removedElsewhere, isTrue);
    return id;
  }

  group('removal reasons (design section 4)', () {
    test('sign-out removal sends SIGN_OUT', () async {
      await rig.signIn(_a);
      final id = rig.storedId()!;
      await rig.signOut();

      final removal = rig.server.removals.single;
      expect(removal.deviceId, id);
      expect(removal.reason, pb.RemoveReason.REMOVE_REASON_SIGN_OUT);
      expect(rig.server.removedMarks, isEmpty);
    });

    test('a failed sign-out re-registers the same id (no mark)', () async {
      await rig.signIn(_a);
      final id = rig.storedId()!;
      await rig.session.beforeExplicitSignOut(_a);
      expect(rig.devices, isEmpty);

      await rig.session.explicitSignOutFailed(_a);
      await rig.service.onSignOutFailed(_a);

      expect(
        rig.server.removals.single.reason,
        pb.RemoveReason.REMOVE_REASON_SIGN_OUT,
      );
      expect(rig.server.removedMarks, isEmpty);
      expect(rig.storedId(), id);
      expect(rig.devices.keys, [id]);
      expect(rig.server.registrations.last.deviceId, id);
      expect(rig.service.status.value, DeviceKeysStatus.ready);
      expect(rig.service.removedElsewhere, isFalse);
    });
  });

  group('detection: DEVICE_REMOVED only (brief amendment 1)', () {
    test('DEVICE_REMOVED on register sets removedElsewhere on the first '
        'answer and registers nothing again', () async {
      await rig.signIn(_a);
      final id = rig.storedId()!;
      removeRemotely(id);
      rig.advance(_hour);
      final before = rig.server.calls.length;

      await rig.service.ensureReady();

      expect(rig.rpcs(before), ['list', 'register']);
      expect(rig.service.removedElsewhere, isTrue);
      expect(rig.service.removedElsewhereFact.value, isTrue);
      expect(rig.service.status.value, DeviceKeysStatus.removedElsewhere);
      expect(rig.setting(kVaultSettingRemovedElsewhere), '\u0001');
      // Nothing deleted: the same device stays in the vault.
      expect(rig.storedId(), id);

      // Within the hour nothing is sent; after it, the list only.
      final after = rig.server.calls.length;
      await rig.service.ensureReady();
      expect(rig.rpcs(after), isEmpty);
      for (var i = 0; i < 3; i++) {
        rig.advance(_hour);
        await rig.service.ensureReady();
        await rig.service.onAppResumed();
      }
      expect(rig.rpcs(after), ['list', 'list', 'list']);
      expect(rig.service.status.value, DeviceKeysStatus.removedElsewhere);
      expect(rig.reported, isEmpty);
    });

    test('DEVICE_REMOVED on upload sets removedElsewhere on the first answer '
        'and uploads nothing again', () async {
      await rig.signIn(_a);
      final id = rig.storedId()!;
      // The doc still lists (the fake server does not hide a marked doc),
      // and the pool needs a top-up: the run uploads.
      rig.devices[id]!.pool.clear();
      rig.server.removedMarks.add(id);
      rig.advance(_hour);
      final before = rig.server.calls.length;

      await rig.service.ensureReady();

      expect(rig.rpcs(before), ['list', 'upload']);
      expect(rig.service.removedElsewhere, isTrue);
      expect(rig.service.status.value, DeviceKeysStatus.removedElsewhere);
      expect(rig.setting(kVaultSettingRemovedElsewhere), '\u0001');

      final after = rig.server.calls.length;
      rig.advance(_hour);
      await rig.service.ensureReady();
      expect(rig.rpcs(after), ['list']);
    });

    test('missing from the list re-registers the same id and key', () async {
      await rig.signIn(_a);
      final id = rig.storedId()!;
      final key = rig.devices[id]!.signatureKey;
      // Deleted without a mark (a SIGN_OUT removal by someone holding the
      // session): an absence is never proof.
      rig.devices.remove(id);
      rig.advance(_hour);
      final before = rig.server.calls.length;

      await rig.service.ensureReady();

      expect(rig.rpcs(before), ['list', 'register', 'upload']);
      expect(rig.server.registrations.last.deviceId, id);
      expect(rig.server.registrations.last.signaturePublicKey, key);
      expect(rig.service.status.value, DeviceKeysStatus.ready);
      expect(rig.service.removedElsewhere, isFalse);
      expect(rig.setting(kVaultSettingRemovedElsewhere), '');
    });

    test('a list answer that hides the device re-registers it, and a '
        'Register refused as DEVICE_REMOVED then marks it', () async {
      await rig.signIn(_a);
      final id = rig.storedId()!;
      rig.server.hiddenFromList.add(id);
      rig.advance(_hour);
      await rig.service.ensureReady();
      expect(rig.service.removedElsewhere, isFalse);
      expect(rig.server.registrations.last.deviceId, id);

      rig.server.removedMarks.add(id);
      rig.advance(_hour);
      await rig.service.ensureReady();
      expect(rig.service.removedElsewhere, isTrue);
    });

    test('NOT_FOUND on upload re-registers', () async {
      await rig.signIn(_a);
      final id = rig.storedId()!;
      rig.devices[id]!.pool.clear();
      rig.server.failNext['upload'] = [
        connect.ConnectException(connect.Code.notFound, 'not found'),
      ];
      rig.advance(_hour);
      await rig.service.ensureReady();
      expect(
        rig.service.status.value,
        const DeviceKeysStatus.failed(retryable: true),
      );

      rig.advance(_hour);
      final before = rig.server.calls.length;
      await rig.service.ensureReady();

      expect(rig.rpcs(before), ['list', 'register', 'upload']);
      expect(rig.server.registrations.last.deviceId, id);
      expect(rig.service.status.value, DeviceKeysStatus.ready);
      expect(rig.service.removedElsewhere, isFalse);
    });

    test('a removedElsewhere vault survives a restart and stays '
        'read-only', () async {
      final id = await removedElsewhere();
      final registrations = rig.server.registrations.length;
      final uploads = rig.server.uploads.length;

      rig.launch();
      await rig.signIn(_a);

      expect(rig.service.removedElsewhere, isTrue);
      expect(rig.service.status.value, DeviceKeysStatus.removedElsewhere);
      for (var i = 0; i < 3; i++) {
        rig.advance(const Duration(days: 8));
        await rig.service.ensureReady();
      }
      expect(rig.server.registrations, hasLength(registrations));
      expect(rig.server.uploads, hasLength(uploads));
      expect(rig.storedId(), id);
      expect(rig.engine.createdIds, hasLength(1));
    });

    test(
      'a failed sign-out while removed elsewhere registers nothing',
      () async {
        await removedElsewhere();
        final registrations = rig.server.registrations.length;
        await rig.session.beforeExplicitSignOut(_a);
        await rig.session.explicitSignOutFailed(_a);
        await rig.service.onSignOutFailed(_a);
        expect(rig.server.registrations, hasLength(registrations));
        expect(rig.service.removedElsewhere, isTrue);
      },
    );
  });

  group('listed again (security read M5)', () {
    test('two listed answers clear the marker; one lacking it resets the '
        'count; a failed call neither counts nor resets', () async {
      final id = await removedElsewhere();
      final key = Uint8List.fromList(
        rig.server.registrations.first.signaturePublicKey,
      );
      // The server lists the device again (same id, same key).
      rig.server.removedMarks.remove(id);
      rig.devices[id] = FakeKeyDevice(
        id: id,
        signatureKey: key,
        createdAt: rig.now,
      );
      final before = rig.server.calls.length;

      await rig.service.checkAgainNow(); // 1
      expect(rig.service.removedElsewhere, isTrue);
      rig.server.hiddenFromList.add(id);
      await rig.service.checkAgainNow(); // lacking: 0
      expect(rig.service.removedElsewhere, isTrue);
      rig.server.hiddenFromList.remove(id);
      await rig.service.checkAgainNow(); // 1
      expect(rig.service.removedElsewhere, isTrue);
      rig.server.failNext['list'] = [keyServerUnavailable()];
      await rig.service.checkAgainNow(); // failed: still 1
      expect(rig.service.removedElsewhere, isTrue);
      expect(rig.service.status.value, DeviceKeysStatus.removedElsewhere);
      await rig.service.checkAgainNow(); // 2: cleared

      expect(rig.service.removedElsewhere, isFalse);
      expect(rig.service.removedElsewhereFact.value, isFalse);
      expect(rig.setting(kVaultSettingRemovedElsewhere), '\u0000');
      expect(
        rig.service.status.value.phase,
        isNot(DeviceKeysPhase.removedElsewhere),
      );
      // Read only until then: lists and nothing else.
      expect(rig.rpcs(before), ['list', 'list', 'list', 'list', 'list']);
      expect(rig.storedId(), id);

      // The next ordinary run is the ordinary upkeep again.
      await rig.service.ensureReady();
      expect(rig.service.status.value, DeviceKeysStatus.ready);
    });

    test(
      'an answer that lists the id with another key does not count',
      () async {
        final id = await removedElsewhere();
        rig.server.removedMarks.remove(id);
        rig.devices[id] = FakeKeyDevice(
          id: id,
          signatureKey: Uint8List.fromList(List.filled(32, 9)),
          createdAt: rig.now,
        );
        await rig.service.checkAgainNow();
        await rig.service.checkAgainNow();
        await rig.service.checkAgainNow();
        expect(rig.service.removedElsewhere, isTrue);
      },
    );

    test('checkAgainNow reads the list once and deletes nothing', () async {
      final id = await removedElsewhere();
      final rows = Map<String, String>.of(rig.file()!.rows);
      final state = rig.file()!.deviceState;
      final before = rig.server.calls.length;

      await rig.service.checkAgainNow();

      expect(rig.rpcs(before), ['list']);
      expect(rig.file()!.rows, rows);
      expect(rig.storedId(), id);
      expect(rig.file()!.deviceState, state);
    });

    test('checkAgainNow is a no-op when not removed elsewhere', () async {
      await rig.signIn(_a);
      final before = rig.server.calls.length;
      await rig.service.checkAgainNow();
      expect(rig.rpcs(before), isEmpty);
    });
  });

  group('the status split (M5)', () {
    test('a server validation refusal is failed with localRecordUnusable '
        'false, and a local unusable device or VaultCorruptException sets '
        'it true', () async {
      // A server VALIDATION refusal.
      rig.server.failNext['register'] = [
        keyServerError(
          connect.Code.invalidArgument,
          common.ErrorReason.ERROR_REASON_VALIDATION,
          metadata: {'field': 'device_id'},
        ),
      ];
      await rig.signIn(_a);
      expect(
        rig.service.status.value,
        const DeviceKeysStatus.failed(retryable: false),
      );
      expect(rig.service.status.value.localRecordUnusable, isFalse);

      // A local device row without its key.
      rig = DeviceKeysRig()..launch();
      await rig.signIn(_a);
      await rig.session.close();
      rig.file()!.rows.remove(kVaultSettingDeviceSignatureKey);
      rig.launch();
      await rig.signIn(_a);
      expect(
        rig.service.status.value,
        const DeviceKeysStatus.failed(
          retryable: false,
          localRecordUnusable: true,
        ),
      );

      // A device setting that does not open under the vault key.
      rig = DeviceKeysRig();
      final (db, session) = rig.realVault();
      rig.launch(realSession: session);
      await rig.signIn(_a);
      final vault = session.vault!;
      addTearDown(vault.close);
      await db.customStatement(
        "UPDATE vault_settings SET value = X'00' "
        "WHERE setting_key = '$kVaultSettingDeviceSignatureKey'",
      );
      rig.advance(_hour);
      await rig.service.ensureReady();
      expect(
        rig.service.status.value,
        const DeviceKeysStatus.failed(
          retryable: false,
          localRecordUnusable: true,
        ),
      );
    });
  });

  group('retryNow', () {
    test('retryNow after the device limit clears the latch and registers; '
        'after a key mismatch it does nothing', () async {
      for (var i = 0; i < 5; i++) {
        rig.devices['other-device-$i-000000'] = FakeKeyDevice(
          id: 'other-device-$i-000000',
          signatureKey: Uint8List(32),
          createdAt: rig.now,
        );
      }
      await rig.signIn(_a);
      expect(rig.service.status.value, DeviceKeysStatus.deviceLimitReached);
      rig.devices.remove('other-device-0-000000');

      await rig.service.retryNow();

      expect(rig.service.status.value, DeviceKeysStatus.ready);
      expect(rig.devices.keys, contains(rig.storedId()));

      // A key mismatch latches too; retryNow leaves it latched.
      final mismatch = DeviceKeysRig()..launch();
      await mismatch.signIn(_a);
      final id = mismatch.storedId()!;
      mismatch.devices[id] = FakeKeyDevice(
        id: id,
        signatureKey: Uint8List.fromList(List.filled(32, 1)),
        createdAt: mismatch.now,
      );
      mismatch.advance(const Duration(days: 8));
      await mismatch.service.ensureReady();
      expect(
        mismatch.service.status.value,
        const DeviceKeysStatus.failed(retryable: false),
      );
      final before = mismatch.server.calls.length;
      await mismatch.service.retryNow();
      expect(mismatch.rpcs(before), isEmpty);
    });
  });

  group('recreateDevice (R17 "set up again")', () {
    test('recreateDevice writes a new id and clears both markers in one '
        'transaction, and is refused with the flag off', () async {
      final old = await removedElsewhere();
      rig.flag = false;
      await expectLater(rig.service.recreateDevice(), throwsStateError);
      expect(rig.storedId(), old);
      rig.flag = true;

      final hold = rig.server.hold['list'] = Completer<void>();
      final commits = rig.file()!.commits;
      final calls = rig.server.calls.length;
      final done = rig.service.recreateDevice();
      for (var i = 0; i < 50 && !rig.rpcs(calls).contains('list'); i++) {
        await Future<void>.delayed(Duration.zero);
      }
      // The run after it waits in its first call: one transaction so far.
      expect(rig.file()!.commits, commits + 1);
      final fresh = rig.storedId()!;
      expect(fresh, isNot(old));
      expect(fresh, matches(RegExp(r'^[0-9a-f]{32}$')));
      expect(rig.setting(kVaultSettingRegisteredOnce), '\u0000');
      expect(rig.setting(kVaultSettingRemovedElsewhere), '\u0000');
      expect(rig.setting(kVaultSettingDeviceLastSeen), '0');
      expect(rig.setting(kVaultSettingLastResortAt), '0');
      expect(rig.service.removedElsewhere, isFalse);

      rig.server.hold.remove('list');
      hold.complete();
      await done;

      // A normal run registered the new id (registered-once 0x00 is absent).
      expect(rig.server.registrations.last.deviceId, fresh);
      expect(rig.devices[fresh]!.pool, hasLength(50));
      expect(rig.setting(kVaultSettingRegisteredOnce), '\u0001');
      expect(rig.service.status.value, DeviceKeysStatus.ready);
    });

    test('recreateDevice is refused when not removed elsewhere', () async {
      await rig.signIn(_a);
      final id = rig.storedId();
      await expectLater(rig.service.recreateDevice(), throwsStateError);
      expect(rig.storedId(), id);
    });
  });
}
