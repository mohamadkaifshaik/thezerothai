// The vault session on a real platform: the real cipher, vault, owner (Web
// Lock on the web) and markers (the real cache database's device settings).
// On an Android device:
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

Uint8List _b(String s) => Uint8List.fromList(utf8.encode(s));

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('vault session', skip: !_supported, () {
    late CryptoEngine engine;
    late AppDatabase cache;
    late DriftVaultMarkers markers;
    final uids = <String>[];
    final sessions = <VaultSession>[];
    var launches = 0;

    String newUid() {
      final uid = 'vault-session-it-${DateTime.now().microsecondsSinceEpoch}';
      uids.add(uid);
      return uid;
    }

    /// A new "launch": a new session with a new launch id, the real
    /// collaborators.
    VaultSession launch() {
      final s = VaultSession(
        openCipher: (uid) => openVaultCipher(uid: uid, engine: engine),
        openVault: openVault,
        wipeVaultFile: wipeVaultFile,
        deleteVaultKey: deleteVaultKey,
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
      cache = AppDatabase();
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
          await markers.clearAll(uid);
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
        'marker names where it lives', (tester) async {
      final uid = newUid();
      final s = launch();
      await s.start();
      await s.onSignedIn(uid, e2eeEnabled: true);
      expect(s.status.value, VaultStatus.ready);
      expect(s.vault, isNotNull);
      final known = await markers.known(uid);
      expect(known, isNotNull);
      expect(known!.storage, s.vault!.storageName);
      if (kIsWeb) {
        expect(vaultWebStorageApi(known.storage), isNotNull);
      } else {
        expect(known.storage, kVaultNativeStorage);
      }
      debugPrint('vault session storage: ${known.storage}');
    });

    testWidgets('explicit sign-out leaves no vault and no key', (tester) async {
      final uid = newUid();
      final s = launch();
      await s.onSignedIn(uid, e2eeEnabled: true);
      await s.runWrite(
        (v) => v.transaction((tx) => tx.putSetting('k', _b('secret'))),
      );
      await s.onSessionEnded(uid, SessionEnd.userSignedOut);
      expect(s.status.value, VaultStatus.off);
      expect(await markers.known(uid), isNull);
      expect(
        (await markers.owedWipes()).map((o) => o.uid),
        isNot(contains(uid)),
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
      await next.start();
      await next.onSignedIn(uid, e2eeEnabled: true);
      expect(next.status.value, VaultStatus.ready);
      expect(utf8.decode((await next.vault!.setting('k'))!), 'kept');
    });
  });
}
