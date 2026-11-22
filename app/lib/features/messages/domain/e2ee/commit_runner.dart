import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../../../../core/crypto/crypto_engine.dart';
import '../../../../core/crypto/crypto_types.dart';
import '../../../../core/crypto/guarded_crypto_engine.dart';
import '../../../../core/crypto/mls_pair.dart';
import '../../../../core/network/app_exception.dart';
import '../../../../core/vault/secure_vault.dart';
import '../../../../core/vault/vault_session.dart';
import '../../data/messaging_repository.dart';
import 'conversation_context.dart';
import 'conversation_crypto.dart';
import 'conversation_locks.dart';
import 'daily_ledger.dart';
import 'e2ee_types.dart';
import 'encrypted_sender.dart' show sendOutcomeUnknown;
import 'membership_rules.dart';
import 'message_receiver.dart';
import 'pipeline_support.dart';
import 'sync_budget.dart';

// The margin a discard waits (below, "The discard margin").
export 'pipeline_support.dart' show kRequestInFlightMargin;

part 'commit_runner_send.dart';

/// R9: a device renews its own leaf keys this long after the last renewal
/// (`ConversationSync.lastSelfUpdateAtMicros`). Read by Task 9's
/// `selfUpdateIfDue`.
const Duration kSelfUpdateEvery = Duration(days: 30);

/// R9: no self-update once this many `CommitConversation` calls were made in
/// the conversation today (calls, retries and refusals included).
const int kSelfUpdateMaxCommitCallsToday = 10;

/// The contract's cap on `CommitConversation` calls per caller and
/// conversation per day (`messages_commits_per_conversation_daily`, MP): the
/// client stops one call short of the server's refusal.
const int kCommitCallsPerConversationPerDay = 20;

/// The longest a server-chosen retry time holds a pending commit (review
/// m9, ruling R3). `retryAfterOf` allows a day (`kMaxServerRetryWait`),
/// which is right for one outbox row; a pending commit holds every send of
/// its conversation, so a hostile or broken retry time must not hold them
/// for a day. After [kRequestInFlightMargin] the catch-up proof decides
/// anyway. Cost: a few more counted calls, bounded by the daily cap.
const Duration kCommitRetryWaitMax = Duration(minutes: 5);

/// What became of one commit of this device.
///
/// `applied`: the server stored this device's commit and the group is one
/// epoch on. `superseded`: another commit won the pair; the device caught
/// up, its own commit is gone, and the caller reconciles again on the new
/// group (a rebuilt copy of the same change is never sent from here).
/// `pending`: the outcome is not known, the confirm could not be stored
/// yet, or a discard is waiting for its margin; the pending record stays
/// and [CommitRunner.resumePending] settles it. `refused`: the server
/// refused it and the commit was discarded. `notAllowed`: from `change` and
/// `selfUpdate`, no commit was made (see [CommitRunner.mayCommit]) and
/// nothing was stored; from `resumePending`, there was no pending record
/// of this runner's, or the record could no longer be sent and was
/// discarded (the group is as it was before the commit was built).
enum CommitOutcome { applied, superseded, pending, refused, notAllowed }

/// Commits by this device (Task 9; M1 to M5, R9, R10): membership changes
/// and self-updates of a conversation's current group.
///
/// **One commit.** Under the conversation lock:
///
/// 1. ONE `runWrite` body: the engine builds the commit on the group at pair
///    P, then ONE transaction stores the group state holding it (epoch
///    unchanged, with the pending record: kind, P, the exact bytes) and the
///    sync record with today's call count one higher. The count is written
///    before the call, so a crash never undercounts.
/// 2. `CommitConversation` with those bytes. An answer of `P.next`: the
///    messages of P are completed, then the commit is confirmed and its
///    transaction written (`ConversationCrypto.confirmOwnCommitLocked`: the
///    step catch-up runs for an own commit met by its bytes). A later pair
///    or STALE_EPOCH: catch-up, which finds this commit by its bytes
///    (`applied`) or applies the winner (`superseded`). An unknown outcome:
///    one more counted call with the identical bytes, at once when the
///    server named no time, else one scheduled resume at its time; still
///    unknown is `pending`. A refusal of the FIRST call: the commit is
///    discarded. A refusal of a later call (an earlier one may have been
///    stored): catch-up first, and the commit is discarded only when the
///    device is then at the server's pair and still holds it, i.e. no
///    commit was stored at P (plan-own-leaf.md: a discarded commit the
///    server stored would come back as an own-leaf answer and force a
///    reset), and only [kRequestInFlightMargin] after the last call (a
///    call with no answer can still be stored until then); before that the
///    outcome is `pending` and one resume is scheduled for the margin's
///    end. A call the client stopped waiting for that still runs (audit
///    M2: it may not have left the client yet) holds every discard; the
///    margin counts from its end, which schedules that resume.
/// 3. [resumePending], after a restart or an unknown outcome: catch-up
///    first; when the server's pair is still P, the identical bytes are sent
///    once more (a counted call), not before the retry time of the last
///    unknown outcome (the server's, five minutes at most, else the
///    margin). A record that can no longer be sent is discarded on the
///    same proof and after the same margin.
///
/// Locking (plan "Global Constraints"): the public entries take the
/// conversation lock; the `...Locked` variants are for a caller that holds
/// it (Task 9's reconcile and acceptance steps). RPCs run under the lock and
/// outside `runWrite`; every `runWrite` body reads the device state and the
/// group fresh, calls the engine and writes ONE transaction.
///
/// Never logs; an unexpected failure is reported as [E2eePipelineError] with
/// a step name only. Defines no `toString`.
class CommitRunner {
  /// [removedElsewhere] is Task 12's fact: this device was removed from the
  /// account on another device (it builds and sends nothing while true).
  ///
  /// [schedule] runs a callback later (a timer in production) and answers
  /// a handle that cancels it: the one resume after a server-chosen retry
  /// time or at the end of the discard margin, at most one per
  /// conversation. [reset] (sign-out) and [cancelScheduled] (the app is
  /// paused) call the handle, so no resume makes network calls then
  /// (review m8; brief amendment 10). Step 9b's re-check timer uses the
  /// same seam shape.
  CommitRunner({
    required ConversationCrypto crypto,
    required MessageReceiver receiver,
    required VaultSession session,
    required CryptoEngine Function() engine,
    required MessagingRepository messaging,
    required DailyLedger ledger,
    required ConversationLocks locks,
    required ConversationContexts contexts,
    required DateTime Function() now,
    required void Function(String conversationId) onChanged,
    required bool Function() removedElsewhere,
    void Function() Function(Duration delay, void Function() run)? schedule,
    void Function(Object error, StackTrace stack)? onUnexpectedError,
  }) : _crypto = crypto,
       _receiver = receiver,
       _session = session,
       _engine = engine,
       _messaging = messaging,
       _ledger = ledger,
       _locks = locks,
       _contexts = contexts,
       _now = now,
       _onChanged = onChanged,
       _removedElsewhere = removedElsewhere,
       _schedule = schedule ?? ((delay, run) => Timer(delay, run).cancel),
       _onUnexpectedError = onUnexpectedError;

  final ConversationCrypto _crypto;
  final MessageReceiver _receiver;
  final VaultSession _session;
  final CryptoEngine Function() _engine;
  final MessagingRepository _messaging;
  final DailyLedger _ledger;
  final ConversationLocks _locks;
  final ConversationContexts _contexts;
  final DateTime Function() _now;
  final void Function(String conversationId) _onChanged;
  final bool Function() _removedElsewhere;
  final void Function() Function(Duration delay, void Function() run) _schedule;
  final void Function(Object error, StackTrace stack)? _onUnexpectedError;

  /// The last RATE_LIMITED answer to a commit of this run (its retry time is
  /// for the removal queue, Task 11); null when there was none.
  RateLimitedException? lastRateLimit;

  // Memory of this run. Nothing here is a fact a write relies on: after a
  // restart a pending commit is only resent sooner.

  /// Conversation -> no resume makes a commit call before this time: the
  /// server's retry time of an unknown outcome, or, when it named none,
  /// [kRequestInFlightMargin] after that outcome (review I2).
  final Map<String, DateTime> _notBefore = {};

  /// Read-only: the time before which no resume of [conversationId]'s
  /// pending commit makes a call (the server's retry time of its last
  /// unknown outcome, else [kRequestInFlightMargin] after it); null when
  /// this run holds none. The upkeep's re-check of a change left `pending`
  /// is due then (review I-A).
  DateTime? resendNotBefore(String conversationId) =>
      _notBefore[conversationId];

  /// The conversations a resume is scheduled for (one each), each with the
  /// handle that cancels it. An entry goes when its callback runs.
  final Map<String, void Function()> _resumeScheduled = {};

  /// The discard margin (review I1). Conversation -> the pending commit this
  /// run last dealt with there and the time its margin is counted from: the
  /// last `CommitConversation` call of those bytes in this run, else the
  /// moment this run first saw the record (when an earlier run last called
  /// is not stored, and every call of an earlier run was made before that
  /// moment). A discard that rests on "catch-up ended at the server's pair
  /// and the record is still held" is made only [kRequestInFlightMargin]
  /// after it: until then a call that got no answer may still be stored,
  /// and a discarded commit the server stores later comes back as an
  /// own-leaf answer and forces a reset (plan-own-leaf.md).
  ///
  /// Audit M2: a call whose client wait ran out may not have left the
  /// client yet (`MessagingRepository.abandonedMlsCall`). While one runs,
  /// no discard is made and nothing is scheduled; when it ends, the margin
  /// counts from that end and one resume is scheduled for the margin's
  /// end.
  final Map<String, _MarginStart> _marginStart = {};

  /// Conversation -> the bytes of a pending commit a call that was not the
  /// first was refused for. The next resume drops it (once the margin has
  /// passed and catch-up ended at the server's pair) instead of sending
  /// the refused bytes again.
  final Map<String, Uint8List> _refusedResend = {};

  /// The conversations whose last [change] in this run the engine could
  /// not build ([lastChangeUnbuildable]).
  final Set<String> _unbuildable = {};

  /// Conversation -> the bytes of a pending removal built with
  /// `pauseExempt` in this run (ruling H): a resume of those bytes is not
  /// held by the M5 pause either.
  final Map<String, Uint8List> _pauseExempt = {};

  /// Audit M1: whether the last [change] / [changeLocked] of
  /// [conversationId] in this run answered `notAllowed` because the engine
  /// could not build it (an [MlsException] from `commitChange`, or a result
  /// that does not fit its group or its adds), with nothing stored. Set
  /// for that one call only: every later change starts it again. The
  /// caller marks the adds of such a change tried for the IST day, so one
  /// broken peer package is not claimed again on every pass.
  bool lastChangeUnbuildable(String conversationId) =>
      _unbuildable.contains(conversationId);

  /// The app is paused: every scheduled resume is cancelled (no network
  /// call while paused). Nothing else is forgotten; a paused app settles
  /// its pending records at its next trigger, which schedules again when
  /// it has to wait.
  void cancelScheduled() {
    final handles = _resumeScheduled.values.toList();
    _resumeScheduled.clear();
    for (final cancel in handles) {
      cancel();
    }
  }

  /// Sign-out or a new vault: cancels every scheduled resume and forgets
  /// this run's memory.
  void reset() {
    lastRateLimit = null;
    _notBefore.clear();
    cancelScheduled();
    _marginStart.clear();
    _refusedResend.clear();
    _unbuildable.clear();
    _pauseExempt.clear();
    _crypto.forgetOwnCommits();
  }

  // -------------------------------------------------------------------------
  // When a commit may be made

  /// True when this device may make a commit of [kind] in [conversationId]
  /// now. ALL of: the pipeline is usable (a ready vault, an available
  /// engine, not removed elsewhere, no engine hold); the group is `ready`,
  /// not provisional, with no pending record; this run synced since its
  /// start; the conversation is ACCEPTED (R10 and pilot gate 5.3: in an
  /// unaccepted conversation, received or sent, this device makes no commit
  /// of any kind); the thread can be answered; the commit calls made here
  /// today are below [kCommitCallsPerConversationPerDay], and below
  /// [kSelfUpdateMaxCommitCallsToday] for a self-update; for a change, fewer
  /// than [kAntiFlapUndosPerDay] own changes were undone here today (M5).
  ///
  /// A change that ADDS also needs the flag (`VaultSession.mayStart`, R1):
  /// [change] checks it; a removal and a self-update need none. False for
  /// the kinds this runner does not make (`init`, `reset`). Reads only;
  /// takes no lock. Never throws.
  ///
  /// [pauseExempt] (controller ruling H, audit L2): the question is for a
  /// removal-only change the caller vouches is an own-device removal (M3:
  /// an own device a readable own list no longer shows) or one the user
  /// queued (Task 11). For it, the M5 pause and the ledger's fail-closed
  /// answer do not say no; every other condition, the daily call cap
  /// included, still does. Why: the pause stops flapping between members,
  /// and a lost own phone or a removal the user asked for must still be
  /// removable the same day; a hostile peer cannot make an honest
  /// device's own list drop it.
  Future<bool> mayCommit(
    String conversationId,
    PendingKind kind, {
    bool pauseExempt = false,
  }) async {
    try {
      return await _allowed(
        conversationId,
        kind,
        hasAdds: false,
        pauseExempt: pauseExempt,
      );
    } on Object catch (e, s) {
      _reportIfBug(e, s, 'commit.mayCommit');
      return false;
    }
  }

  Future<bool> _allowed(
    String id,
    PendingKind kind, {
    required bool hasAdds,
    bool pauseExempt = false,
  }) async {
    if (kind != PendingKind.change && kind != PendingKind.selfUpdate) {
      return false;
    }
    final vault = _session.vault;
    if (vault == null || !_usable(id)) return false;
    // R1: an add is a start; the flag must be on.
    if (hasAdds && !_session.mayStart) return false;
    final context = _contexts.of(id);
    if (!context.syncedSinceStart || !context.canReply) return false;
    final state = await _crypto.describeState(id);
    if (state.phase != ConversationPhase.ready || !state.requestAccepted) {
      return false;
    }
    final group = await _currentGroup(vault, id);
    if (group == null || group.hasPending) return false;
    final sync =
        (await vault.conversation(id))?.sync ?? const ConversationSync();
    if (_callsToday(sync) >= _cap(kind)) return false;
    // M5, through the ledger's own accessor (an unreadable record reads at
    // its cap). Not for an exempt removal (ruling H).
    if (kind == PendingKind.change &&
        !pauseExempt &&
        await _ledger.undone(id) >= kAntiFlapUndosPerDay) {
      return false;
    }
    return true;
  }

  /// The parts of "the pipeline is usable" that are not stored: not removed
  /// elsewhere, the engine available, and no engine hold of the receiver
  /// (device-level trouble, or this conversation's group).
  bool _usable(String id) {
    if (_removedElsewhere()) return false;
    final engine = _engine();
    if (engine is GuardedCryptoEngine && engine.unavailable.value) {
      return false;
    }
    if (_receiver.engineHeldUntil != null) return false;
    final hold = _contexts.of(id).engineHoldUntil;
    return hold == null || !_now().isBefore(hold);
  }

  int _cap(PendingKind kind) => kind == PendingKind.selfUpdate
      ? kSelfUpdateMaxCommitCallsToday
      : kCommitCallsPerConversationPerDay;

  /// The commit calls made today (the server's day, IST).
  int _callsToday(ConversationSync sync) =>
      sync.commitCallsDay == istDay(_now()) ? sync.commitCallsToday : 0;

  // -------------------------------------------------------------------------
  // The public entries

  /// One commit that adds the devices behind [adds] (claimed and checked,
  /// R3; each is pinned with the side it was checked for) and removes
  /// [removeDeviceIds]. `notAllowed`, with nothing built, when [mayCommit]
  /// says no, when it adds while the flag is not on, when it would change
  /// nothing, names this device, or names a device twice. Takes the
  /// conversation lock (never call it with the lock held). Never throws.
  Future<CommitOutcome> change(
    String conversationId, {
    List<UsableClaim> adds = const [],
    List<Uint8List> removeDeviceIds = const [],
    BudgetPriority priority = BudgetPriority.background,
  }) => _locks.run(
    conversationId,
    () => _commitLocked(
      conversationId,
      PendingKind.change,
      adds: adds,
      removes: removeDeviceIds,
      priority: priority,
    ),
  );

  /// [change] for a caller that ALREADY HOLDS the conversation lock.
  ///
  /// [pauseExempt]: see [mayCommit]. Only for a change with no adds (one
  /// with adds is `notAllowed`); the caller vouches that every removal is
  /// an own-device removal (M3) or a user-queued one. The exemption holds
  /// for this run's resends of the record too; after a restart the record
  /// is judged as any other (a fresh reconcile builds it again).
  Future<CommitOutcome> changeLocked(
    String conversationId, {
    List<UsableClaim> adds = const [],
    List<Uint8List> removeDeviceIds = const [],
    BudgetPriority priority = BudgetPriority.background,
    bool pauseExempt = false,
  }) {
    assert(
      _locks.isHeld(conversationId),
      'The caller must hold the conversation lock.',
    );
    if (pauseExempt && adds.isNotEmpty) {
      return Future.value(CommitOutcome.notAllowed);
    }
    return _commitLocked(
      conversationId,
      PendingKind.change,
      adds: adds,
      removes: removeDeviceIds,
      priority: priority,
      pauseExempt: pauseExempt,
    );
  }

  /// One commit that renews this device's own leaf keys (R9). Whether one
  /// is DUE is the caller's question (Task 9's `selfUpdateIfDue`); this
  /// only asks [mayCommit]. Takes the conversation lock. Never throws.
  Future<CommitOutcome> selfUpdate(
    String conversationId, {
    BudgetPriority priority = BudgetPriority.background,
  }) => _locks.run(
    conversationId,
    () => _commitLocked(
      conversationId,
      PendingKind.selfUpdate,
      priority: priority,
    ),
  );

  /// [selfUpdate] for a caller that ALREADY HOLDS the conversation lock.
  Future<CommitOutcome> selfUpdateLocked(
    String conversationId, {
    BudgetPriority priority = BudgetPriority.background,
  }) {
    assert(
      _locks.isHeld(conversationId),
      'The caller must hold the conversation lock.',
    );
    return _commitLocked(
      conversationId,
      PendingKind.selfUpdate,
      priority: priority,
    );
  }

  /// Settles a pending change or self-update record left by an earlier run
  /// or an unknown outcome: catch-up first (it confirms this commit when the
  /// server stored it, or applies the winner); when the device is then at
  /// the server's pair and still holds the record, the identical bytes are
  /// sent once more (one more counted call).
  ///
  /// `notAllowed`: there was no such record, or it could no longer be sent
  /// (the flag for an add, the daily cap, M5, a read-only thread, an
  /// unaccepted conversation) and was discarded, which is safe because
  /// catch-up just showed that no commit is stored at its pair and the
  /// in-flight margin has passed. `refused`: an earlier resend of it was
  /// refused and it was discarded on the same proof. `pending`: still not
  /// known (the catch-up did not reach the server's pair, the retry time
  /// or the discard margin has not passed, the device is removed
  /// elsewhere, or the call got no answer).
  ///
  /// Callers (controller ruling, 2026-11-22): step 9b's `reconcile` calls
  /// [resumePendingLocked] FIRST, before any list call, whenever the group
  /// holds a pending record; Task 13 calls this on app open and on resume.
  /// The sender does not, and catch-up does not (this runs catch-up
  /// itself). Besides them only this runner's own scheduled resume calls
  /// it. Takes the conversation lock. Never throws.
  Future<CommitOutcome> resumePending(
    String conversationId, {
    BudgetPriority priority = BudgetPriority.background,
  }) =>
      _locks.run(conversationId, () => _resumeLocked(conversationId, priority));

  /// [resumePending] for a caller that ALREADY HOLDS the conversation lock.
  Future<CommitOutcome> resumePendingLocked(
    String conversationId, {
    BudgetPriority priority = BudgetPriority.background,
  }) {
    assert(
      _locks.isHeld(conversationId),
      'The caller must hold the conversation lock.',
    );
    return _resumeLocked(conversationId, priority);
  }

  // -------------------------------------------------------------------------
  // One commit

  Future<CommitOutcome> _commitLocked(
    String id,
    PendingKind kind, {
    List<UsableClaim> adds = const [],
    List<Uint8List> removes = const [],
    required BudgetPriority priority,
    bool pauseExempt = false,
  }) async {
    final PipelineOp op;
    final PendingCommit pending;
    final String key;
    if (kind == PendingKind.change) _unbuildable.remove(id);
    try {
      final started = await _op();
      if (started == null) return CommitOutcome.notAllowed;
      op = started;
      final welcomeDeviceIds = <String>[];
      if (kind == PendingKind.change) {
        if (adds.isEmpty && removes.isEmpty) return CommitOutcome.notAllowed;
        final removed = <String>{};
        for (final r in removes) {
          // This device never removes itself, and no id is named twice.
          if (_same(r, op.deviceId) || !removed.add(hexOf(r))) {
            return CommitOutcome.notAllowed;
          }
        }
        final added = <String>{};
        for (final a in adds) {
          final hex = hexOf(a.deviceId);
          if (_same(a.deviceId, op.deviceId) ||
              removed.contains(hex) ||
              !added.add(hex)) {
            return CommitOutcome.notAllowed;
          }
          // The server addresses a welcome by the device id as text.
          welcomeDeviceIds.add(utf8.decode(a.deviceId));
        }
      }
      if (!await _allowed(
        id,
        kind,
        hasAdds: adds.isNotEmpty,
        pauseExempt: pauseExempt,
      )) {
        return CommitOutcome.notAllowed;
      }
      // The first call's key, drawn before anything is stored: a failed
      // random source leaves no pending commit behind.
      key = hexOf(await randomOf(_engine(), 16));
      final built = await _build(
        op,
        id,
        kind,
        adds: adds,
        removes: removes,
        welcomeDeviceIds: welcomeDeviceIds,
        pauseExempt: pauseExempt,
      );
      if (built == null) return CommitOutcome.notAllowed;
      pending = built;
      if (pauseExempt) _pauseExempt[id] = pending.commit;
    } on BadRandom {
      _reportBug('commit.random');
      return CommitOutcome.notAllowed;
    } on Object catch (e, s) {
      // Nothing was stored: a body that threw wrote nothing.
      _reportIfBug(e, s, 'commit.build');
      return CommitOutcome.notAllowed;
    }
    // The checked side and key of each add, for whichever step confirms
    // this commit in this run (review m2, m5): the direct confirm, a
    // resume, or a catch-up of any caller that meets it by its bytes.
    _crypto.rememberOwnAdds(id, pending.builtOn, adds);
    _onChanged(id);
    return _send(
      op,
      id,
      pending,
      firstKey: key,
      first: true,
      tries: 2,
      priority: priority,
    );
  }

  /// Step 1, ONE `runWrite` body: everything read fresh, the engine call,
  /// and ONE transaction with the group state holding the pending commit
  /// and the call count. Null: nothing was built and nothing stored.
  Future<PendingCommit?> _build(
    PipelineOp op,
    String id,
    PendingKind kind, {
    required List<UsableClaim> adds,
    required List<Uint8List> removes,
    required List<String> welcomeDeviceIds,
    required bool pauseExempt,
  }) => _session.runWrite((v) async {
    op.check(v);
    final groups = await v.groups(id);
    if (groups.isEmpty || groups.any((g) => g.provisional)) return null;
    final group = groups.last; // ascending generation
    if (group.hasPending) return null;
    final sync = (await v.conversation(id))?.sync ?? const ConversationSync();
    // R10, read fresh: never a commit in an unaccepted conversation.
    if (!sync.requestAccepted) return null;
    final calls = _callsToday(sync);
    if (calls >= _cap(kind)) return null;
    if (adds.isNotEmpty && !_session.mayStart) return null;
    // M5, on the record as it is in this body (not for an exempt removal,
    // ruling H).
    if (kind == PendingKind.change &&
        !pauseExempt &&
        (await _ledger.readLocked(v)).undoneIn(id) >= kAntiFlapUndosPerDay) {
      return null;
    }
    final deviceState = await v.deviceState();
    if (deviceState == null) return null;
    final CommitResult result;
    try {
      result = kind == PendingKind.selfUpdate
          ? await _engine().selfUpdate(deviceState, group.state)
          : await _engine().commitChange(
              deviceState,
              group.state,
              addKeyPackages: [for (final a in adds) a.keyPackage],
              removeDeviceIds: removes,
            );
    } on MlsException {
      // Nothing was stored; the group state is as it was.
      if (kind == PendingKind.change) _unbuildable.add(id);
      return null;
    }
    // Not an answer for this group's pair, or a welcome that does not go
    // with the adds: nothing of it is stored.
    if (result.epoch != group.epoch ||
        result.commit.isEmpty ||
        (result.welcome != null) != adds.isNotEmpty) {
      if (kind == PendingKind.change) _unbuildable.add(id);
      return null;
    }
    final pending = PendingCommit(
      kind: kind,
      builtOn: MlsPair(group.generation, group.epoch),
      commit: result.commit,
      welcome: result.welcome,
      welcomeDeviceIds: welcomeDeviceIds,
    );
    await v.transaction((tx) async {
      await tx.putGroup(
        GroupRecord(
          conversationId: id,
          generation: group.generation,
          epoch: group.epoch,
          state: result.groupState,
          pending: pending,
        ),
      );
      // Counted before the call, so a crash never undercounts.
      await tx.putConversationSync(
        id,
        sync.copyWith(
          commitCallsDay: istDay(_now()),
          commitCallsToday: calls + 1,
        ),
      );
    });
    return pending;
  });

  // Step 2 (the call and its answers), the discard, the count of one more
  // call, step 3 (the resume) and the scheduled resume are in the part
  // `commit_runner_send.dart`.

  // -------------------------------------------------------------------------

  Future<PipelineOp?> _op() async {
    final vault = _session.vault;
    if (vault == null) return null;
    final deviceId = await vault.deviceId();
    if (deviceId == null) return null;
    return PipelineOp(_session, vault, vault.uid, deviceId);
  }

  /// The highest stored group when none is provisional, else null.
  Future<GroupRecord?> _currentGroup(SecureVault vault, String id) async {
    final groups = await vault.groups(id);
    if (groups.isEmpty || groups.any((g) => g.provisional)) return null;
    return groups.last; // ascending generation
  }

  void _reportBug(String step) =>
      _onUnexpectedError?.call(E2eePipelineError(step), StackTrace.current);

  /// Reports a programming error (never an expected failure) by its step
  /// name only; the error itself is never passed on.
  void _reportIfBug(Object e, StackTrace s, String step) {
    if (isPipelineBug(e)) {
      _onUnexpectedError?.call(E2eePipelineError(step), s);
    }
  }
}

/// What counting one more commit call ended with
/// (`_CommitSend._countCall`).
enum _Count { counted, atCap, failed }

/// A pending commit's bytes and the time its discard margin is counted from
/// (`CommitRunner._marginStart`): the latest of its calls' starts and of
/// the ends of its calls that outlived the client's wait. No `toString`.
class _MarginStart {
  _MarginStart(this.commit, this.at);

  final Uint8List commit;
  DateTime at;

  /// Calls of these bytes that outlived the client's wait and have not
  /// ended yet (audit M2): while one runs, no margin has started.
  int running = 0;
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
