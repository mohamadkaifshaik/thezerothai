import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../../../core/crypto/crypto_engine.dart';
import '../../../../core/crypto/mls_pair.dart';
import '../../../../core/network/app_exception.dart';
import '../../../../core/vault/secure_vault.dart';
import '../../../../core/vault/vault_session.dart';
import '../../../../core/vault/vault_status.dart';
import '../../../../gen/dzeroth/keys/v1/keys.pb.dart' as kpb;
import '../../../keys/data/keys_repository.dart';
import '../../../keys/domain/device_keys_service.dart'
    show kDeviceKeysRateLimitFallback;
import '../../data/messaging_repository.dart' show kMlsRpcTimeout;
import 'commit_runner.dart';
import 'conversation_context.dart';
import 'conversation_crypto.dart';
import 'conversation_locks.dart';
import 'device_directory.dart';
import 'device_key_history.dart' show KeyHistory, KeyRefusal;
import 'e2ee_types.dart';
import 'former_pins.dart';
import 'membership_rules.dart' show mayRemoveOwnDevice;
import 'membership_upkeep.dart';
import 'message_receiver.dart';
import 'pipeline_support.dart';
import 'removal_record.dart';
import 'sync_budget.dart';

part 'removal_queue_runner_attempt.dart';
part 'removal_queue_runner_store.dart';

/// The `limit_name` of the per-caller, per-conversation daily commit cap
/// (20 a day, shared by the user's devices). It holds one conversation
/// only (review I2).
const String kLimitCommitsPerConversationDaily =
    'messages_commits_per_conversation_daily';

/// Fix round 4, ruling 6 (CR2 M-4): a pass's lost-own-device check reuses
/// an own list fetched less than this long ago instead of a fresh
/// `ListMyKeyDevices` (passes come in bursts: resume, vault ready, hooks).
const Duration kLostOwnListReuse = Duration(seconds: 60);

/// The device-removal queue (plan Task 11, R17): the user removes one of
/// their devices; this device removes it from every encrypted conversation
/// it holds group state for.
///
/// **removeDevice.** `RemoveKeyDevice` first (sent with the flag off too
/// when this device has a vault, F-5). A failure queues nothing and
/// rethrows: the device is still in the directory, so a removal commit
/// would be undone by another device's next reconciliation (M11: 5b's text
/// says the device can still read and send, and that blocking or resetting
/// a conversation are the remaining choices). Only on success is the device
/// queued, once for every conversation with group state, most recently
/// active first (the newest stored message).
///
/// **The intent (review M1).** Before the call, an intent `{deviceId, at}`
/// is stored in the runner's own record ([kVaultSettingRemovalRecord]). A
/// definite refusal of a new removal removes it and rethrows; on success it
/// becomes the queue entries, in the same write. A definite refusal of the
/// RETRY of a stored intent (by [removeDevice] or a pass) proves nothing
/// about the first call, so a fresh own list decides (fix round 4, ruling
/// 2): it names the id, the intent goes; it is readable and does not name
/// it, the device is queued; it cannot be read, the intent stays. An intent
/// left by a crash, a vault
/// change or an unknown outcome (a network failure, a timeout, an unknown
/// server error) is sent again at the start of the next pass
/// (RemoveKeyDevice of a removed device answers success) and then queued;
/// one older than [kRemovalIntentLimit] is dropped.
///
/// **A pass** visits the queued conversations in order and makes at most
/// ONE attempt in each (one `CommitConversation` change carrying every
/// queued device of it, or the resume of its pending record), then stops.
/// An entry leaves the queue when its device is no longer a pinned member
/// (removed by this commit or by anyone's), read on pins this device has
/// caught up (fix round 3, ruling 1: after the attempt's own catch-up, or
/// at the server pair the last listing of this run answered; otherwise the
/// entry stays). CANNOT_MESSAGE, and a thread
/// that cannot be answered, park the entry until [noteConversation] sees
/// the conversation usable again; an unaccepted conversation parks it
/// until [onAccepted]. RATE_LIMITED stops the pass and stores
/// `notBeforeMicros` (below).
///
/// **Own devices only (review I1).** [removeDevice] takes only an id that a
/// fresh `ListMyKeyDevices` lists (the server answers success for any id,
/// so the call alone proves nothing), and a pass removes only `mine` pins:
/// an entry whose device is pinned on the peer's side leaves the queue and
/// is reported (`removalQueue.notOwn`; its removed mark goes too, unless
/// the pin carries the mark's key: then the mark stays and
/// `removalQueue.keyConflict` is reported, fix round 4, ruling 9); an
/// `unattributed` one waits for its
/// attribution, unless (fix round 2, ruling 1) its key is the key the fresh
/// own list showed when the user removed it (stored with the removed mark):
/// then it is removed too, since no list can attribute it any more. The
/// upkeep's reconcile, fed from this queue, follows the same rule
/// (`removedKeyOf`).
///
/// Only `mine` pins (and those marked `unattributed` ones) are ever
/// removed, so a peer's device is never touched by the queue. (Fix round 2,
/// ruling 9: the last peer-side device backstop of amendment 1 could not be
/// reached by any pin and is gone, with `lastPeerDeviceKept`.)
///
/// **Rate limits (audit L1, round P; amendment 2).** A RATE_LIMITED answer
/// to THIS pass's change is read from [CommitRunner.lastRateLimitIn] of the
/// conversation (compared by identity before and after), never the
/// runner-wide [CommitRunner.lastRateLimit], which another conversation's
/// commit may have set. The entry stays; `notBeforeMicros` = now + the
/// server's retry time capped at [kMaxServerRetryWait] (24 h, security
/// read L1), or [kDeviceKeysRateLimitFallback] when it named none (Open
/// question 7); no pass starts before it, and one timer starts the pass
/// then. Review I2: that queue-wide hold is for a limit of the whole user
/// (the per-user daily cap, the per-minute bucket, an unnamed one). The
/// per-conversation daily cap ([kLimitCommitsPerConversationDaily]) holds
/// only its conversation, in memory and with the same 24 h cap; the pass
/// goes on to the others.
///
/// **The pause exemption (ruling H; amendment 3).** A user-queued removal
/// (a device with a removed mark) goes through [CommitRunner.mayCommit] and
/// [CommitRunner.changeLocked] with `pauseExempt: true` when only the
/// exemption would let it go: the M5 pause and the fail-closed ledger do
/// not hold it; the 20-call cap and every other condition still do.
///
/// **Lost own devices (SA M2; fix round 2, ruling 11).** Each pass also
/// queues every `mine` pin that a fresh own list does not show, in every
/// conversation with group state (the M3 condition), so a removal made on
/// another own device reaches the conversations this device holds even
/// when none of them is opened. Those entries are not user-queued: no
/// pause exemption. A later pass whose own list names the device again
/// drops such an unmarked entry (fix round 4, ruling 3: one list glitch
/// must not freeze into a removal), and reconcile leaves unmarked queued
/// ids to its own M3 decision.
///
/// **One owner per pass (amendment 4).** The upkeep's `queuedRemovals` is
/// [queuedFor] (set by the constructor), so `reconcile`'s one commit
/// carries the queued removals, and the acceptance's reconcile runs them
/// before any encrypt (R10). Both commit only under the conversation lock
/// after reading the pins fresh, and neither calls the other: whichever
/// holds the lock first owns that conversation's removal for that hold;
/// the other finds the device gone (an applied commit) or a pending record
/// (which it resumes, never rebuilds). So the same removal is never
/// committed twice. This runner's pass never calls `reconcile`; the
/// upkeep never calls this runner.
///
/// **Priorities (amendment 5).** Timer-driven passes, and the passes the
/// vault-ready, resume and conversation hooks start, run at
/// [BudgetPriority.background]; the pass after [removeDevice] at
/// [BudgetPriority.live]. No pass runs at [BudgetPriority.user]: a user
/// priority asked of [runPass] is served as live.
///
/// **Persistence (amendment 7).** The queue lives in the vault under
/// [kVaultSettingRemovalQueue] (sealed) and is written after every change;
/// it survives a restart ([onVaultReady] loads it). The runner's own record
/// ([kVaultSettingRemovalRecord]) holds the intents (M1) and the devices
/// the user removed, for [kRemovedByUserLimit] and at most
/// [kMaxRemovalIntents] (concern 1, [wasRemovedByUser]). A stored value
/// (either one) that cannot be read is "unknown": a pass queues, removes
/// and writes nothing, [unreadable] says so and [wasRemovedByUser] throws.
/// [removeDevice] is NOT refused (fix round 2, ruling 10: failing closed
/// would keep a lost device in): after its fresh own-list check it sends
/// RemoveKeyDevice and, on success, writes the unreadable value fresh
/// (`removalQueue.rebuilt`); the other one, when readable, keeps what it
/// held (fix round 4, ruling 12). 5b: after `rebuilt`, the user is asked
/// to check the device list again.
///
/// Never logs; an unexpected failure is reported as [E2eePipelineError]
/// with a step name only. Defines no `toString` (it holds device ids).
class RemovalQueueRunner {
  /// [upkeep]: its `queuedRemovals` seam is set to [queuedFor] here, so
  /// the wiring cannot leave it unset (amendment 4). [schedule] runs a
  /// callback later (a [Timer] in production) and answers a handle that
  /// cancels it: the one pass at `notBeforeMicros`. [directory]: its own
  /// list is read fresh after a removal (review M2).
  RemovalQueueRunner({
    required KeysRepository keys,
    required DeviceDirectory directory,
    required CommitRunner commits,
    required MembershipUpkeep upkeep,
    required MessageReceiver receiver,
    required ConversationCrypto crypto,
    required VaultSession session,
    required CryptoEngine Function() engine,
    required ConversationLocks locks,
    required ConversationContexts contexts,
    required DateTime Function() now,
    required bool Function() removedElsewhere,
    required bool Function() removedDefinitely,
    void Function() Function(Duration delay, void Function() run)? schedule,
    void Function(Object error, StackTrace stack)? onUnexpectedError,
  }) : _keys = keys,
       _directory = directory,
       _commits = commits,
       _receiver = receiver,
       _crypto = crypto,
       _session = session,
       _engine = engine,
       _locks = locks,
       _contexts = contexts,
       _now = now,
       _removedElsewhere = removedElsewhere,
       _removedDefinitely = removedDefinitely,
       _schedule = schedule ?? ((delay, run) => Timer(delay, run).cancel),
       _onUnexpectedError = onUnexpectedError {
    upkeep
      ..queuedRemovals = queuedFor
      ..removedKeyOf = _removedKeyOf
      ..removedByUser = _removedByUser;
  }

  final KeysRepository _keys;
  final DeviceDirectory _directory;
  final CommitRunner _commits;
  final MessageReceiver _receiver;
  final ConversationCrypto _crypto;
  final VaultSession _session;
  final CryptoEngine Function() _engine;
  final ConversationLocks _locks;
  final ConversationContexts _contexts;
  final DateTime Function() _now;

  /// Task 13 passes `DeviceKeysService.stopsPipeline` here (passes, commits)
  /// and `.removedElsewhere` (definite) to [_removedDefinitely], the user
  /// removal's gate (final round 5, SA L8: an unreadable marker must not
  /// stop the user removing a lost device).
  final bool Function() _removedElsewhere;
  final bool Function() _removedDefinitely;
  final void Function() Function(Duration delay, void Function() run) _schedule;
  final void Function(Object error, StackTrace stack)? _onUnexpectedError;

  /// The image of the stored queue, valid for [_loadedFor] only.
  final List<RemovalQueueEntry> _entries = [];
  int? _notBeforeMicros;
  SecureVault? _loadedFor;

  /// The image of the runner's record ([kVaultSettingRemovalRecord]):
  /// removals asked for whose call's outcome is not known (review M1), and
  /// the devices the user removed, for [kRemovedByUserLimit] (concern 1).
  final List<RemovalMark> _intents = [];
  final List<RemovalMark> _removed = [];

  /// Device ids [removeDevice] is sending now (a pass leaves them alone).
  final Set<String> _sending = {};

  /// Fix round 4, CR2 Nit: the [removeDevice] call in progress per id; a
  /// second call for the id joins it.
  final Map<String, Future<void>> _removing = {};

  /// The vault whose stored queue could not be read (reported once).
  SecureVault? _unreadableFor;

  /// Fix round 4, ruling 12: which of the two stored values could not be
  /// read at the last load (a rebuild replaces only that one).
  bool _queueUnreadable = false;
  bool _recordUnreadable = false;

  /// Conversations whose `removalQueue.keyMismatch` was reported this run.
  final Set<String> _mismatchReported = {};

  /// Fix round 4, ruling 11: conversations whose `removalQueue.keyHistory`
  /// was reported this run.
  final Set<String> _historyReported = {};

  /// Review I2: conversations held by their own daily commit cap, until
  /// the time (capped at 24 h). Memory only: the F-7 record has no field
  /// for it and lives outside this task's files; after a restart a held
  /// conversation costs at most one refused call.
  final Map<String, DateTime> _holds = {};

  /// Ruling 4 (fix round 2): a RATE_LIMITED answer to a leftover intent's
  /// RemoveKeyDevice holds every intent until this time. Memory only: after
  /// a restart it costs at most one refused call.
  DateTime? _intentsNotBefore;

  /// Fix round 5, ruling 2 (R1): when the last RemoveKeyDevice of this run
  /// succeeded. An own list fetched before it is neither reused by a pass
  /// nor used to drop an unmarked entry: it may still name that device (a
  /// removal queued without a mark at the mark cap, while the refresh
  /// after it was deferred). Memory only.
  DateTime? _lastRemovedAt;

  /// Ruling 6 (SA L4): the load dropped expired marks; the next pass
  /// writes the record.
  bool _recordPruned = false;

  /// Ruling 7 (fix round 2): how many times reset() ran. A pass started
  /// before a reset writes no hold and arms no timer after it.
  int _resets = 0;

  /// How many times [reset] ran (Task 13's sign-out test).
  @visibleForTesting
  int get resets => _resets;

  int _passesAsked = 0;

  /// How many passes were asked for (started or joined; Task 13's wiring
  /// tests). A count only.
  @visibleForTesting
  int get passesAsked => _passesAsked;

  final ValueNotifier<int> _pending = ValueNotifier(0);

  /// Brief amendment 3: the intents whose RemoveKeyDevice answered
  /// REAUTH_REQUIRED, parked until the user signs in again and asks again
  /// ([removeDevice]). Parked again from the stored mark (fix wave 9).
  final Set<String> _reauthParked = {};
  final Set<String> _rebuildReauth = {}; // no intent stored (fix wave 10)
  final ValueNotifier<bool> _needsReauth = ValueNotifier(false);

  Future<void>? _running;
  bool _again = false;
  BudgetPriority _againPriority = BudgetPriority.background;

  void Function()? _timerCancel;
  DateTime? _timerAt;

  // -------------------------------------------------------------------------
  // Reads

  /// The queued conversations, parked ones included (5b's
  /// `removalsPending`). Nothing is ever dropped for being slow: with more
  /// than about 400 conversations the queue takes more than a day (500
  /// commit calls per user per day, shared by all own devices).
  ValueListenable<int> get pending => _pending;

  /// Brief amendment 3 (removal design section 4, "Task 11 queue"): true
  /// while a removal waits for a re-sign-in. A REMOTE RemoveKeyDevice of
  /// an id the server has not marked yet needs a recent sign-in; when it
  /// answers REAUTH_REQUIRED (the first call did not reach the server in
  /// time) its intent is PARKED, never dropped: it stays stored (so
  /// [wasRemovedByUser] still answers true), no pass sends it again, and
  /// this turns true. The UI (lane D PR 4 / 5b) then asks the user to sign
  /// in again and calls [removeDevice] for the same id, which sends it at
  /// once; its success clears the ask, and so does [dropRemoval]. The
  /// intent is stored marked as waiting (fix wave 9, SA L5): never dropped
  /// for its age, and the next run parks it again on load. [reset] clears
  /// the memory only. While the stored record cannot be read (the rebuild
  /// path), no intent is stored, but the ask is raised the same way (fix
  /// round 1, M3).
  ValueListenable<bool> get needsReauth => _needsReauth;

  /// The device ids queued for [conversationId], parked ones included (the
  /// upkeep's `queuedRemovals`, amendment 4). Empty while the queue is not
  /// loaded for the open vault, or cannot be read (fail closed).
  Set<Uint8List> queuedFor(String conversationId) {
    if (!_loaded) return <Uint8List>{};
    return {
      for (final e in _entries)
        if (e.conversationId == conversationId) e.deviceId,
    };
  }

  /// Amendment 6 and concern 1, for Task 10's `_createReset` and
  /// reconcile's own-device adds (a follow-up after Task 10 merges):
  /// whether the user removed [deviceId]. True only for a confirmed
  /// removal (RemoveKeyDevice of it succeeded less than
  /// [kRemovedByUserLimit] ago; stored in the vault, so it survives a
  /// restart) or while an intent for it waits with an unknown outcome
  /// (review M1; a definite refusal drops it unless a fresh own list shows
  /// the device gone, fix round 4, ruling 2). A queue entry alone
  /// is not an answer: the queue also holds own devices no user removed
  /// (ruling 11). Own side only (SA L2, ruling 13): it answers for the
  /// user's own devices; an id the queue found pinned on the peer's side
  /// loses its mark, unless that pin carries the mark's key (a server
  /// mis-attribution, fix round 4, ruling 9). Loads the stored record
  /// first. Throws [StateError] when there is no vault or the record cannot
  /// be read: the answer is UNKNOWN then, and the caller must use only
  /// devices from a fresh directory. Read only.
  Future<bool> wasRemovedByUser(Uint8List deviceId) async {
    final vault = _session.vault;
    if (vault == null) throw StateError('The vault is not ready.');
    if (!await _ensureLoaded(vault)) {
      throw StateError('The removal record cannot be read.');
    }
    final now = _now();
    bool names(RemovalMark m) => _same(utf8.encode(m.deviceId), deviceId);
    if (_removed.any((m) => names(m) && !_older(m, now, kRemovedByUserLimit))) {
      return true;
    }
    return _intents.any(names);
  }

  /// Ruling 1 (fix round 2; the upkeep's `removedKeyOf`): the key the fresh
  /// own list showed when the user removed [deviceId], while its mark is
  /// within [kRemovedByUserLimit]; null without one, or while the record is
  /// not loaded for the open vault.
  Uint8List? _removedKeyOf(Uint8List deviceId) =>
      _markOf(deviceId)?.signatureKey;

  /// Ruling 11 (the upkeep's `removedByUser`): [deviceId] has an unexpired
  /// removed mark, so its queued removal is the user's (pause exempt).
  bool _removedByUser(Uint8List deviceId) => _markOf(deviceId) != null;

  RemovalMark? _markOf(Uint8List deviceId) {
    if (!_loaded) return null;
    final now = _now();
    for (final m in _removed) {
      if (_older(m, now, kRemovedByUserLimit)) continue;
      if (_same(utf8.encode(m.deviceId), deviceId)) return m;
    }
    return null;
  }

  /// Amendment 7: the stored queue of the open vault could not be read.
  bool get unreadable =>
      _unreadableFor != null && identical(_unreadableFor, _session.vault);

  bool get _loaded =>
      _loadedFor != null && identical(_loadedFor, _session.vault);

  // -------------------------------------------------------------------------
  // The public entries

  /// R17: RemoveKeyDevice first; only on success the device is queued for
  /// every conversation this device has group state for, most recently
  /// active first. Throws [ArgumentError] for an empty id, for this
  /// device's own id (use sign-out) and for an id a fresh own list does not
  /// name (review I1: callers pass an id from the own list; a stored intent
  /// for the id skips that check and is finished, ruling 3), [StateError]
  /// with no call when there is no vault, while this device is removed
  /// elsewhere (fix wave 2, SA M2), or [kMaxRemovalIntents] intents
  /// are stored already (ruling 6; the removed-mark cap never refuses,
  /// fix round 4, ruling 10; reported as
  /// `removalQueue.intentCap`), and rethrows a failed own-list read
  /// (nothing sent) or a failed RemoveKeyDevice (nothing queued; except a
  /// definite refusal of a stored intent's retry while a fresh own list no
  /// longer names the device: the first call removed it, so it is queued
  /// and this completes, fix round 4, ruling 2). A stored
  /// queue or record that cannot be read does not refuse it (ruling 10):
  /// the unreadable one is rebuilt once RemoveKeyDevice succeeded (a
  /// readable one is kept, fix round 4, ruling 12). Then a pass starts at
  /// [BudgetPriority.live]; this returns once the queue is stored.
  ///
  /// A call for an id whose removal is already being made joins it (fix
  /// round 4, CR2 Nit): it answers that call's outcome and sends nothing.
  Future<void> removeDevice(String deviceId) {
    final joined = _removing[deviceId];
    if (joined != null) return joined;
    final run = _removeDevice(deviceId);
    _removing[deviceId] = run;
    run.whenComplete(() {
      if (identical(_removing[deviceId], run)) _removing.remove(deviceId);
    }).ignore();
    return run;
  }

  Future<void> _removeDevice(String deviceId) async {
    // Fix wave 2 (SA M2): a device the account removed elsewhere removes no
    // other device: no own-list read, no RemoveKeyDevice, no intent stored
    // (a stored one would go out once the fact clears).
    if (_removedDefinitely()) {
      throw StateError('This device was removed elsewhere.');
    }
    if (deviceId.isEmpty) throw ArgumentError.value('', 'deviceId');
    final id = Uint8List.fromList(utf8.encode(deviceId));
    final vault = _session.vault;
    if (vault == null) throw StateError('The vault is not ready.');
    // Fix round 5, ruling 3: the run this call started in.
    final resets = _resets;
    final own = await vault.deviceId();
    if (own == null) throw StateError('This device has no id yet.');
    if (_same(own, id)) {
      throw ArgumentError('This device is removed by signing out.');
    }
    // CR Minor 8 and SA M1 (fix round 2, ruling 10): a stored queue or
    // record that cannot be read must not keep a lost device in: failing
    // closed here would keep the attacker in. With the fresh own-list check
    // below, RemoveKeyDevice is still sent; nothing is written before it
    // (the unreadable values stay as they are if it fails), and on success
    // the unreadable value is rebuilt fresh (an empty queue plus this
    // device's entries, or an empty record plus its mark), written over it
    // (`removalQueue.rebuilt`); a readable one keeps its values (ruling 12).
    // Reconcile's M3 rule still removes the device wherever a readable own
    // list no longer shows it.
    final rebuild = !await _ensureLoaded(vault) && unreadable;
    if (!rebuild && !_loaded) {
      throw StateError('The removal queue cannot be read.');
    }
    // CR Minor 1 (fix round 2, ruling 3): a stored intent for the id is a
    // removal the user already asked for whose outcome is unknown. The
    // server may have carried it out, so the own list may no longer name
    // the device: the own-list check was made when the intent was stored,
    // and this call finishes it (RemoveKeyDevice again, then queue).
    final waiting = _intents.where((i) => i.deviceId == deviceId).firstOrNull;
    final Uint8List? key;
    if (waiting != null) {
      key = waiting.signatureKey;
    } else {
      // CR Minor 4 and SA L1 (fix round 2, ruling 6): at the intent cap
      // the new removal is refused, before anything is sent; no intent is
      // dropped to make room (a hostile own list must not push out the
      // user's real removals). Expired marks go first. SA N1 (fix round 4,
      // ruling 10): the removed-mark cap never refuses; [_queueRemoved]
      // makes room or queues the device without a mark.
      final now = _now();
      _removed.removeWhere((m) => _older(m, now, kRemovedByUserLimit));
      if (_intents.length >= kMaxRemovalIntents) {
        _reportBug('removalQueue.intentCap');
        throw StateError('Too many device removals are stored.');
      }
      // Review I1: only this user's own devices. RemoveKeyDevice of an id
      // the caller does not own answers success too (the server deletes
      // under the caller's uid only), so the call proves nothing: a fresh
      // own list decides, before anything is sent. A failed read rethrows.
      final mine = await _keys.listMine().timeout(
        kMlsRpcTimeout,
        onTimeout: () => throw const NetworkException('timed out'),
      );
      final listed = mine.devices.where((d) => d.deviceId == deviceId);
      if (listed.isEmpty) {
        throw ArgumentError('Not one of this user\'s devices.');
      }
      // Ruling 1 (fix round 2): the key the own list shows now, kept with
      // the intent and then the removed mark.
      key = Uint8List.fromList(listed.first.signaturePublicKey);
    }
    if (!identical(_session.vault, vault) || (!rebuild && !_loaded)) {
      throw StateError('The vault changed.');
    }
    // CR Minor 3 (fix round 2, ruling 5): marked as being sent BEFORE the
    // intent's write, and until it is queued, so a pass that starts while
    // either is in flight never sends the same intent a second time.
    _sending.add(deviceId);
    try {
      if (waiting == null && !rebuild) {
        // Review M1: the intent is stored BEFORE the call, so a crash or a
        // vault change between the call and the queue's write leaves it,
        // and the next pass sends it again and queues. (Not while
        // rebuilding: that write would replace the unreadable values before
        // the call succeeded.)
        _intents.add(
          RemovalMark(
            deviceId: deviceId,
            atMicros: _now().microsecondsSinceEpoch,
            signatureKey: key,
          ),
        );
        await _save(vault, queue: false);
      }
      Object? failure;
      StackTrace? failureStack;
      try {
        await _sendRemove(deviceId);
      } on Object catch (e, s) {
        failure = e;
        failureStack = s;
      }
      if (failure != null) {
        if (failure is ReauthRequiredException) {
          // Brief amendment 3: parked, never dropped (the intent stored
          // above stays, now marked so: fix wave 9). Fix round 1, M3: a
          // rebuild stored no intent, but the ask is raised all the same;
          // the user's next call for the id sends it and clears it.
          if (rebuild) {
            _parkRebuild(deviceId);
          } else {
            await _parkStored(vault, deviceId);
          }
          Error.throwWithStackTrace(failure, failureStack!);
        }
        var settled = false;
        if (_definiteRefusal(failure) && identical(_loadedFor, vault)) {
          if (waiting == null) {
            // A new removal: not removed, the intent goes. When this write
            // fails the intent stays and a pass sends it again; that is the
            // user's own ask.
            _intents.removeWhere((i) => i.deviceId == deviceId);
            try {
              await _save(vault, queue: false);
            } on Object catch (e, s) {
              _reportIfBug(e, s, 'removalQueue.intentWrite');
            }
          } else {
            // Fix round 4, ruling 2: the retry of a stored intent proves
            // nothing about the first call; a fresh own list decides.
            settled = await _settleRefusedRetry(
              vault,
              waiting,
              BudgetPriority.live,
              resets,
            );
          }
        }
        if (!settled) Error.throwWithStackTrace(failure, failureStack!);
        // Removed by the first call, and queued: the user's ask is done.
        _startPass(BudgetPriority.live);
        return;
      }
      _unparkReauth(deviceId);
      if (!identical(_session.vault, vault)) {
        throw StateError('The vault changed.');
      }
      if (rebuild && !_loaded) {
        // SA N3 (fix round 4, ruling 12): only the value that cannot be
        // read is rebuilt; the readable one, loaded into the image, stays.
        if (_queueUnreadable) {
          _entries.clear();
          _notBeforeMicros = null;
        }
        if (_recordUnreadable) {
          _intents.clear();
          _removed.clear();
          _recordPruned = false;
        }
        _holds.clear();
        _intentsNotBefore = null;
        _loadedFor = vault;
        _unreadableFor = null;
        _reportBug('removalQueue.rebuilt');
      }
      if (!_loaded) throw StateError('The vault changed.');
      await _queueRemoved(vault, deviceId, key, BudgetPriority.live);
    } finally {
      _sending.remove(deviceId);
    }
    _startPass(BudgetPriority.live);
  }

  /// One pass: one attempt per queued conversation, then stop. Joins a
  /// running pass (one more runs after it). [priority]
  /// [BudgetPriority.user] is served as [BudgetPriority.live]
  /// (amendment 5). Never throws.
  Future<void> runPass({BudgetPriority priority = BudgetPriority.background}) =>
      _startPass(priority);

  /// The vault became ready: the stored queue is loaded and a pass starts.
  Future<void> onVaultReady() => _startPass(BudgetPriority.background);

  /// The app resumed: a pass starts (none before `notBeforeMicros`).
  Future<void> onAppResumed() => _startPass(BudgetPriority.background);

  /// The app is paused: the queue timer is cancelled (no call while
  /// paused). The next trigger arms it again.
  void cancelScheduled() {
    final cancel = _timerCancel;
    _timerCancel = null;
    _timerAt = null;
    cancel?.call();
  }

  /// Sign-out or a new vault: the timer is cancelled and this run's memory
  /// forgotten (the stored queue stays in its vault).
  void reset() {
    _resets++;
    cancelScheduled();
    _entries.clear();
    _intents.clear();
    _notBeforeMicros = null;
    _loadedFor = null;
    _unreadableFor = null;
    _queueUnreadable = false;
    _recordUnreadable = false;
    _removed.clear();
    _mismatchReported.clear();
    _historyReported.clear();
    _holds.clear();
    _intentsNotBefore = null;
    _recordPruned = false;
    _lastRemovedAt = null;
    // Fix round 5, ruling 5 (m5): a removal of the old run is not joined
    // by the next run's call for the same id (its own call, sent again).
    _removing.clear();
    _reauthParked.clear();
    _rebuildReauth.clear();
    _needsReauth.value = false;
    _publish();
  }

  /// Fix wave 9 (SA L5): the user gives up a removal waiting for a
  /// re-sign-in: its intent goes and its ask clears, with no call; a
  /// [StateError] for any other id, while its call is in flight, with no
  /// vault or an unreadable record (final round 4).
  Future<void> dropRemoval(String deviceId) => _dropRemoval(deviceId);

  /// A conversation header or inbox row was taken
  /// (`ConversationContexts.note`; Task 13 wires it): when [conversationId]
  /// is usable again (accepted, and its thread can be answered), its parked
  /// entries are un-parked and a pass starts. Never throws. Completes once
  /// the un-park is stored, never waiting for the pass (review I3): it may
  /// be called while holding a conversation lock.
  ///
  /// Never call it (or [onAccepted]) inside a `VaultSession.runWrite`
  /// body, and never await it there: the un-park is stored with its own
  /// `runWrite`, which waits for the write the caller holds (the session's
  /// mutex is not re-entrant), so that would deadlock in a release build
  /// and fail with a [StateError] in a debug build (fix round 2, ruling
  /// 16). Call it after the write returned.
  Future<void> noteConversation(String conversationId) =>
      _unparkIfUsable(conversationId);

  /// R10: [conversationId] became accepted (after the upkeep's acceptance,
  /// whose reconcile already carried the queued removals): its parked
  /// entries are un-parked when it can be answered, and a pass starts (it
  /// lets go of the removed ones). Never throws. Like [noteConversation]
  /// it never waits for the pass, so it may be called under a lock, and
  /// like it, never inside a `runWrite` body.
  Future<void> onAccepted(String conversationId) =>
      _unparkIfUsable(conversationId);

  /// How many times the conversations were ranked by recent activity (a
  /// sealed read per conversation each time; fix round 5, ruling 6).
  @visibleForTesting
  int get rankingReads => _rankingReads;
  int _rankingReads = 0;

  /// Completes when no pass is running.
  @visibleForTesting
  Future<void> idle() async {
    while (_running != null) {
      await _running;
    }
  }

  // -------------------------------------------------------------------------
  // Passes

  Future<void> _startPass(BudgetPriority priority) {
    _passesAsked++;
    final p = priority == BudgetPriority.user ? BudgetPriority.live : priority;
    final running = _running;
    if (running != null) {
      _again = true;
      if (p.index < _againPriority.index) _againPriority = p;
      return running;
    }
    // In the root zone: a pass must not read as holding the lock of
    // whoever started it.
    final run = Zone.root.run(() => _passes(p));
    _running = run;
    unawaited(
      run.whenComplete(() {
        if (identical(_running, run)) _running = null;
      }),
    );
    return run;
  }

  Future<void> _passes(BudgetPriority first) async {
    var priority = first;
    while (true) {
      _again = false;
      _againPriority = BudgetPriority.background;
      try {
        await _pass(priority);
      } on Object catch (e, s) {
        _reportIfBug(e, s, 'removalQueue.pass');
      }
      if (!_again) return;
      priority = _againPriority;
    }
  }

  Future<void> _pass(BudgetPriority priority) async {
    final vault = _session.vault;
    if (vault == null || _removedElsewhere()) return;
    if (!await _ensureLoaded(vault)) return;
    final thisDevice = await vault.deviceId();
    if (thisDevice == null) return;
    // Ruling 7: this pass belongs to the run it started in.
    final resets = _resets;
    if (_recordPruned) {
      _recordPruned = false;
      await _save(vault, queue: false);
    }
    // Review M1: a leftover intent first (a keys call, not a commit: the
    // queue's hold does not apply to it).
    await _runIntents(vault, priority, resets);
    if (!_current(vault, resets)) return;
    // Ruling 11 (SA M2): own devices the own list no longer shows, queued
    // even while the queue is held (queuing is local; the hold is for
    // commits).
    final own = await _queueLostOwn(vault, thisDevice, priority, resets);
    if (!_current(vault, resets)) return;
    final notBefore = _notBeforeMicros;
    if (notBefore != null) {
      final at = DateTime.fromMicrosecondsSinceEpoch(notBefore, isUtc: true);
      if (_now().isBefore(at)) {
        _armTimer(at, resets);
        return;
      }
      _notBeforeMicros = null;
      await _save(vault);
    }
    final order = <String>[];
    for (final e in _entries) {
      if (!order.contains(e.conversationId)) order.add(e.conversationId);
    }
    for (final id in order) {
      // Fix round 4, ruling 4 (CR2 M-2): the same check as everywhere in
      // the pass, so a pass that outlived a reset() and a reload stops.
      if (!_current(vault, resets) || _removedElsewhere()) return;
      final held = _holds[id];
      if (held != null) {
        if (_now().isBefore(held)) continue;
        _holds.remove(id);
      }
      if (await _attempt(vault, id, thisDevice, priority, resets, own)) return;
    }
    // Review I2: the earliest per-conversation hold left starts the next
    // pass.
    DateTime? next;
    for (final at in _holds.values) {
      if (next == null || at.isBefore(next)) next = at;
    }
    if (next != null) _armTimer(next, resets);
  }

  /// Ruling 7: [vault] is still the session's and the loaded one, and no
  /// reset() came since the pass that read [resets] started.
  bool _current(SecureVault vault, int resets) =>
      resets == _resets &&
      identical(_session.vault, vault) &&
      identical(_loadedFor, vault);

  // One conversation's turn (`_attempt`, `_attemptLocked`, `_removable`,
  // `_prune`, `_pinsCaughtUp`, `_pruneAgainst`): the part file
  // removal_queue_runner_attempt.dart.

  // -------------------------------------------------------------------------
  // The queue

  void _park(String id) => _setParked(id, parked: true);

  bool _setParked(String id, {required bool parked}) {
    var changed = false;
    for (var i = 0; i < _entries.length; i++) {
      final e = _entries[i];
      if (e.conversationId != id || e.parked == parked) continue;
      _entries[i] = RemovalQueueEntry(
        deviceId: e.deviceId,
        conversationId: e.conversationId,
        parked: parked,
      );
      changed = true;
    }
    return changed;
  }

  Future<void> _unparkIfUsable(String id) async {
    try {
      final vault = _session.vault;
      if (vault == null || !await _ensureLoaded(vault)) return;
      final accepted =
          (await vault.conversation(id))?.sync.requestAccepted ?? false;
      if (!accepted || !_contexts.of(id).canReply) return;
      if (_setParked(id, parked: false)) await _save(vault);
      if (_entries.any((e) => e.conversationId == id)) {
        // Review I3: never awaited. A caller may hold a conversation lock
        // (a header noted inside attribution or catch-up); the pass takes
        // that lock, so awaiting it here would deadlock.
        unawaited(_startPass(BudgetPriority.background));
      }
    } on Object catch (e, s) {
      _reportIfBug(e, s, 'removalQueue.unpark');
    }
  }

  /// One timer for the pass at [at] (the queue's `notBeforeMicros`, a
  /// per-conversation hold, or the intents' hold), running a background
  /// pass. An armed timer that runs no later is kept (ruling 4: one timer;
  /// its pass arms the next one).
  void _armTimer(DateTime at, int resets) {
    if (resets != _resets || !_loaded) return;
    final armed = _timerAt;
    if (_timerCancel != null && armed != null && !armed.isAfter(at)) return;
    cancelScheduled();
    var delay = at.difference(_now());
    if (delay.isNegative) delay = Duration.zero;
    late final void Function() handle;
    handle = Zone.root.run(
      () => _schedule(delay, () {
        if (!identical(_timerCancel, handle)) return;
        _timerCancel = null;
        _timerAt = null;
        unawaited(_startPass(BudgetPriority.background));
      }),
    );
    _timerCancel = handle;
    _timerAt = at;
  }

  // -------------------------------------------------------------------------

  void _reportBug(String step) =>
      _onUnexpectedError?.call(E2eePipelineError(step), StackTrace.current);

  void _reportIfBug(Object e, StackTrace s, String step) {
    if (isPipelineBug(e)) {
      _onUnexpectedError?.call(E2eePipelineError(step), s);
    }
  }
}

/// Constant-time equality of two byte lists (the length is not secret).
bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}
