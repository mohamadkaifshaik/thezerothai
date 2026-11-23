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
import 'device_keys_status.dart';
import 'key_batch_day.dart';
import 'key_limits.dart';
import 'pending_upload.dart';

export 'device_keys_status.dart';
export 'key_limits.dart';

part 'device_keys_elsewhere.dart';
part 'key_package_batches.dart';

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

/// A generated batch whose upload is not confirmed: sealed JSON
/// {"v":1,"oneTime":[base64...],"lastResort":base64|null,"lastResortAt":micros|null,"countBefore":n,"outcome":"failed"|"unknown"}.
/// `lastResortAt` is when the last-resort package was generated (null with
/// no last-resort package).
/// A record with no packages = none saved. The private parts of its
/// packages are already in the device state ([PendingUpload]).
const String kVaultSettingPendingUpload = 'keys.device.pendingUpload';

/// Plan 5a Task 12 (R17): one byte, 0x01 = this device was removed from the
/// account on another device (the key directory answered DEVICE_REMOVED to
/// its RegisterKeyDevice or UploadKeyPackages), 0x00 or absent = not. Set
/// only by that answer (brief amendment 1: an absence from a list is never
/// proof). Cleared by [kRemovedElsewhereListedAgain] listed answers or by
/// "set up again" ([DeviceKeysService.recreateDevice]).
const String kVaultSettingRemovedElsewhere = 'keys.device.removedElsewhere';

/// Security read M5: consecutive successful ListMyKeyDevices answers that
/// list this device with its key, while removed elsewhere, that clear
/// [kVaultSettingRemovedElsewhere]. An answer that lacks it resets the
/// count; a failed call neither counts nor resets. Memory only.
const int kRemovedElsewhereListedAgain = 2;

/// Builds the periodic check (injected so tests drive it by hand).
typedef DeviceKeysTimerFactory = Timer Function(
  Duration period,
  void Function() onTick,
);

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

  /// The latch was set for the device limit (LIMIT_REACHED `key_devices`),
  /// the only one [retryNow] clears.
  bool _latchedForLimit = false;

  /// Task 12: the vault whose device was removed elsewhere (its
  /// [kVaultSettingRemovedElsewhere] reads 0x01), and the listed answers
  /// counted toward clearing it (M5).
  SecureVault? _removedVault;
  int _listedAgain = 0;
  final ValueNotifier<bool> _removedFact = ValueNotifier(false);
  final _reportedPending = Expando<bool>();

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

  /// Task 12 (R17): true once the key directory answered DEVICE_REMOVED to
  /// this device's Register or Upload, for the open vault (persisted in
  /// [kVaultSettingRemovedElsewhere], so it survives a restart). While it
  /// holds every run is read only (one ListMyKeyDevices, no register, no
  /// upload) and the pipeline stops: pass this getter, as the same fact, to
  /// every `removedElsewhere` seam (crypto, receiver, starter, sender,
  /// commit runner, upkeep, removal queue). Nothing is deleted until the
  /// user chooses "set up again" ([recreateDevice], through
  /// `DeviceReset.setUpAgain`). Synchronous after [onVaultReady]; false with
  /// no vault.
  bool get removedElsewhere =>
      _removedVault != null && identical(_removedVault, _session.vault);

  /// [removedElsewhere] as a listenable (the port's `removedElsewhere`):
  /// the value for the last vault this service saw.
  ValueListenable<bool> get removedElsewhereFact => _removedFact;

  /// Security read M5, the port's `checkRemovedAgain`: while removed
  /// elsewhere, one ListMyKeyDevices read now, counted toward the
  /// [kRemovedElsewhereListedAgain] consecutive listed answers that clear
  /// it; no register, no upload, nothing deleted. No-op otherwise. While
  /// the server keeps its removed mark the id is never listed, so in
  /// practice "set up again" is the way out. Never throws.
  Future<void> checkAgainNow() async {
    if (_disposed || !removedElsewhere) return;
    await _start(force: true);
  }

  /// The port's `retryDeviceSetup` (5b's A7): clears the latch for the
  /// open vault only when it was set for the device limit (LIMIT_REACHED
  /// `key_devices`) and starts a forced run now. A latch for a key
  /// mismatch or an unusable device stays, and nothing is sent; so does
  /// a device removed elsewhere. Without a latch it is a forced run. Never
  /// throws.
  Future<void> retryNow() async {
    final vault = _session.vault;
    if (_disposed || vault == null || removedElsewhere) return;
    if (identical(_latchedVault, vault)) {
      if (!_latchedForLimit) return;
      _latchedVault = null;
      _latchedForLimit = false;
    }
    await _start(force: true);
  }

  /// R17 "set up again" (called by `DeviceReset.setUpAgain` after its own
  /// transaction): a NEW device id, state and key in the vault, in ONE
  /// transaction with the last-seen and last-resort times "0", the
  /// registered-once and removed-elsewhere markers 0x00 and no pending
  /// upload; then a normal run registers the new id with a fresh pool
  /// (completes when that run ends; its outcome is in [status]). Needs the
  /// flag on (creating a device, R1) and [removedElsewhere]: a
  /// [StateError] otherwise, with nothing written.
  Future<void> recreateDevice() => _recreateDevice();

  /// A [VaultSession.addVaultReadyHook] hook: a vault was opened and
  /// published. Reads the vault's removed-elsewhere marker first (so
  /// [removedElsewhere] is set when this returns), then runs at once (not
  /// throttled). Starts the periodic check on first use.
  Future<void> onVaultReady(SecureVault vault) async {
    if (_disposed || !identical(_session.vault, vault)) return;
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
    await _loadRemoved(vault);
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

  /// This device's own removal: always SIGN_OUT (removal design 2.4: the
  /// server keeps no mark, so [onSignOutFailed] can register the same id).
  Future<void> _removeQuietly(String id) async {
    final rpc = _repo.removeDevice(
      deviceId: id,
      idempotencyKey: _newKey(),
      reason: pb.RemoveReason.REMOVE_REASON_SIGN_OUT,
    );
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
      // resumes under the same id when the flag turns on); one removed
      // elsewhere stays so.
      if (removedElsewhere) {
        _status.value = DeviceKeysStatus.removedElsewhere;
        return;
      }
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
      // Task 12: a device removed elsewhere is read only (a list, nothing
      // else) until the marker clears or the user sets it up again.
      if (await _syncRemoved(vault)) {
        await _checkListed(vault, uid, live);
        return;
      }
      await _upkeep(vault, uid, live, epoch);
      _successVault = vault;
      _lastSuccess = _now();
      _status.value = DeviceKeysStatus.ready;
    } on _Cancelled {
      _status.value = DeviceKeysStatus.idle;
    } on DeviceRemovedException {
      // Brief amendment 1: the server's own statement, on the FIRST such
      // answer to Register or Upload. No retry, no upload; later runs are
      // read only. Nothing is deleted.
      await _markRemoved(vault, uid, live);
    } on FeatureDisabledException {
      // The gate remembers it until the flag set changes.
      _status.value = DeviceKeysStatus.idle;
    } on LimitReachedException catch (e) {
      if (e.quota == 'key_devices') {
        _latchedVault = vault;
        _latchedForLimit = true;
        _status.value = DeviceKeysStatus.deviceLimitReached;
      } else {
        _status.value = const DeviceKeysStatus.failed(retryable: true);
      }
    } on ValidationException catch (e, stack) {
      // `signature_public_key`: the server holds another key for this id,
      // which random ids make impossible short of a bug. Not rotated
      // automatically; reported. Any other field is a bug too. A server
      // answer: localRecordUnusable stays false (M5).
      _latchedVault = vault;
      _latchedForLimit = false;
      _status.value = const DeviceKeysStatus.failed(retryable: false);
      _report(
        e.field == 'signature_public_key' ? 'keyMismatch' : 'validation',
        stack,
      );
    } on RateLimitedException catch (e) {
      _notBefore = _now().add(e.retryAfter ?? kDeviceKeysRateLimitFallback);
      _status.value = const DeviceKeysStatus.failed(retryable: true);
    } on NotFoundException {
      // The device vanished between list and upload: register next time
      // (same id and key). Not a removal: a really removed id answers that
      // Register with DEVICE_REMOVED (brief amendment 1).
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
    } on _BatchCap {
      // Retried hourly; generation resumes on the next IST day.
      _status.value = const DeviceKeysStatus.failed(retryable: true);
    } on _BadPoolCount catch (_, stack) {
      // Nothing generated or saved; reported on every run (hourly at most)
      // so a server that keeps answering it is not silenced.
      _status.value = const DeviceKeysStatus.failed(retryable: true);
      _report('poolCount', stack);
    } on _DeviceUnusable catch (_, stack) {
      // Fail closed: nothing written, nothing sent, no new id; latched. A
      // local fact (M5): 5b may offer the vault reset.
      _latchedVault = vault;
      _latchedForLimit = false;
      _status.value = const DeviceKeysStatus.failed(
        retryable: false,
        localRecordUnusable: true,
      );
      _report('deviceUnusable', stack);
    } on VaultCorruptException catch (_, stack) {
      // A device row that does not open under the vault key: never
      // overwritten here; latched. A local fact (M5).
      _latchedVault = vault;
      _latchedForLimit = false;
      _status.value = const DeviceKeysStatus.failed(
        retryable: false,
        localRecordUnusable: true,
      );
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
        count = _poolCount(mine.keyPackageCount);
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
      count = _poolCount(r.device.keyPackageCount);
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
    check();
    final (batch, previousUnknown, cap) = await _takeOrGenerateBatch(
      vault,
      uid,
      count: count,
      oneTime: oneTime,
      lastResort: lastResort,
      hasLastResort: hasLastResort,
    );
    if (batch.isEmpty) return;
    check();
    final key = _newKey();
    Future<pb.UploadKeyPackagesResponse> upload() => _publish(
      local.id,
      epoch,
      () => _repo.uploadKeyPackages(
        deviceId: local.id,
        keyPackages: batch.oneTime,
        lastResortKeyPackage: batch.lastResort,
        idempotencyKey: key,
      ),
    );
    try {
      await upload();
    } on AppException catch (e) {
      // A typed refusal is rethrown BEFORE check(): a removal that started
      // mid-upload must not turn it into a cancel and lose the back-off
      // (RATE_LIMITED), the forced register or the latch. The "failed"
      // record is written only while no removal is under way.
      if (!_unknownOutcome(e)) {
        if (!previousUnknown && !_removing && _removalEpoch == epoch) {
          final refused = PendingUpload(
            batch.oneTime,
            batch.lastResort,
            batch.countBefore,
            failed: true,
            lastResortMicros: batch.lastResortMicros,
          );
          // Best effort: the typed refusal (back-off, forced register,
          // latch) must survive a failed write; the saved record then stays
          // "unknown", which only makes the next run read the count first.
          try {
            await _persist(
              vault,
              uid,
              (tx) =>
                  tx.putSetting(kVaultSettingPendingUpload, refused.encode()),
            );
          } on _Cancelled {
            // The vault or the user changed: the run is over, not a failed
            // write.
            rethrow;
          } catch (_, stack) {
            _report('pendingUploadWrite', stack);
          }
        }
        rethrow;
      }
      check();
      // A refusal on this retry cannot resolve the first attempt.
      await upload();
    }
    check();
    await _persist(vault, uid, (tx) async {
      await tx.putSetting(
        kVaultSettingPendingUpload,
        PendingUpload.empty.encode(),
      );
      await tx.putSetting(kVaultSettingDeviceLastSeen, _micros(nowMicros));
      if (batch.lastResort != null) {
        // When it was generated, not now: a resend must not extend the
        // package's 30 days (SA L2).
        await tx.putSetting(
          kVaultSettingLastResortAt,
          _micros(batch.lastResortMicros),
        );
      }
    });
    // A last-resort-only batch sent at the cap: the pool is still capped.
    if (cap != null) throw cap;
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
  /// [_loadOrCreate]). Read only: creates and writes nothing and makes no
  /// MLS engine call itself (on Android a vault read unseals through the
  /// engine's cipher, so the engine may still run). Any failure reads as
  /// "no".
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
    // Task 12: 0x00 (written by "set up again" for a new id) reads as absent.
    final marker = await v.setting(kVaultSettingRegisteredOnce);
    final once = marker != null && marker.length == 1 && marker[0] == 0x01;
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
