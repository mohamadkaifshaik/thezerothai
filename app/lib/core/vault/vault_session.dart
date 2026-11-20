import 'dart:async';

import 'package:flutter/foundation.dart';

import '../session/session_end.dart';
import 'keyed_mutex.dart';
import 'secure_vault.dart';
import 'vault_cipher.dart';
import 'vault_markers.dart';
import 'vault_owner.dart';
import 'vault_status.dart';

/// Opens the vault cipher of a user (`openVaultCipher`); with [create] false
/// it never generates a key (a missing one is `keyLost`).
typedef VaultCipherOpener = Future<VaultCipher> Function(
  String uid, {
  required bool create,
});

/// Opens a user's vault (`openVault`); with [create] false it never creates
/// one (none there is [VaultStatus.unavailable]).
typedef VaultOpener = Future<SecureVault> Function({
  required String uid,
  required VaultCipher cipher,
  String? expectedStorage,
  required bool create,
});

/// Erases a user's vault file(s) by the vault key alias
/// (`wipeVaultFileForAlias`): the wipe paths know users only by alias.
typedef VaultFileWiper = Future<void> Function({
  required String alias,
  String? expectedStorage,
});

/// Deletes a user's vault key by alias without opening it
/// (`deleteVaultKeyForAlias`).
typedef VaultKeyDeleter = Future<void> Function({required String alias});

/// How long the directory-removal hook may run when the session itself runs
/// it (an account deletion that ended the session without a sign-out
/// request); the same budget as the auth bloc's `beforeSignOut`.
const Duration kVaultExplicitWipeHookTimeout = Duration(seconds: 3);

/// A lost key is confirmed (and the vault wiped) only by a DIFFERENT launch
/// at least this long after the first observation, on every platform.
const Duration kVaultKeyLossConfirmAfter = Duration(hours: 1);

/// A step of the vault session failed unexpectedly, or something the owner
/// must hear about happened (`recreated`: the marked vault was found empty
/// and a new one made in it). Names the step only: no uid, no path, no
/// message of the original error (which could carry one).
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
/// - **Opening** happens on a supported platform (Android, web), with
///   persistent markers ([VaultMarkers.persistent]), when the flag is
///   [E2eeFlag.on] OR this device already has a vault for the signed-in user
///   (its known-vault marker): the flag only gates STARTING encryption
///   ([mayStart]). Both openers get `create: flag == on`: with the flag off
///   or unknown a missing key is `keyLost`, a missing vault is `unavailable`,
///   and nothing is generated or created. Order: owner lock -> cipher ->
///   markers -> vault -> ready, then the ready hooks
///   ([addVaultReadyHook]) outside the queue. No marker and a flag that is
///   not on: [VaultStatus.off], no lock, cipher, engine or file is touched
///   and no marker is written. Anything else leaves [status] at [VaultStatus.off] /
///   [VaultStatus.unsupported] / [VaultStatus.unavailable] and opens
///   nothing. No flag answer ever closes or wipes an open vault.
/// - **Wiping** is driven by device facts (a `vault.known` or `vault.wipeOwed`
///   marker, or this process opened that vault), whatever the flag reads
///   now, and only for: an explicit sign-out or account deletion
///   ([onSessionEnded], [noteAccountDeleted], a pending explicit end found at
///   [start]), a different user signing in ([onSignedIn]), an owed wipe, a
///   key loss seen on two separate launches an hour apart, and the user's own
///   warned [resetByUser]. A flag answer never wipes. Every wipe is journalled first
///   (`vault.wipeOwed`, with how far its file step got). Its order depends
///   on whether the vault is open in this session:
///   - a vault that is NOT open (another user's, an owed wipe, a confirmed
///     key loss, a closed or lost vault): file -> key -> markers -> lock;
///     the key is deleted only after the file wipe succeeded;
///   - the OPEN vault of an explicit sign-out or account deletion: writers
///     stopped -> rows and key ([SecureVault.wipe]: rows deleted, then
///     `cipher.destroy()`) -> the now-empty file (best effort) -> markers
///     -> lock. If the rows or the key cannot be deleted, the wipe stays
///     owed for the next launch.
/// - [VaultStatus.unavailable], [VaultStatus.storageChanged] and
///   [VaultStatus.heldElsewhere] never wipe and never delete a key. A failed
///   open is not repeated automatically in this process; [retry] (app
///   resume) or the next launch tries again, once.
/// - A lost session ([SessionEnd.sessionLost]) closes the vault and keeps
///   it.
/// - Markers name users by the vault key alias only, never by uid.
///
/// All work runs one operation at a time, in call order. No method throws
/// into the UI; unexpected failures go to the error reporter as
/// [VaultSessionError] (a step name only).
///
/// The hooks (the ready hooks, [beforeExplicitWipe]) must NEVER await a
/// queued method of this session (they would wait for themselves or for a
/// later operation), and every vault write goes through [runWrite].
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
  /// confirmed only when a launch with ANOTHER id sees it again, at least
  /// [kVaultKeyLossConfirmAfter] later by [_now].
  final String _launchId;
  final DateTime Function() _now;
  final Duration _hookTimeout;
  final void Function(Object error, StackTrace stack)? _onUnexpectedError;

  /// The ready hooks, in registration order ([addVaultReadyHook]).
  final List<Future<void> Function(SecureVault vault)> _readyHooks = [];

  /// Registers a hook that runs after every successful open, once the vault
  /// is published, OUTSIDE the session's queue. Hooks run in registration
  /// order, one after the other; a hook that throws is reported (generically,
  /// `VaultSessionError(ready)`) and does not stop the next, and the vault
  /// stays ready. Bootstrap registers the device keys first; later pipeline
  /// starts register after it.
  ///
  /// Contract for the implementer:
  /// - The vault it is handed may ALREADY be closed, wiped or replaced by
  ///   the time it runs (sign-out, lost lock, another user); the session
  ///   checks `identical(session.vault, vault)` before each hook and skips
  ///   the rest once it is no longer the open one.
  /// - It writes ONLY through [runWrite], and first checks
  ///   `identical(session.vault, vault)` and the uid it expects.
  /// - A [StateError] from [runWrite] (or the vault) means "cancelled":
  ///   stop quietly.
  /// - It must never await a queued session method (it would wait for a
  ///   later operation, or for itself).
  void addVaultReadyHook(Future<void> Function(SecureVault vault) hook) =>
      _readyHooks.add(hook);

  /// Best-effort removal of this device from the key directory before an
  /// explicit wipe (Task 7). Runs from [beforeExplicitSignOut] inside the
  /// auth bloc's 3 s budget or, for an end without a sign-out request, here
  /// with [kVaultExplicitWipeHookTimeout]; a failure never stops the wipe.
  ///
  /// Contract for the implementer:
  /// - It may keep running after its budget ends (the timeout only stops
  ///   waiting), so it must be idempotent and safe to run again.
  /// - It must not assume the vault is open (it may run for a vault that
  ///   is closed, or before the session opened it).
  /// - It must never await a queued session method.
  Future<void> Function(String uid)? beforeExplicitWipe;

  final ValueNotifier<VaultStatus> _status;
  final KeyedMutex _mutex = KeyedMutex();
  Future<void> _queue = Future.value();

  String? _uid;
  E2eeFlag _flag = E2eeFlag.unknown;
  bool _vaultKnown = false;
  bool _started = false;
  SecureVault? _vault;
  bool _historyLost = false;
  VaultOwner? _owner;
  String? _ownedAlias;
  StreamSubscription<void>? _lostSub;
  bool _lost = false;
  bool _writesOpen = false;
  String? _hookRanFor;

  /// Aliases of the vaults this process opened.
  final Set<String> _openedThisProcess = {};

  /// The result of a failed open per uid in this process: not repeated
  /// automatically until [retry] or the next launch.
  final Map<String, VaultStatus> _blocked = {};

  /// The uids in [_blocked] whose block was left by a `create: false` open
  /// that answered unavailable, or by a known-marker read that failed at
  /// sign-in (see [_fail]); the `on` answer clears these and no other.
  final Set<String> _softBlocked = {};

  /// Where the vault stands for the signed-in user.
  ValueListenable<VaultStatus> get status => _status;

  /// The last `e2ee_dm` answer for the signed-in user; [E2eeFlag.unknown]
  /// before any.
  E2eeFlag get flag => _flag;

  /// Whether this device may START encryption now (create a vault or a
  /// device, register, upload, claim, `mls_init`, commit adds, reset): the
  /// flag is [E2eeFlag.on]. Opening what already exists never needs it.
  bool get mayStart => _flag == E2eeFlag.on;

  /// Synchronous: this device has a vault for the signed-in user (its vault
  /// is open, or its known-vault marker was found by the last [onSignedIn] or
  /// open). False when signed out. A field the queue sets (sign-in after the
  /// marker read, open, wipe, session end), never an awaited read.
  bool get vaultKnown => _vaultKnown;

  /// The open vault while it is ready and writable; null otherwise. Write
  /// through [runWrite] so writes are serialised and stop on a lost lock.
  SecureVault? get vault => _writesOpen ? _vault : null;

  /// True while the open vault was recreated in this open: its marker said
  /// a vault existed, but the database held no vault (emptied outside the
  /// app), so the earlier history is gone. Reported once as
  /// `VaultSessionError('recreated')`.
  bool get historyLostThisOpen => _vault != null && _historyLost;

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

  /// Called once at app start with the user the auth SDK restored (null:
  /// signed out). Resolves explicit sign-outs a killed launch left pending
  /// (the same user restored: forgotten; anyone else or nobody: that wipe
  /// is owed), then completes every owed wipe, before anything is opened.
  /// Every other operation waits for it.
  ///
  /// [restoreDefinitive] says whether [restoredUid] came from the auth SDK's
  /// first real event. When it did not (a slow web restore timed out, or
  /// the SDK failed), a null [restoredUid] may only mean "not loaded yet":
  /// pending ends are then left alone (only owed wipes run) and are
  /// resolved by [onSignedIn], or by the next launch.
  Future<void> start({
    required String? restoredUid,
    required bool restoreDefinitive,
  }) => _enqueue(
    'start',
    () => _ensureStarted(restoredUid, resolvePending: restoreDefinitive),
  );

  /// A user is signed in ([uid]) with the flag answer [flag]. Completes owed
  /// wipes, wipes the vaults of other users this device still has (a failure
  /// there never blocks [uid]'s own vault), then opens [uid]'s vault when the
  /// flag is [E2eeFlag.on] or this device already has one (its known-vault
  /// marker). With neither, the status is [VaultStatus.off], nothing is opened
  /// and no marker is written.
  Future<void> onSignedIn(String uid, {required E2eeFlag flag}) =>
      _enqueue('signIn', () async {
        if (_uid != uid) {
          _hookRanFor = null;
          _vaultKnown = false;
        }
        _uid = uid;
        _flag = flag;
        if (!_supported) return _setStatus(VaultStatus.unsupported);
        final open = _vault;
        if (open != null && open.uid != uid) await _closeOpen();
        if (_ownedAlias != null && _ownedAlias != vaultKeyAlias(uid)) {
          await _releaseOwner();
        }
        await _ensureStarted(uid);
        if (_markers.persistent) {
          // [uid] is signed in: its own pending end did not happen; every
          // other user's pending end is now a wipe owed.
          await _resolvePending(uid);
          if (!await _wipeOthers(uid)) {
            // [uid]'s own wipe is still owed: its vault must not be used.
            // Only a marker actually found is a device fact (a failed read
            // is not one).
            _vaultKnown = await _readKnown(uid) ?? false;
            return _fail(uid, VaultStatus.unavailable);
          }
        }
        if (_vault?.uid == uid) {
          _vaultKnown = true;
          return;
        }
        // The device fact, read AFTER the wipes above (an own owed wipe that
        // just finished cleared the marker).
        final known = await _readKnown(uid);
        if (known != null) _vaultKnown = known;
        if (flag != E2eeFlag.on) {
          // No vault on this device and nothing may start one: no lock,
          // cipher, engine or file is touched and no marker is written. A
          // marker that cannot be read is not a reason to touch anything
          // either.
          if (known == null) {
            return _fail(uid, VaultStatus.unavailable, soft: true);
          }
          if (!known) return _setStatus(VaultStatus.off);
        }
        await _open(uid);
      });

  /// [previousUid]'s session ended. [SessionEnd.userSignedOut] and
  /// [SessionEnd.accountDeleted] wipe that user's vault and key (when this
  /// device has one): journal -> directory hook -> vault rows and key ->
  /// file -> markers -> lock. [SessionEnd.sessionLost] closes the vault and
  /// keeps everything.
  Future<void> onSessionEnded(String previousUid, SessionEnd reason) =>
      _enqueue('sessionEnd', () async {
        final wasCurrent = _uid == previousUid;
        if (wasCurrent) _uid = null;
        if (!_supported) return;
        if (reason == SessionEnd.sessionLost) {
          if (_vault?.uid == previousUid ||
              _ownedAlias == vaultKeyAlias(previousUid)) {
            await _closeOpen();
          }
          _hookRanFor = null;
          if (wasCurrent) _vaultKnown = false;
          return _setStatus(VaultStatus.off);
        }
        await _ensureStarted(null);
        // [vaultKnown] stays true through the directory hook (a flag-off
        // device still removes itself from the directory); it ends after.
        await _wipeExplicit(previousUid);
        _hookRanFor = null;
        if (wasCurrent) _vaultKnown = false;
        _setStatus(VaultStatus.off);
      });

  /// `e2ee_dm` changed for [uid]. Ignored unless [uid] is still the signed-in
  /// user when it runs (a flag answer for a user who has left). It only
  /// changes [flag] and [mayStart]: nothing closes and nothing is wiped,
  /// whatever the answer. Becoming [E2eeFlag.on] with no open vault opens
  /// one (creating it when none exists).
  Future<void> onFlagChanged(E2eeFlag flag, {required String? uid}) =>
      _enqueue('flag', () async {
        if (uid == null || uid != _uid) return;
        if (_flag == flag) return;
        _flag = flag;
        if (!_supported) return;
        if (flag != E2eeFlag.on || _vault != null) return;
        // A block left by a `create: false` open that answered unavailable
        // (see [_fail]) does not outlive the answer that lets the vault start.
        // Never one that an owed wipe, a lost key or another tab caused, and
        // never while a
        // wipe is owed (the open would finish it because of a flag answer).
        if (_softBlocked.contains(uid)) {
          var owed = true;
          try {
            owed = await _owedFor(vaultKeyAlias(uid)) != null;
          } catch (_, stack) {
            _report('markers', stack);
          }
          if (!owed) {
            _unblock(uid);
          }
        }
        // A flag answer never wipes: a key loss this open could confirm ends
        // as keyLost pending, and a later sign-in or launch confirms it.
        await _open(uid, allowConfirmedWipe: false);
      });

  /// A deliberate new attempt (app resume): forgets this process's failed
  /// open of the signed-in user and tries once more, under the same open rule
  /// as [onSignedIn] (flag on, or a vault already on this device). Never call
  /// it in a loop: each refused web open can leave an idle worker.
  Future<void> retry() => _enqueue('retry', () async {
    final uid = _uid;
    if (!_supported || uid == null) return;
    _unblock(uid);
    if (_vault != null) return;
    if (_flag != E2eeFlag.on) {
      final known = await _readKnown(uid);
      if (known != null) _vaultKnown = known;
      if (known != true) {
        // Nothing to open and nothing may start: not a stale failure.
        if (known == false) _setStatus(VaultStatus.off);
        return;
      }
    }
    await _open(uid);
  });

  /// The auth bloc's explicit-sign-out step for [uid] (its 3 s budget, only
  /// when the intent was armed for [uid]). When this device has a vault for
  /// [uid] (and [uid] is the session's user, or the session has no user
  /// yet): records a pending explicit end FIRST (so a launch killed before
  /// the wipe still wipes, see [start]), then runs the directory-removal
  /// hook, so [onSessionEnded] does not run it again. Not queued; never
  /// throws. The hook may outlive the bloc's budget (see
  /// [beforeExplicitWipe]).
  Future<void> beforeExplicitSignOut(String uid) async {
    // Another user known to be the session's: not this one's to end. A
    // session that has not yet run onSignedIn (null) still records the end
    // for the uid it is given (kill safety).
    if (!_supported || (_uid != null && uid != _uid)) return;
    final alias = vaultKeyAlias(uid);
    try {
      if (!await _hasVaultFacts(alias)) return;
    } catch (_, stack) {
      _report('markers', stack);
      return;
    }
    if (_markers.persistent) {
      try {
        await _markers.writePendingEnd(alias);
      } catch (_, stack) {
        _report('markers', stack);
      }
    }
    final hook = beforeExplicitWipe;
    if (hook == null) return;
    _hookRanFor = uid;
    try {
      await hook(uid);
    } catch (_) {
      // Best effort (offline, token gone): the wipe goes on regardless.
    }
  }

  /// The explicit sign-out of [uid] failed and [uid] is still signed in:
  /// forgets the pending end [beforeExplicitSignOut] recorded, and that the
  /// hook ran (a later end runs it again). Not queued; never throws.
  Future<void> explicitSignOutFailed(String uid) async {
    if (_hookRanFor == uid) _hookRanFor = null;
    if (!_supported || !_markers.persistent) return;
    try {
      await _markers.clearPendingEnd(vaultKeyAlias(uid));
    } catch (_, stack) {
      _report('markers', stack);
    }
  }

  /// The server accepted the deletion of [uid]'s account: when this device
  /// has a vault for [uid] (a known marker, an owed wipe, or a vault opened
  /// this process), journals its wipe at once, so a launch killed before the
  /// session ends still wipes it. No facts: nothing (a user who never had
  /// the vault causes no vault work). Facts that cannot be read: journals
  /// anyway (fail towards wiping). Not queued (the queue can be busy
  /// opening); an existing owed record is kept as it is. Never throws.
  Future<void> noteAccountDeleted(String uid) async {
    if (!_supported || !_markers.persistent) return;
    final alias = vaultKeyAlias(uid);
    var facts = true;
    try {
      facts = await _hasVaultFacts(alias);
    } catch (_, stack) {
      _report('markers', stack);
    }
    if (!facts) return;
    try {
      await _ensureOwed(alias);
    } catch (_, stack) {
      // The owed list could not be read: write a fresh record.
      _report('journal', stack);
      await _journal(OwedWipe(alias));
    }
  }

  /// DESTROYS the signed-in user's encrypted history on this device, every
  /// copy the platform lists, and the vault key: the user's own, warned
  /// choice (no caller yet; the warning, and the second confirmation when
  /// `!mayStart`, belong to the UI plan). Allowed when a user is signed in,
  /// the platform is supported, markers persist and the status is
  /// [VaultStatus.storageChanged], [VaultStatus.keyLost], [VaultStatus.ready]
  /// or [VaultStatus.unavailable] with a wipe owed for this user; otherwise
  /// it returns false and does nothing.
  ///
  /// Steps: the wipe is journalled as owed (any copy); the directory removal
  /// of the old device id runs ([beforeExplicitWipe], within
  /// [kVaultExplicitWipeHookTimeout], best effort: a refusal or timeout
  /// never stops the wipe; with no open vault the id is unknown and the step
  /// is skipped); the vault closes; every listed copy and the key are wiped
  /// and the user's markers cleared; then a fresh vault opens ONLY when
  /// [mayStart], else the status is [VaultStatus.off]. A failed wipe stays
  /// owed (it completes at the next launch). True when the vault was wiped.
  ///
  /// The status and user are those the user saw when asking: they are
  /// sampled now, and the queued reset does nothing unless the user is the
  /// same and the status when it runs is still the one sampled (a reset
  /// asked while `opening`, or in `keyLost`, never wipes a vault that has
  /// since become ready).
  Future<bool> resetByUser() async {
    final askedUid = _uid;
    final askedStatus = _status.value;
    var wiped = false;
    await _enqueue(
      'reset',
      () async => wiped = await _reset(askedUid, askedStatus),
    );
    return wiped;
  }

  Future<bool> _reset(String? askedUid, VaultStatus askedStatus) async {
    final uid = _uid;
    if (!_supported || uid == null) return false;
    if (askedUid != uid) return false;
    if (!_markers.persistent) return false;
    final alias = vaultKeyAlias(uid);
    final current = _status.value;
    if (current != askedStatus) return false;
    final allowed =
        current == VaultStatus.storageChanged ||
        current == VaultStatus.keyLost ||
        current == VaultStatus.ready ||
        (current == VaultStatus.unavailable && await _owedFor(alias) != null);
    if (!allowed) return false;
    final open = _vault;
    final hasOpen = open != null && open.uid == uid;
    // (1) The journal, before anything else.
    await _ensureOwed(alias, anyCopy: true);
    // (2) The directory removal of the old id, only when the id is known
    // (an open vault). Best effort.
    final hook = beforeExplicitWipe;
    if (hook != null && hasOpen) {
      try {
        await hook(uid).timeout(_hookTimeout);
      } catch (_) {
        // Offline or timed out: the wipe goes on.
      }
    }
    // (3) Close, then wipe every listed copy and the key.
    if (hasOpen) await _closeOpen();
    final done = await _wipeClosed(alias, anyCopy: true);
    if (!done) {
      // Stays owed; the vault is closed, so it is never reported ready.
      await _fail(
        uid,
        current == VaultStatus.ready ? VaultStatus.unavailable : current,
      );
      return false;
    }
    _vaultKnown = false;
    _unblock(uid);
    if (mayStart) {
      await _open(uid);
    } else {
      await _releaseOwner();
      _setStatus(VaultStatus.off);
    }
    return true;
  }

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

  /// Once per session: with [resolvePending] (a definite session state),
  /// pending explicit ends against [currentUid]; then the owed wipes.
  Future<void> _ensureStarted(
    String? currentUid, {
    bool resolvePending = false,
  }) async {
    if (_started) return;
    _started = true;
    if (!_supported || !_markers.persistent) return;
    if (resolvePending) await _resolvePending(currentUid);
    final List<OwedWipe> owed;
    try {
      owed = await _markers.owedWipes();
    } catch (_, stack) {
      _report('markers', stack);
      return;
    }
    for (final o in owed) {
      await _wipeClosed(o.alias);
    }
  }

  /// Resolves pending explicit ends against [currentUid], the user known to
  /// be signed in now (null: known to be nobody): its own is cleared (that
  /// sign-out did not happen); every other becomes an owed wipe, and its
  /// pending marker is cleared only once that record is written (a failed
  /// write keeps the pending marker for a later resolution).
  Future<void> _resolvePending(String? currentUid) async {
    final current = currentUid == null ? null : vaultKeyAlias(currentUid);
    final List<String> pending;
    try {
      pending = await _markers.pendingEnds();
    } catch (_, stack) {
      _report('markers', stack);
      return;
    }
    for (final alias in pending) {
      try {
        if (alias != current) await _ensureOwed(alias, strict: true);
        await _markers.clearPendingEnd(alias);
      } catch (_, stack) {
        _report('markers', stack);
      }
    }
  }

  /// Whether the known-vault marker of [uid] exists (a device fact: this
  /// device has a vault for it). Read only; false when markers do not
  /// persist; null (reported) when they cannot be read.
  Future<bool?> _readKnown(String uid) async {
    if (!_markers.persistent) return false;
    try {
      return await _markers.known(vaultKeyAlias(uid)) != null;
    } catch (_, stack) {
      _report('markers', stack);
      return null;
    }
  }

  bool _isOpenFor(String alias) {
    final open = _vault;
    return open != null && vaultKeyAlias(open.uid) == alias;
  }

  Future<bool> _hasVaultFacts(String alias) async {
    if (_isOpenFor(alias) || _openedThisProcess.contains(alias)) return true;
    if (!_markers.persistent) return false;
    if (await _markers.known(alias) != null) return true;
    return await _owedFor(alias) != null;
  }

  /// Wipes owed vaults and the vaults of every user but [uid]. False when
  /// [uid]'s own owed wipe could not be completed (its open vault is closed
  /// first).
  Future<bool> _wipeOthers(String uid) async {
    final own = vaultKeyAlias(uid);
    final Set<String> targets;
    try {
      targets = {
        for (final o in await _markers.owedWipes()) o.alias,
        for (final k in await _markers.knownVaults())
          if (k.alias != own) k.alias,
      };
    } catch (_, stack) {
      _report('markers', stack);
      return false;
    }
    var ownOk = true;
    for (final alias in targets) {
      if (alias == own && _isOpenFor(own)) await _closeOpen();
      final ok = await _wipeClosed(alias);
      if (alias == own && !ok) ownOk = false;
    }
    return ownOk;
  }

  /// The explicit sign-out / account-deletion wipe of [uid].
  Future<void> _wipeExplicit(String uid) async {
    final alias = vaultKeyAlias(uid);
    final bool facts;
    try {
      facts = await _hasVaultFacts(alias);
    } catch (_, stack) {
      _report('markers', stack);
      return;
    }
    if (!facts) {
      // Nothing of [uid] on this device: no collaborator is called.
      if (_ownedAlias != null || _vault != null) await _closeOpen();
      return;
    }
    // (1) The journal, before anything else: a crash from here on is
    // finished at the next launch. A failed journal write is reported and
    // the wipe still goes on (it is what the person asked for).
    if (_markers.persistent) {
      try {
        await _ensureOwed(alias);
      } catch (_, stack) {
        _report('journal', stack);
      }
    }
    // (2) Directory removal, best effort, unless beforeSignOut already ran it.
    final hook = beforeExplicitWipe;
    if (hook != null && _hookRanFor != uid) {
      try {
        await hook(uid).timeout(_hookTimeout);
      } catch (_) {
        // Offline or timed out: the wipe goes on.
      }
    }
    final open = _vault;
    if (open == null || open.uid != uid || _lost || _ownedAlias != alias) {
      // Not open here, or the lock was lost: the closed path (its own lock).
      if (_ownedAlias != null || open != null) await _closeOpen();
      await _wipeClosed(alias);
      _openedThisProcess.remove(alias);
      _unblock(uid);
      return;
    }
    // (3) The open vault: stop writers, rows -> cipher.destroy (the key).
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
    _openedThisProcess.remove(alias);
    _unblock(uid);
    if (wiped) {
      // (4) The now-empty database file too (best effort: rows and key are
      // already gone, so a refusal leaves only an empty file).
      try {
        await _wipeVaultFile(alias: alias, expectedStorage: open.storageName);
      } catch (_) {}
      // (5) Markers, only when everything that matters is gone.
      try {
        await _markers.clearAll(alias);
      } catch (_, stack) {
        _report('markers', stack);
      }
    }
    // (6) The lock.
    await _releaseOwner();
  }

  /// Writes [wipe] as owed. A failure is reported; the caller goes on.
  Future<void> _journal(OwedWipe wipe) async {
    try {
      await _markers.writeWipeOwed(wipe);
    } catch (_, stack) {
      _report('journal', stack);
    }
  }

  /// The owed wipe of [alias], journalled now unless one is already
  /// recorded (its progress is kept); with [anyCopy] the record is marked
  /// to erase any listed copy. Throws when the markers cannot be read; with
  /// [strict], also when the record cannot be written (otherwise a failed
  /// write is reported and the caller goes on).
  Future<OwedWipe> _ensureOwed(
    String alias, {
    bool anyCopy = false,
    bool strict = false,
  }) async {
    final owed = await _owedFor(alias);
    var record = owed ?? OwedWipe(alias);
    if (anyCopy && !record.anyCopy) record = record.copyWith(anyCopy: true);
    if (!identical(record, owed)) {
      if (strict) {
        await _markers.writeWipeOwed(record);
      } else {
        await _journal(record);
      }
    }
    return record;
  }

  Future<OwedWipe?> _owedFor(String alias) async {
    for (final o in await _markers.owedWipes()) {
      if (o.alias == alias) return o;
    }
    return null;
  }

  /// Wipes [alias]'s vault while it is not open in this process: journal ->
  /// owner lock -> journal "file started" -> file(s) -> journal "file done"
  /// -> key -> markers -> lock. The first attempt passes the storage
  /// marker, so the web wipe refuses (and keeps the key) when the marked
  /// copy is not listed; once the file step has started, or for [anyCopy]
  /// (the explicit reset), it erases whatever copy is listed, so an owed
  /// wipe can always be finished by a later launch (the marked copy may be
  /// gone already, or evicted). An owed wipe whose file step succeeded goes
  /// straight to the key. [cipher], when given, is the live cipher of the
  /// lock this session holds: it is ended with [VaultCipher.destroy] instead
  /// of deleting the key behind its back. True when everything was wiped.
  Future<bool> _wipeClosed(
    String alias, {
    bool anyCopy = false,
    VaultCipher? cipher,
  }) async {
    if (!_markers.persistent) return false;
    final heldBySession = !_lost && _ownedAlias == alias;
    VaultOwner? owner;
    try {
      var record = await _ensureOwed(alias, anyCopy: anyCopy);
      if (!heldBySession) {
        owner = _createOwner();
        if (!await owner.acquireForAlias(alias)) return false;
      }
      if (!record.fileDone) {
        String? expected;
        if (!record.fileStarted && !record.anyCopy) {
          expected = (await _markers.known(alias))?.storage;
        }
        if (!record.fileStarted) {
          record = record.copyWith(fileStarted: true);
          await _journal(record);
        }
        await _wipeVaultFile(alias: alias, expectedStorage: expected);
        record = record.copyWith(fileDone: true);
        await _journal(record);
      }
      // Only after the file(s) are gone.
      if (cipher != null && heldBySession) {
        await cipher.destroy();
      } else {
        await _deleteVaultKey(alias: alias);
      }
      await _markers.clearAll(alias);
      _openedThisProcess.remove(alias);
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
    _ownedAlias = null;
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
    _historyLost = false;
    if (open != null) {
      try {
        await _mutex.run(open.uid, open.close);
      } catch (_, stack) {
        _report('close', stack);
      }
    }
    await _releaseOwner();
  }

  /// Forgets this process's failed open of [uid], soft or hard.
  void _unblock(String uid) {
    _blocked.remove(uid);
    _softBlocked.remove(uid);
  }

  /// A failed open: remember it for this process, close [uid]'s vault if it
  /// is open, release the lock.
  ///
  /// [soft]: a block left by a `create: false` open that answered
  /// unavailable (any cause: nothing here to open, a timeout, a cipher or
  /// storage failure, a newer schema stamp), or by a known-marker read that
  /// failed at sign-in, with no wipe owed; the `on` answer may clear it
  /// ([onFlagChanged]), still under the open rule. Every other block
  /// (an owed wipe, `keyLost`, `heldElsewhere`, a failed reset) is hard.
  Future<void> _fail(
    String uid,
    VaultStatus status, {
    bool soft = false,
  }) async {
    _blocked[uid] = status;
    if (soft) {
      _softBlocked.add(uid);
    } else {
      _softBlocked.remove(uid);
    }
    if (_vault?.uid == uid) {
      await _closeOpen();
    } else {
      await _releaseOwner();
    }
    _setStatus(status);
  }

  /// Any launch that opens the vault, or answers unavailable or
  /// storageChanged, breaks a key-loss streak: EVERY `unavailable` path of
  /// [_open] and [_onKeyLost] calls this, including those where the marker
  /// store itself failed. Best effort: a failed clear is tolerated. With
  /// [quiet] (the path has already reported its marker failure) it is not
  /// reported again, so one launch reports a broken marker store once.
  Future<void> _clearStreak(String alias, {bool quiet = false}) async {
    try {
      await _markers.clearKeyLostSeen(alias);
    } catch (_, stack) {
      if (!quiet) _report('markers', stack);
    }
  }

  void _onLost(String uid) {
    // Ownership is gone: stop writing at once, close in order.
    _lost = true;
    _writesOpen = false;
    _ownedAlias = null;
    _blocked[uid] = VaultStatus.heldElsewhere;
    _softBlocked.remove(uid);
    final open = _vault;
    if (open == null || open.uid != uid) return;
    _setStatus(VaultStatus.heldElsewhere);
    unawaited(
      _enqueue('lost', () async {
        if (!identical(_vault, open)) return;
        _vault = null;
        _historyLost = false;
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
    final alias = vaultKeyAlias(uid);
    if (!_markers.persistent) {
      // Markers that do not outlive this launch cannot keep the vault safe.
      return _setStatus(VaultStatus.unavailable);
    }
    final blocked = _blocked[uid];
    if (blocked != null) return _setStatus(blocked);
    // Only a flag that is on may START a vault (create a key or a database);
    // otherwise an existing one is opened as it is.
    final create = _flag == E2eeFlag.on;
    _setStatus(VaultStatus.opening);

    // 0. A wipe still owed for [uid] is finished first, on every path to an
    // open (sign-in, flag on, retry): a half-wiped vault is never used.
    final OwedWipe? owed;
    try {
      owed = await _owedFor(alias);
    } catch (_, stack) {
      _report('markers', stack);
      await _clearStreak(alias, quiet: true);
      return _fail(uid, VaultStatus.unavailable);
    }
    if (owed != null) {
      if (_isOpenFor(alias)) await _closeOpen();
      if (!await _wipeClosed(alias)) {
        await _clearStreak(alias);
        return _fail(uid, VaultStatus.unavailable);
      }
      // The owed wipe is done: nothing of this user is left on the device.
      // Only a flag that is on may start a new vault.
      _vaultKnown = false;
      if (!create) return _setStatus(VaultStatus.off);
    }

    // 1. The owner lock.
    final owner = _owner ??= _createOwner();
    final bool acquired;
    try {
      if (_ownedAlias != null && _ownedAlias != alias) await _releaseOwner();
      _lost = false;
      acquired = await owner.acquireForAlias(alias);
    } catch (_, stack) {
      _report('acquire', stack);
      await _clearStreak(alias);
      return _fail(uid, VaultStatus.unavailable);
    }
    if (!acquired) return _fail(uid, VaultStatus.heldElsewhere);
    _ownedAlias = alias;
    _cancelLost();
    // Right after the grant: the lost stream does not replay.
    _lostSub = owner.lost.listen((_) => _onLost(uid));

    // 2. The cipher.
    final VaultCipher cipher;
    try {
      cipher = await _openCipher(uid, create: create);
    } on VaultKeyException catch (e) {
      if (e.failure == VaultKeyFailure.keyLost) {
        return _onKeyLost(uid, null, allowConfirmedWipe);
      }
      await _clearStreak(alias);
      return _fail(uid, VaultStatus.unavailable);
    } on UnsupportedError {
      await _releaseOwner();
      return _setStatus(VaultStatus.unsupported);
    } catch (_, stack) {
      _report('cipher', stack);
      await _clearStreak(alias);
      return _fail(uid, VaultStatus.unavailable);
    }

    // 3. The markers.
    final KnownVault? known;
    try {
      known = await _markers.known(alias);
    } catch (_, stack) {
      _report('markers', stack);
      await _closeCipher(cipher);
      await _clearStreak(alias, quiet: true);
      return _fail(uid, VaultStatus.unavailable);
    }

    // 4. The vault; on the web the marker's storage is checked before
    // anything is created. A cipher that does not end up inside a published
    // vault is CLOSED on every path (its key zeroed or its handle dropped;
    // the stored key stays: only a confirmed wipe destroys it).
    final SecureVault vault;
    try {
      vault = await _openVault(
        uid: uid,
        cipher: cipher,
        expectedStorage: known?.storage,
        create: create,
      );
    } on VaultOpenException catch (e) {
      switch (e.status) {
        case VaultStatus.keyLost:
          await _onKeyLost(uid, cipher, allowConfirmedWipe);
          await _closeCipher(cipher);
          return;
        case VaultStatus.storageChanged:
          await _closeCipher(cipher);
          await _clearStreak(alias);
          return _fail(uid, VaultStatus.storageChanged);
        case VaultStatus.unsupported:
          await _closeCipher(cipher);
          await _releaseOwner();
          return _setStatus(VaultStatus.unsupported);
        default:
          await _closeCipher(cipher);
          await _clearStreak(alias);
          // Under create false this is "nothing to open here" (no wipe is
          // owed: step 0 finished or found none): the `on` answer may retry.
          return _fail(uid, VaultStatus.unavailable, soft: !create);
      }
    } catch (_, stack) {
      _report('open', stack);
      await _closeCipher(cipher);
      await _clearStreak(alias);
      return _fail(uid, VaultStatus.unavailable);
    }

    if (_lost) {
      // Another tab took the lock while this one was opening.
      await _closeQuietly(vault);
      return _fail(uid, VaultStatus.heldElsewhere);
    }

    // 5. The storage marker: first run of this build, or a new vault. A
    // marked vault found empty and made again is ready (nothing else exists
    // to protect) but reported: its history is gone.
    final recreated = known != null && vault.createdThisOpen;
    if (known == null || vault.createdThisOpen) {
      try {
        await _markers.writeKnown(
          KnownVault(
            alias: alias,
            storage: vault.storageName,
            createdAtMicros: _now().microsecondsSinceEpoch,
          ),
        );
      } catch (_, stack) {
        // A vault without its marker must not be used.
        _report('markers', stack);
        await _closeQuietly(vault);
        await _clearStreak(alias, quiet: true);
        return _fail(uid, VaultStatus.unavailable);
      }
    }
    await _clearStreak(alias);

    // 6. Publish, unless the lock was lost during the steps above (checked
    // synchronously, right before publishing).
    if (_lost || _ownedAlias != alias) {
      await _closeQuietly(vault);
      return _fail(uid, VaultStatus.heldElsewhere);
    }
    _vault = vault;
    _historyLost = recreated;
    _writesOpen = true;
    _vaultKnown = true;
    _openedThisProcess.add(alias);
    _unblock(uid);
    _setStatus(VaultStatus.ready);
    if (recreated) _report('recreated', StackTrace.current);

    // 7. The ready hooks, in registration order, outside the queue: the
    // vault stays ready whatever they do.
    if (_readyHooks.isNotEmpty) unawaited(_runReady(vault));
  }

  Future<void> _runReady(SecureVault vault) async {
    for (final hook in List.of(_readyHooks)) {
      // The vault may be closed, wiped or replaced by now: the rest is
      // skipped once it is no longer the open one.
      if (!identical(this.vault, vault)) return;
      try {
        await hook(vault);
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

  /// Ends a cipher that no published vault holds. Never deletes the stored
  /// key (a no-op for a cipher already destroyed or closed).
  Future<void> _closeCipher(VaultCipher? cipher) async {
    if (cipher == null) return;
    try {
      await cipher.close();
    } catch (_) {}
  }

  /// The vault's key does not open it. The first launch that sees this
  /// records it (launch and time) and wipes nothing; only a DIFFERENT launch
  /// at least [kVaultKeyLossConfirmAfter] later that sees it again wipes the
  /// file, then the key, then the markers, and opens a fresh vault. [cipher]
  /// is dropped unused unless the wipe is confirmed while this session still
  /// holds the lock.
  Future<void> _onKeyLost(
    String uid,
    VaultCipher? cipher,
    bool allowConfirmedWipe,
  ) async {
    final alias = vaultKeyAlias(uid);
    final now = _now().microsecondsSinceEpoch;
    final KeyLostSeen? seen;
    try {
      seen = await _markers.keyLostSeen(alias);
    } catch (_, stack) {
      _report('markers', stack);
      await _clearStreak(alias, quiet: true);
      return _fail(uid, VaultStatus.unavailable);
    }
    // No observation yet, or one "from the future" (the clock moved back):
    // this launch records (or restarts) it, so confirmation is never
    // blocked for good.
    if (seen == null || now < seen.atMicros) {
      try {
        await _markers.writeKeyLostSeen(
          alias,
          KeyLostSeen(launchId: _launchId, atMicros: now),
        );
      } catch (_, stack) {
        _report('markers', stack);
        // An unavailable launch: no observation of it may survive (one
        // "from the future" would otherwise stay).
        await _clearStreak(alias, quiet: true);
        return _fail(uid, VaultStatus.unavailable);
      }
      return _fail(uid, VaultStatus.keyLost);
    }
    final confirmed =
        allowConfirmedWipe &&
        seen.launchId != _launchId &&
        now - seen.atMicros >= kVaultKeyLossConfirmAfter.inMicroseconds;
    if (!confirmed) return _fail(uid, VaultStatus.keyLost);
    // Confirmed. With the lock still held the live cipher ends the key;
    // after a lost lock the closed path takes its own lock (or is refused).
    final held = !_lost && _ownedAlias == alias;
    // A cipher the wipe will not destroy is closed before the key goes.
    if (!held) await _closeCipher(cipher);
    final wiped = await _wipeClosed(alias, cipher: held ? cipher : null);
    if (!wiped) {
      // The key stays (a failed file wipe never deletes it); owed.
      return _fail(uid, VaultStatus.keyLost);
    }
    // Everything of this user is gone (markers included).
    _vaultKnown = false;
    if (_flag != E2eeFlag.on) {
      // Only a flag that is on may start a new vault: nothing is re-created.
      await _releaseOwner();
      return _setStatus(VaultStatus.off);
    }
    _setStatus(VaultStatus.opening);
    await _open(uid, allowConfirmedWipe: false);
  }
}
