// Device keys on a real platform: the real MLS engine, vault cipher, vault,
// owner (Web Lock on the web), markers (device settings of a cache database
// of its OWN, never the app's `dzeroth` cache) and vault session; only the
// key directory is a fake (`FakeKeyServer`, behind a real ApiClient at the
// repository seam). On an Android device:
//   cd app && flutter test integration_test/device_keys_test.dart -d <serial>
// In Chrome, JS and --wasm builds, with ChromeDriver on a free port (see
// crypto/README.md "Browser tests"; `make crypto-web` first):
//   cd app && flutter drive --driver=test_driver/integration_test.dart
//     --target=integration_test/device_keys_test.dart -d web-server
//     --browser-name=chrome --driver-port=<port> --headless [--wasm]
// Every assertion is in a testWidgets body (flutter drive on the web reports
// only those). No dart:io import here.
import 'dart:convert';
import 'dart:math';

import 'package:dzeroth/core/crypto/crypto_engine.dart';
import 'package:dzeroth/core/crypto/crypto_engine_factory.dart';
import 'package:dzeroth/core/feature_flags/service_feature_gate.dart';
import 'package:dzeroth/core/session/session_end.dart';
import 'package:dzeroth/core/storage/app_database.dart';
import 'package:dzeroth/core/vault/vault_cipher.dart';
import 'package:dzeroth/core/vault/vault_markers.dart';
import 'package:dzeroth/core/vault/vault_open.dart';
import 'package:dzeroth/core/vault/vault_owner.dart';
import 'package:dzeroth/core/vault/vault_session.dart';
import 'package:dzeroth/core/vault/vault_status.dart';
import 'package:dzeroth/features/keys/data/keys_repository.dart';
import 'package:dzeroth/features/keys/domain/device_keys_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'support/fake_key_server.dart';

final bool _supported =
    kIsWeb || defaultTargetPlatform == TargetPlatform.android;

/// The test's own cache database (the app's is `kCacheDatabaseName`): the
/// production one must never be used here, its wipes would hit real vaults.
const String _cacheName = 'dzeroth_device_keys_it';

final RegExp _serverIdPattern = RegExp(r'^[A-Za-z0-9_-]{16,64}$');

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  void report(String key, Object? value) {
    debugPrint('$key: $value');
    binding.reportData = {...?binding.reportData, key: '$value'};
  }

  group('device keys', skip: !_supported, () {
    late CryptoEngine engine;
    late AppDatabase cache;
    late DriftVaultMarkers markers;
    final uids = <String>[];
    final sessions = <VaultSession>[];
    final services = <DeviceKeysService>[];
    final random = Random.secure();
    var launches = 0;

    String newUid() {
      final uid =
          'device-keys-it-${DateTime.now().microsecondsSinceEpoch}-'
          '${random.nextInt(0xffffffff)}';
      uids.add(uid);
      return uid;
    }

    String hexId() =>
        [for (var i = 0; i < 16; i++) random.nextInt(256)]
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join();

    /// A new launch: a session with the real collaborators and a service
    /// over [server], signed in as [uid()].
    (VaultSession, DeviceKeysService) launch(
      FakeKeyServer server,
      String? Function() uid,
    ) {
      final s = VaultSession(
        openCipher: (u) => openVaultCipher(uid: u, engine: engine),
        openVault: openVault,
        wipeVaultFile: wipeVaultFileForAlias,
        deleteVaultKey: deleteVaultKeyForAlias,
        createOwner: createVaultOwner,
        markers: markers,
        supported: true,
        launchId: 'device-keys-it-${launches++}',
      );
      final service = DeviceKeysService(
        session: s,
        repository: KeysRepository(
          apiClient: server.apiClient,
          gate: ServiceFeatureGate(isEnabled: () => true),
          deviceFacts: () => false,
        ),
        engine: () => engine,
        currentUid: uid,
      );
      s
        ..onVaultReady = service.onVaultReady
        ..beforeExplicitWipe = service.removeThisDevice;
      sessions.add(s);
      services.add(service);
      return (s, service);
    }

    setUpAll(() {
      engine = createCryptoEngine();
      cache = AppDatabase.named(_cacheName);
      markers = DriftVaultMarkers(cache, persistent: true);
    });

    tearDown(() async {
      // Cleanup only; the assertions are in the test bodies.
      for (final s in services) {
        s.dispose();
      }
      services.clear();
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

    testWidgets('first run: a random device registered, 50 one-time packages '
        'and a last-resort one uploaded, their private parts in the vault; '
        'a second ensureReady sends nothing', (tester) async {
      final server = FakeKeyServer();
      final uid = newUid();
      final (s, service) = launch(server, () => uid);
      await s.start(restoredUid: null, restoreDefinitive: true);
      await s.onSignedIn(uid, e2eeEnabled: true);
      await service.ensureReady();

      expect(s.status.value, VaultStatus.ready);
      expect(service.status.value, DeviceKeysStatus.ready);
      expect(server.calls, ['register', 'upload']);

      final vault = s.vault!;
      final id = utf8.decode((await vault.deviceId())!);
      expect(id, matches(RegExp(r'^[0-9a-f]{32}$')));
      expect(id, matches(_serverIdPattern));
      expect(id, isNot(contains(uid)));
      expect(server.devices.keys, [id]);
      final device = server.devices[id]!;
      expect(device.pool, hasLength(50));
      expect(device.lastResort, isNotNull);
      expect(device.signatureKey, hasLength(32));
      final upload = server.uploads.single;
      expect(upload.keyPackages, hasLength(50));

      // The private parts are in the vault: a peer adds this device with an
      // uploaded one-time package, and with the last-resort one, and the
      // device state read back from the vault joins both groups.
      final state = (await vault.deviceState())!;
      final peer = await engine.createDevice(
        Uint8List.fromList(utf8.encode(hexId())),
      );
      for (final package in [
        upload.keyPackages[7],
        upload.lastResortKeyPackage,
      ]) {
        final groupId = Uint8List.fromList(utf8.encode(hexId()));
        final group = await engine.createGroup(peer.deviceState, groupId);
        final commit = await engine.commitChange(
          peer.deviceState,
          group,
          addKeyPackages: [Uint8List.fromList(package)],
        );
        final joined = await engine.joinFromWelcome(state, commit.welcome!);
        expect(joined.groupId, groupId);
      }

      // The device state the engine has after joining is not persisted
      // here (the test never writes it back): the vault is unchanged.
      final calls = server.calls.length;
      await service.ensureReady();
      expect(server.calls.length, calls, reason: 'a second run is a no-op');
      report('device_id_length', id.length);
      report('pool', device.pool.length);
    });

    testWidgets('explicit sign-out removes the device and wipes the vault; '
        'signing in again gives a NEW device id', (tester) async {
      final server = FakeKeyServer();
      final uid = newUid();
      String? current = uid;
      final (s, service) = launch(server, () => current);
      await s.start(restoredUid: null, restoreDefinitive: true);
      await s.onSignedIn(uid, e2eeEnabled: true);
      await service.ensureReady();
      final id = utf8.decode((await s.vault!.deviceId())!);
      expect(server.devices.keys, [id]);

      // The auth bloc's explicit sign-out: hook, then the session end.
      await s.beforeExplicitSignOut(uid);
      current = null;
      await s.onSessionEnded(uid, SessionEnd.userSignedOut);
      expect(server.devices, isEmpty);
      expect(server.removals.single.deviceId, id);
      expect(s.status.value, VaultStatus.off);
      expect(await markers.known(vaultKeyAlias(uid)), isNull);

      // Signing in again: an empty, new vault and a new device.
      current = uid;
      await s.onSignedIn(uid, e2eeEnabled: true);
      expect(s.vault!.createdThisOpen, isTrue, reason: 'the old vault is gone');
      await service.ensureReady();
      final fresh = utf8.decode((await s.vault!.deviceId())!);
      expect(fresh, isNot(id));
      expect(server.devices.keys, [fresh]);
      expect(server.devices[fresh]!.pool, hasLength(50));
      expect(service.status.value, DeviceKeysStatus.ready);
    });
  });
}
