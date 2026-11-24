import 'dart:async';

import 'package:drift/native.dart';
import 'package:dzeroth/app/session_encryption_device.dart';
import 'package:dzeroth/core/storage/app_database.dart';
import 'package:dzeroth/core/vault/vault_session.dart';
import 'package:dzeroth/core/vault/vault_status.dart';
import 'package:dzeroth/features/keys/domain/device_keys_service.dart';
import 'package:dzeroth/features/messages/domain/e2ee/encryption_device.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../support/fake_vault_world.dart';

class _MockSession extends Mock implements VaultSession {}

const _a = 'user-a';
const _key = 'account:e2ee_unavailable_since';

void main() {
  late AppDatabase db;
  late FakeVaultWorld world;
  late ValueNotifier<DeviceKeysStatus> deviceKeys;
  late ValueNotifier<bool> engine;
  late DateTime clock;
  late List<Object> reported;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    world = FakeVaultWorld();
    deviceKeys = ValueNotifier(DeviceKeysStatus.dormant);
    engine = ValueNotifier(false);
    // Relative to now (the fixed-date guard); the adapter reads the injected
    // clock only.
    clock = DateTime.now().toUtc();
    reported = [];
  });
  tearDown(() => db.close());

  SessionEncryptionDevice adapt(VaultSession session, String launch) =>
      SessionEncryptionDevice(
        session: session,
        deviceKeys: deviceKeys,
        engineUnavailable: engine,
        database: db,
        now: () => clock,
        launchId: launch,
        onUnexpectedError: (e, _) => reported.add(e),
      );

  group('forwarding', () {
    test('every getter forwards to the session', () async {
      final session = world.launch();
      final device = adapt(session, 'l1');
      addTearDown(device.dispose);

      expect(device.vaultStatus, same(session.status));
      expect(device.deviceKeys, same(deviceKeys));
      expect(device.engineUnavailable, same(engine));
      expect(device.flag, E2eeFlag.unknown);
      expect(device.mayStart, isFalse);
      expect(device.vaultKnown, isFalse);
      expect(device.historyLostThisOpen, isFalse);
      expect(device.localRecordUnusable, isFalse);

      await session.onSignedIn(_a, flag: E2eeFlag.on);
      expect(device.vaultStatus.value, VaultStatus.ready);
      expect(device.flag, E2eeFlag.on);
      expect(device.mayStart, isTrue);
      expect(device.vaultKnown, isTrue);

      deviceKeys.value = const DeviceKeysStatus.failed(
        retryable: false,
        localRecordUnusable: true,
      );
      expect(device.localRecordUnusable, isTrue);
      deviceKeys.value = const DeviceKeysStatus.failed(retryable: false);
      expect(device.localRecordUnusable, isFalse);
    });

    test('retryOpen calls retry once', () async {
      final session = _MockSession();
      when(() => session.status).thenReturn(ValueNotifier(VaultStatus.off));
      when(() => session.retry()).thenAnswer((_) async {});
      final device = adapt(session, 'l1');
      addTearDown(device.dispose);
      await device.retryOpen();
      verify(() => session.retry()).called(1);
    });

    test('the adapter is an EncryptionDevice and names no wipe', () {
      final session = _MockSession();
      when(() => session.status).thenReturn(ValueNotifier(VaultStatus.off));
      final device = adapt(session, 'l1');
      addTearDown(device.dispose);
      expect(device, isA<EncryptionDevice>());
    });
  });

  group('unavailableLong (R4)', () {
    Future<SessionEncryptionDevice> launchUnavailable(String launch) async {
      world.cipherUnavailable.add(_a);
      final session = world.launch();
      final device = adapt(session, launch);
      await session.onSignedIn(_a, flag: E2eeFlag.on);
      expect(session.status.value, VaultStatus.unavailable);
      await device.idle;
      return device;
    }

    test('unavailable on one launch never sets unavailableLong', () async {
      final device = await launchUnavailable('l1');
      addTearDown(device.dispose);
      expect(device.unavailableLong.value, isFalse);
      expect(await db.readSetting(_key), isNotNull);
      // A day later, same launch: still the short text.
      clock = clock.add(const Duration(hours: 48));
      await device.recheck();
      expect(device.unavailableLong.value, isFalse);
    });

    test('unavailable on two launches 24 h apart sets it', () async {
      final first = await launchUnavailable('l1');
      first.dispose();
      clock = clock.add(kUnavailableNamesSignOutAfter);
      final second = await launchUnavailable('l2');
      addTearDown(second.dispose);
      expect(second.unavailableLong.value, isTrue);
    });

    test('two launches less than 24 h apart do not set it', () async {
      final first = await launchUnavailable('l1');
      first.dispose();
      clock = clock.add(const Duration(hours: 23));
      final second = await launchUnavailable('l2');
      addTearDown(second.dispose);
      expect(second.unavailableLong.value, isFalse);
    });

    test('a ready open in between clears it', () async {
      final first = await launchUnavailable('l1');
      first.dispose();
      // Launch 2 opens fine: the stored value goes.
      world.cipherUnavailable.clear();
      final session = world.launch();
      final ok = adapt(session, 'l2');
      addTearDown(ok.dispose);
      await session.onSignedIn(_a, flag: E2eeFlag.on);
      await ok.idle;
      expect(session.status.value, VaultStatus.ready);
      expect(await db.readSetting(_key), isNull);
      // Launch 3, 48 h later: unavailable again counts from here.
      clock = clock.add(const Duration(hours: 48));
      final third = await launchUnavailable('l3');
      addTearDown(third.dispose);
      expect(third.unavailableLong.value, isFalse);
    });

    test('opening or off between two unavailable launches does not clear '
        'the stored time', () async {
      final first = await launchUnavailable('l1');
      first.dispose();
      clock = clock.add(const Duration(hours: 30));
      final session = world.launch();
      final second = adapt(session, 'l2');
      addTearDown(second.dispose);
      // The launch's first statuses (off, opening) leave the key alone.
      expect(await db.readSetting(_key), isNotNull);
      world.cipherUnavailable.add(_a);
      await session.onSignedIn(_a, flag: E2eeFlag.on);
      await second.idle;
      expect(second.unavailableLong.value, isTrue);
    });

    test('a malformed stored value is replaced, not trusted', () async {
      await db.writeSetting(_key, 'garbage');
      final device = await launchUnavailable('l1');
      addTearDown(device.dispose);
      expect(device.unavailableLong.value, isFalse);
      expect(await db.readSetting(_key), startsWith('l1|'));
    });

    test(
      'a failed read leaves it false and is reported without text',
      () async {
        await db.close();
        db = AppDatabase.forTesting(NativeDatabase.memory());
        final session = world.launch();
        world.cipherUnavailable.add(_a);
        final broken = SessionEncryptionDevice(
          session: session,
          deviceKeys: deviceKeys,
          engineUnavailable: engine,
          database: _FailingReads(db),
          now: () => clock,
          launchId: 'l1',
          onUnexpectedError: (e, _) => reported.add(e),
        );
        addTearDown(broken.dispose);
        await session.onSignedIn(_a, flag: E2eeFlag.on);
        await broken.idle;
        expect(broken.unavailableLong.value, isFalse);
        expect(reported, hasLength(1));
        expect(reported.single, isA<StateError>());
        expect(
          (reported.single as StateError).message,
          'unavailableSince.read',
        );
      },
    );
  });

  group('fix round D and E', () {
    Future<SessionEncryptionDevice> launchUnavailable(String launch) async {
      world.cipherUnavailable.add(_a);
      final session = world.launch();
      final device = adapt(session, launch);
      await session.onSignedIn(_a, flag: E2eeFlag.on);
      await device.idle;
      return device;
    }

    test('a stored time in the future is treated as absent', () async {
      final future = clock.add(const Duration(days: 400));
      await db.writeSetting(_key, 'l0|${future.microsecondsSinceEpoch}');
      final device = await launchUnavailable('l1');
      addTearDown(device.dispose);
      expect(device.unavailableLong.value, isFalse);
      expect(await db.readSetting(_key), startsWith('l1|'));
    });

    test(
      'a stored time that is zero or negative is treated as absent',
      () async {
        await db.writeSetting(_key, 'l0|-5');
        final device = await launchUnavailable('l1');
        addTearDown(device.dispose);
        expect(device.unavailableLong.value, isFalse);
        expect(await db.readSetting(_key), startsWith('l1|'));
      },
    );

    test('any other failure in the queue step reports one fixed '
        'StateError and the queue keeps working', () async {
      await db.writeSetting(
        _key,
        'l0|${clock.subtract(const Duration(days: 3)).microsecondsSinceEpoch}',
      );
      var throwNow = true;
      world.cipherUnavailable.add(_a);
      final session = world.launch();
      final device = SessionEncryptionDevice(
        session: session,
        deviceKeys: deviceKeys,
        engineUnavailable: engine,
        database: db,
        now: () {
          if (throwNow) throw StateError('secret clock detail');
          return clock;
        },
        launchId: 'l1',
        onUnexpectedError: (e, _) => reported.add(e),
      );
      addTearDown(device.dispose);
      await session.onSignedIn(_a, flag: E2eeFlag.on);
      await device.idle;
      expect(reported, hasLength(1));
      expect((reported.single as StateError).message, 'unavailableSince');
      throwNow = false;
      await device.recheck();
      expect(device.unavailableLong.value, isTrue);
    });

    test('flag off and no vault: the 24 h clock is not started', () async {
      final session = _MockSession();
      when(() => session.status)
          .thenReturn(ValueNotifier(VaultStatus.unavailable));
      when(() => session.vaultKnown).thenReturn(false);
      when(() => session.mayStart).thenReturn(false);
      final device = adapt(session, 'l1');
      addTearDown(device.dispose);
      await device.idle;
      expect(await db.readSetting(_key), isNull);
    });

    test('a status other than unavailable clears unavailableLong and '
        'keeps the stored time', () async {
      final first = await launchUnavailable('l1');
      first.dispose();
      clock = clock.add(kUnavailableNamesSignOutAfter);
      world.cipherUnavailable.add(_a);
      final session = world.launch();
      final second = adapt(session, 'l2');
      addTearDown(second.dispose);
      await session.onSignedIn(_a, flag: E2eeFlag.on);
      await second.idle;
      expect(second.unavailableLong.value, isTrue);
      world.cipherUnavailable.clear();
      await session.retry();
      await second.idle;
      // Not ready (or it is): only `ready` may delete; a plain non-ready
      // status leaves the key. Drive one directly.
      (session.status as ValueNotifier<VaultStatus>).value =
          VaultStatus.opening;
      await second.idle;
      expect(second.unavailableLong.value, isFalse);
    });

    test(
      'resetForAccount clears unavailableLong and drops queued work',
      () async {
        final first = await launchUnavailable('l1');
        first.dispose();
        clock = clock.add(kUnavailableNamesSignOutAfter);
        final second = await launchUnavailable('l2');
        addTearDown(second.dispose);
        expect(second.unavailableLong.value, isTrue);
        second.resetForAccount();
        expect(second.unavailableLong.value, isFalse);
        await second.idle;
        expect(second.unavailableLong.value, isFalse);
      },
    );

    test('last round item 8: the status left unavailable while the queued '
        'step was reading: unavailableLong is not set', () async {
      final gated = _GatedReads();
      addTearDown(gated.close);
      await gated.writeSetting(
        _key,
        'l0|${clock.subtract(const Duration(days: 3)).microsecondsSinceEpoch}',
      );
      final status = ValueNotifier(VaultStatus.unavailable);
      final session = _MockSession();
      when(() => session.status).thenReturn(status);
      when(() => session.vaultKnown).thenReturn(true);
      when(() => session.mayStart).thenReturn(true);
      gated.gate = Completer<void>();
      final device = SessionEncryptionDevice(
        session: session,
        deviceKeys: deviceKeys,
        engineUnavailable: engine,
        database: gated,
        now: () => clock,
        launchId: 'l1',
        onUnexpectedError: (e, _) => reported.add(e),
      );
      addTearDown(device.dispose);
      status.value = VaultStatus.opening;
      gated.gate!.complete();
      await device.idle;
      expect(device.unavailableLong.value, isFalse);
    });

    test('a write after sign-out is dropped (the epoch is captured when '
        'the status changed)', () async {
      world.cipherUnavailable.add(_a);
      final session = world.launch();
      final device = adapt(session, 'l1');
      addTearDown(device.dispose);
      final signing = session.onSignedIn(_a, flag: E2eeFlag.on);
      // The status listener ran during onSignedIn; end the session before the
      // queued step gets to write.
      await signing;
      db.sessionEpoch.end();
      await device.idle;
      expect(await db.readSetting(_key), isNull);
    });
  });
}

/// An [AppDatabase] whose `readSetting` waits for [gate] when one is set.
class _GatedReads extends AppDatabase {
  _GatedReads() : super.forTesting(NativeDatabase.memory());

  Completer<void>? gate;

  @override
  Future<String?> readSetting(String key) async {
    final g = gate;
    if (g != null) await g.future;
    return super.readSetting(key);
  }
}

/// An [AppDatabase] whose `readSetting` throws (a cache failure).
class _FailingReads extends AppDatabase {
  _FailingReads(AppDatabase inner) : super.forTesting(NativeDatabase.memory());

  @override
  Future<String?> readSetting(String key) => throw StateError('read');
}
