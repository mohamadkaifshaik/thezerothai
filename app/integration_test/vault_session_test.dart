// The vault session on a real platform: the real cipher, vault, owner (Web
// Lock on the web) and markers (device settings of a cache database of its
// OWN, never the app's `dzeroth` cache). On an Android device:
//   cd app && flutter test integration_test/vault_session_test.dart -d <serial>
// In Chrome, JS and --wasm builds, with ChromeDriver on a free port (see
// crypto/README.md "Browser tests"):
//   cd app && MLS_VECTORS_PORT=8095 flutter drive
//     --driver=test_driver/integration_test.dart
//     --target=integration_test/vault_session_test.dart -d web-server
//     --browser-name=chrome --driver-port=<port> --headless [--wasm]
// Every assertion is in a testWidgets body (flutter drive on the web reports
// only those). No dart:io import here.
import 'dart:convert';
import 'dart:math';

import 'package:dzeroth/core/crypto/crypto_engine.dart';
import 'package:dzeroth/core/crypto/crypto_engine_factory.dart';
import 'package:dzeroth/core/session/session_end.dart';
import 'package:dzeroth/core/storage/app_database.dart';
import 'package:dzeroth/core/vault/vault_cipher.dart';
import 'package:dzeroth/core/vault/vault_markers.dart';
import 'package:dzeroth/core/vault/vault_open.dart';
import 'package:dzeroth/core/vault/vault_owner.dart';
import 'package:dzeroth/core/vault/vault_session.dart';
import 'package:dzeroth/core/vault/vault_status.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

final bool _supported =
    kIsWeb || defaultTargetPlatform == TargetPlatform.android;

/// The test's own cache database (the app's is `kCacheDatabaseName`).
const String _cacheName = 'dzeroth_vault_session_it';

Uint8List _b(String s) => Uint8List.fromList(utf8.encode(s));

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  /// Facts for the report; on the web the driver saves them in
  /// build/integration_response_data.json.
  void report(String key, Object? value) {
    debugPrint('$key: $value');
    binding.reportData = {...?binding.reportData, key: '$value'};
  }

  group('vault session', skip: !_supported, () {
    late CryptoEngine engine;
    late AppDatabase cache;
    late DriftVaultMarkers markers;
    final uids = <String>[];
    final sessions = <VaultSession>[];
    final random = Random.secure();
    var launches = 0;

    /// Aliases whose file wipe COMPLETED (the real wiper, counted).
    final filesWiped = <String>[];
    Future<void> countedWipe({
      required String alias,
      String? expectedStorage,
    }) async {
      await wipeVaultFileForAlias(
        alias: alias,
        expectedStorage: expectedStorage,
      );
      filesWiped.add(alias);
    }

    String newUid() {
      final uid =
          'vault-session-it-${DateTime.now().microsecondsSinceEpoch}-'
          // Not `1 << 32`: that is 0 on the web (32-bit shifts in JS).
          '${random.nextInt(0xffffffff)}';
      uids.add(uid);
      return uid;
    }

    /// A new "launch": a new session with a new launch id, the real
    /// collaborators.
    VaultSession launch() {
      final s = VaultSession(
        openCipher: (uid) => openVaultCipher(uid: uid, engine: engine),
        openVault: openVault,
        wipeVaultFile: countedWipe,
        deleteVaultKey: deleteVaultKeyForAlias,
        createOwner: createVaultOwner,
        markers: markers,
        supported: true,
        launchId: 'it-launch-${launches++}',
      );
      sessions.add(s);
      return s;
    }

    setUpAll(() {
      engine = createCryptoEngine();
      cache = AppDatabase.named(_cacheName);
      markers = DriftVaultMarkers(cache, persistent: true);
    });

    tearDown(() async {
      // Cleanup only; the assertions are in the test bodies.
      for (final s in sessions) {
        try {
          await s.close();
        } catch (_) {}
      }
      sessions.clear();
      for (final uid in uids) {
        try {
          await wipeVaultFile(uid: uid);
        } catch (_) {}
        try {
          await deleteVaultKey(uid: uid);
        } catch (_) {}
        try {
          await markers.clearAll(vaultKeyAlias(uid));
        } catch (_) {}
      }
      uids.clear();
    });

    tearDownAll(() async {
      try {
        await cache.close();
      } catch (_) {}
    });

    testWidgets('sign-in opens the vault and reports ready; the storage '
        'marker names where it lives, and no marker holds the uid', (
      tester,
    ) async {
      final uid = newUid();
      final s = launch();
      await s.start(restoredUid: uid);
      await s.onSignedIn(uid, e2eeEnabled: true);
      expect(s.status.value, VaultStatus.ready);
      expect(s.vault, isNotNull);
      final known = await markers.known(vaultKeyAlias(uid));
      expect(known, isNotNull);
      expect(known!.storage, s.vault!.storageName);
      if (kIsWeb) {
        expect(vaultWebStorageApi(known.storage), isNotNull);
      } else {
        expect(known.storage, kVaultNativeStorage);
      }
      for (final row in await cache.select(cache.appSettingEntries).get()) {
        expect(row.settingKey, isNot(contains(uid)));
        expect(row.settingValue, isNot(contains(uid)));
      }
      report('vault_storage', known.storage);
    });

    testWidgets('the cache reports its storage; the markers are durable only '
        'on one the vault accepts', (tester) async {
      // The cache is open (the test above, or this read).
      await cache.readSetting('probe');
      final chosen = cache.webStorage;
      final persistent = vaultMarkersPersistent(
        cacheInMemory: false,
        isWeb: kIsWeb,
        cacheWebStorage: chosen,
      );
      if (kIsWeb) {
        expect(chosen, isNotNull);
        expect(persistent, kVaultAcceptedWebStorages.contains(chosen));
      } else {
        expect(chosen, isNull);
        expect(persistent, isTrue);
      }
      report('cache_web_storage', chosen?.name);
      report('markers_persistent', persistent);
    });

    testWidgets('explicit sign-out leaves no vault and no key', (tester) async {
      final uid = newUid();
      final s = launch();
      await s.onSignedIn(uid, e2eeEnabled: true);
      await s.runWrite(
        (v) => v.transaction((tx) => tx.putSetting('k', _b('secret'))),
      );
      filesWiped.clear();
      await s.onSessionEnded(uid, SessionEnd.userSignedOut);
      expect(s.status.value, VaultStatus.off);
      // The emptied database file was removed too (the open vault was
      // closed and unregistered by its wipe, so the file wipe could run).
      expect(filesWiped, [vaultKeyAlias(uid)]);
      expect(await markers.known(vaultKeyAlias(uid)), isNull);
      expect(
        (await markers.owedWipes()).map((o) => o.alias),
        isNot(contains(vaultKeyAlias(uid))),
      );

      // No key: opening the cipher has to make a new one.
      final cipher = await openVaultCipher(uid: uid, engine: engine);
      expect(cipher.freshlyCreated, isTrue);
      // No vault: opening creates a new, empty one.
      final vault = await openVault(uid: uid, cipher: cipher);
      expect(vault.createdThisOpen, isTrue);
      expect(await vault.setting('k'), isNull);
      await vault.close();
    });

    testWidgets('an explicit sign-out killed after its pending marker: the '
        'next launch with nobody restored wipes', (tester) async {
      final uid = newUid();
      final s = launch();
      await s.onSignedIn(uid, e2eeEnabled: true);
      await s.runWrite(
        (v) => v.transaction((tx) => tx.putSetting('k', _b('secret'))),
      );
      await s.beforeExplicitSignOut(uid);
      expect(await markers.pendingEnds(), contains(vaultKeyAlias(uid)));
      // "Killed": the vault is closed without any wipe; a new launch.
      await s.close();
      final next = launch();
      await next.start(restoredUid: null);
      expect(await markers.pendingEnds(), isNot(contains(vaultKeyAlias(uid))));
      expect(await markers.known(vaultKeyAlias(uid)), isNull);
      final cipher = await openVaultCipher(uid: uid, engine: engine);
      expect(cipher.freshlyCreated, isTrue, reason: 'the key is gone');
      await cipher.destroy();
    });

    testWidgets('an accepted deletion of a user with NO vault on this device '
        'journals a wipe that the next launch completes (no owed wipe left '
        'behind)', (tester) async {
      final uid = newUid();
      final s = launch();
      await s.noteAccountDeleted(uid);
      expect(
        (await markers.owedWipes()).map((o) => o.alias),
        contains(vaultKeyAlias(uid)),
      );
      final next = launch();
      await next.start(restoredUid: null);
      expect(
        (await markers.owedWipes()).map((o) => o.alias),
        isNot(contains(vaultKeyAlias(uid))),
      );
    });

    testWidgets('session lost, then the same user (same launch and a new '
        'launch) finds the same data', (tester) async {
      final uid = newUid();
      final s = launch();
      await s.onSignedIn(uid, e2eeEnabled: true);
      await s.runWrite(
        (v) => v.transaction((tx) => tx.putSetting('k', _b('kept'))),
      );
      await s.onSessionEnded(uid, SessionEnd.sessionLost);
      expect(s.status.value, VaultStatus.off);

      await s.onSignedIn(uid, e2eeEnabled: true);
      expect(s.status.value, VaultStatus.ready);
      expect(utf8.decode((await s.vault!.setting('k'))!), 'kept');
      expect(s.vault!.createdThisOpen, isFalse);
      await s.onSessionEnded(uid, SessionEnd.sessionLost);

      final next = launch();
      await next.start(restoredUid: uid);
      await next.onSignedIn(uid, e2eeEnabled: true);
      expect(next.status.value, VaultStatus.ready);
      expect(utf8.decode((await next.vault!.setting('k'))!), 'kept');
    });
  });
}
