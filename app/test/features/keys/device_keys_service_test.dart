import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' show AppLifecycleState;

import 'package:connectrpc/connect.dart' as connect;
import 'package:dzeroth/core/crypto/crypto_engine.dart';
import 'package:dzeroth/core/crypto/crypto_types.dart';
import 'package:dzeroth/core/feature_flags/service_feature_gate.dart';
import 'package:dzeroth/core/session/session_end.dart';
import 'package:dzeroth/core/vault/vault_session.dart';
import 'package:dzeroth/core/vault/vault_status.dart';
import 'package:dzeroth/features/keys/data/keys_repository.dart';
import 'package:dzeroth/features/keys/domain/device_keys_service.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_crypto_engine.dart';
import '../../support/fake_key_server.dart';
import '../../support/fake_vault_world.dart';

const _a = 'user-a';
const _b = 'user-b';
const _hour = Duration(hours: 1);
const _day = Duration(days: 1);

/// The server's device-id rule (keys.proto).
final _serverIdPattern = RegExp(r'^[A-Za-z0-9_-]{16,64}$');

/// Records the engine calls the service makes, in [log], and the results.
class _RecordingEngine implements CryptoEngine {
  _RecordingEngine(this.log);

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
class _Rig {
  _Rig() {
    server = FakeKeyServer(now: () => now);
    engine = _RecordingEngine(log);
    // Snapshot of the vault at the moment each RPC reaches the server.
    for (final name in ['register', 'upload', 'list', 'remove']) {
      server.onCall[name] = () async => _onRpc(name);
    }
  }

  final FakeVaultWorld world = FakeVaultWorld();
  late final FakeKeyServer server;
  final List<String> log = [];
  late final _RecordingEngine engine;

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

  void launch() {
    session = world.launch(supported: supported, reported: reported);
    gate = ServiceFeatureGate(isEnabled: () => flag, now: () => now);
    service = DeviceKeysService(
      session: session,
      repository: KeysRepository(apiClient: server.apiClient, gate: gate),
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
      ..onVaultReady = service.onVaultReady
      ..beforeExplicitWipe = service.removeThisDevice;
  }

  /// Signs [user] in and waits for the device run the open started.
  Future<void> signIn(String user) async {
    uid = user;
    await session.start(restoredUid: null, restoreDefinitive: true);
    await session.onSignedIn(user, e2eeEnabled: flag);
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

void main() {
  late _Rig rig;

  setUp(() {
    rig = _Rig()..launch();
  });

  group('first run', () {
    test('creates a random device, persists id, state and key in ONE '
        'transaction, THEN registers; generates 50 + a last-resort package, '
        'persists the new state, THEN uploads 51', () async {
      await rig.signIn(_a);

      expect(rig.service.status.value, DeviceKeysStatus.ready);
      expect(rig.rpcs(), ['register', 'upload']);
      expect(rig.engine.createdIds, hasLength(1));
      // The device row existed when RegisterKeyDevice reached the server.
      expect(rig.deviceAtRegister, [true]);
      // The engine was asked for 50 one-time packages and a last-resort one.
      expect(rig.engine.generated, [(50, true)]);
      final upload = rig.server.uploads.single;
      expect(upload.keyPackages, hasLength(50));
      expect(upload.lastResortKeyPackage, isNotEmpty);
      expect(
        upload.lastResortKeyPackage,
        rig.engine.lastGenerated!.keyPackages.last,
      );
      // The state that holds the private parts was in the vault BEFORE the
      // upload reached the server.
      expect(rig.stateAtUpload.single, rig.engine.lastGenerated!.deviceState);
      // Engine order: random id -> create -> (register) -> generate.
      expect(rig.log, [
        'engine.random:16',
        'engine.create',
        'rpc.register',
        'engine.generate:50:true',
        'rpc.upload',
      ]);

      final id = rig.storedId()!;
      final dev = rig.devices[id]!;
      expect(dev.pool, hasLength(50));
      expect(dev.lastResort, isNotNull);
      expect(
        dev.signatureKey,
        rig.server.registrations.single.signaturePublicKey,
      );
      expect(rig.server.registrations.single.deviceId, id);
      expect(upload.deviceId, id);
      expect(rig.reported, isEmpty);
    });

    test('the device id is 32 lower-case hex of 16 random bytes, valid for '
        "the server's pattern, the same bytes the engine got (UTF-8), and not "
        'a function of the uid', () async {
      await rig.signIn(_a);
      final id = rig.storedId()!;
      expect(id, matches(RegExp(r'^[0-9a-f]{32}$')));
      expect(id, matches(_serverIdPattern));
      expect(utf8.decode(rig.engine.createdIds.single), id);
      expect(id, isNot(contains(_a)));

      // The same uid on another install gets another id.
      final other = _Rig()..launch();
      await other.signIn(_a);
      expect(other.storedId(), isNot(id));
      expect(other.storedId(), matches(_serverIdPattern));
    });

    test('vault setting keys never contain the uid', () async {
      await rig.signIn(_a);
      for (final key in rig.file()!.rows.keys) {
        expect(key, isNot(contains(_a)));
      }
      expect(rig.file()!.rows.keys, isNotEmpty);
    });

    test('two concurrent ensureReady calls share one run: one device, one '
        'registration, one upload', () async {
      rig.uid = _a;
      await rig.session.start(restoredUid: null, restoreDefinitive: true);
      await rig.session.onSignedIn(_a, e2eeEnabled: true);
      await Future.wait([
        rig.service.ensureReady(),
        rig.service.ensureReady(),
        rig.service.ensureReady(),
      ]);
      expect(rig.engine.createdIds, hasLength(1));
      expect(rig.rpcs(), ['register', 'upload']);
      expect(rig.devices, hasLength(1));
    });
  });

  group('later runs', () {
    test('a second ensureReady within the hour is a no-op (no RPC); after '
        'the hour it lists and, with a full pool, does nothing else', () async {
      await rig.signIn(_a);
      final before = rig.server.calls.length;
      await rig.service.ensureReady();
      expect(rig.rpcs(before), isEmpty);

      rig.advance(_hour);
      await rig.service.ensureReady();
      expect(rig.rpcs(before), ['list']);
      expect(rig.engine.createdIds, hasLength(1));
      expect(rig.service.status.value, DeviceKeysStatus.ready);
    });

    test('top-up thresholds: 19 left -> generate and upload 31; 20 left -> '
        'nothing', () async {
      await rig.signIn(_a);
      final dev = rig.devices[rig.storedId()]!;
      dev.pool.removeRange(0, 30); // 20 left
      rig.advance(_hour);
      var before = rig.server.calls.length;
      await rig.service.ensureReady();
      expect(rig.rpcs(before), ['list']);

      dev.pool.removeAt(0); // 19 left
      rig.advance(_hour);
      before = rig.server.calls.length;
      await rig.service.ensureReady();
      expect(rig.rpcs(before), ['list', 'upload']);
      final upload = rig.server.uploads.last;
      expect(upload.keyPackages, hasLength(31));
      expect(upload.lastResortKeyPackage, isEmpty);
      expect(rig.engine.generated.last, (31, false));
      expect(rig.stateAtUpload.last, rig.engine.lastGenerated!.deviceState);
      expect(dev.pool, hasLength(50));
    });

    test('the last-resort package is replaced once it is 30 days old, not '
        'before', () async {
      await rig.signIn(_a);
      rig.advance(const Duration(days: 29));
      await rig.service.ensureReady();
      expect(
        rig.server.uploads.where((u) => u.lastResortKeyPackage.isNotEmpty),
        hasLength(1),
      );
      rig.advance(_day);
      await rig.service.ensureReady();
      final rotated = rig.server.uploads.last;
      expect(rotated.lastResortKeyPackage, isNotEmpty);
      expect(rotated.keyPackages, isEmpty);
      expect(rig.engine.generated.last, (0, true));
      expect(
        rig.devices[rig.storedId()]!.lastResort,
        rotated.lastResortKeyPackage,
      );
      expect(rig.stateAtUpload.last, rig.engine.lastGenerated!.deviceState);
    });

    test('a server without the last-resort package gets one again', () async {
      await rig.signIn(_a);
      rig.devices[rig.storedId()]!.lastResort = null;
      rig.advance(_hour);
      await rig.service.ensureReady();
      expect(rig.server.uploads.last.lastResortKeyPackage, isNotEmpty);
      expect(rig.server.uploads.last.keyPackages, isEmpty);
    });

    test(
      'stay active: the last register/upload over 7 days ago -> '
      'RegisterKeyDevice although the pool is full; within 7 days -> not',
      () async {
        await rig.signIn(_a);
        rig.advance(const Duration(days: 6, hours: 23));
        var before = rig.server.calls.length;
        await rig.service.ensureReady();
        expect(rig.rpcs(before), ['list']);

        rig.advance(const Duration(hours: 2)); // 7 days and 1 hour
        before = rig.server.calls.length;
        await rig.service.ensureReady();
        expect(rig.rpcs(before), ['list', 'register']);
        expect(rig.server.registrations.last.deviceId, rig.storedId());

        // Registered just now: the next week does not register again.
        rig.advance(const Duration(days: 6));
        before = rig.server.calls.length;
        await rig.service.ensureReady();
        expect(rig.rpcs(before), ['list']);
      },
    );
  });

  group('crash safety', () {
    test('killed after the state was persisted and before the upload: the '
        'next launch tops up correctly under the same id', () async {
      rig.server.hold['upload'] = Completer<void>(); // never answers
      rig.uid = _a;
      await rig.session.start(restoredUid: null, restoreDefinitive: true);
      await rig.session.onSignedIn(_a, e2eeEnabled: true);
      // Let the run reach the held upload.
      for (var i = 0; i < 20 && rig.server.uploads.isEmpty; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(rig.server.uploads, hasLength(1));
      final id = rig.storedId()!;
      expect(rig.devices[id]!.pool, isEmpty);

      // "Killed": a new launch over the same device and directory.
      rig.server.hold.remove('upload');
      rig.advance(const Duration(minutes: 5));
      rig.launch();
      await rig.signIn(_a);

      expect(rig.storedId(), id);
      expect(rig.engine.createdIds, hasLength(1));
      expect(rig.devices.keys, [id]);
      expect(rig.devices[id]!.pool, hasLength(50));
      expect(rig.devices[id]!.lastResort, isNotNull);
      expect(rig.server.uploads.last.keyPackages, hasLength(50));
      expect(rig.stateAtUpload.last, rig.engine.lastGenerated!.deviceState);
      expect(rig.service.status.value, DeviceKeysStatus.ready);
    });

    test('killed after the device was persisted and before it registered: '
        'the next launch registers the SAME id', () async {
      rig.server.hold['register'] = Completer<void>(); // never answers
      rig.uid = _a;
      await rig.session.start(restoredUid: null, restoreDefinitive: true);
      await rig.session.onSignedIn(_a, e2eeEnabled: true);
      for (var i = 0; i < 20 && rig.server.registrations.isEmpty; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      final id = rig.storedId()!;
      expect(rig.devices, isEmpty);

      rig.server.hold.remove('register');
      rig.launch();
      await rig.signIn(_a);
      expect(rig.engine.createdIds, hasLength(1));
      expect(rig.rpcs(1), ['list', 'register', 'upload']);
      expect(rig.devices.keys, [id]);
      expect(rig.devices[id]!.pool, hasLength(50));
    });

    test(
      'offline at the first registration: failed(retryable); retried on '
      'a resume an hour later, under the same id (no second device)',
      () async {
        rig.server.failNext['register'] = [keyServerUnavailable()];
        await rig.signIn(_a);
        expect(
          rig.service.status.value,
          const DeviceKeysStatus.failed(retryable: true),
        );
        final id = rig.storedId()!;
        expect(rig.devices, isEmpty);

        // A resume within the hour sends nothing.
        rig.advance(const Duration(minutes: 30));
        var before = rig.server.calls.length;
        await rig.service.onAppResumed();
        expect(rig.rpcs(before), isEmpty);

        rig.advance(const Duration(minutes: 31));
        before = rig.server.calls.length;
        await rig.service.onAppResumed();
        expect(rig.rpcs(before), ['list', 'register', 'upload']);
        expect(rig.devices.keys, [id]);
        expect(rig.engine.createdIds, hasLength(1));
        expect(rig.service.status.value, DeviceKeysStatus.ready);
        expect(rig.reported, isEmpty);
      },
    );
  });

  group('new identity', () {
    test(
      'a confirmed key loss (fresh vault) creates a NEW device id',
      () async {
        await rig.signIn(_a);
        final old = rig.storedId()!;
        await rig.session.close();

        // The platform key is gone: the first launch only records it; a
        // different launch an hour later wipes and opens a fresh vault.
        rig.world.loseKey(_a);
        rig.launch();
        await rig.signIn(_a);
        expect(rig.session.status.value, VaultStatus.keyLost);
        await rig.session.close();
        rig.advance(_hour + const Duration(minutes: 1));
        rig.launch();
        await rig.signIn(_a);
        expect(rig.session.status.value, VaultStatus.ready);

        final fresh = rig.storedId()!;
        expect(fresh, isNot(old));
        expect(fresh, matches(_serverIdPattern));
        expect(rig.server.registrations.last.deviceId, fresh);
        expect(rig.devices[fresh]!.pool, hasLength(50));
      },
    );

    test('historyLostThisOpen (the vault emptied outside the app) -> a NEW '
        'device id', () async {
      await rig.signIn(_a);
      final old = rig.storedId()!;
      await rig.session.close();
      rig.world.files[_a]!
        ..clearRows()
        ..stamped = false;

      rig.launch();
      await rig.signIn(_a);
      expect(rig.session.historyLostThisOpen, isTrue);
      final fresh = rig.storedId()!;
      expect(fresh, isNot(old));
      expect(rig.server.registrations.last.deviceId, fresh);
    });
  });

  group('errors', () {
    test('LIMIT_REACHED key_devices -> deviceLimitReached; nothing is '
        'retried until a new vault opens', () async {
      for (var i = 0; i < 5; i++) {
        rig.devices['other-device-$i-000000'] = FakeKeyDevice(
          id: 'other-device-$i-000000',
          signatureKey: Uint8List(32),
          createdAt: rig.now,
        );
      }
      await rig.signIn(_a);
      expect(rig.service.status.value, DeviceKeysStatus.deviceLimitReached);
      expect(rig.rpcs(), ['register']);

      rig.advance(const Duration(hours: 3));
      await rig.service.onAppResumed();
      await rig.service.ensureReady();
      rig.tick?.call();
      await rig.service.ensureReady();
      expect(rig.rpcs(), ['register']);
      expect(rig.reported, isEmpty);
    });

    test('VALIDATION signature_public_key (same id, other key) -> failed, '
        'reported generically, the id is NOT rotated', () async {
      await rig.signIn(_a);
      final id = rig.storedId()!;
      final dev = rig.devices[id]!;
      rig.devices[id] = FakeKeyDevice(
        id: id,
        signatureKey: Uint8List.fromList(List.filled(32, 1)),
        createdAt: dev.createdAt,
      );
      rig.advance(const Duration(days: 8));
      await rig.service.ensureReady();
      expect(
        rig.service.status.value,
        const DeviceKeysStatus.failed(retryable: false),
      );
      expect(rig.storedId(), id);
      expect(rig.engine.createdIds, hasLength(1));
      expect(rig.reported, [isA<DeviceKeysError>()]);
      expect(rig.reported.single.toString(), isNot(contains(id)));

      // Latched: no further attempts in this vault.
      rig.advance(const Duration(hours: 2));
      final before = rig.server.calls.length;
      await rig.service.onAppResumed();
      expect(rig.rpcs(before), isEmpty);
    });

    test('FEATURE_DISABLED from the server -> idle; the gate remembers it '
        'and nothing is sent until the flag set changes', () async {
      rig.server.featureEnabled = false;
      await rig.signIn(_a);
      expect(rig.service.status.value, DeviceKeysStatus.idle);
      expect(rig.rpcs(), ['register']);
      rig.advance(const Duration(hours: 2));
      await rig.service.onAppResumed();
      expect(rig.rpcs(), ['register']);

      // A fresh GetMe resets the gate: the next attempt goes through.
      rig.server.featureEnabled = true;
      rig.gate.reset();
      await rig.service.onAppResumed();
      expect(rig.rpcs(), ['register', 'list', 'register', 'upload']);
      expect(rig.service.status.value, DeviceKeysStatus.ready);
    });

    test('RATE_LIMITED -> backs off for the retry hint; never loops', () async {
      rig.server.failNext['register'] = [
        keyServerError(
          connect.Code.resourceExhausted,
          common.ErrorReason.ERROR_REASON_RATE_LIMITED,
          retryAfter: const Duration(hours: 2),
        ),
      ];
      await rig.signIn(_a);
      expect(
        rig.service.status.value,
        const DeviceKeysStatus.failed(retryable: true),
      );
      expect(rig.rpcs(), ['register']);

      rig.advance(const Duration(minutes: 90));
      await rig.service.onAppResumed();
      await rig.service.ensureReady();
      expect(rig.rpcs(), ['register']);

      rig.advance(const Duration(minutes: 31));
      await rig.service.onAppResumed();
      expect(rig.rpcs(), ['register', 'list', 'register', 'upload']);
    });

    test(
      'an engine failure -> failed(retryable), reported by step only',
      () async {
        rig.engine.failCreate = const MlsException(
          MlsErrorCode.internal,
          'secret detail',
        );
        await rig.signIn(_a);
        expect(
          rig.service.status.value,
          const DeviceKeysStatus.failed(retryable: true),
        );
        expect(rig.rpcs(), isEmpty);
        expect(rig.storedId(), isNull);
        expect(rig.reported.single, isA<DeviceKeysError>());
        expect(rig.reported.single.toString(), isNot(contains('secret')));
      },
    );
  });

  group('uploads with an unknown outcome', () {
    test('one identical retry (same key, same bytes), then a fresh top-up '
        'after the next list', () async {
      // Both attempts are applied by the server but answer UNAVAILABLE.
      rig.server.failAfterApply['upload'] = [
        keyServerUnavailable(),
        keyServerUnavailable(),
      ];
      await rig.signIn(_a);
      expect(
        rig.service.status.value,
        const DeviceKeysStatus.failed(retryable: true),
      );
      final first = rig.server.uploads;
      expect(first, hasLength(2));
      expect(first[1].idempotencyKey, first[0].idempotencyKey);
      expect(first[1].keyPackages, first[0].keyPackages);
      expect(first[1].lastResortKeyPackage, first[0].lastResortKeyPackage);
      expect(rig.engine.generated, [(50, true)]);
      final id = rig.storedId()!;
      expect(rig.devices[id]!.pool, hasLength(50));

      // Others claim 40 packages; the next run lists and tops up with FRESH
      // packages under a new key.
      rig.devices[id]!.pool.removeRange(0, 40);
      rig.advance(_hour);
      await rig.service.onAppResumed();
      final fresh = rig.server.uploads.last;
      expect(rig.server.uploads, hasLength(3));
      expect(fresh.idempotencyKey, isNot(first[0].idempotencyKey));
      expect(fresh.keyPackages, hasLength(40));
      for (final p in fresh.keyPackages) {
        expect(first[0].keyPackages, isNot(contains(p)));
      }
      expect(rig.service.status.value, DeviceKeysStatus.ready);
    });

    test('a retry that succeeds completes the run', () async {
      rig.server.failAfterApply['upload'] = [keyServerUnavailable()];
      await rig.signIn(_a);
      expect(rig.server.uploads, hasLength(2));
      expect(rig.service.status.value, DeviceKeysStatus.ready);
    });
  });

  group('sign-out and the session', () {
    test('explicit sign-out removes the device from the directory, then the '
        'vault is wiped; signing in again gives a NEW id', () async {
      await rig.signIn(_a);
      final id = rig.storedId()!;
      await rig.signOut();
      expect(rig.devices, isEmpty);
      expect(rig.server.removals.single.deviceId, id);
      expect(rig.world.files[_a]?.deviceId, isNull);

      await rig.signIn(_a);
      final fresh = rig.storedId()!;
      expect(fresh, isNot(id));
      expect(rig.devices.keys, [fresh]);
    });

    test('a removal is idempotent and needs an open vault: with none in this '
        'tab it sends nothing', () async {
      await rig.signIn(_a);
      await rig.service.removeThisDevice(_a);
      await rig.service.removeThisDevice(_a);
      expect(rig.server.removals, hasLength(2));
      expect(rig.devices, isEmpty);

      await rig.session.close();
      final before = rig.server.calls.length;
      await rig.service.removeThisDevice(_a);
      expect(rig.rpcs(before), isEmpty);
    });

    test('a removal that hangs is given up after the short timeout', () {
      fakeAsync((async) {
        // Built inside the fake zone, so every future of the rig runs here.
        rig = _Rig()..launch();
        rig.signIn(_a);
        async.flushMicrotasks();
        expect(rig.session.status.value, VaultStatus.ready);
        expect(rig.service.status.value, DeviceKeysStatus.ready);
        rig.server.hold['remove'] = Completer<void>();
        var done = false;
        Object? error;
        rig.service
            .removeThisDevice(_a)
            .then<void>(
              (_) => done = true,
              onError: (Object e) {
                error = e;
              },
            );
        async.flushMicrotasks();
        expect(done, isFalse);
        async.elapse(kDeviceKeysRemoveTimeout);
        // Given up (the RPC may keep running), without throwing.
        expect(done, isTrue);
        expect(error, isNull);
      });
    });

    test('sign-out during an in-flight registration: the registered id is '
        'removed afterwards', () async {
      final hold = rig.server.hold['register'] = Completer<void>();
      rig.uid = _a;
      await rig.session.start(restoredUid: null, restoreDefinitive: true);
      await rig.session.onSignedIn(_a, e2eeEnabled: true);
      for (var i = 0; i < 20 && rig.server.registrations.isEmpty; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      final id = rig.storedId()!;

      // The hook runs while RegisterKeyDevice is in flight.
      rig.server.hold.remove('register');
      await rig.session.beforeExplicitSignOut(_a);
      expect(rig.server.removals.map((r) => r.deviceId), [id]);
      // The registration lands after the removal...
      hold.complete();
      await rig.service.ensureReady(); // joins the run in flight
      for (var i = 0; i < 20 && rig.server.removals.length < 2; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      // ...and is removed again; nothing is uploaded.
      expect(rig.devices, isEmpty);
      expect(rig.server.uploads, isEmpty);
      expect(rig.server.removals.map((r) => r.deviceId), [id, id]);
      rig.uid = null;
      await rig.session.onSessionEnded(_a, SessionEnd.userSignedOut);
      expect(rig.reported, isEmpty);
    });

    test('a failed sign-out: the device removed by the hook is registered '
        'again under the SAME id, with a fresh pool', () async {
      await rig.signIn(_a);
      final id = rig.storedId()!;
      await rig.session.beforeExplicitSignOut(_a);
      expect(rig.devices, isEmpty);

      // The sign-out failed: the user is still signed in, the vault ready.
      await rig.session.explicitSignOutFailed(_a);
      await rig.service.onSignOutFailed(_a);

      expect(rig.storedId(), id);
      expect(rig.devices.keys, [id]);
      expect(rig.devices[id]!.pool, hasLength(50));
      expect(rig.devices[id]!.lastResort, isNotNull);
      expect(rig.server.registrations.last.deviceId, id);
      expect(rig.engine.createdIds, hasLength(1));
      expect(rig.service.status.value, DeviceKeysStatus.ready);
    });

    test('the vault handed to the hook is closed mid-run: nothing is '
        'written, nothing is uploaded, no error surfaces', () async {
      final hold = rig.server.hold['register'] = Completer<void>();
      rig.uid = _a;
      await rig.session.start(restoredUid: null, restoreDefinitive: true);
      await rig.session.onSignedIn(_a, e2eeEnabled: true);
      for (var i = 0; i < 20 && rig.server.registrations.isEmpty; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      final commits = rig.file(_a)!.commits;
      // The session is lost (vault closed, kept).
      rig.uid = null;
      await rig.session.onSessionEnded(_a, SessionEnd.sessionLost);
      rig.server.hold.remove('register');
      hold.complete();
      await rig.service.ensureReady();
      for (var i = 0; i < 10; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(rig.file(_a)!.commits, commits);
      expect(rig.server.uploads, isEmpty);
      expect(rig.reported, isEmpty);
      expect(rig.service.status.value, DeviceKeysStatus.idle);
    });

    test(
      'the vault is REPLACED by another user mid-run: no write of the old '
      "run lands in the new vault; the new user gets its own device",
      () async {
        final hold = rig.server.hold['register'] = Completer<void>();
        rig.uid = _a;
        await rig.session.start(restoredUid: null, restoreDefinitive: true);
        await rig.session.onSignedIn(_a, e2eeEnabled: true);
        for (var i = 0; i < 20 && rig.server.registrations.isEmpty; i++) {
          await Future<void>.delayed(Duration.zero);
        }
        final idA = rig.storedId(_a)!;

        // A's session is lost; B signs in (a new vault, B's own file).
        rig.uid = null;
        await rig.session.onSessionEnded(_a, SessionEnd.sessionLost);
        rig.server.hold.remove('register');
        rig.uid = _b;
        await rig.session.onSignedIn(_b, e2eeEnabled: true);
        hold.complete();
        await rig.service.ensureReady();

        // A different user signing in wiped A's vault (global wipe rule).
        expect(rig.file(_a), isNull);
        final idB = rig.storedId(_b)!;
        // B's own run: create, last-seen after register, state after
        // generation, last-seen after upload. A write of the old run would
        // be a fifth.
        expect(rig.file(_b)!.commits, 4);
        expect(idB, isNot(idA));
        // B's file holds B's device only, with B's key.
        expect(rig.server.uploads.map((u) => u.deviceId), [
          idB,
        ], reason: 'the old run never uploads');
        expect(rig.reported, isEmpty);
        expect(rig.service.status.value, DeviceKeysStatus.ready);
      },
    );

    test(
      'the vault is replaced for the SAME user mid-run (flag off and on '
      'again): the old run stops after its RPC, the new vault starts over',
      () async {
        final hold = rig.server.hold['register'] = Completer<void>();
        rig.uid = _a;
        await rig.session.start(restoredUid: null, restoreDefinitive: true);
        await rig.session.onSignedIn(_a, e2eeEnabled: true);
        for (var i = 0; i < 20 && rig.server.registrations.isEmpty; i++) {
          await Future<void>.delayed(Duration.zero);
        }
        final id = rig.storedId()!;

        // The same user's vault is closed and opened again: a new vault
        // object over the same file.
        await rig.session.onFlagChanged(false, uid: _a);
        rig.server.hold.remove('register');
        await rig.session.onFlagChanged(true, uid: _a);
        expect(rig.session.status.value, VaultStatus.ready);
        hold.complete();
        await rig.service.ensureReady();

        // Old run: its register only. New run: list, register (its vault has
        // no last-seen time, the old run never wrote one), upload.
        expect(rig.rpcs(), ['register', 'list', 'register', 'upload']);
        expect(rig.storedId(), id);
        expect(rig.engine.createdIds, hasLength(1));
        expect(rig.server.uploads.single.deviceId, id);
        expect(rig.reported, isEmpty);
        expect(rig.service.status.value, DeviceKeysStatus.ready);
      },
    );

    test('with the gate off while the vault is still open, a removal sends '
        'nothing', () async {
      await rig.signIn(_a);
      final before = rig.server.rpcCount;
      rig.flag = false;
      await rig.service.removeThisDevice(_a);
      expect(rig.server.rpcCount, before);
      expect(rig.devices, hasLength(1));
    });
  });

  group('fail closed', () {
    test('a device row without its public key is never replaced: nothing is '
        'written or sent, the id stays, reported by step', () async {
      await rig.signIn(_a);
      final id = rig.storedId()!;
      await rig.session.close();
      rig.file()!.rows.remove(kVaultSettingDeviceSignatureKey);
      final commits = rig.file()!.commits;
      final calls = rig.server.calls.length;

      rig.launch();
      await rig.signIn(_a);
      expect(rig.session.status.value, VaultStatus.ready);
      expect(
        rig.service.status.value,
        const DeviceKeysStatus.failed(retryable: false),
      );
      expect(rig.storedId(), id);
      expect(rig.file()!.commits, commits);
      expect(rig.rpcs(calls), isEmpty);
      expect(rig.engine.createdIds, hasLength(1));
      expect(rig.reported, [isA<DeviceKeysError>()]);
      expect(rig.reported.single.toString(), 'DeviceKeysError(deviceUnusable)');

      // Latched for this vault.
      rig.advance(const Duration(hours: 2));
      await rig.service.onAppResumed();
      expect(rig.rpcs(calls), isEmpty);
    });
  });

  group('gates', () {
    test(
      'flag off: the vault never opens, nothing is generated or sent',
      () async {
        rig.flag = false;
        await rig.signIn(_a);
        await rig.service.ensureReady();
        await rig.service.onAppResumed();
        expect(rig.server.rpcCount, 0);
        expect(rig.engine.createdIds, isEmpty);
        expect(rig.service.status.value, DeviceKeysStatus.idle);
      },
    );

    test(
      'the flag reads off for the gate while a vault is open: no RPC',
      () async {
        rig.uid = _a;
        await rig.session.start(restoredUid: null, restoreDefinitive: true);
        rig.flag = false; // the gate's view
        await rig.session.onSignedIn(_a, e2eeEnabled: true);
        await rig.service.ensureReady();
        expect(rig.server.rpcCount, 0);
        expect(rig.engine.createdIds, isEmpty);
      },
    );

    test('unsupported platform (iOS): no RPC', () async {
      rig = _Rig()
        ..supported = false
        ..launch();
      await rig.signIn(_a);
      await rig.service.ensureReady();
      expect(rig.session.status.value, VaultStatus.unsupported);
      expect(rig.server.rpcCount, 0);
      expect(rig.engine.createdIds, isEmpty);
    });

    test('vault not ready (held by another tab): no RPC', () async {
      rig.world.heldElsewhere.add(_a);
      await rig.signIn(_a);
      await rig.service.ensureReady();
      await rig.service.onAppResumed();
      expect(rig.session.status.value, VaultStatus.heldElsewhere);
      expect(rig.server.rpcCount, 0);
    });
  });

  group('cadence', () {
    test(
      'a periodic tick runs at most once an hour; resume likewise',
      () async {
        await rig.signIn(_a);
        expect(rig.timers, 1);
        expect(rig.tickPeriod, lessThanOrEqualTo(_hour));
        var before = rig.server.calls.length;
        rig.advance(const Duration(minutes: 59));
        rig.tick!();
        await rig.service.onAppResumed();
        expect(rig.rpcs(before), isEmpty);

        rig.advance(const Duration(minutes: 2));
        rig.tick!();
        await rig.service.ensureReady(); // joins the tick's run
        expect(rig.rpcs(before), ['list']);

        before = rig.server.calls.length;
        await rig.service.onAppResumed();
        expect(rig.rpcs(before), isEmpty);
      },
    );

    test('a second sign-in does not start a second timer', () async {
      await rig.signIn(_a);
      await rig.signOut();
      await rig.signIn(_a);
      expect(rig.timers, 1);
    });

    test('B-M6(5): the periodic tick does nothing while the app is not in '
        'the foreground', () async {
      await rig.signIn(_a);
      rig.advance(const Duration(hours: 2));
      final before = rig.server.calls.length;
      rig.foreground = false;
      rig.tick!();
      await pumpEventQueue();
      expect(rig.rpcs(before), isEmpty);
      rig.foreground = true;
      rig.tick!();
      await rig.service.ensureReady(); // joins the tick's run
      expect(rig.rpcs(before), ['list']);
    });
  });

  group('final fix wave', () {
    test('B-M5: a RATE_LIMITED back-off of user A does not hold back user '
        "B's first run", () async {
      rig.server.failNext['register'] = [
        keyServerError(
          connect.Code.resourceExhausted,
          common.ErrorReason.ERROR_REASON_RATE_LIMITED,
          retryAfter: const Duration(hours: 2),
        ),
      ];
      await rig.signIn(_a);
      expect(
        rig.service.status.value,
        const DeviceKeysStatus.failed(retryable: true),
      );
      rig.uid = null;
      await rig.session.onSessionEnded(_a, SessionEnd.sessionLost);
      final before = rig.server.calls.length;
      rig.uid = _b;
      await rig.session.onSignedIn(_b, e2eeEnabled: true);
      await rig.service.ensureReady();
      expect(rig.rpcs(before), ['register', 'upload']);
      expect(rig.service.status.value, DeviceKeysStatus.ready);
    });

    test('B-M6(3): a hung ListMyKeyDevices is given up at the client '
        "deadline, so the next user's run is not blocked", () async {
      // Real time: long enough for the calls that DO answer under load.
      rig.rpcTimeout = const Duration(seconds: 1);
      rig.launch();
      await rig.signIn(_a);
      rig.advance(_hour);
      rig.server.hold['list'] = Completer<void>(); // never answers
      unawaited(rig.service.ensureReady());
      for (var i = 0; i < 20 && !rig.server.calls.contains('list'); i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(rig.server.calls.last, 'list');
      rig.uid = null;
      await rig.session.onSessionEnded(_a, SessionEnd.sessionLost);
      rig.server.hold.remove('list');
      final before = rig.server.calls.length;
      rig.uid = _b;
      await rig.session.onSignedIn(_b, e2eeEnabled: true);
      await rig.service.ensureReady().timeout(const Duration(seconds: 5));
      expect(rig.rpcs(before), ['register', 'upload']);
      expect(rig.service.status.value, DeviceKeysStatus.ready);
    });

    test('B-M6(3): a register past the deadline is an unknown outcome: '
        'failed(retryable); a removal that started meanwhile removes the '
        'device again once the call lands', () async {
      // Real time: long enough for the calls that DO answer under load.
      rig.rpcTimeout = const Duration(seconds: 1);
      rig.launch();
      final hold = rig.server.hold['register'] = Completer<void>();
      rig.uid = _a;
      await rig.session.start(restoredUid: null, restoreDefinitive: true);
      await rig.session.onSignedIn(_a, e2eeEnabled: true);
      await rig.service.ensureReady().timeout(const Duration(seconds: 5));
      expect(
        rig.service.status.value,
        const DeviceKeysStatus.failed(retryable: true),
      );
      final id = rig.storedId()!;
      expect(rig.devices, isEmpty);
      // The sign-out hook runs after the deadline, then the call lands.
      await rig.service.removeThisDevice(_a);
      rig.server.hold.remove('register');
      hold.complete();
      for (var i = 0; i < 50 && rig.server.removals.length < 2; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(rig.devices, isEmpty);
      expect(rig.server.removals.map((r) => r.deviceId), [id, id]);
    });

    test('B-M6(3): an upload past the deadline is retried ONCE with the same '
        'idempotency key', () async {
      // Real time: long enough for the calls that DO answer under load.
      rig.rpcTimeout = const Duration(seconds: 1);
      rig.launch();
      final hold = rig.server.hold['upload'] = Completer<void>();
      rig.uid = _a;
      await rig.session.start(restoredUid: null, restoreDefinitive: true);
      await rig.session.onSignedIn(_a, e2eeEnabled: true);
      await rig.service.ensureReady().timeout(const Duration(seconds: 5));
      expect(rig.server.uploads, hasLength(2));
      expect(
        rig.server.uploads.first.idempotencyKey,
        rig.server.uploads.last.idempotencyKey,
      );
      expect(
        rig.service.status.value,
        const DeviceKeysStatus.failed(retryable: true),
      );
      rig.server.hold.remove('upload');
      hold.complete();
    });

    test("B-M6(4): a removal hook for another user than the open vault's "
        'sets no latch: that user keeps running', () async {
      await rig.signIn(_a);
      rig.advance(_hour);
      await rig.service.removeThisDevice(_b);
      expect(rig.server.removals, isEmpty);
      final before = rig.server.calls.length;
      await rig.service.ensureReady();
      expect(rig.rpcs(before), ['list']);
      expect(rig.service.status.value, DeviceKeysStatus.ready);
    });

    for (final liveAtFailure in [false, true]) {
      test('B-M6(7): a session-changed UNAUTHENTICATED while the run is '
          '${liveAtFailure ? 'still live -> failed' : 'no longer live -> '
                    'idle'}', () async {
        await rig.signIn(_a);
        rig.advance(_hour);
        rig.server.failNext['list'] = [
          connect.ConnectException(connect.Code.unauthenticated, 'changed'),
        ];
        rig.server.onCall['list'] = () async {
          if (!liveAtFailure) rig.uid = null;
        };
        await rig.service.ensureReady();
        expect(
          rig.service.status.value,
          liveAtFailure
              ? const DeviceKeysStatus.failed(retryable: true)
              : DeviceKeysStatus.idle,
        );
        expect(rig.reported, isEmpty);
      });
    }

    test('B-M6(8): the removal hook ran, the app was killed before the '
        'session ended, the same user is restored: the device registers '
        'again under the SAME id', () async {
      await rig.signIn(_a);
      final id = rig.storedId()!;
      await rig.session.beforeExplicitSignOut(_a);
      expect(rig.devices, isEmpty);

      // Killed: new session and service objects over the same stores.
      rig.launch();
      rig.uid = _a;
      await rig.session.start(restoredUid: _a, restoreDefinitive: true);
      await rig.session.onSignedIn(_a, e2eeEnabled: true);
      await rig.service.ensureReady();

      expect(rig.session.status.value, VaultStatus.ready);
      expect(rig.storedId(), id);
      expect(rig.devices.keys, [id]);
      expect(rig.devices[id]!.pool, hasLength(50));
      expect(rig.engine.createdIds, hasLength(1));
      expect(rig.service.status.value, DeviceKeysStatus.ready);
    });
  });

  testWidgets('B-M6(5): the default foreground check reads the binding\'s '
      'lifecycle state', (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    expect(deviceKeysForegroundFromBinding(), isTrue);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    expect(deviceKeysForegroundFromBinding(), isFalse);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    expect(deviceKeysForegroundFromBinding(), isFalse);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    expect(deviceKeysForegroundFromBinding(), isTrue);
  });
}
