import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:drift_flutter/drift_flutter.dart'
    show MissingBrowserFeature, WasmDatabaseResult, WasmStorageImplementation;
import 'package:dzeroth/core/vault/secure_vault.dart';
import 'package:dzeroth/core/vault/vault_database.dart';
import 'package:dzeroth/core/vault/vault_open.dart';
import 'package:dzeroth/core/vault/vault_open_io.dart';
import 'package:dzeroth/core/vault/vault_status.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_vault_cipher.dart';

/// Counts [close] calls; nothing else is used by the handler.
class _RecordingExecutor extends Fake implements QueryExecutor {
  int closes = 0;

  @override
  Future<void> close() async => closes++;
}

Matcher _throwsStatus(VaultStatus status) => throwsA(
  isA<VaultOpenException>().having((e) => e.status, 'status', status),
);

void main() {
  test('the web storage decision, for every storage drift can choose', () {
    const expected = {
      WasmStorageImplementation.opfsShared: true,
      WasmStorageImplementation.opfsLocks: true,
      WasmStorageImplementation.sharedIndexedDb: true,
      WasmStorageImplementation.unsafeIndexedDb: false,
      WasmStorageImplementation.inMemory: false,
    };
    // A new drift storage fails here until it is classified.
    expect(expected.keys.toSet(), WasmStorageImplementation.values.toSet());
    for (final entry in expected.entries) {
      expect(
        isAcceptedVaultWebStorage(entry.key),
        entry.value,
        reason: '${entry.key}',
      );
    }
    expect(kVaultAcceptedWebStorages, {
      WasmStorageImplementation.opfsShared,
      WasmStorageImplementation.opfsLocks,
      WasmStorageImplementation.sharedIndexedDb,
    });
  });

  test('the web result handler refuses in-memory and unsafe IndexedDB, '
      'closing their connection, and accepts durable storage', () async {
    for (final storage in WasmStorageImplementation.values) {
      final executor = _RecordingExecutor();
      final result = WasmDatabaseResult(
        DatabaseConnection(executor),
        storage,
        storage == WasmStorageImplementation.inMemory
            ? {MissingBrowserFeature.indexedDb}
            : const {},
      );
      if (isAcceptedVaultWebStorage(storage)) {
        checkVaultWebResult(result);
        await pumpEventQueue();
        expect(executor.closes, 0, reason: '$storage');
      } else {
        expect(
          () => checkVaultWebResult(result),
          _throwsStatus(VaultStatus.unavailable),
          reason: '$storage',
        );
        await pumpEventQueue();
        expect(executor.closes, 1, reason: '$storage');
      }
      expect(lastVaultWebStorage, storage);
    }
  });

  test(
    'anything but Android (native) is unsupported, before drift starts',
    () async {
      expect(
        () => openIoVaultConnection('dzeroth_vault_x', isAndroid: false),
        _throwsStatus(VaultStatus.unsupported),
      );
      // The VM host is not Android.
      await expectLater(
        openVault(uid: 'u1', cipher: FakeVaultCipher()),
        _throwsStatus(VaultStatus.unsupported),
      );
      await expectLater(
        wipeVaultFile(uid: 'u1'),
        _throwsStatus(VaultStatus.unsupported),
      );
    },
  );

  test('an empty uid is refused', () async {
    await expectLater(
      openVault(uid: '', cipher: FakeVaultCipher()),
      throwsArgumentError,
    );
    await expectLater(wipeVaultFile(uid: ''), throwsArgumentError);
  });

  test('wipeVaultDatabase deletes every row with a cipher that throws, and '
      'closes the database', () async {
    final dir = Directory.systemTemp.createTempSync('vault_wipe');
    final file = File('${dir.path}${Platform.pathSeparator}v.sqlite');
    final cipher = FakeVaultCipher();
    final vault = await openVaultOnDatabase(
      VaultDatabase.forTesting(NativeDatabase(file)),
      uid: 'u1',
      cipher: cipher,
    );
    await vault.transaction((tx) async {
      await tx.putDevice(Uint8List(3), Uint8List(4));
      await tx.putMessage(
        StoredMessage(
          conversationId: 'c1',
          messageId: 'm1',
          createdAtMicros: 1,
          fromSelf: true,
          state: StoredMessageState.visible,
          generation: 1,
          epoch: 1,
          content: Uint8List(5),
        ),
      );
      await tx.putSetting('a', Uint8List(1));
    });
    await vault.close();
    cipher.throwsEverything = true;

    final wiped = VaultDatabase.forTesting(NativeDatabase(file));
    await wipeVaultDatabase(wiped);
    await expectLater(wiped.customSelect('SELECT 1').get(), throwsA(anything));

    final check = VaultDatabase.forTesting(NativeDatabase(file));
    for (final table in check.vaultTables) {
      expect(
        await check.select(table).get(),
        isEmpty,
        reason: table.actualTableName,
      );
    }
    await check.close();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('wipeVaultDatabase on a failing storage is unavailable', () async {
    final db = VaultDatabase.forTesting(
      LazyDatabase(() async => throw StateError('no storage')),
    );
    await expectLater(
      wipeVaultDatabase(db),
      _throwsStatus(VaultStatus.unavailable),
    );
  });
}
