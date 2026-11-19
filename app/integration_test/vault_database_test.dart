// The vault database on a real platform, with the real cipher. On an
// Android device:
//   cd app && flutter test integration_test/vault_database_test.dart -d <serial>
// In Chrome, JS and --wasm builds, with ChromeDriver on a free port (see
// crypto/README.md "Browser tests"):
//   cd app && MLS_VECTORS_PORT=8095 flutter drive
//     --driver=test_driver/integration_test.dart
//     --target=integration_test/vault_database_test.dart -d web-server
//     --browser-name=chrome --driver-port=<port> --headless [--wasm]
// The web storage drift chose is printed and written to the drive report
// data (`vault_web_storage`). Every assertion is in a testWidgets body
// (flutter drive on the web reports only those). No dart:io import here.
import 'dart:convert';

import 'package:dzeroth/core/crypto/crypto_engine.dart';
import 'package:dzeroth/core/crypto/crypto_engine_factory.dart';
import 'package:dzeroth/core/storage/app_database.dart';
import 'package:dzeroth/core/vault/secure_vault.dart';
import 'package:drift_flutter/drift_flutter.dart' show WebStorageApi;
import 'package:dzeroth/core/vault/vault_cipher.dart';
import 'package:dzeroth/core/vault/vault_database.dart';
import 'package:dzeroth/core/vault/vault_open.dart';
import 'package:dzeroth/core/vault/vault_status.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'support/vault_db_platform.dart';

final bool _supported =
    kIsWeb || defaultTargetPlatform == TargetPlatform.android;

Uint8List _b(String s) => Uint8List.fromList(utf8.encode(s));
String _s(Uint8List? b) => b == null ? '<null>' : utf8.decode(b);

StoredMessage _msg(String id, int at) => StoredMessage(
  conversationId: 'c1',
  messageId: id,
  createdAtMicros: at,
  fromSelf: at.isEven,
  state: StoredMessageState.visible,
  generation: 1,
  epoch: at,
  content: _b('hello $id'),
);

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('vault database', skip: !_supported, () {
    late CryptoEngine engine;
    final uids = <String>[];
    final open = <SecureVault>[];

    String newUid() {
      final uid = 'vault-db-it-${DateTime.now().microsecondsSinceEpoch}';
      uids.add(uid);
      return uid;
    }

    Future<VaultCipher> cipherFor(String uid) =>
        openVaultCipher(uid: uid, engine: engine);

    Future<SecureVault> vaultFor(String uid, VaultCipher cipher) async {
      final vault = await openVault(uid: uid, cipher: cipher);
      open.add(vault);
      return vault;
    }

    setUp(() => engine = createCryptoEngine());

    tearDown(() async {
      // Cleanup only; the assertions are in the test bodies.
      for (final vault in open) {
        try {
          await vault.close();
        } catch (_) {}
      }
      open.clear();
      for (final uid in uids) {
        try {
          await wipeVaultFile(uid: uid);
        } catch (_) {}
        try {
          await deleteVaultKey(uid: uid);
        } catch (_) {}
      }
      uids.clear();
    });

    testWidgets('write, close, reopen with the stored key, read back', (
      tester,
    ) async {
      final uid = newUid();
      final first = await vaultFor(uid, await cipherFor(uid));
      if (kIsWeb) {
        final storage = lastVaultWebStorage;
        debugPrint('vault web storage: ${storage?.name}');
        binding.reportData = {'vault_web_storage': storage?.name};
        expect(storage, isNotNull);
        expect(kVaultAcceptedWebStorages, contains(storage));
      }
      await first.transaction((tx) async {
        await tx.putDevice(_b('device-id'), _b('device-state'));
        await tx.putGroup(
          GroupRecord(
            conversationId: 'c1',
            generation: 2,
            epoch: 3,
            state: _b('group-state'),
            pendingCommit: true,
          ),
        );
        for (var i = 0; i < 120; i++) {
          await tx.putMessage(_msg('m$i', 1000 + i));
        }
        await tx.putOutbox(
          OutboxItem(
            idempotencyKey: 'k1',
            conversationId: 'c1',
            generation: 2,
            epoch: 3,
            ciphertext: _b('wire'),
            reportCommitment: _b('commitment'),
            content: _b('pending'),
            createdAtMicros: 5,
          ),
        );
        await tx.putSetting('s', _b('v'));
      });
      await first.close();
      open.remove(first);

      final cipher = await cipherFor(uid);
      expect(cipher.freshlyCreated, isFalse);
      final again = await vaultFor(uid, cipher);
      expect(_s(await again.deviceId()), 'device-id');
      expect(_s(await again.deviceState()), 'device-state');
      final group = (await again.group('c1'))!;
      expect(
        [group.generation, group.epoch, group.pendingCommit],
        [2, 3, true],
      );
      expect(_s(group.state), 'group-state');
      final all = <StoredMessage>[];
      String? before;
      while (true) {
        final page = await again.messages(
          'c1',
          limit: 50,
          beforeSortKey: before,
        );
        all.addAll(page);
        if (page.length < 50) break;
        before = page.last.sortKey;
      }
      expect(all, hasLength(120));
      expect(all.first.messageId, 'm119');
      expect(_s(all.last.content), 'hello m0');
      expect(all.last.fromSelf, isTrue);
      final outbox = (await again.outbox()).items;
      expect(outbox.single.idempotencyKey, 'k1');
      expect(_s(outbox.single.content), 'pending');
      expect(_s(await again.setting('s')), 'v');
    });

    testWidgets('a throwing transaction leaves no trace on the platform', (
      tester,
    ) async {
      final uid = newUid();
      final vault = await vaultFor(uid, await cipherFor(uid));
      await vault.transaction(
        (tx) => tx.putGroup(
          GroupRecord(
            conversationId: 'c1',
            generation: 1,
            epoch: 1,
            state: _b('old'),
            pendingCommit: false,
          ),
        ),
      );
      Object? caught;
      try {
        await vault.transaction((tx) async {
          await tx.putGroup(
            GroupRecord(
              conversationId: 'c1',
              generation: 1,
              epoch: 2,
              state: _b('new'),
              pendingCommit: true,
            ),
          );
          await tx.putMessage(_msg('m1', 1));
          throw StateError('engine failed');
        });
      } catch (e) {
        caught = e;
      }
      expect(caught, isA<StateError>());
      expect(_s((await vault.group('c1'))!.state), 'old');
      expect(await vault.hasMessage('c1', 'm1'), isFalse);
    });

    testWidgets('a lost key is keyLost, the rows stay, and wipeVaultFile '
        'then a new key opens an empty vault', (tester) async {
      final uid = newUid();
      final vault = await vaultFor(uid, await cipherFor(uid));
      await vault.transaction((tx) => tx.putMessage(_msg('m1', 1)));
      await vault.close();
      open.remove(vault);

      // The key goes; the next cipher is a new key.
      await deleteVaultKey(uid: uid);
      final fresh = await cipherFor(uid);
      expect(fresh.freshlyCreated, isTrue);
      VaultStatus? status;
      try {
        await vaultFor(uid, fresh);
      } on VaultOpenException catch (e) {
        status = e.status;
      }
      expect(status, VaultStatus.keyLost);
      // Twice: still keyLost (nothing was overwritten).
      status = null;
      try {
        await vaultFor(uid, fresh);
      } on VaultOpenException catch (e) {
        status = e.status;
      }
      expect(status, VaultStatus.keyLost);

      await wipeVaultFile(uid: uid);
      final recovered = await vaultFor(uid, fresh);
      expect(await recovered.hasMessage('c1', 'm1'), isFalse);
      await recovered.transaction((tx) => tx.putMessage(_msg('m2', 2)));
      expect(_s((await recovered.message('c1', 'm2'))!.content), 'hello m2');
    });

    testWidgets('two users have separate files, and the cache database works '
        'next to the vault', (tester) async {
      final a = newUid();
      final b = '$a-b';
      uids.add(b);
      final vaultA = await vaultFor(a, await cipherFor(a));
      final vaultB = await vaultFor(b, await cipherFor(b));
      await vaultA.transaction((tx) => tx.putMessage(_msg('a1', 1)));
      expect(await vaultB.hasMessage('c1', 'a1'), isFalse);

      final cache = AppDatabase();
      try {
        await cache.customSelect('SELECT 1').get();
        expect(await vaultA.hasMessage('c1', 'a1'), isTrue);
      } finally {
        await cache.close();
      }
    });

    testWidgets('wipe removes the rows and the key', (tester) async {
      final uid = newUid();
      final vault = await vaultFor(uid, await cipherFor(uid));
      await vault.transaction((tx) => tx.putMessage(_msg('m1', 1)));
      await vault.wipe();
      open.remove(vault);
      final cipher = await cipherFor(uid);
      expect(cipher.freshlyCreated, isTrue);
      final reopened = await vaultFor(uid, cipher);
      expect(await reopened.hasMessage('c1', 'm1'), isFalse);
    });

    testWidgets('wipeVaultFile erases the vault and, on the web, removes '
        'its database', (tester) async {
      final uid = newUid();
      final name = vaultDatabaseName(uid);
      final cipher = await cipherFor(uid);
      final vault = await vaultFor(uid, cipher);
      await vault.transaction((tx) => tx.putMessage(_msg('m1', 1)));
      await vault.close();
      open.remove(vault);
      if (kIsWeb) {
        final before = await existingWebStorageApis(name);
        debugPrint('vault databases before wipeVaultFile: $before');
        expect(before, hasLength(1));
      }

      await wipeVaultFile(uid: uid);

      if (kIsWeb) {
        final after = await existingWebStorageApis(name);
        debugPrint('vault databases after wipeVaultFile: $after');
        binding.reportData = {
          ...?binding.reportData,
          'after_wipe_vault_file': after,
        };
        // OPFS copies are deleted; an IndexedDB copy stays, empty.
        expect(after, isNot(contains('opfs')));
      }
      // The key is still there (deleteVaultKey is separate): a new, empty
      // vault opens under it.
      final again = await vaultFor(uid, cipher);
      expect(await again.hasMessage('c1', 'm1'), isFalse);
    });

    testWidgets('web: a vault that also exists in another storage is '
        'storageChanged, never ready or keyLost, and nothing is lost', (
      tester,
    ) async {
      if (!kIsWeb) return;
      final uid = newUid();
      final name = vaultDatabaseName(uid);
      final cipher = await cipherFor(uid);
      final vault = await vaultFor(uid, cipher);
      final storage = lastVaultWebStorage!;
      await vault.transaction((tx) => tx.putMessage(_msg('m1', 1)));
      await vault.close();
      open.remove(vault);
      if (storage.storageApi != WebStorageApi.opfs) {
        // Only an OPFS vault can get an IndexedDB twin in the same browser.
        debugPrint('storageChanged case not reachable on ${storage.name}');
        binding.reportData = {
          ...?binding.reportData,
          'storage_changed_case': 'not reachable on ${storage.name}',
        };
        return;
      }
      expect(await createIndexedDbCopy(name), isTrue);
      expect(await existingWebStorageApis(name), ['indexedDb', 'opfs']);

      VaultStatus? status;
      try {
        await vaultFor(uid, cipher);
      } on VaultOpenException catch (e) {
        status = e.status;
      }
      expect(status, VaultStatus.storageChanged);
      expect(await existingWebStorageApis(name), ['indexedDb', 'opfs']);

      // Recovery: wipeVaultFile scrubs both copies and deletes the OPFS
      // one; the next open uses the empty IndexedDB copy as a new vault.
      await wipeVaultFile(uid: uid);
      final remaining = await existingWebStorageApis(name);
      final recovered = await vaultFor(uid, cipher);
      expect(await recovered.hasMessage('c1', 'm1'), isFalse);
      binding.reportData = {
        ...?binding.reportData,
        'storage_changed_case': 'storageChanged',
        'after_twin_wipe': remaining,
        'reopened_on': lastVaultWebStorage?.name,
      };
    });
  });
}
