import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../../../../core/crypto/crypto_engine.dart';
import '../../../../core/crypto/guarded_crypto_engine.dart';
import '../../../../core/crypto/mls_pair.dart';
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

part 'e2ee_pipeline_parts.dart';
part 'e2ee_pipeline_work.dart';

/// The most conversation ids [E2eePipeline] remembers per kind of hint
/// before a vault is ready (gate item 42): the oldest goes first.
const int kPipelineNotesMax = 256;

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
  final LinkedHashMap<String, int> _notedDeleted = LinkedHashMap();
  final LinkedHashSet<String> _notedPushes = LinkedHashSet();

  /// A conversation's local copies changed (the parts' `onChanged`, and a
  /// delete made here). Never carries content.
  Stream<String> get changes => _changes.stream;

  /// The coordinator of the open vault (Task 13b's `watchThread` calls
  /// [opened], [closed] and [refresh] through the pipeline); null before.
  SyncCoordinator? get coordinator => _parts?.sync;

  /// The pipeline started for the open vault (parts built, device usable,
  /// not removed elsewhere).
  bool get started {
    final s = _startedFor;
    return s != null && identical(s.vault, _session.vault);
  }

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
    final window = onStartWindowForTest;
    if (window != null) await window();
    try {
      await _applyNotes(parts);
    } on Object catch (e, s) {
      // Review I2: nothing a remembered note does may keep the start from
      // running.
      if (e is! StateError) _report('pipeline.notes', s);
    }
    await parts.sync.onVaultReady();
    _afterStartNotes(parts);
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
    // goes (gate items 41, 42).
    _teardown();
    forgetNotes();
  }

  void _teardown() {
    final parts = _parts;
    _parts = null;
    _startedFor = null;
    _wasRemoved = false;
    _owedWhilePaused.clear();
    if (parts == null) return;
    if (identical(_owners[parts.vault], this)) _owners[parts.vault] = null;
    parts.dispose();
  }

  /// Drops the remembered hints (sign-out; bootstrap may call it for a
  /// session that never had a vault). Remembered DELETES are kept (review
  /// I2, controller ruling 2): a delete-for-me the user made is never lost
  /// to a sign-out of the same account; it is dropped only once made.
  void forgetNotes() {
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
      await _deleteNow(parts, conversationId, at);
    });
  }

  void _rememberDelete(String id, int at) {
    final before = _notedDeleted.remove(id);
    _notedDeleted[id] = before != null && before > at ? before : at;
    while (_notedDeleted.length > kPipelineNotesMax) {
      _notedDeleted.remove(_notedDeleted.keys.first);
    }
  }

  /// One delete; on any failure it is remembered again (a [StateError] is
  /// quiet, anything else reported). Never throws.
  Future<bool> _deleteNow(_Parts parts, String id, int at) async {
    try {
      await parts.deleteLocal(id, at);
      return true;
    } on Object catch (e, s) {
      if (e is! StateError) _report('pipeline.delete', s);
      _rememberDelete(id, at);
      return false;
    }
  }

  Future<void>? _deleting;

  /// Makes every remembered delete (one pass at a time). Never throws.
  Future<void> _applyDeletes(_Parts parts) {
    final running = _deleting;
    if (running != null) return running;
    final pass = _applyDeletesOnce(parts);
    _deleting = pass;
    return pass.whenComplete(() {
      if (identical(_deleting, pass)) _deleting = null;
    });
  }

  Future<void> _applyDeletesOnce(_Parts parts) async {
    for (final e in [..._notedDeleted.entries]) {
      if (!parts.live) return;
      _notedDeleted.remove(e.key);
      await _deleteNow(parts, e.key, e.value);
    }
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
      parts.sync.onPush(id);
    }
  }

  void _remember(LinkedHashSet<String> set, String id) {
    set
      ..remove(id)
      ..add(id);
    while (set.length > kPipelineNotesMax) {
      set.remove(set.first);
    }
  }

  /// At start, before the coordinator's sequence: the remembered ids join
  /// the known set (gate item 24). The remembered deletes were made at
  /// vault ready ([_applyDeletes]).
  Future<void> _applyNotes(_Parts parts) async {
    final encrypted = [..._notedEncrypted];
    for (final id in encrypted) {
      await _addKnown(parts, id);
    }
  }

  /// After the coordinator's sequence: the remembered encrypted hints,
  /// accepts and pushes.
  void _afterStartNotes(_Parts parts) {
    if (!started || !identical(_parts, parts)) return;
    final encrypted = [..._notedEncrypted];
    final accepted = [..._notedAccepted];
    final pushes = [..._notedPushes];
    _notedEncrypted.clear();
    _notedAccepted.clear();
    _notedPushes.clear();
    encrypted.forEach(parts.sync.onEncrypted);
    for (final id in accepted) {
      _inRoot(() => parts.accepted(id));
    }
    pushes.forEach(parts.sync.onPush);
  }

  Future<void> _addKnown(_Parts parts, String id) async {
    if (!parts.known.isLoadedFor(parts.vault) || parts.known.contains(id)) {
      return;
    }
    try {
      await parts.known.add(id);
    } on Object catch (e, s) {
      if (e is! StateError) _report('pipeline.known.add', s);
    }
  }

  void _onConversationsChanged() {
    final parts = _parts;
    if (_disposed || parts == null || !started) return;
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
    final owed = [..._owedWhilePaused];
    _owedWhilePaused.clear();
    if (started) parts.sync.onAppResumed();
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
    forgetNotes();
    unawaited(_changes.close());
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
      _notedPushes.length;

  /// The seam every part's timer goes through (gate item 40).
  @visibleForTesting
  void Function() scheduleForTest(Duration delay, void Function() run) =>
      _scheduleCancellable(delay, run);
}
