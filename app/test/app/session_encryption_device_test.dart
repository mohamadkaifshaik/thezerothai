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
    clock = DateTime.utc(2026, 11, 24, 12);
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
}

/// An [AppDatabase] whose `readSetting` throws (a cache failure).
class _FailingReads extends AppDatabase {
  _FailingReads(AppDatabase inner) : super.forTesting(NativeDatabase.memory());

  @override
  Future<String?> readSetting(String key) => throw StateError('read');
}
