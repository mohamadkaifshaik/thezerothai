import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:dzeroth/core/crypto/crypto_engine.dart';
import 'package:dzeroth/core/crypto/crypto_types.dart';
import 'package:dzeroth/core/feature_flags/service_feature_gate.dart';
import 'package:dzeroth/core/session/session_end.dart';
import 'package:dzeroth/core/vault/secure_vault.dart' show openVaultOnDatabase;
import 'package:dzeroth/core/vault/vault_database.dart';
import 'package:dzeroth/core/vault/vault_session.dart';
import 'package:dzeroth/core/vault/vault_status.dart';
import 'package:dzeroth/features/keys/data/keys_repository.dart';
import 'package:dzeroth/features/keys/domain/device_keys_service.dart';

import 'fake_crypto_engine.dart';
import 'fake_key_server.dart';
import 'fake_vault_cipher.dart';
import 'fake_vault_world.dart';

/// Records the engine calls the service makes, in [log], and the results.
class RecordingKeyEngine implements CryptoEngine {
  RecordingKeyEngine(this.log);

  final List<String> log;
  final FakeCryptoEngine _inner = FakeCryptoEngine();
  final List<Uint8List> createdIds = [];
  KeyPackagesResult? lastGenerated;
  final List<(int, bool)> generated = [];

  /// Thrown by the next createDevice when set.
  MlsException? failCreate;

  @override
  Future<Uint8List> randomBytes(int length) {
    log.add('engine.random:$length');
    return _inner.randomBytes(length);
  }

  @override
  Future<DeviceCreated> createDevice(Uint8List deviceId) async {
    log.add('engine.create');
    final fail = failCreate;
    if (fail != null) {
      failCreate = null;
      throw fail;
    }
    createdIds.add(Uint8List.fromList(deviceId));
    return _inner.createDevice(deviceId);
  }

  @override
  Future<KeyPackagesResult> generateKeyPackages(
    Uint8List deviceState, {
    required int count,
    required bool lastResort,
  }) async {
    log.add('engine.generate:$count:$lastResort');
    generated.add((count, lastResort));
    final r = await _inner.generateKeyPackages(
      deviceState,
      count: count,
      lastResort: lastResort,
    );
    lastGenerated = r;
    return r;
  }

  @override
  Object? noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('$invocation');
}

/// One device: the vault world, the key directory, the engine, a clock, the
/// flag and the signed-in user; [launch] makes a new session + service over
/// the same world and server (an app restart).
class DeviceKeysRig {
  DeviceKeysRig() {
    server = FakeKeyServer(now: () => now);
    engine = RecordingKeyEngine(log);
    // Snapshot of the vault at the moment each RPC reaches the server.
    for (final name in ['register', 'upload', 'list', 'remove']) {
      server.onCall[name] = () async => _onRpc(name);
    }
  }

  final FakeVaultWorld world = FakeVaultWorld();
  late final FakeKeyServer server;
  final List<String> log = [];
  late final RecordingKeyEngine engine;

  /// The injected clock (starts at the real time; only advanced by hand).
  DateTime now = DateTime.now().toUtc();
  bool flag = true;
  String? uid;
  final List<Object> reported = [];
  bool supported = true;

  /// What the service's foreground check answers.
  bool foreground = true;

  /// The service's client deadline on list/register/upload.
  Duration rpcTimeout = kDeviceKeysRpcTimeout;

  /// The vault device state (per uid) when each upload reached the server.
  final List<Uint8List?> stateAtUpload = [];

  /// Whether the vault held a device when each register reached the server.
  final List<bool> deviceAtRegister = [];

  late VaultSession session;
  late DeviceKeysService service;
  late ServiceFeatureGate gate;

  /// The periodic tick the service scheduled (driven by hand).
  void Function()? tick;
  Duration? tickPeriod;
  int timers = 0;

  void _onRpc(String name) {
    log.add('rpc.$name');
    final file = uid == null ? null : world.files[uid];
    if (name == 'upload') {
      stateAtUpload.add(file?.deviceState);
    }
    if (name == 'register') {
      deviceAtRegister.add(file?.deviceId != null);
    }
  }

  void advance(Duration d) {
    now = now.add(d);
    world.advance(d);
  }

  /// Moves the clock to one minute after the next IST midnight (UTC+05:30).
  void toNextIstDay() {
    const ist = Duration(hours: 5, minutes: 30);
    final local = now.add(ist);
    final midnight = DateTime.utc(
      local.year,
      local.month,
      local.day,
    ).add(const Duration(days: 1)).subtract(ist);
    advance(midnight.difference(now) + const Duration(minutes: 1));
  }

  void launch({VaultSession? realSession}) {
    session =
        realSession ?? world.launch(supported: supported, reported: reported);
    gate = ServiceFeatureGate(isEnabled: () => flag, now: () => now);
    service = DeviceKeysService(
      session: session,
      repository: KeysRepository(
        apiClient: server.apiClient,
        gate: gate,
        deviceFacts: () => session.vaultKnown,
      ),
      engine: () => engine,
      currentUid: () => uid,
      now: () => now,
      periodicTimer: (period, onTick) {
        timers++;
        tickPeriod = period;
        tick = onTick;
        return _NoTimer();
      },
      rpcTimeout: rpcTimeout,
      isForeground: () => foreground,
      onUnexpectedError: (error, _) => reported.add(error),
    );
    session
      ..addVaultReadyHook(service.onVaultReady)
      ..beforeExplicitWipe = service.removeThisDevice;
  }

  /// A session over the real vault on an in-memory database (pass it to
  /// [launch]).
  (VaultDatabase, VaultSession) realVault() {
    final db = VaultDatabase.forTesting(NativeDatabase.memory());
    final cipher = FakeVaultCipher();
    final session = VaultSession(
      openCipher: (_, {required create}) async => cipher,
      openVault: ({
        required uid,
        required cipher,
        String? expectedStorage,
        required create,
      }) => openVaultOnDatabase(db, uid: uid, cipher: cipher),
      wipeVaultFile: ({required alias, String? expectedStorage}) async {},
      deleteVaultKey: ({required alias}) async {},
      createOwner: () => FakeVaultOwner(world),
      markers: world.markers,
      supported: true,
      launchId: 'keys-real-vault',
      now: () => now,
    );
    return (db, session);
  }

  /// What the session is told about e2ee_dm at sign-in (null: [flag]).
  E2eeFlag? answer;
  E2eeFlag get sessionFlag => answer ?? (flag ? E2eeFlag.on : E2eeFlag.off);

  /// Signs [user] in and waits for the device run the open started.
  Future<void> signIn(String user) async {
    uid = user;
    await session.start(restoredUid: null, restoreDefinitive: true);
    await session.onSignedIn(user, flag: sessionFlag);
    await service.ensureReady();
  }

  /// The explicit sign-out path of the auth bloc: the hook inside the
  /// budget, then the session end.
  Future<void> signOut() async {
    final user = uid!;
    await session.beforeExplicitSignOut(user);
    uid = null;
    await session.onSessionEnded(user, SessionEnd.userSignedOut);
  }

  FakeVaultFile? file([String? user]) => world.files[user ?? uid];

  String? storedId([String? user]) {
    final bytes = file(user)?.deviceId;
    return bytes == null ? null : utf8.decode(bytes);
  }

  String setting(String key, [String? user]) => file(user)?.rows[key] ?? '';

  Map<String, FakeKeyDevice> get devices => server.devices;

  /// The RPCs that reached the server, from [from] on.
  List<String> rpcs([int from = 0]) => server.calls.sublist(from);
}

class _NoTimer implements Timer {
  @override
  void cancel() {}

  @override
  bool get isActive => true;

  @override
  int get tick => 0;
}
