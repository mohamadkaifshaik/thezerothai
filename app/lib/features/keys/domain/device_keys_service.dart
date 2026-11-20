import 'dart:async';
import 'dart:convert';
import 'dart:ui' show AppLifecycleState;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart' show SchedulerBinding;
import 'package:uuid/uuid.dart';

import '../../../core/crypto/crypto_engine.dart';
import '../../../core/crypto/crypto_types.dart';
import '../../../core/network/app_exception.dart';
import '../../../core/vault/secure_vault.dart';
import '../../../core/vault/vault_session.dart';
import '../../../core/vault/vault_status.dart' show VaultCorruptException;
import '../../../gen/dzeroth/keys/v1/keys.pb.dart' as pb;
import '../data/keys_repository.dart';

/// One-time key packages uploaded at first registration, and the level a
/// top-up restores.
const int kKeyPackagePoolTarget = 50;

/// A top-up runs when the server reports fewer than this many.
const int kKeyPackageTopUpBelow = 20;

/// The last-resort package is replaced once it is this old.
const Duration kLastResortMaxAge = Duration(days: 30);

/// RegisterKeyDevice is called again (even with a full pool) once the last
/// successful register or upload is this old: the server drops a device
/// from lookups 30 days after it was last seen (keys.proto).
const Duration kDeviceStayActiveAfter = Duration(days: 7);

/// A run starts at most once per this interval (apart from sign-in, a new
/// vault and a failed sign-out).
const Duration kDeviceKeysRunInterval = Duration(hours: 1);

/// How often the periodic check looks at [kDeviceKeysRunInterval].
const Duration kDeviceKeysTickPeriod = Duration(minutes: 15);

/// How long the sign-out removal waits for RemoveKeyDevice (inside the auth
/// bloc's 3 s budget); the RPC itself may keep running.
const Duration kDeviceKeysRemoveTimeout = Duration(seconds: 2);

/// How long a failed sign-out waits for a removal still in flight before it
/// registers the device again.
const Duration kDeviceKeysRemovalWait = Duration(seconds: 30);

/// The back-off after RATE_LIMITED when the server sent no retry hint.
const Duration kDeviceKeysRateLimitFallback = Duration(minutes: 1);

/// The client deadline on ListMyKeyDevices, RegisterKeyDevice and
/// UploadKeyPackages. A call past it is an unknown outcome (handled like a
/// network error); without it a hung call would block every later run,
/// including the next user's (runs are chained, single flight).
const Duration kDeviceKeysRpcTimeout = Duration(seconds: 30);

/// Whether the app is in the foreground, from the binding: `resumed`. On
/// the web a null state also counts (the engine starts `resumed` and
/// reports `inactive` on blur and `hidden` when the tab is hidden; before
/// the first report the framework may not have a state yet). On Android a
/// null state (no lifecycle report yet) is not the foreground.
bool deviceKeysForegroundFromBinding() {
  final state = SchedulerBinding.instance.lifecycleState;
  if (state == null) return kIsWeb;
  return state == AppLifecycleState.resumed;
}

/// Vault setting keys (stored in clear: no uid, no device id in them). The
/// values are sealed by the vault.
const String kVaultSettingDeviceSignatureKey = 'keys.device.signatureKey';

/// Microseconds since the epoch (UTF-8 decimal) of the last successful
/// RegisterKeyDevice or UploadKeyPackages; "0" = never.
const String kVaultSettingDeviceLastSeen = 'keys.device.lastSeenMicros';

/// Microseconds since the epoch (UTF-8 decimal) of the last-resort package
/// the server accepted; "0" = none.
const String kVaultSettingLastResortAt = 'keys.device.lastResortMicros';

/// Builds the periodic check (injected so tests drive it by hand).
typedef DeviceKeysTimerFactory = Timer Function(
  Duration period,
  void Function() onTick,
);

enum DeviceKeysPhase { idle, ready, deviceLimitReached, failed, dormant }

/// Where this device stands in the key directory. [idle]: nothing to do or
/// not allowed now (no vault, signed out, cancelled, or the flag is not on
/// and the vault holds no device); [dormant]: a device exists in the vault
/// and the flag is not on: nothing is sent, nothing is generated; [ready]: the
/// device is registered with a full pool; [deviceLimitReached]: the user
/// has 5 devices and must remove one (UI in a later plan); failed: the last
/// attempt failed, [retryable] when a later attempt (hourly or on resume)
/// may succeed.
@immutable
class DeviceKeysStatus {
  const DeviceKeysStatus._(this.phase) : retryable = false;
  const DeviceKeysStatus.failed({required this.retryable})
    : phase = DeviceKeysPhase.failed;

  static const idle = DeviceKeysStatus._(DeviceKeysPhase.idle);
  static const ready = DeviceKeysStatus._(DeviceKeysPhase.ready);
  static const dormant = DeviceKeysStatus._(DeviceKeysPhase.dormant);
  static const deviceLimitReached = DeviceKeysStatus._(
    DeviceKeysPhase.deviceLimitReached,
  );

  final DeviceKeysPhase phase;
  final bool retryable;

  @override
  bool operator ==(Object other) =>
      other is DeviceKeysStatus &&
      other.phase == phase &&
      other.retryable == retryable;

  @override
  int get hashCode => Object.hash(phase, retryable);

  @override
  String toString() => phase == DeviceKeysPhase.failed
      ? 'DeviceKeysStatus.failed(retryable: $retryable)'
      : 'DeviceKeysStatus.${phase.name}';
}

/// A device-keys step failed unexpectedly. Names the step only: never a
/// device id, a key, a package, state or the original message.
class DeviceKeysError implements Exception {
  const DeviceKeysError(this.step);

  final String step;

  @override
  String toString() => 'DeviceKeysError($step)';
}

/// The run stopped because its vault, its user or its purpose went away.
class _Cancelled implements Exception {
  const _Cancelled();
}

/// The vault holds a device row this service cannot use (an id of another
/// shape, no state, no public key).
class _DeviceUnusable implements Exception {
  const _DeviceUnusable();
}

/// This device as the vault holds it.
class _Local {
  const _Local({
    required this.id,
    required this.signatureKey,
    required this.created,
    required this.lastSeenMicros,
    required this.lastResortMicros,
  });

  final String id;
  final Uint8List signatureKey;

  /// Created by this run (never registered yet).
  final bool created;
  final int lastSeenMicros;
  final int lastResortMicros;
}

/// Gives this install an encryption device, publishes it in the key
/// directory and keeps its pool of one-time key packages topped up.
///
/// **Device id.** 16 bytes from [CryptoEngine.randomBytes], written as 32
/// lower-case hex characters: valid for the server's `[A-Za-z0-9_-]{16,64}`
/// for every value. The SAME string goes to the server (`device_id`) and,
/// as its UTF-8 bytes, to [CryptoEngine.createDevice] and the vault: the
/// MLS credential carries exactly those bytes, so a peer can compare a
/// credential with the directory entry byte for byte. Never derived from
/// the uid or any other identifier. A vault without a device (first run, a
/// confirmed key loss, an emptied vault, a reset) gets a NEW id.
///
/// **Order.** id + state + public key in ONE vault transaction, then
/// RegisterKeyDevice; generated packages' device state persisted, then
/// UploadKeyPackages. A package whose private part was never saved never
/// reaches the server.
///
/// **Session.** Driven by [onVaultReady] (the [VaultSession] hook, outside
/// its queue). The vault it is handed may already be closed or replaced:
/// every write goes through [VaultSession.runWrite] and first checks that
/// the session's vault is still that vault and the signed-in uid unchanged;
/// the same is checked after every RPC. Otherwise the run stops quietly. No
/// queued session method is ever awaited from here.
///
/// **Serialisation.** Engine calls and vault writes run inside
/// [VaultSession.runWrite] (the session's single mutex key per uid); RPCs
/// run outside it. Concurrent [ensureReady] calls share one run.
///
/// **Cadence.** At sign-in (a new vault), then at most once an hour on
/// resume ([onAppResumed]) or the periodic check (foreground only);
/// RATE_LIMITED backs off by the server's hint, for that user only. Every
/// list/register/upload has a client deadline ([kDeviceKeysRpcTimeout]).
/// Never loops.
///
/// Nothing here logs ids, keys, packages or state; unexpected failures go
/// to `onUnexpectedError` as [DeviceKeysError] (a step name).
class DeviceKeysService {
  DeviceKeysService({
    required VaultSession session,
    required KeysRepository repository,
    required CryptoEngine Function() engine,
    required String? Function() currentUid,
    DateTime Function() now = DateTime.now,
    DeviceKeysTimerFactory? periodicTimer,
    String Function()? newIdempotencyKey,
    Duration removeTimeout = kDeviceKeysRemoveTimeout,
    Duration rpcTimeout = kDeviceKeysRpcTimeout,
    bool Function() isForeground = deviceKeysForegroundFromBinding,
    void Function(Object error, StackTrace stack)? onUnexpectedError,
  }) : _session = session,
       _repo = repository,
       _engine = engine,
       _currentUid = currentUid,
       _now = now,
       _periodic = periodicTimer ?? _defaultPeriodic,
       _newKey = newIdempotencyKey ?? _uuid,
       _removeTimeout = removeTimeout,
       _rpcTimeout = rpcTimeout,
       _isForeground = isForeground,
       _onUnexpectedError = onUnexpectedError;

  static Timer _defaultPeriodic(Duration period, void Function() onTick) =>
      Timer.periodic(period, (_) => onTick());

  static String _uuid() => const Uuid().v4();

  final VaultSession _session;
  final KeysRepository _repo;
  final CryptoEngine Function() _engine;
  final String? Function() _currentUid;
  final DateTime Function() _now;
  final DeviceKeysTimerFactory _periodic;
  final String Function() _newKey;
  final Duration _removeTimeout;
  final Duration _rpcTimeout;
  final bool Function() _isForeground;
  final void Function(Object error, StackTrace stack)? _onUnexpectedError;

  /// The uid of the last vault [onVaultReady] saw: the back-off state below
  /// ([_notBefore], [_forceRegister]) belongs to that user only.
  String? _readyUid;
  final ValueNotifier<DeviceKeysStatus> _status = ValueNotifier(
    DeviceKeysStatus.idle,
  );

  /// The run in flight (single flight) and the vault it is for.
  Future<void>? _run;
  SecureVault? _runVault;

  /// The vault and time of the last successful run.
  SecureVault? _successVault;
  DateTime? _lastSuccess;

  /// When the last run that passed every gate started.
  DateTime? _lastAttempt;

  /// No run before this (RATE_LIMITED).
  DateTime? _notBefore;

  /// The vault for which nothing is retried (device limit, key mismatch)
  /// until a new vault opens.
  SecureVault? _latchedVault;

  /// A sign-out removal started (and for which vault); every run stops
  /// before publishing anything, and a run whose registration or upload
  /// raced it removes the device again.
  bool _removing = false;
  SecureVault? _removingVault;
  int _removalEpoch = 0;

  /// The last RemoveKeyDevice RPC (not its timed wait).
  Future<void>? _removalRpc;

  /// Register on the next run whatever the stored time says (after a failed
  /// sign-out, or an upload refused as NOT_FOUND).
  bool _forceRegister = false;

  Timer? _timer;
  bool _disposed = false;

  ValueListenable<DeviceKeysStatus> get status => _status;

  /// A [VaultSession.addVaultReadyHook] hook: a vault was opened and
  /// published. Runs
  /// at once (not throttled). Starts the periodic check on first use.
  Future<void> onVaultReady(SecureVault vault) {
    if (_disposed || !identical(_session.vault, vault)) return Future.value();
    if (_readyUid != vault.uid) {
      // Another user's vault: the previous user's RATE_LIMITED back-off and
      // forced registration do not carry over.
      _readyUid = vault.uid;
      _notBefore = null;
      _forceRegister = false;
    }
    if (_removing && !identical(vault, _removingVault)) {
      // A vault opened after the removal: that sign-out is over.
      _removing = false;
      _removingVault = null;
    }
    _timer ??= _periodic(kDeviceKeysTickPeriod, _onTick);
    return ensureReady();
  }

  /// The app came back to the foreground: a run if the last one started at
  /// least an hour ago.
  Future<void> onAppResumed() => _maybeRun();

  /// The periodic check runs only in the foreground (a backgrounded app
  /// waits for [onAppResumed]).
  void _onTick() {
    if (!_isForeground()) return;
    unawaited(_maybeRun());
  }

  Future<void> _maybeRun() {
    final last = _lastAttempt;
    if (last != null && _now().difference(last) < kDeviceKeysRunInterval) {
      return _run ?? Future.value();
    }
    return ensureReady();
  }

  /// Creates or loads this device, registers it and tops up its pool.
  /// Idempotent: after a successful run for the same vault less than an
  /// hour ago it sends nothing. Concurrent calls share one run. Never
  /// throws; the outcome is in [status].
  Future<void> ensureReady() => _start(force: false);

  Future<void> _start({required bool force}) {
    final vault = _session.vault;
    final current = _run;
    if (_disposed || vault == null) {
      if (current == null) _status.value = DeviceKeysStatus.idle;
      return Future.value();
    }
    if (current != null && identical(_runVault, vault) && !force) {
      return current;
    }
    final success = _lastSuccess;
    if (!force &&
        identical(_successVault, vault) &&
        success != null &&
        _now().difference(success) < kDeviceKeysRunInterval) {
      return current ?? Future.value();
    }
    late final Future<void> next;
    next = (current ?? Future<void>.value())
        .then((_) => _runOnce(vault))
        .whenComplete(() {
          if (identical(_run, next)) {
            _run = null;
            _runVault = null;
          }
        });
    _run = next;
    _runVault = vault;
    return next;
  }

  /// [VaultSession.beforeExplicitWipe] (explicit sign-out or account
  /// deletion): removes this device from the directory, best effort, within
  /// [kDeviceKeysRemoveTimeout]; failures are ignored. Idempotent; may be
  /// called again and may outlive its budget (the RPC keeps running).
  ///
  /// The device id lives only in the vault, and this never opens it: when
  /// no vault of [uid] is open in this tab (closed, held by another tab,
  /// never opened), nothing is sent. The directory entry then drops out of
  /// lookups and claims on its own 30 days after it was last seen
  /// (keys.proto), and stays in the user's device list until removed. With
  /// `e2ee_dm` off it is still sent when this device holds a vault (the
  /// repository's device-facts rule); with no vault nothing is.
  ///
  /// When the open vault belongs to ANOTHER user than [uid], nothing
  /// happens at all, not even the "removing" latch: that user's runs must
  /// not stop because of a hook for someone else.
  Future<void> removeThisDevice([String? uid]) async {
    final vault = _session.vault;
    if (vault != null && uid != null && vault.uid != uid) return;
    _removing = true;
    _removalEpoch++;
    _removingVault = vault;
    if (vault == null) return;
    final String? id;
    try {
      id = _decodeId(await vault.deviceId());
    } catch (_) {
      return; // closed or wiped meanwhile
    }
    if (id == null) return;
    await _removeQuietly(id);
  }

  /// The explicit sign-out of [uid] failed and [uid] is still signed in:
  /// the hook may already have removed this device, so it is registered
  /// again under the SAME id (the vault still holds it; the server accepts
  /// the same id and key) with a fresh pool, at once.
  Future<void> onSignOutFailed(String uid) async {
    if (_disposed || _currentUid() != uid) return;
    _removing = false;
    _removingVault = null;
    final vault = _session.vault;
    if (vault == null || vault.uid != uid) return;
    _forceRegister = true;
    final pending = _removalRpc;
    if (pending != null) {
      try {
        await pending.timeout(kDeviceKeysRemovalWait);
      } catch (_) {}
    }
    if (_removing) return; // another removal started meanwhile
    await _start(force: true);
  }

  /// Stops the periodic check; runs in flight stop at their next check.
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
  }

  // ---------------------------------------------------------------------

  Future<void> _removeQuietly(String id) async {
    final rpc = _repo.removeDevice(deviceId: id, idempotencyKey: _newKey());
    final settled = rpc.then<void>((_) {}, onError: (Object _) {});
    _removalRpc = settled;
    try {
      await rpc.timeout(_removeTimeout);
    } catch (_) {
      // Offline, refused or slow: the wipe goes on; see removeThisDevice.
    }
  }

  void _report(String step, StackTrace stack) =>
      _onUnexpectedError?.call(DeviceKeysError(step), stack);

  Future<void> _runOnce(SecureVault vault) async {
    final uid = vault.uid;
    bool live() =>
        !_disposed && identical(_session.vault, vault) && _currentUid() == uid;
    if (!live() || _removing) {
      _status.value = DeviceKeysStatus.idle;
      return;
    }
    if (identical(_latchedVault, vault)) return;
    if (!_repo.enabled) {
      // The flag is not on: nothing is generated, written or sent, whatever
      // the vault holds. A device already in the vault is dormant (upkeep
      // resumes under the same id when the flag turns on).
      final dormant = await _hasUsableDevice(vault);
      _status.value = dormant && live()
          ? DeviceKeysStatus.dormant
          : DeviceKeysStatus.idle;
      return;
    }
    final notBefore = _notBefore;
    if (notBefore != null && _now().isBefore(notBefore)) return;
    _lastAttempt = _now();
    final epoch = _removalEpoch;
    try {
      await _upkeep(vault, uid, live, epoch);
      _successVault = vault;
      _lastSuccess = _now();
      _status.value = DeviceKeysStatus.ready;
    } on _Cancelled {
      _status.value = DeviceKeysStatus.idle;
    } on FeatureDisabledException {
      // The gate remembers it until the flag set changes.
      _status.value = DeviceKeysStatus.idle;
    } on LimitReachedException catch (e) {
      if (e.quota == 'key_devices') {
        _latchedVault = vault;
        _status.value = DeviceKeysStatus.deviceLimitReached;
      } else {
        _status.value = const DeviceKeysStatus.failed(retryable: true);
      }
    } on ValidationException catch (e, stack) {
      // `signature_public_key`: the server holds another key for this id,
      // which random ids make impossible short of a bug. Not rotated
      // automatically; reported. Any other field is a bug too.
      _latchedVault = vault;
      _status.value = const DeviceKeysStatus.failed(retryable: false);
      _report(
        e.field == 'signature_public_key' ? 'keyMismatch' : 'validation',
        stack,
      );
    } on RateLimitedException catch (e) {
      _notBefore = _now().add(e.retryAfter ?? kDeviceKeysRateLimitFallback);
      _status.value = const DeviceKeysStatus.failed(retryable: true);
    } on NotFoundException {
      // The device vanished between list and upload: register next time.
      _forceRegister = true;
      _status.value = const DeviceKeysStatus.failed(retryable: true);
    } on UnauthenticatedException {
      // The account changed while a call waited for its tokens (the API
      // client's session-changed refusal): this run is over, not failed.
      _status.value = live()
          ? const DeviceKeysStatus.failed(retryable: true)
          : DeviceKeysStatus.idle;
    } on AppException {
      // Offline, UNAVAILABLE, unknown (the gate reports unknown ones), or a
      // call past the client deadline ([kDeviceKeysRpcTimeout]).
      _status.value = const DeviceKeysStatus.failed(retryable: true);
    } on _DeviceUnusable catch (_, stack) {
      // Fail closed: nothing written, nothing sent, no new id; latched.
      _latchedVault = vault;
      _status.value = const DeviceKeysStatus.failed(retryable: false);
      _report('deviceUnusable', stack);
    } on VaultCorruptException catch (_, stack) {
      // A device row that does not open under the vault key: never
      // overwritten here; latched.
      _latchedVault = vault;
      _status.value = const DeviceKeysStatus.failed(retryable: false);
      _report('vaultCorrupt', stack);
    } on MlsException catch (_, stack) {
      _status.value = const DeviceKeysStatus.failed(retryable: true);
      _report('engine', stack);
    } on StateError catch (_, stack) {
      // The vault closed under the run: cancelled. Otherwise a bug.
      if (live()) {
        _status.value = const DeviceKeysStatus.failed(retryable: true);
        _report('vault', stack);
      } else {
        _status.value = DeviceKeysStatus.idle;
      }
    } catch (_, stack) {
      _status.value = const DeviceKeysStatus.failed(retryable: true);
      _report('unexpected', stack);
    }
  }

  Future<void> _upkeep(
    SecureVault vault,
    String uid,
    bool Function() live,
    int epoch,
  ) async {
    void check() {
      if (!live() || _removing || _removalEpoch != epoch) {
        throw const _Cancelled();
      }
    }

    // 1. This device, created (id, state and public key in one
    // transaction) when the vault has none.
    final local = await _session.runWrite((v) async {
      if (!identical(v, vault) || _currentUid() != uid) {
        throw const _Cancelled();
      }
      return _loadOrCreate(v);
    });
    final nowMicros = _now().microsecondsSinceEpoch;

    // 2. Registered? A new device registers at once; a known one is looked
    // up (missing: never registered, removed by a failed sign-out's hook).
    var mustRegister =
        local.created ||
        _forceRegister ||
        _olderThan(local.lastSeenMicros, nowMicros, kDeviceStayActiveAfter);
    var count = 0;
    var hasLastResort = false;
    if (!local.created) {
      check();
      final list = await _deadline(_repo.listMine());
      check();
      pb.KeyDevice? mine;
      for (final d in list.devices) {
        if (d.deviceId == local.id) mine = d;
      }
      if (mine == null) {
        mustRegister = true;
      } else {
        count = mine.keyPackageCount;
        hasLastResort = mine.hasLastResort;
      }
    }
    if (mustRegister) {
      check(); // never publish once a removal started
      final r = await _publish(
        local.id,
        epoch,
        () => _repo.registerDevice(
          deviceId: local.id,
          signaturePublicKey: local.signatureKey,
          idempotencyKey: _newKey(),
        ),
      );
      check();
      _forceRegister = false;
      count = r.device.keyPackageCount;
      hasLastResort = r.device.hasLastResort;
      await _persistRegistered(vault, uid, nowMicros);
    }

    // 3. The pool.
    final oneTime = count < kKeyPackageTopUpBelow
        ? kKeyPackagePoolTarget - count
        : 0;
    final lastResort =
        !hasLastResort ||
        _olderThan(local.lastResortMicros, nowMicros, kLastResortMaxAge);
    if (oneTime <= 0 && !lastResort) return;
    check();
    final packages = await _session.runWrite((v) async {
      if (!identical(v, vault) || _currentUid() != uid) {
        throw const _Cancelled();
      }
      final state = await v.deviceState();
      if (state == null) throw StateError('No device state.');
      final r = await _engine().generateKeyPackages(
        state,
        count: oneTime < 0 ? 0 : oneTime,
        lastResort: lastResort,
      );
      // The private parts are saved BEFORE any package is sent.
      await v.transaction((tx) => tx.putDeviceState(r.deviceState));
      return r.keyPackages;
    });
    check();
    final oneTimePackages = lastResort
        ? packages.sublist(0, packages.length - 1)
        : packages;
    final lastResortPackage = lastResort ? packages.last : null;
    // One logical upload: an unknown outcome is retried ONCE with the same
    // request and key (the server stores nothing twice while unclaimed);
    // after that, the next run lists and tops up with fresh packages.
    final key = _newKey();
    Future<pb.UploadKeyPackagesResponse> upload() => _publish(
      local.id,
      epoch,
      () => _repo.uploadKeyPackages(
        deviceId: local.id,
        keyPackages: oneTimePackages,
        lastResortKeyPackage: lastResortPackage,
        idempotencyKey: key,
      ),
    );
    try {
      await upload();
    } on AppException catch (e) {
      if (!_unknownOutcome(e)) rethrow;
      check();
      await upload();
    }
    check();
    await _persist(vault, uid, (tx) async {
      await tx.putSetting(kVaultSettingDeviceLastSeen, _micros(nowMicros));
      if (lastResort) {
        await tx.putSetting(kVaultSettingLastResortAt, _micros(nowMicros));
      }
    });
  }

  /// [call] under the client deadline: past [_rpcTimeout] it is a
  /// [NetworkException] (an unknown outcome, as a lost connection). The
  /// call itself is not cancelled.
  Future<T> _deadline<T>(Future<T> call) => call.timeout(
    _rpcTimeout,
    onTimeout: () =>
        throw const NetworkException('The key directory did not answer.'),
  );

  /// Runs an RPC that can publish this device, under the client deadline;
  /// if a removal started while it ran (whatever its outcome), removes the
  /// device again, best effort. A call past the deadline may still land
  /// later: if a removal has started by the time it settles, the device is
  /// removed again then too.
  Future<T> _publish<T>(String id, int epoch, Future<T> Function() rpc) async {
    final call = rpc();
    var timedOut = false;
    try {
      return await call.timeout(
        _rpcTimeout,
        onTimeout: () {
          timedOut = true;
          throw const NetworkException('The key directory did not answer.');
        },
      );
    } finally {
      if (_removing || _removalEpoch != epoch) await _removeQuietly(id);
      if (timedOut) {
        unawaited(
          call.then<void>((_) {}, onError: (Object _) {}).then((_) async {
            if (_removing || _removalEpoch != epoch) await _removeQuietly(id);
          }),
        );
      }
    }
  }

  /// Whether the vault holds a usable device (the existing-device branch of
  /// [_loadOrCreate]). Read only: creates and writes nothing, never touches
  /// the engine. Any failure reads as "no".
  Future<bool> _hasUsableDevice(SecureVault v) async {
    try {
      if (_decodeId(await v.deviceId()) == null) return false;
      if (await v.deviceState() == null) return false;
      final key = await v.setting(kVaultSettingDeviceSignatureKey);
      return key != null && key.length == 32;
    } catch (_) {
      return false;
    }
  }

  /// After a successful RegisterKeyDevice: records the last-seen time and,
  /// after the FIRST successful one for the stored id, that this vault's
  /// device was registered once (written once, skipped when present), in the
  /// same transaction, through the session's write path.
  Future<void> _persistRegistered(
    SecureVault vault,
    String uid,
    int nowMicros,
  ) => _session.runWrite((v) async {
    if (!identical(v, vault) || _currentUid() != uid) {
      throw const _Cancelled();
    }
    final once = await v.setting(kVaultSettingRegisteredOnce) != null;
    await v.transaction((tx) async {
      await tx.putSetting(kVaultSettingDeviceLastSeen, _micros(nowMicros));
      if (!once) {
        await tx.putSetting(
          kVaultSettingRegisteredOnce,
          Uint8List.fromList(const [0x01]),
        );
      }
    });
  });

  Future<_Local> _loadOrCreate(SecureVault v) async {
    final idBytes = await v.deviceId();
    if (idBytes != null) {
      final id = _decodeId(idBytes);
      final state = await v.deviceState();
      final key = await v.setting(kVaultSettingDeviceSignatureKey);
      if (id != null && state != null && key != null && key.length == 32) {
        return _Local(
          id: id,
          signatureKey: key,
          created: false,
          lastSeenMicros: await _readMicros(v, kVaultSettingDeviceLastSeen),
          lastResortMicros: await _readMicros(v, kVaultSettingLastResortAt),
        );
      }
      // Cannot happen (written in one transaction). Fail closed: never
      // overwrite or rotate an existing device here.
      throw const _DeviceUnusable();
    }
    final engine = _engine();
    final random = await engine.randomBytes(16);
    final id = _hex(random);
    final idBytesNew = Uint8List.fromList(utf8.encode(id));
    final created = await engine.createDevice(idBytesNew);
    await v.transaction((tx) async {
      await tx.putDevice(idBytesNew, created.deviceState);
      await tx.putSetting(
        kVaultSettingDeviceSignatureKey,
        created.signaturePublicKey,
      );
      await tx.putSetting(kVaultSettingDeviceLastSeen, _micros(0));
      await tx.putSetting(kVaultSettingLastResortAt, _micros(0));
    });
    return _Local(
      id: id,
      signatureKey: created.signaturePublicKey,
      created: true,
      lastSeenMicros: 0,
      lastResortMicros: 0,
    );
  }

  Future<void> _persist(
    SecureVault vault,
    String uid,
    Future<void> Function(VaultTx tx) body,
  ) => _session.runWrite((v) async {
    if (!identical(v, vault) || _currentUid() != uid) {
      throw const _Cancelled();
    }
    await v.transaction(body);
  });

  static bool _unknownOutcome(AppException e) =>
      e is NetworkException ||
      e is UnknownApiException ||
      e is ScreeningUnavailableException;

  /// True when [atMicros] is unset (0), in the future (the clock moved
  /// back) or at least [age] before [nowMicros].
  static bool _olderThan(int atMicros, int nowMicros, Duration age) =>
      atMicros <= 0 ||
      atMicros > nowMicros ||
      nowMicros - atMicros >= age.inMicroseconds;

  static final RegExp _idPattern = RegExp(r'^[0-9a-f]{32}$');

  static String? _decodeId(Uint8List? bytes) {
    if (bytes == null) return null;
    try {
      final id = utf8.decode(bytes);
      return _idPattern.hasMatch(id) ? id : null;
    } on FormatException {
      return null;
    }
  }

  static String _hex(Uint8List bytes) {
    final b = StringBuffer();
    for (final x in bytes) {
      b.write(x.toRadixString(16).padLeft(2, '0'));
    }
    return b.toString();
  }

  // Decimal text, not ByteData.setInt64 (which throws on dart2js).
  static Uint8List _micros(int value) =>
      Uint8List.fromList(utf8.encode(value.toString()));

  static Future<int> _readMicros(SecureVault v, String key) async {
    final bytes = await v.setting(key);
    if (bytes == null) return 0;
    try {
      return int.tryParse(utf8.decode(bytes)) ?? 0;
    } on FormatException {
      return 0;
    }
  }
}
