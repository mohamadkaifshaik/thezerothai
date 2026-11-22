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

/// What became of one commit of this device.
///
/// `applied`: the server stored this device's commit and the group is one
/// epoch on. `superseded`: another commit won the pair; the device caught
/// up, its own commit is gone, and the caller reconciles again on the new
/// group (a rebuilt copy of the same change is never sent from here).
/// `pending`: the outcome is not known, or the confirm could not be stored
/// yet; the pending record stays and [CommitRunner.resumePending] settles
/// it. `refused`: the server refused it and the commit was discarded.
/// `notAllowed`: no commit was made (see [CommitRunner.mayCommit]) and
/// nothing was stored.
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
///    reset).
/// 3. [resumePending], after a restart or an unknown outcome: catch-up
///    first; when the server's pair is still P, the identical bytes are sent
///    once more (a counted call).
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
  /// [schedule] runs a callback later (a timer in production): the one
  /// resume after a server-chosen retry time, at most one per conversation.
  /// It is harmless after [reset] (it only starts a resume, which reads
  /// everything fresh).
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
    void Function(Duration delay, void Function() run)? schedule,
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
       _schedule = schedule ?? ((delay, run) => Timer(delay, run)),
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
  final void Function(Duration delay, void Function() run) _schedule;
  final void Function(Object error, StackTrace stack)? _onUnexpectedError;

  /// The last RATE_LIMITED answer to a commit of this run (its retry time is
  /// for the removal queue, Task 11); null when there was none.
  RateLimitedException? lastRateLimit;

  // Memory of this run. Nothing here is a fact a write relies on: after a
  // restart a pending commit is only resent sooner.

  /// Conversation -> no commit call before this time (the server's retry
  /// time of an unknown outcome).
  final Map<String, DateTime> _notBefore = {};

  /// The conversations a resume is scheduled for (one each).
  final Set<String> _resumeScheduled = {};

  /// Sign-out or a new vault: forgets this run's memory.
  void reset() {
    lastRateLimit = null;
    _notBefore.clear();
    _resumeScheduled.clear();
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
  Future<bool> mayCommit(String conversationId, PendingKind kind) async {
    try {
      return await _allowed(conversationId, kind, hasAdds: false);
    } on Object catch (e, s) {
      _reportIfBug(e, s, 'commit.mayCommit');
      return false;
    }
  }

  Future<bool> _allowed(
    String id,
    PendingKind kind, {
    required bool hasAdds,
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
    // its cap).
    if (kind == PendingKind.change &&
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
  Future<CommitOutcome> changeLocked(
    String conversationId, {
    List<UsableClaim> adds = const [],
    List<Uint8List> removeDeviceIds = const [],
    BudgetPriority priority = BudgetPriority.background,
  }) {
    assert(
      _locks.isHeld(conversationId),
      'The caller must hold the conversation lock.',
    );
    return _commitLocked(
      conversationId,
      PendingKind.change,
      adds: adds,
      removes: removeDeviceIds,
      priority: priority,
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
  /// (the flag for an add, the daily cap, M5, a read-only thread) and was
  /// discarded, which is safe because catch-up just showed that no commit
  /// is stored at its pair. `pending`: still not known (the catch-up did
  /// not reach the server's pair, the server's retry time has not come, or
  /// the call got no answer). Takes the conversation lock. Never throws.
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
  }) async {
    final PipelineOp op;
    final PendingCommit pending;
    final String key;
    final sides = <String, ClaimSide>{};
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
        for (final a in adds) {
          final hex = hexOf(a.deviceId);
          if (_same(a.deviceId, op.deviceId) ||
              removed.contains(hex) ||
              sides.containsKey(hex)) {
            return CommitOutcome.notAllowed;
          }
          sides[hex] = a.side;
          // The server addresses a welcome by the device id as text.
          welcomeDeviceIds.add(utf8.decode(a.deviceId));
        }
      }
      if (!await _allowed(id, kind, hasAdds: adds.isNotEmpty)) {
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
      );
      if (built == null) return CommitOutcome.notAllowed;
      pending = built;
    } on BadRandom {
      _reportBug('commit.random');
      return CommitOutcome.notAllowed;
    } on Object catch (e, s) {
      // Nothing was stored: a body that threw wrote nothing.
      _reportIfBug(e, s, 'commit.build');
      return CommitOutcome.notAllowed;
    }
    _onChanged(id);
    return _send(
      op,
      id,
      pending,
      firstKey: key,
      first: true,
      tries: 2,
      sides: sides,
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
    // M5, on the record as it is in this body.
    if (kind == PendingKind.change &&
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
      return null;
    }
    // Not an answer for this group's pair, or a welcome that does not go
    // with the adds: nothing of it is stored.
    if (result.epoch != group.epoch ||
        result.commit.isEmpty ||
        (result.welcome != null) != adds.isNotEmpty) {
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

  /// Step 2: `CommitConversation` with [pending]'s exact bytes, and what
  /// each answer does. [first]: no earlier call of these bytes can have
  /// reached the server (the call follows its build in this same hold);
  /// [tries]: the calls this step may make (the call, and one resend at
  /// once of an unknown outcome). Each call's count was written before it.
  /// Never throws.
  Future<CommitOutcome> _send(
    PipelineOp op,
    String id,
    PendingCommit pending, {
    required String firstKey,
    required bool first,
    required int tries,
    required Map<String, ClaimSide> sides,
    required BudgetPriority priority,
  }) async {
    final at = pending.builtOn;
    final context = _contexts.of(id);
    String? key = firstKey;
    var isFirst = first;
    var left = tries;
    try {
      while (true) {
        if (!op.live) return CommitOutcome.pending;
        // A new 128-bit key per call (K3). The server recognises a repeat
        // by the stored bytes, not by the key.
        final callKey = key ?? hexOf(await randomOf(_engine(), 16));
        key = null;
        final MlsPair answer;
        try {
          answer = await _messaging.commitConversation(
            idempotencyKey: callKey,
            conversationId: id,
            builtOn: at,
            commit: pending.commit,
            welcome: pending.welcome,
            welcomeDeviceIds: pending.welcomeDeviceIds,
          );
        } on StaleEpochException {
          // Another commit holds the pair, or this one does (an earlier
          // call was stored): catch-up tells which.
          return await _afterCatchUp(op, id, pending, priority);
        } on AppException catch (e) {
          if (sendOutcomeUnknown(e)) {
            isFirst = false;
            left--;
            final wait = retryAfterOf(e);
            if (wait != null) {
              // The server named a time: nothing is sent before it, and
              // one resume is scheduled for it.
              _notBefore[id] = _now().add(wait);
              if (left > 0) _scheduleResume(id, wait, priority);
              return CommitOutcome.pending;
            }
            // The identical bytes once more, as one more counted call.
            if (left > 0 && await _countCall(op, id, pending.kind)) continue;
            return CommitOutcome.pending;
          }
          // A refusal. Remembered whatever becomes of the commit.
          if (e is CannotMessageException) context.canReply = false;
          if (e is RateLimitedException) lastRateLimit = e;
          // VALIDATION idempotency_key says the server holds something
          // under the key: never treated as a first call's refusal.
          if (isFirst && e is! IdempotencyKeyReusedException) {
            return await _discard(op, id, pending)
                ? CommitOutcome.refused
                : CommitOutcome.pending;
          }
          // An earlier call's outcome is unknown: never a discard before
          // catch-up showed that no commit is stored at the pair.
          return await _afterCatchUp(op, id, pending, priority, refused: true);
        }
        if (answer == at.next) {
          // The epoch is closed now: its messages are completed, then the
          // commit is confirmed and its transaction written.
          final confirmed = await _crypto.confirmOwnCommitLocked(
            id,
            at,
            ownAdds: sides,
            priority: priority,
          );
          if (!confirmed) {
            // The server holds the commit; the next catch-up confirms it
            // by its bytes.
            return CommitOutcome.pending;
          }
          _settledNow(id);
          return CommitOutcome.applied;
        }
        // A pair later than the next one (or any other answer): as
        // STALE_EPOCH.
        return await _afterCatchUp(op, id, pending, priority);
      }
    } on BadRandom {
      _reportBug('commit.random');
      return CommitOutcome.pending;
    } on Object catch (e, s) {
      // The pending record stays; the next resume settles it.
      _reportIfBug(e, s, 'commit.send');
      return CommitOutcome.pending;
    }
  }

  /// Catch-up, then what became of [pending]: `applied` when this run
  /// confirmed it by its bytes, `superseded` when the group moved on without
  /// it. Still held: `pending`, unless [refused] (the server refused a call
  /// that was not the first) and the catch-up ended at the server's pair,
  /// which shows no commit is stored at the built-on pair: then it is
  /// discarded (`refused`).
  Future<CommitOutcome> _afterCatchUp(
    PipelineOp op,
    String id,
    PendingCommit pending,
    BudgetPriority priority, {
    bool refused = false,
  }) async {
    final result = await _crypto.catchUpLocked(id, priority: priority);
    if (!op.live) return CommitOutcome.pending;
    final settled = await _settled(op.vault, id, pending);
    if (settled != null) {
      _settledNow(id);
      return settled;
    }
    if (refused && result == CatchUpResult.current) {
      return await _discard(op, id, pending)
          ? CommitOutcome.refused
          : CommitOutcome.pending;
    }
    return CommitOutcome.pending;
  }

  /// Null while the group still holds [pending] at its built-on pair.
  /// Otherwise how it ended: this run confirmed it, or it is gone.
  Future<CommitOutcome?> _settled(
    SecureVault vault,
    String id,
    PendingCommit pending,
  ) async {
    final at = pending.builtOn;
    if (await _holds(vault, id, pending) != null) return null;
    return _crypto.ownCommitConfirmedAt(id) == at
        ? CommitOutcome.applied
        : CommitOutcome.superseded;
  }

  /// The group that still holds [pending] at its built-on pair, or null.
  Future<GroupRecord?> _holds(
    SecureVault vault,
    String id,
    PendingCommit pending,
  ) async {
    final at = pending.builtOn;
    final group = await vault.group(id, at.generation);
    final held = group?.pending;
    if (group == null ||
        group.provisional ||
        group.epoch != at.epoch ||
        held == null ||
        !_same(held.commit, pending.commit)) {
      return null;
    }
    return group;
  }

  /// The commit is settled (applied or superseded): the pair moved, so a
  /// live pull of the new pair is owed before the next send or commit, and
  /// no retry time is kept.
  void _settledNow(String id) {
    _notBefore.remove(id);
    _contexts.of(id).syncedSinceStart = false;
  }

  /// Drops [pending] in ONE `runWrite` body: the group read fresh, the
  /// engine's discard, and the group state without the pending record.
  /// Only ever called when no call of these bytes can have been stored (the
  /// first call was refused, or catch-up ended at the server's pair with
  /// the record still held). False when nothing was written.
  Future<bool> _discard(PipelineOp op, String id, PendingCommit pending) async {
    try {
      final done = await _session.runWrite((v) async {
        op.check(v);
        final group = await _holds(v, id, pending);
        final deviceState = await v.deviceState();
        if (group == null || deviceState == null) return false;
        final next = await _engine().discardCommit(deviceState, group.state);
        await v.transaction(
          (tx) => tx.putGroup(
            GroupRecord(
              conversationId: id,
              generation: group.generation,
              epoch: group.epoch,
              state: next,
            ),
          ),
        );
        return true;
      });
      if (done) {
        _notBefore.remove(id);
        _onChanged(id);
      }
      return done;
    } on Object catch (e, s) {
      _reportIfBug(e, s, 'commit.discard');
      return false;
    }
  }

  /// One more commit call is about to be made: counted first, in its own
  /// transaction. False (make no call) at the day's cap for [kind], or when
  /// nothing could be written.
  Future<bool> _countCall(PipelineOp op, String id, PendingKind kind) async {
    try {
      return await _session.runWrite((v) async {
        op.check(v);
        final sync =
            (await v.conversation(id))?.sync ?? const ConversationSync();
        final calls = _callsToday(sync);
        if (calls >= _cap(kind)) return false;
        await v.transaction(
          (tx) => tx.putConversationSync(
            id,
            sync.copyWith(
              commitCallsDay: istDay(_now()),
              commitCallsToday: calls + 1,
            ),
          ),
        );
        return true;
      });
    } on Object catch (e, s) {
      _reportIfBug(e, s, 'commit.count');
      return false;
    }
  }

  // -------------------------------------------------------------------------
  // Step 3: a pending record of an earlier run

  Future<CommitOutcome> _resumeLocked(
    String id,
    BudgetPriority priority,
  ) async {
    try {
      final op = await _op();
      if (op == null) return CommitOutcome.notAllowed;
      final group = await _currentGroup(op.vault, id);
      final pending = group?.pending;
      // An init or a reset is not this runner's (Tasks 8 and 10).
      if (pending == null ||
          (pending.kind != PendingKind.change &&
              pending.kind != PendingKind.selfUpdate)) {
        return CommitOutcome.notAllowed;
      }
      // A device removed elsewhere sends and decides nothing.
      if (_removedElsewhere()) return CommitOutcome.pending;
      final result = await _crypto.catchUpLocked(id, priority: priority);
      if (!op.live) return CommitOutcome.pending;
      final settled = await _settled(op.vault, id, pending);
      if (settled != null) {
        _settledNow(id);
        return settled;
      }
      // Only at the server's pair is "no commit is stored at the built-on
      // pair" known; anything else waits for the next resume.
      if (result != CatchUpResult.current) return CommitOutcome.pending;
      final notBefore = _notBefore[id];
      if (notBefore != null && _now().isBefore(notBefore)) {
        return CommitOutcome.pending;
      }
      if (!_usable(id)) return CommitOutcome.pending;
      // May these bytes still be sent? When not (and never again today),
      // they are dropped rather than left to hold the conversation's sends:
      // the catch-up above showed the server does not hold them.
      if (!await _maySendAgain(op.vault, id, pending) ||
          !await _countCall(op, id, pending.kind)) {
        if (!await _discard(op, id, pending)) return CommitOutcome.pending;
        return CommitOutcome.notAllowed;
      }
      return await _send(
        op,
        id,
        pending,
        firstKey: hexOf(await randomOf(_engine(), 16)),
        first: false,
        tries: 1,
        sides: const {},
        priority: priority,
      );
    } on BadRandom {
      _reportBug('commit.random');
      return CommitOutcome.pending;
    } on Object catch (e, s) {
      _reportIfBug(e, s, 'commit.resume');
      return CommitOutcome.pending;
    }
  }

  /// The stored and remembered conditions of [mayCommit] that can have
  /// changed since [pending] was built (the daily cap is [_countCall]'s).
  Future<bool> _maySendAgain(
    SecureVault vault,
    String id,
    PendingCommit pending,
  ) async {
    final sync =
        (await vault.conversation(id))?.sync ?? const ConversationSync();
    if (!sync.requestAccepted) return false;
    if (!_contexts.of(id).canReply) return false;
    // A commit with a welcome adds: the flag must still be on (R1).
    if (pending.welcome != null && !_session.mayStart) return false;
    if (pending.kind == PendingKind.change &&
        await _ledger.undone(id) >= kAntiFlapUndosPerDay) {
      return false;
    }
    return true;
  }

  /// One resume of [id] at the server's retry time (at most one scheduled
  /// per conversation). Scheduled in the root zone: the callback must not
  /// read as holding the conversation lock this was called under.
  void _scheduleResume(String id, Duration wait, BudgetPriority priority) {
    if (!_resumeScheduled.add(id)) return;
    Zone.root.run(
      () => _schedule(wait, () {
        _resumeScheduled.remove(id);
        unawaited(resumePending(id, priority: priority));
      }),
    );
  }

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

/// Constant-time equality of two byte lists (the length is not secret).
bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}
