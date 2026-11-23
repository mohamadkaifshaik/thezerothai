import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../../../../core/crypto/crypto_engine.dart';
import '../../../../core/crypto/guarded_crypto_engine.dart';
import '../../../../core/crypto/mls_pair.dart';
import '../../../../core/session/session_end.dart';
import '../../../../core/vault/secure_vault.dart';
import '../../../../core/vault/vault_session.dart';
import '../../../../core/vault/vault_status.dart';
import '../../../../gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;
import '../../../../gen/dzeroth/messaging/v1/messaging.pbenum.dart';
import '../../../keys/data/keys_repository.dart';
import '../../../keys/domain/device_keys_service.dart';
import '../../data/messaging_repository.dart';
import 'commit_runner.dart';
import 'conversation_context.dart';
import 'conversation_crypto.dart';
import 'conversation_locks.dart';
import 'daily_ledger.dart';
import 'device_directory.dart';
import 'device_reset.dart';
import 'e2ee_types.dart';
import 'encrypted_sender.dart';
import 'group_starter.dart';
import 'known_conversations.dart';
import 'membership_upkeep.dart';
import 'message_receiver.dart';
import 'removal_queue_runner.dart';
import 'sync_budget.dart';
import 'sync_coordinator.dart';

part 'e2ee_pipeline_notes.dart';
part 'e2ee_pipeline_parts.dart';
part 'e2ee_pipeline_work.dart';

/// The most conversation ids [E2eePipeline] remembers per kind of hint
/// before a vault is ready (gate item 42): the oldest goes first.
const int kPipelineNotesMax = 256;

/// Fix wave ruling 5 (code review M2): the most passes the start window
/// makes over the owed init discards before the coordinator starts.
const int kOwedDiscardPasses = 4;

/// The vault each pipeline runs for (gate item 1): one main-isolate
/// pipeline per vault object. A second pipeline handed the same vault (a
/// second wiring, a background handler) runs nothing.
final Expando<E2eePipeline> _owners = Expando('e2eePipelineOwner');

/// Plan 5a Task 13 (late-bound seam, gate items 17-19): the removal queue
/// runner's `wasRemovedByUser`, for the starter and the upkeep, which are
/// built before the runner (the runner takes the upkeep). While [runner]
/// answers null the answer is unknown: a [StateError] (SA L5), which the
/// starter's reset and the upkeep's reconcile treat as "own devices from a
/// fresh list only", never a programming error. The runner's answer reads
/// the vault only: it never waits for a pass or a conversation lock, so it
/// may be asked under a lock (N-4).
Future<bool> Function(Uint8List deviceId) wasRemovedByUserOf(
  RemovalQueueRunner? Function() runner,
) => (deviceId) {
  final r = runner();
  if (r == null) {
    return Future<bool>.error(StateError('The removal queue is not ready.'));
  }
  return r.wasRemovedByUser(deviceId);
};

/// Plan 5a Task 13: builds and owns the encrypted-message pipeline's parts
/// (Tasks 2-12) and the [SyncCoordinator] that drives them; the one object
/// bootstrap holds besides the port (13b).
///
/// **R1: with no vault nothing runs.** The constructor only adds listeners
/// (the session's status, the device keys' status and fact, the
/// repository's `conversationsChanged`). The parts are built in
/// [onVaultReady]; before it, and after the vault closes, every entry
/// returns at once and calls no collaborator: no engine, no vault, no
/// `KeysRepository`, no MLS method of `MessagingRepository`. The hints
/// ([noteEncrypted], [noteAccepted], [noteDeleted], [onPush]) are
/// remembered in bounded sets ([kPipelineNotesMax]), applied when the
/// pipeline starts and dropped when a ready vault closes (sign-out, a user
/// change) or with [forgetNotes].
///
/// **Start.** [onVaultReady] (registered AFTER `DeviceKeysService
/// .onVaultReady`, which has loaded the removed-elsewhere marker by then)
/// builds the parts for that vault (once per vault object), loads the
/// known set and puts its ids into the cache's ever-encrypted set (gate
/// item 12). The coordinator's vault-ready sequence runs only when:
/// [DeviceKeysService.stopsPipeline] is false; this device is usable (its
/// status is `ready` or `dormant`, it has a device id in the vault and the
/// vault says it registered once, gate item 28); and it has not already
/// run for this (vault, flag) pair. A `deviceKeys.status` change re-checks
/// that (the first poll after the device becomes usable; the flag turning
/// on, whose `ensureReady` moves the status, runs the gated work once,
/// after the device's own upkeep; gate item 29). [start] is the same check
/// for bootstrap's flag listener.
///
/// **Removed elsewhere (gate items 32-34).** The status entering
/// `removedElsewhere` (or the fact turning true) stops the coordinator; the
/// fact clearing wakes it: the vault-ready sequence runs again for the same
/// ready vault (a welcome poll and a pass included). [setUpAgain] runs
/// `DeviceReset.setUpAgain`, then forgets the run's commit and device
/// memory, then starts again.
///
/// **Parts are kept per vault (a deviation from the plan's "rebuilt").**
/// A wake or a flag change reruns the start over the SAME parts. Why: the
/// conversation locks live in the parts, and an operation of the earlier
/// start may still be running on the same vault; two sets of parts would
/// hold two sets of locks over one vault. Memory is reset where a gate asks
/// (sign-out, set up again).
///
/// **Pause (gate items 39, 40).** [onAppPaused] cancels the upkeep's, the
/// commit runner's, the removal queue's and the coordinator's timers; a
/// callback whose timer cannot be cancelled (the sender's and the
/// starter's) that fires while paused is held and runs at [onAppResumed].
///
/// Never logs; an unexpected failure is reported as [E2eePipelineError]
/// with a step name only. Defines no `toString`.
class E2eePipeline {
  E2eePipeline({
    required VaultSession session,
    required DeviceKeysService deviceKeys,
    required GuardedCryptoEngine Function() engine,
    required MessagingRepository messaging,
    required KeysRepository keys,
    required String? Function() ownUserId,
    required String? Function() currentUid,
    bool Function() publicIdsOff = _never,
    DateTime Function() now = DateTime.now,
    SyncSchedule? schedule,
    @visibleForTesting int budgetScale = 1,
    void Function(Object error, StackTrace stack)? onUnexpectedError,
  }) : assert(budgetScale >= 1, 'Only tests raise the budgets.'),
       _budgetScale = budgetScale,
       _session = session,
       _deviceKeys = deviceKeys,
       _engine = engine,
       _messaging = messaging,
       _keys = keys,
       _ownUserId = ownUserId,
       _currentUid = currentUid,
       _publicIdsOff = publicIdsOff,
       _now = now,
       _schedule = schedule ?? _timer,
       _onUnexpectedError = onUnexpectedError {
    session.status.addListener(_onSessionStatus);
    deviceKeys.status.addListener(_onDeviceStatus);
    deviceKeys.removedElsewhereFact.addListener(_onDeviceStatus);
    _changed = messaging.conversationsChanged.listen(
      (_) => _onConversationsChanged(),
    );
  }

  static bool _never() => false;

  static void Function() _timer(Duration delay, void Function() run) =>
      Timer(delay, run).cancel;

  final VaultSession _session;
  final DeviceKeysService _deviceKeys;
  final GuardedCryptoEngine Function() _engine;
  final MessagingRepository _messaging;
  final KeysRepository _keys;
  final String? Function() _ownUserId;

  /// The authenticated uid (Firebase Auth's, as `DeviceKeysService` takes
  /// it): the account remembered notes belong to (fix round 2, r1-I2).
  /// Never the `ownUserId` reference, which may be null early in a run or
  /// change form (uid / public id) for the same account.
  final String? Function() _currentUid;
  final bool Function() _publicIdsOff;
  final DateTime Function() _now;
  final SyncSchedule _schedule;
  final void Function(Object error, StackTrace stack)? _onUnexpectedError;

  /// Multiplies every budget's calls per minute: 1 in production; a test
  /// whose clock stands still raises it so no call waits for a real minute.
  final int _budgetScale;

  StreamSubscription<void>? _changed;
  final StreamController<String> _changes = StreamController.broadcast();

  _Parts? _parts;

  /// The (vault, flag) pair the coordinator last started for.
  ({SecureVault vault, bool mayStart})? _startedFor;

  /// The device was seen removed elsewhere since the last start: its
  /// clearing is a wake.
  bool _wasRemoved = false;

  /// "Set up again" is running: status changes start nothing until it ends.
  bool _settingUp = false;

  bool _paused = false;
  final List<void Function()> _owedWhilePaused = [];
  bool _disposed = false;

  // Hints remembered before the pipeline started (gate item 42).
  final LinkedHashSet<String> _notedEncrypted = LinkedHashSet();
  final LinkedHashSet<String> _notedAccepted = LinkedHashSet();

  /// Each remembered delete: its time and (fix wave ruling 6, security
  /// audit L3) the newest stored message's time when the user deleted, or
  /// null when that could not be read then (read at the delete instead).
  final LinkedHashMap<String, _NotedDelete> _notedDeleted = LinkedHashMap();
  final LinkedHashSet<String> _notedPushes = LinkedHashSet();

  /// Fix round 2 (r1-I1): conversations whose local delete was made while
  /// the pipeline was not started, and whose pending init still waits for
  /// the starter's discard (MLS calls). Bounded and account-tagged like the
  /// notes; run after a start; kept by [forgetNotes] like the deletes.
  final LinkedHashSet<String> _owedDiscards = LinkedHashSet();

  /// Review I5, fix round 2 (r1-I2): the account every remembered note
  /// belongs to, the AUTHENTICATED uid ([_currentUid]) when it was noted.
  /// Notes are applied only to a vault whose `uid` is that account; a note
  /// made under another account first drops them all, and so does any apply
  /// to another account's vault.
  String? _notesUser;

  /// The running pass of remembered deletes (`_applyDeletes`, in
  /// e2ee_pipeline_notes.dart).
  Future<void>? _deleting;

  /// Deletes made at once by [noteDeleted] that have not ended (re-review
  /// r2-m1: the start window waits for them before its last look at the
  /// owed discards). Each never throws.
  final Set<Future<void>> _deletesInFlight = {};

  /// A conversation's local copies changed (the parts' `onChanged`, and a
  /// delete made here). Never carries content.
  Stream<String> get changes => _changes.stream;

  /// 13b-i review M3: an event (synchronous, no payload) each time the
  /// parts of a vault are built in [onVaultReady]; the port's `send` waits
  /// on it, bounded, while the vault is ready and the parts are not yet.
  Stream<void> get partsBuilt => _partsBuilt.stream;
  final StreamController<void> _partsBuilt = StreamController.broadcast(
    sync: true,
  );

  /// The coordinator of the open vault (Task 13b's `watchThread` calls
  /// [opened], [closed] and [refresh] through the pipeline); null before.
  SyncCoordinator? get coordinator => _parts?.sync;

  /// Plan 5a Task 13b: what the port (`EncryptedMessagingImpl`) reads: the
  /// same collaborators this pipeline was built with.
  VaultSession get session => _session;
  DeviceKeysService get deviceKeys => _deviceKeys;
  MessagingRepository get messaging => _messaging;

  /// The AUTHENTICATED uid now (the `currentUid` this pipeline was built
  /// with); the port binds a no-vault send to it (branch audit L1).
  String? get authenticatedUid => _currentUid();

  /// Plan 5a Task 13b: the parts of the open vault, for the port; null
  /// before [onVaultReady] built them, and once that vault closed or
  /// changed (sign-out, another user, a lost lock).
  ///
  /// 13b-i review M5: these are the mutating parts, public only because the
  /// port is its own library. `test/guards/e2ee_port_parts_guard_test.dart`
  /// allows [parts] and [reportPortError] only in the port's files under
  /// lib/ (`@internal` would not stop a reader in the same package).
  PipelineParts? get parts {
    final p = _parts;
    return p != null && p.live ? PipelineParts._(p) : null;
  }

  /// Plan 5a Task 13b: the port's unexpected failure, reported as
  /// [E2eePipelineError] with the step name only.
  void reportPortError(String step, StackTrace stack) => _report(step, stack);

  /// Plan 5a Task 13b (the port's `removalsPending`): the open vault's
  /// removal queue count, parked conversations included; 0 with no parts.
  /// One listenable for the app's lifetime: it follows the parts of each
  /// vault ([_watchRemovals]).
  ValueListenable<int> get removalsPending => _removals;
  final ValueNotifier<int> _removals = ValueNotifier(0);
  void Function()? _unwatchRemovals;

  /// Port additions (lane D): the open vault's removal runner's
  /// `needsReauth` and `parkedRefs`, followed as [removalsPending] is;
  /// false and empty with no parts.
  ValueListenable<bool> get removalNeedsReauth => _needsReauth;
  ValueListenable<List<String>> get parkedRemovals => _parked;
  final ValueNotifier<bool> _needsReauth = ValueNotifier(false);
  final ValueNotifier<List<String>> _parked = ValueNotifier(const []);

  void _watchRemovals(_Parts? parts) {
    _unwatchRemovals?.call();
    _unwatchRemovals = null;
    if (parts == null) {
      _removals.value = 0;
      _parked.value = const [];
      _needsReauth.value = false;
      return;
    }
    final runner = parts.runner;
    void copy() {
      _removals.value = runner.pending.value;
      _parked.value = runner.parkedRefs.value;
      _needsReauth.value = runner.needsReauth.value;
    }

    final followed = [runner.pending, runner.parkedRefs, runner.needsReauth];
    for (final l in followed) {
      l.addListener(copy);
    }
    _unwatchRemovals = () {
      for (final l in followed) {
        l.removeListener(copy);
      }
    };
    copy();
  }

  /// The pipeline started for the open vault (parts built, device usable,
  /// not removed elsewhere) and its coordinator runs. Review I3: false while
  /// a start applies the remembered notes (the start window): a hint then
  /// is remembered and replayed right after the coordinator started.
  bool get started {
    final s = _startedFor;
    return s != null &&
        identical(s.vault, _session.vault) &&
        _starting == 0 &&
        (_parts?.sync.running ?? false);
  }

  /// Starts inside their window (review I3), and what an [opened] in the
  /// window waits for.
  int _starting = 0;
  Completer<void>? _startGate;

  /// A list change arrived in the start window: re-read after the start.
  bool _inboxOwed = false;

  // -------------------------------------------------------------------------
  // Start

  /// The vault-ready hook (`VaultSession.addVaultReadyHook`, registered
  /// after the device keys' own hook). See the class comment.
  Future<void> onVaultReady(SecureVault vault) async {
    if (_disposed || !identical(_session.vault, vault)) return;
    final owner = _owners[vault];
    if (owner != null && !identical(owner, this)) {
      _report('pipeline.owner', StackTrace.current);
      return;
    }
    _owners[vault] = this;
    var parts = _parts;
    if (parts == null || !identical(parts.vault, vault)) {
      parts?.dispose();
      parts = _parts = _Parts(this, vault);
      _startedFor = null;
      _watchRemovals(parts);
      if (!_partsBuilt.isClosed) _partsBuilt.add(null);
    }
    try {
      if (!parts.known.isLoadedFor(vault)) await parts.known.load(vault);
    } on Object catch (e, s) {
      // An unreadable known set: the crypto reads it again (and fails
      // closed) on its own; a closed vault is quiet.
      if (e is! StateError) _report('pipeline.known', s);
    }
    if (!identical(_session.vault, vault) || !identical(_parts, parts)) return;
    if (parts.known.isLoadedFor(vault)) {
      // Gate item 12: `noteEverEncrypted` runs after the committing
      // transaction, so a crash can leave the cache's mark missing.
      final session = _messaging.cacheSession;
      for (final id in parts.known.ids) {
        try {
          await _messaging.noteEverEncrypted(id, session: session);
        } on Object catch (e, s) {
          if (e is! StateError) _report('pipeline.everEncrypted', s);
        }
      }
    }
    // Review I2: a delete the user made before the vault was ready is a
    // local write: made now, whatever the device state.
    await _applyDeletes(parts);
    await _maybeStart();
  }

  /// Bootstrap's flag listener calls this after `deviceKeys.ensureReady()`
  /// when the flag turns on (gate item 29): the gated work starts once.
  /// Idempotent; a no-op before [onVaultReady].
  Future<void> start() => _maybeStart();

  Future<void> _maybeStart() async {
    final parts = _parts;
    final vault = _session.vault;
    if (_disposed ||
        _settingUp ||
        parts == null ||
        vault == null ||
        !identical(parts.vault, vault)) {
      return;
    }
    if (_deviceKeys.stopsPipeline) {
      if (_deviceKeys.removedElsewhere) _wasRemoved = true;
      parts.sync.stop();
      _startedFor = null;
      return;
    }
    if (!await _deviceUsable(vault)) return;
    if (_disposed ||
        _settingUp ||
        !identical(_parts, parts) ||
        !identical(_session.vault, vault) ||
        _deviceKeys.stopsPipeline) {
      return;
    }
    final mayStart = _session.mayStart;
    final last = _startedFor;
    if (last != null &&
        identical(last.vault, vault) &&
        last.mayStart == mayStart) {
      return;
    }
    _startedFor = (vault: vault, mayStart: mayStart);
    _wasRemoved = false;
    // Review I3: the start window. Hints arriving in it are remembered
    // (`started` is false) and replayed once the coordinator runs.
    if (_starting++ == 0) _startGate = Completer<void>();
    Future<void>? sequence;
    try {
      final window = onStartWindowForTest;
      if (window != null) await window();
      try {
        await _applyNotes(parts);
      } on Object catch (e, s) {
        // Review I2: nothing a remembered note does may keep the start from
        // running.
        if (e is! StateError) _report('pipeline.notes', s);
      }
      // Fix round 2 (r1-I1): never throws.
      await _applyOwedDiscards(parts);
      // Re-review r2-m1, fix wave ruling 5 (M2): a delete made in this
      // window owes its discard only once its local transaction ends: wait
      // for those and look again until quiet (bounded), right before the
      // coordinator's resumeProvisional (which since ruling 1 also refuses
      // to resend a deleted conversation's init).
      await _settleOwedDiscards(parts);
      if (parts.live && identical(_startedFor?.vault, vault)) {
        // The coordinator is running once this call returns (it sets its
        // state before its first await).
        sequence = parts.sync.onVaultReady();
      }
    } finally {
      if (--_starting == 0) {
        final gate = _startGate;
        _startGate = null;
        gate?.complete();
      }
    }
    if (sequence == null) return;
    _afterStartNotes(parts);
    await sequence;
  }

  /// Gate item 28: this device's id is in the vault, the vault says it
  /// registered once, and the device keys are `ready`, or `dormant` while
  /// the flag is not on. With the flag on, `dormant` means the device's own
  /// upkeep for the flag has not run yet: the gated work waits for it
  /// (device first, pipeline second; gate item 29). A start made earlier
  /// keeps running meanwhile.
  Future<bool> _deviceUsable(SecureVault vault) async {
    final phase = _deviceKeys.status.value.phase;
    final usable =
        phase == DeviceKeysPhase.ready ||
        (phase == DeviceKeysPhase.dormant && !_session.mayStart);
    if (!usable) return false;
    try {
      if (await vault.deviceId() == null) return false;
      final once = await vault.setting(kVaultSettingRegisteredOnce);
      return once != null && once.length == 1 && once[0] == 0x01;
    } on Object catch (e, s) {
      if (e is! StateError) _report('pipeline.device', s);
      return false;
    }
  }

  void _onDeviceStatus() {
    if (_disposed) return;
    final removed =
        _deviceKeys.status.value.phase == DeviceKeysPhase.removedElsewhere ||
        _deviceKeys.removedElsewhere;
    if (removed) {
      // Gate item 32.
      _wasRemoved = true;
      _parts?.sync.stop();
      _startedFor = null;
      return;
    }
    if (_wasRemoved && !_deviceKeys.stopsPipeline) {
      // Gate item 33: the fact cleared; the receiver's `stopped(+1 min)`
      // answers are not waited for: the whole start runs again.
      _wasRemoved = false;
      _startedFor = null;
    }
    unawaited(_maybeStart());
  }

  void _onSessionStatus() {
    final parts = _parts;
    if (parts == null) return;
    if (_session.status.value == VaultStatus.ready &&
        identical(_session.vault, parts.vault)) {
      return;
    }
    // Sign-out, a user change, a lost lock: everything this run remembered
    // goes (gate items 41, 42). The reason is not known here, so deletes
    // stay (bootstrap's end-of-session call drops them for an explicit end).
    _teardown();
    forgetNotes(SessionEnd.sessionLost);
  }

  void _teardown() {
    final parts = _parts;
    _parts = null;
    _startedFor = null;
    _wasRemoved = false;
    _inboxOwed = false;
    _owedWhilePaused.clear();
    _watchRemovals(null);
    if (parts == null) return;
    if (identical(_owners[parts.vault], this)) _owners[parts.vault] = null;
    parts.dispose();
  }

  /// Drops the remembered hints (sign-out; bootstrap calls it at every end
  /// of a session, with its [end]). For [SessionEnd.sessionLost] (the vault
  /// is kept) remembered DELETES and owed discards are kept (review I2,
  /// controller ruling 2): a delete-for-me the user made is never lost to a
  /// lost session of the same account; it is dropped only once made.
  ///
  /// Fix wave ruling 7 (security audit L4): an explicit end
  /// ([SessionEnd.userSignedOut], [SessionEnd.accountDeleted]) wipes the
  /// vault they target, so they are dropped with the account tag: no
  /// conversation id of that account stays in memory.
  void forgetNotes(SessionEnd end) {
    if (end != SessionEnd.sessionLost) {
      _dropAllNotes();
      return;
    }
    _notedEncrypted.clear();
    _notedAccepted.clear();
    _notedPushes.clear();
  }

  // -------------------------------------------------------------------------
  // Hints from the repository and pushes

  /// `MessagingRepository.onEncryptedConversation`. With a started
  /// pipeline the known set gains [conversationId] (its own transaction)
  /// and the coordinator polls welcomes when no group is here; otherwise it
  /// is remembered.
  void noteEncrypted(String conversationId) {
    if (_disposed || conversationId.isEmpty) return;
    final parts = _parts;
    if (parts == null || !started) {
      _remember(_notedEncrypted, conversationId);
      return;
    }
    _inRoot(() async {
      await _addKnown(parts, conversationId);
      parts.sync.onEncrypted(conversationId);
    });
  }

  /// `MessagingRepository.onRequestAccepted` (the user accepted): the
  /// upkeep's acceptance steps, then the removal queue's un-park (gate item
  /// 43).
  void noteAccepted(String conversationId) {
    if (_disposed || conversationId.isEmpty) return;
    final parts = _parts;
    if (parts == null || !started) {
      _remember(_notedAccepted, conversationId);
      return;
    }
    _inRoot(() => parts.accepted(conversationId));
  }

  /// `MessagingRepository.onConversationDeleted` (delete-for-me): every
  /// local copy and unsent row of [conversationId] goes in one transaction;
  /// the group, the marks and the sync record stay, with `cleared_at` now
  /// (gate item 47). Done as soon as the vault is ready, whatever the device
  /// state (a local write the user asked for). Before that, and after a
  /// failed attempt, it is remembered (review I2) and made at the next vault
  /// ready or resume.
  void noteDeleted(String conversationId) {
    if (_disposed || conversationId.isEmpty) return;
    final at = _now().microsecondsSinceEpoch;
    final parts = _parts;
    if (parts == null || !parts.live) {
      _rememberDelete(conversationId, at);
      return;
    }
    _inRoot(() async {
      // Fix wave ruling 6 (security audit L3): the delete covers what was
      // stored when the user deleted, read now, before anything waits.
      final run = parts
          .newestStoredAt(conversationId)
          .then((upTo) => _deleteNow(parts, conversationId, at, upTo: upTo))
          .then((_) {});
      _deletesInFlight.add(run);
      try {
        await run;
      } finally {
        _deletesInFlight.remove(run);
      }
    });
  }

  /// A message push (`PushCubit`'s `lastMessageConversationId` when
  /// `messagePushes` grew): a welcome poll and a pull of that conversation.
  void onPush(String? conversationId) {
    if (_disposed) return;
    final id = conversationId ?? '';
    final parts = _parts;
    if (parts == null || !started) {
      if (id.isNotEmpty) _remember(_notedPushes, id);
      return;
    }
    if (id.isEmpty) {
      parts.sync.pushWithoutConversation();
    } else {
      _inRoot(() => _pushed(parts, id));
    }
  }

  /// Fix wave ruling 9 (security audit L6): a pushed id is pulled and
  /// caught up only when it is in the known set or a cached inbox row;
  /// any other id is dropped (no per-id work or state) and the push only
  /// polls welcomes, as a push without an id does. Why the welcome poll is
  /// kept: the first message of a NEW conversation arrives as a welcome,
  /// before its row is cached. Never throws.
  Future<void> _pushed(_Parts parts, String id) async {
    if (!parts.live) return;
    var mine = parts.known.isLoadedFor(parts.vault) && parts.known.contains(id);
    if (!mine) {
      try {
        final rows = (await _messaging.cachedConversations(Folder.FOLDER_INBOX))
            .conversations;
        mine = rows.any((r) => r.id == id);
      } on Object {
        mine = false;
      }
    }
    if (!parts.live || !identical(_parts, parts) || !started) return;
    if (mine) {
      parts.sync.onPush(id);
    } else {
      ignoredPushes++;
      parts.sync.pushWithoutConversation();
    }
  }

  /// Pushes whose id was dropped by [_pushed] (tests).
  @visibleForTesting
  int ignoredPushes = 0;

  void _onConversationsChanged() {
    final parts = _parts;
    if (_disposed || parts == null) return;
    if (_starting > 0) {
      // Review I3: replayed once the coordinator runs.
      _inboxOwed = true;
      return;
    }
    if (!started) return;
    _inRoot(parts.rereadInbox);
  }

  // -------------------------------------------------------------------------
  // Lifecycle

  /// The app came back to the foreground. Bootstrap calls the engine's,
  /// the session's retry and the device keys' resume first (13-ii).
  void onAppResumed() {
    _paused = false;
    final parts = _parts;
    if (_disposed || parts == null) {
      _owedWhilePaused.clear();
      return;
    }
    // Gate item 37: a new receive run right after the engine's.
    parts.receiver.onAppResumed();
    // Review I2: a delete that failed earlier is tried again.
    if (_notedDeleted.isNotEmpty && parts.live) {
      _inRoot(() => _applyDeletes(parts));
    }
    // Re-review r2-m1, fix wave ruling 5 (M3): an owed init discard (one
    // that could not decide, or one owed while not started) is tried again,
    // and the coordinator's resume is CHAINED after it.
    final owed = [..._owedWhilePaused];
    _owedWhilePaused.clear();
    if (_owedDiscards.isNotEmpty && started && !_deviceKeys.stopsPipeline) {
      _inRoot(() async {
        await _applyOwedDiscards(parts);
        if (started && identical(_parts, parts)) parts.sync.onAppResumed();
      });
    } else if (started) {
      parts.sync.onAppResumed();
    }
    for (final run in owed) {
      run();
    }
  }

  /// The app went to the background (gate items 39, 40).
  void onAppPaused() {
    _paused = true;
    final parts = _parts;
    if (_disposed || parts == null) return;
    parts.upkeep.cancelScheduled();
    parts.commits.cancelScheduled();
    parts.runner.cancelScheduled();
    parts.sync.onAppPaused();
  }

  /// Task 13b's first `watchThread` listener of [conversationId].
  Future<void> opened(String conversationId) async {
    // Review I3: an open in the start window waits for the start.
    final gate = _startGate;
    if (gate != null) await gate.future;
    final parts = _parts;
    if (_disposed || parts == null || !started) return;
    await parts.sync.opened(conversationId);
  }

  /// Task 13b's last `watchThread` listener of [conversationId] went away.
  void closed(String conversationId) => _parts?.sync.closed(conversationId);

  /// R17 "set up again" (the port's `setUpDeviceAgain`; gate item 34):
  /// `DeviceReset.setUpAgain`, then the commit runner's, the crypto's own
  /// commits', the starter's, the upkeep's and the directory's memory goes,
  /// then the pipeline starts again (its welcome poll included). Throws as
  /// `DeviceReset.setUpAgain` does; a [StateError] with no ready vault.
  Future<void> setUpAgain() async {
    final parts = _parts;
    if (_disposed || parts == null || !identical(parts.vault, _session.vault)) {
      throw StateError('The vault is not ready.');
    }
    _settingUp = true;
    try {
      parts.sync.stop();
      _startedFor = null;
      await parts.reset.setUpAgain();
      parts.commits.reset();
      parts.crypto.forgetOwnCommits();
      parts.starter.reset();
      parts.upkeep.reset();
      parts.directory.clear();
    } finally {
      _settingUp = false;
    }
    _wasRemoved = false;
    await _maybeStart();
  }

  /// Stops everything and removes every listener.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _session.status.removeListener(_onSessionStatus);
    _deviceKeys.status.removeListener(_onDeviceStatus);
    _deviceKeys.removedElsewhereFact.removeListener(_onDeviceStatus);
    unawaited(_changed?.cancel());
    _changed = null;
    _teardown();
    forgetNotes(SessionEnd.sessionLost);
    unawaited(_changes.close());
    unawaited(_partsBuilt.close());
  }

  // -------------------------------------------------------------------------
  // Seams the parts share

  /// The parts' `schedule` (a cancellable timer): a callback that fires
  /// while paused is held for [onAppResumed] (gate item 40).
  void Function() _scheduleCancellable(Duration delay, void Function() run) =>
      _schedule(delay, () {
        if (_disposed) return;
        if (_paused) {
          _owedWhilePaused.add(run);
          return;
        }
        run();
      });

  /// The sender's and the starter's `schedule` (no cancel handle).
  void _scheduleFire(Duration delay, void Function() run) {
    _scheduleCancellable(delay, run);
  }

  void _onPartChanged(String conversationId) {
    if (!_changes.isClosed) _changes.add(conversationId);
  }

  /// Runs [body] in the root zone, unawaited: a repository callback or a
  /// lock holder never waits for it, and the work never reads as holding
  /// the caller's lock.
  void _inRoot(Future<void> Function() body) {
    Zone.root.run(() {
      unawaited(
        body().catchError((Object e, StackTrace s) {
          if (e is! StateError) _report('pipeline.hint', s);
        }),
      );
    });
  }

  void _report(String step, StackTrace stack) =>
      _onUnexpectedError?.call(E2eePipelineError(step), stack);

  // -------------------------------------------------------------------------
  // For tests

  @visibleForTesting
  ConversationCrypto get crypto => _parts!.crypto;
  @visibleForTesting
  MessageReceiver get receiver => _parts!.receiver;
  @visibleForTesting
  EncryptedSender get sender => _parts!.sender;
  @visibleForTesting
  GroupStarter get starter => _parts!.starter;
  @visibleForTesting
  CommitRunner get commits => _parts!.commits;
  @visibleForTesting
  MembershipUpkeep get upkeep => _parts!.upkeep;
  @visibleForTesting
  RemovalQueueRunner get runner => _parts!.runner;
  @visibleForTesting
  DeviceDirectory get directory => _parts!.directory;
  @visibleForTesting
  KnownConversations get known => _parts!.known;
  @visibleForTesting
  ConversationContexts get contexts => _parts!.contexts;
  @visibleForTesting
  ConversationLocks get locks => _parts!.locks;
  @visibleForTesting
  DailyLedger get ledger => _parts!.ledger;
  @visibleForTesting
  DeviceReset get deviceReset => _parts!.reset;
  @visibleForTesting
  SyncBudget get syncBudget => _parts!.syncBudget;
  @visibleForTesting
  SyncBudget get readBudget => _parts!.readBudget;
  @visibleForTesting
  bool get hasParts => _parts != null;

  /// Awaited inside the start window (after this start is claimed, before
  /// the remembered notes are applied): a test holds it to send hints into
  /// the window. Null in production.
  @visibleForTesting
  Future<void> Function()? onStartWindowForTest;

  /// How many hints are remembered (a count only).
  @visibleForTesting
  int get notedCount =>
      _notedEncrypted.length +
      _notedAccepted.length +
      _notedDeleted.length +
      _notedPushes.length +
      _owedDiscards.length;

  /// The seam every part's timer goes through (gate item 40).
  @visibleForTesting
  void Function() scheduleForTest(Duration delay, void Function() run) =>
      _scheduleCancellable(delay, run);
}
