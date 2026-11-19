import 'dart:async';

import 'package:flutter/foundation.dart';

import '../session/session_end.dart';
import 'keyed_mutex.dart';
import 'secure_vault.dart';
import 'vault_cipher.dart';
import 'vault_markers.dart';
import 'vault_owner.dart';
import 'vault_status.dart';

/// Opens (or creates) the vault cipher of a user (`openVaultCipher`).
typedef VaultCipherOpener = Future<VaultCipher> Function(String uid);

/// Opens a user's vault (`openVault`).
typedef VaultOpener = Future<SecureVault> Function({
  required String uid,
  required VaultCipher cipher,
  String? expectedStorage,
});

/// Erases a user's vault file(s) (`wipeVaultFile`).
typedef VaultFileWiper = Future<void> Function({
  required String uid,
  String? expectedStorage,
});

/// Deletes a user's vault key without opening it (`deleteVaultKey`).
typedef VaultKeyDeleter = Future<void> Function({required String uid});

/// How long the directory-removal hook may run when the session itself runs
/// it (an account deletion that ended the session without a sign-out
/// request); the same budget as the auth bloc's `beforeSignOut`.
const Duration kVaultExplicitWipeHookTimeout = Duration(seconds: 3);

/// A step of the vault session failed unexpectedly. Names the step only: no
/// uid, no path, no message of the original error (which could carry one).
class VaultSessionError implements Exception {
  const VaultSessionError(this.step);

  final String step;

  @override
  String toString() => 'VaultSessionError($step)';
}

/// The one owner of the encrypted vault's lifecycle for the app: when it is
/// opened, closed and wiped. A wrong wipe destroys a user's history for
/// good; a missed wipe leaves one user's data for the next. The rules:
///
/// - **Opening** happens only with `e2ee_dm` on, on a supported platform
///   (Android, web), with persistent markers ([VaultMarkers.persistent]),
///   in this order: owner lock -> cipher -> markers -> vault ->
///   ready -> [onVaultReady]. Anything else leaves [status] at
///   [VaultStatus.off] / [VaultStatus.unsupported] / [VaultStatus.unavailable]
///   and opens nothing.
/// - **Wiping** is driven by device facts (a `vault.known` or `vault.wipeOwed`
///   marker, or this process opened that vault), whatever the flag reads
///   now, and only for: an explicit sign-out or account deletion
///   ([onSessionEnded]), a different user signing in ([onSignedIn]), an
///   owed wipe ([start]), a key loss seen on two separate launches, and the
///   explicit [resetVaultForStorageChange]. Every wipe is journalled first
///   (`vault.wipeOwed`), and runs file -> key -> markers -> lock.
/// - [VaultStatus.unavailable], [VaultStatus.storageChanged] and
///   [VaultStatus.heldElsewhere] never wipe and never delete a key. A failed
///   open is not repeated automatically in this process; [retry] (app
///   resume) or the next launch tries again, once.
/// - A lost session ([SessionEnd.sessionLost]) closes the vault and keeps
///   it.
///
/// All work runs one operation at a time, in call order. No method throws
/// into the UI; unexpected failures go to the error reporter as
/// [VaultSessionError] (a step name only).
class VaultSession {
  VaultSession({
    required VaultCipherOpener openCipher,
    required VaultOpener openVault,
    required VaultFileWiper wipeVaultFile,
    required VaultKeyDeleter deleteVaultKey,
    required VaultOwner Function() createOwner,
    required VaultMarkers markers,
    required bool supported,
    required String launchId,
    DateTime Function() now = DateTime.now,
    this.onVaultReady,
    this.beforeExplicitWipe,
    Duration explicitWipeHookTimeout = kVaultExplicitWipeHookTimeout,
    void Function(Object error, StackTrace stack)? onUnexpectedError,
  }) : _openCipher = openCipher,
       _openVault = openVault,
       _wipeVaultFile = wipeVaultFile,
       _deleteVaultKey = deleteVaultKey,
       _createOwner = createOwner,
       _markers = markers,
       _supported = supported,
       _launchId = launchId,
       _now = now,
       _hookTimeout = explicitWipeHookTimeout,
       _onUnexpectedError = onUnexpectedError,
       _status = ValueNotifier(
         supported ? VaultStatus.off : VaultStatus.unsupported,
       );

  final VaultCipherOpener _openCipher;
  final VaultOpener _openVault;
  final VaultFileWiper _wipeVaultFile;
  final VaultKeyDeleter _deleteVaultKey;
  final VaultOwner Function() _createOwner;
  final VaultMarkers _markers;
  final bool _supported;

  /// Distinguishes app launches (a new random id per process): key loss is
  /// confirmed only when a launch with ANOTHER id sees it again.
  final String _launchId;
  final DateTime Function() _now;
  final Duration _hookTimeout;
  final void Function(Object error, StackTrace stack)? _onUnexpectedError;

  /// Runs after a successful open (Task 7: device registration). A failure
  /// is reported and leaves the vault ready.
  Future<void> Function(SecureVault vault)? onVaultReady;

  /// Best-effort removal of this device from the key directory before an
  /// explicit wipe (Task 7). Runs inside the auth bloc's `beforeSignOut`
  /// budget ([beforeExplicitSignOut]); a failure never stops the wipe.
  Future<void> Function(String uid)? beforeExplicitWipe;

  final ValueNotifier<VaultStatus> _status;
  final KeyedMutex _mutex = KeyedMutex();
  Future<void> _queue = Future.value();

  String? _uid;
  bool _flag = false;
  bool _started = false;
  SecureVault? _vault;
  VaultOwner? _owner;
  String? _ownedUid;
  StreamSubscription<void>? _lostSub;
  bool _lost = false;
  bool _writesOpen = false;
  String? _hookRanFor;
  final Set<String> _openedThisProcess = {};

  /// The result of a failed open per uid in this process: not repeated
  /// automatically until [retry] or the next launch.
  final Map<String, VaultStatus> _blocked = {};

  /// Where the vault stands for the signed-in user.
  ValueListenable<VaultStatus> get status => _status;

  /// The open vault while it is ready and writable; null otherwise. Write
  /// through [runWrite] so writes are serialised and stop on a lost lock.
  SecureVault? get vault => _writesOpen ? _vault : null;

  /// Runs [body] with the open vault under the session's mutex (one key per
  /// uid). Fails with [StateError] when the vault is not ready, or stopped
  /// (lost lock, sign-out, flag off) before [body] could start.
  Future<T> runWrite<T>(Future<T> Function(SecureVault vault) body) {
    final v = _vault;
    if (v == null || !_writesOpen) {
      return Future.error(StateError('The vault is not ready.'));
    }
    return _mutex.run(v.uid, () async {
      if (!_writesOpen || !identical(_vault, v)) {
        throw StateError('The vault is not ready.');
      }
      return body(v);
    });
  }

  /// Completes the wipes owed from an earlier launch, before anything is
  /// opened for any user. Called once at app start; every other operation
  /// waits for it.
  Future<void> start() => _enqueue('start', _ensureStarted);

  /// A user is signed in ([uid]). Completes owed wipes, wipes the vaults of
  /// other users this device still has (a failure there never blocks
  /// [uid]'s own vault), then opens [uid]'s vault when [e2eeEnabled].
  Future<void> onSignedIn(String uid, {required bool e2eeEnabled}) =>
      _enqueue('signIn', () async {
        if (_uid != uid) _hookRanFor = null;
        _uid = uid;
        _flag = e2eeEnabled;
        if (!_supported) return _setStatus(VaultStatus.unsupported);
        final open = _vault;
        if (open != null && open.uid != uid) await _closeOpen();
        if (_ownedUid != null && _ownedUid != uid) await _releaseOwner();
        await _ensureStarted();
        if (_markers.persistent) {
          if (!await _wipeOthers(uid)) {
            // [uid]'s own wipe is still owed: its vault must not be used.
            return _fail(uid, VaultStatus.unavailable);
          }
        }
        if (!_flag) return _setStatus(VaultStatus.off);
        if (_vault?.uid == uid) return;
        await _open(uid);
      });

  /// [previousUid]'s session ended. [SessionEnd.userSignedOut] and
  /// [SessionEnd.accountDeleted] wipe that user's vault and key (when this
  /// device has one): directory hook -> vault rows and key -> markers ->
  /// lock. [SessionEnd.sessionLost] closes the vault and keeps everything.
  Future<void> onSessionEnded(String previousUid, SessionEnd reason) =>
      _enqueue('sessionEnd', () async {
        if (_uid == previousUid) _uid = null;
        if (!_supported) return;
        if (reason == SessionEnd.sessionLost) {
          if (_vault?.uid == previousUid || _ownedUid == previousUid) {
            await _closeOpen();
          }
          _hookRanFor = null;
          return _setStatus(VaultStatus.off);
        }
        await _ensureStarted();
        await _wipeExplicit(previousUid);
        _hookRanFor = null;
        _setStatus(VaultStatus.off);
      });

  /// `e2ee_dm` changed for the signed-in user. Off closes the vault WITHOUT
  /// wiping (markers kept); on opens it again.
  Future<void> onFlagChanged(bool e2eeEnabled) => _enqueue('flag', () async {
    if (_flag == e2eeEnabled) return;
    _flag = e2eeEnabled;
    final uid = _uid;
    if (!_supported || uid == null) return;
    if (!e2eeEnabled) {
      await _closeOpen();
      return _setStatus(VaultStatus.off);
    }
    if (_vault == null) await _open(uid);
  });

  /// A deliberate new attempt (app resume): forgets this process's failed
  /// open of the signed-in user and tries once more. Never call it in a
  /// loop: each refused web open can leave an idle worker.
  Future<void> retry() => _enqueue('retry', () async {
    final uid = _uid;
    if (!_supported || uid == null) return;
    _blocked.remove(uid);
    if (_flag && _vault == null) await _open(uid);
  });

  /// Runs the directory-removal hook for the signed-in user. Called from the
  /// auth bloc's `beforeSignOut` (its 3 s budget) on an explicit sign-out,
  /// so [onSessionEnded] does not run it again. Only when this device has
  /// a vault for that user. Never throws.
  Future<void> beforeExplicitSignOut() async {
    final uid = _uid;
    final hook = beforeExplicitWipe;
    if (!_supported || uid == null || hook == null) return;
    try {
      if (!await _hasVaultFacts(uid)) return;
      _hookRanFor = uid;
      await hook(uid);
    } catch (_) {
      // Best effort (offline, token gone): the wipe goes on regardless.
    }
  }

  /// DESTROYS the signed-in user's encrypted history on this device, every
  /// copy the platform lists, and the vault key: the explicit way out of
  /// [VaultStatus.storageChanged] (the history then exists in a storage
  /// this browser cannot use now, or in two copies). Only the user's own,
  /// warned choice may call this. Then a fresh vault opens (flag on).
  Future<void> resetVaultForStorageChange() => _enqueue('reset', () async {
    final uid = _uid;
    if (!_supported || uid == null) return;
    if (_status.value != VaultStatus.storageChanged) return;
    if (!_markers.persistent) return;
    // Nothing is open in this state; any copy listed is erased.
    final wiped = await _wipeClosed(uid, expectedFromMarker: false);
    if (!wiped) return _fail(uid, VaultStatus.storageChanged);
    _blocked.remove(uid);
    if (_flag) {
      await _open(uid);
    } else {
      _setStatus(VaultStatus.off);
    }
  });

  /// Closes the vault (no wipe) and stops; for app teardown and tests.
  Future<void> close() => _enqueue('close', _closeOpen);

  // ---------------------------------------------------------------------

  Future<void> _enqueue(String step, Future<void> Function() op) {
    final next = _queue.then((_) => op()).catchError((
      Object error,
      StackTrace stack,
    ) {
      _report(step, stack);
    });
    _queue = next;
    return next;
  }

  void _report(String step, StackTrace stack) =>
      _onUnexpectedError?.call(VaultSessionError(step), stack);

  void _setStatus(VaultStatus status) => _status.value = status;

  Future<void> _ensureStarted() async {
    if (_started) return;
    _started = true;
    if (!_supported || !_markers.persistent) return;
    final List<OwedWipe> owed;
    try {
      owed = await _markers.owedWipes();
    } catch (_, stack) {
      _report('owedWipes', stack);
      return;
    }
    for (final o in owed) {
      await _wipeClosed(o.uid);
    }
  }

  Future<bool> _hasVaultFacts(String uid) async {
    if (_vault?.uid == uid || _openedThisProcess.contains(uid)) return true;
    if (!_markers.persistent) return false;
    if (await _markers.known(uid) != null) return true;
    return await _owedFor(uid) != null;
  }

  /// Wipes owed vaults and the vaults of every user but [uid]. False when
  /// [uid]'s own owed wipe could not be completed.
  Future<bool> _wipeOthers(String uid) async {
    final Set<String> targets;
    try {
      targets = {
        for (final o in await _markers.owedWipes()) o.uid,
        for (final k in await _markers.knownVaults())
          if (k.uid != uid) k.uid,
      };
    } catch (_, stack) {
      _report('markers', stack);
      return false;
    }
    var ownOk = true;
    for (final other in targets) {
      final ok = await _wipeClosed(other);
      if (other == uid && !ok) ownOk = false;
    }
    return ownOk;
  }

  /// The explicit sign-out / account-deletion wipe of [uid].
  Future<void> _wipeExplicit(String uid) async {
    final bool facts;
    try {
      facts = await _hasVaultFacts(uid);
    } catch (_, stack) {
      _report('markers', stack);
      return;
    }
    if (!facts) {
      // Nothing of [uid] on this device: no collaborator is called.
      if (_ownedUid != null || _vault != null) await _closeOpen();
      return;
    }
    // (1) Directory removal, best effort, unless beforeSignOut already ran it.
    final hook = beforeExplicitWipe;
    if (hook != null && _hookRanFor != uid) {
      try {
        await hook(uid).timeout(_hookTimeout);
      } catch (_) {
        // Offline or timed out: the wipe goes on.
      }
    }
    final open = _vault;
    if (open == null || open.uid != uid) {
      if (_ownedUid != null || open != null) await _closeOpen();
      await _wipeClosed(uid);
      _openedThisProcess.remove(uid);
      _blocked.remove(uid);
      return;
    }
    // (2) The open vault: stop writers, rows -> cipher.destroy (the key).
    await _journal(uid);
    _writesOpen = false;
    _cancelLost();
    var wiped = false;
    try {
      await _mutex.run(uid, open.wipe);
      wiped = true;
    } catch (_) {
      // Rows (or the key) could not be deleted: the wipe stays owed.
      try {
        await open.close();
      } catch (_) {}
    }
    _vault = null;
    _openedThisProcess.remove(uid);
    _blocked.remove(uid);
    // (3) Markers, only when everything is gone.
    if (wiped) {
      try {
        await _markers.clearAll(uid);
      } catch (_, stack) {
        _report('markers', stack);
      }
    }
    // (4) The lock.
    await _releaseOwner();
  }

  /// Records the wipe of [uid] as owed before it starts, so a failure or a
  /// crash in the middle is finished at the next launch.
  Future<void> _journal(String uid, {bool fileDone = false}) async {
    try {
      await _markers.writeWipeOwed(uid, fileDone: fileDone);
    } catch (_, stack) {
      _report('journal', stack);
    }
  }

  Future<OwedWipe?> _owedFor(String uid) async {
    for (final o in await _markers.owedWipes()) {
      if (o.uid == uid) return o;
    }
    return null;
  }

  /// Wipes [uid]'s vault while it is not open in this process: owner lock
  /// -> journal -> file(s) -> journal "file done" -> key -> markers -> lock.
  /// With [expectedFromMarker] the web wipe refuses (and keeps the key) when
  /// the marked copy is not listed. An owed wipe whose file step already
  /// succeeded goes straight to the key (the file may be gone, and the
  /// marker check would refuse it for good). [cipher], when given, is
  /// [uid]'s live cipher: it is ended with [VaultCipher.destroy] instead of
  /// deleting the key behind its back. True when everything was wiped.
  ///
  /// Remaining window: a crash after the file is deleted and before "file
  /// done" is written leaves an owed wipe the web marker check refuses
  /// (status unavailable for that user until an explicit reset).
  Future<bool> _wipeClosed(
    String uid, {
    bool expectedFromMarker = true,
    VaultCipher? cipher,
  }) async {
    if (!_markers.persistent) return false;
    final heldBySession = _ownedUid == uid;
    VaultOwner? owner;
    try {
      final owed = await _owedFor(uid);
      if (owed == null) await _journal(uid);
      if (!heldBySession) {
        owner = _createOwner();
        if (!await owner.acquire(uid)) return false;
      }
      if (!(owed?.fileDone ?? false)) {
        final known = await _markers.known(uid);
        await _wipeVaultFile(
          uid: uid,
          expectedStorage: expectedFromMarker ? known?.storage : null,
        );
        await _journal(uid, fileDone: true);
      }
      // Only after the file(s) are gone.
      if (cipher != null) {
        await cipher.destroy();
      } else {
        await _deleteVaultKey(uid: uid);
      }
      await _markers.clearAll(uid);
      return true;
    } on Exception {
      // VaultOpenException / VaultKeyException: retried at the next launch.
      return false;
    } catch (_, stack) {
      _report('wipe', stack);
      return false;
    } finally {
      if (owner != null) {
        try {
          await owner.release();
        } catch (_) {}
      }
    }
  }

  /// Stops listening for a lost lock. Not awaited: cancelling a broadcast
  /// subscription takes effect at once.
  void _cancelLost() {
    final sub = _lostSub;
    _lostSub = null;
    unawaited(sub?.cancel());
  }

  Future<void> _releaseOwner() async {
    _cancelLost();
    final owner = _owner;
    _ownedUid = null;
    if (owner == null) return;
    try {
      await owner.release();
    } catch (_, stack) {
      _report('release', stack);
    }
  }

  /// Stops writers, closes the vault (no wipe) and releases the lock.
  Future<void> _closeOpen() async {
    _writesOpen = false;
    _cancelLost();
    final open = _vault;
    _vault = null;
    if (open != null) {
      try {
        await _mutex.run(open.uid, open.close);
      } catch (_, stack) {
        _report('close', stack);
      }
    }
    await _releaseOwner();
  }

  /// A failed open: remember it for this process, release the lock.
  Future<void> _fail(String uid, VaultStatus status) async {
    _blocked[uid] = status;
    await _releaseOwner();
    _setStatus(status);
  }

  /// Any launch that opens the vault, or answers unavailable or
  /// storageChanged, breaks a key-loss streak.
  Future<void> _clearStreak(String uid) async {
    try {
      await _markers.clearKeyLostSeen(uid);
    } catch (_, stack) {
      _report('markers', stack);
    }
  }

  void _onLost(String uid) {
    // Ownership is gone: stop writing at once, close in order.
    _lost = true;
    _writesOpen = false;
    _ownedUid = null;
    _blocked[uid] = VaultStatus.heldElsewhere;
    final open = _vault;
    if (open == null || open.uid != uid) return;
    _setStatus(VaultStatus.heldElsewhere);
    unawaited(
      _enqueue('lost', () async {
        if (!identical(_vault, open)) return;
        _vault = null;
        _cancelLost();
        try {
          await _mutex.run(uid, open.close);
        } catch (_, stack) {
          _report('close', stack);
        }
      }),
    );
  }

  Future<void> _open(String uid, {bool allowConfirmedWipe = true}) async {
    if (!_markers.persistent) {
      // Markers that do not outlive this launch cannot keep the vault safe.
      return _setStatus(VaultStatus.unavailable);
    }
    final blocked = _blocked[uid];
    if (blocked != null) return _setStatus(blocked);
    _setStatus(VaultStatus.opening);

    // 0. A wipe still owed for [uid] is finished first, on every path to an
    // open (sign-in, flag on, retry): a half-wiped vault is never used.
    final OwedWipe? owed;
    try {
      owed = await _owedFor(uid);
    } catch (_, stack) {
      _report('markers', stack);
      return _fail(uid, VaultStatus.unavailable);
    }
    if (owed != null && !await _wipeClosed(uid)) {
      return _fail(uid, VaultStatus.unavailable);
    }

    // 1. The owner lock.
    final owner = _owner ??= _createOwner();
    final bool acquired;
    try {
      if (_ownedUid != null && _ownedUid != uid) await _releaseOwner();
      _lost = false;
      acquired = await owner.acquire(uid);
    } catch (_, stack) {
      _report('acquire', stack);
      return _fail(uid, VaultStatus.unavailable);
    }
    if (!acquired) return _fail(uid, VaultStatus.heldElsewhere);
    _ownedUid = uid;
    _cancelLost();
    // Right after the grant: the lost stream does not replay.
    _lostSub = owner.lost.listen((_) => _onLost(uid));

    // 2. The cipher.
    final VaultCipher cipher;
    try {
      cipher = await _openCipher(uid);
    } on VaultKeyException catch (e) {
      if (e.failure == VaultKeyFailure.keyLost) {
        return _onKeyLost(uid, null, allowConfirmedWipe);
      }
      await _clearStreak(uid);
      return _fail(uid, VaultStatus.unavailable);
    } on UnsupportedError {
      await _releaseOwner();
      return _setStatus(VaultStatus.unsupported);
    } catch (_, stack) {
      _report('cipher', stack);
      await _clearStreak(uid);
      return _fail(uid, VaultStatus.unavailable);
    }

    // 3. The markers.
    final KnownVault? known;
    try {
      known = await _markers.known(uid);
    } catch (_, stack) {
      _report('markers', stack);
      return _fail(uid, VaultStatus.unavailable);
    }

    // 4. The vault; on the web the marker's storage is checked before
    // anything is created.
    final SecureVault vault;
    try {
      vault = await _openVault(
        uid: uid,
        cipher: cipher,
        expectedStorage: known?.storage,
      );
    } on VaultOpenException catch (e) {
      switch (e.status) {
        case VaultStatus.keyLost:
          return _onKeyLost(uid, cipher, allowConfirmedWipe);
        case VaultStatus.storageChanged:
          await _clearStreak(uid);
          return _fail(uid, VaultStatus.storageChanged);
        case VaultStatus.unsupported:
          await _releaseOwner();
          return _setStatus(VaultStatus.unsupported);
        default:
          await _clearStreak(uid);
          return _fail(uid, VaultStatus.unavailable);
      }
    } catch (_, stack) {
      _report('open', stack);
      await _clearStreak(uid);
      return _fail(uid, VaultStatus.unavailable);
    }

    if (_lost) {
      // Another tab took the lock while this one was opening.
      await _closeQuietly(vault);
      return _fail(uid, VaultStatus.heldElsewhere);
    }

    // 5. The storage marker: first run of this build, or a new vault.
    if (known == null || vault.createdThisOpen) {
      try {
        await _markers.writeKnown(
          KnownVault(
            uid: uid,
            storage: vault.storageName,
            createdAtMicros: _now().microsecondsSinceEpoch,
          ),
        );
      } catch (_, stack) {
        // A vault without its marker must not be used.
        _report('markers', stack);
        await _closeQuietly(vault);
        return _fail(uid, VaultStatus.unavailable);
      }
    }
    await _clearStreak(uid);

    _vault = vault;
    _writesOpen = true;
    _openedThisProcess.add(uid);
    _blocked.remove(uid);
    _setStatus(VaultStatus.ready);

    // 6. Task 7's hook.
    final ready = onVaultReady;
    if (ready != null) {
      try {
        await ready(vault);
      } catch (_, stack) {
        _report('ready', stack);
      }
    }
  }

  Future<void> _closeQuietly(SecureVault vault) async {
    try {
      await vault.close();
    } catch (_) {}
  }

  /// The vault's key does not open it. The first launch that sees this
  /// records it and wipes nothing; only a LATER launch that sees it again
  /// wipes the file, then the key, then the markers, and opens a fresh
  /// vault. [cipher] is dropped unused unless the wipe is confirmed.
  Future<void> _onKeyLost(
    String uid,
    VaultCipher? cipher,
    bool allowConfirmedWipe,
  ) async {
    final String? seen;
    try {
      seen = await _markers.keyLostSeen(uid);
    } catch (_, stack) {
      _report('markers', stack);
      return _fail(uid, VaultStatus.unavailable);
    }
    if (seen == null) {
      try {
        await _markers.writeKeyLostSeen(uid, _launchId);
      } catch (_, stack) {
        _report('markers', stack);
        return _fail(uid, VaultStatus.unavailable);
      }
      return _fail(uid, VaultStatus.keyLost);
    }
    if (seen == _launchId || !allowConfirmedWipe) {
      return _fail(uid, VaultStatus.keyLost);
    }
    // Confirmed on a second launch. The lock is held by this session.
    final wiped = await _wipeClosed(uid, cipher: cipher);
    if (!wiped) {
      // The key stays (a failed file wipe never deletes it); owed.
      return _fail(uid, VaultStatus.keyLost);
    }
    _setStatus(VaultStatus.opening);
    await _open(uid, allowConfirmedWipe: false);
  }
}
