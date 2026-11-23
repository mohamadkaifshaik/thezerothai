import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../../../../core/crypto/crypto_engine.dart';
import '../../../../core/crypto/crypto_types.dart';
import '../../../../core/crypto/guarded_crypto_engine.dart';
import '../../../../core/network/app_exception.dart';
import '../../../../core/vault/secure_vault.dart';
import '../../../../core/vault/vault_session.dart';
import '../../../../gen/dzeroth/keys/v1/keys.pb.dart' as kpb;
import '../../../keys/data/keys_repository.dart';
import '../../data/messaging_repository.dart';
import 'commit_runner.dart';
import 'conversation_context.dart';
import 'conversation_crypto.dart';
import 'conversation_locks.dart';
import 'daily_ledger.dart';
import 'device_directory.dart';
import 'device_key_history.dart';
import 'e2ee_types.dart';
import 'former_pins.dart';
import 'known_conversations.dart';
import 'membership_rules.dart';
import 'message_receiver.dart';
import 'pipeline_support.dart';
import 'sync_budget.dart';

part 'membership_upkeep_reconcile.dart';

const FormerPins _former = FormerPins();

/// Review I-A, audit L1 (controller ruling C): a re-check armed because a
/// change did not land may arm one more when it does not land either, up
/// to this many chained re-checks per conversation. After that the
/// outside triggers (Task 13: an open, a send, the app's resume) take
/// over, each of which starts a new chain. Bounded, so no loop.
const int kMaxChainedRechecks = 3;

/// Membership commits of this device and the request rules (Task 9 step
/// 9b; M1 to M4, R9, the R7 lost-send rule, R10, security read H2):
/// [reconcile] keeps the group's members equal to the devices the key
/// directory lists, [selfUpdateIfDue] renews this device's leaf, and
/// [acceptForReply] / [onAccepted] are the acceptance of a request. Every
/// commit goes through the [CommitRunner].
///
/// **Request rules (R10, pilot gate 5.3).** While the stored sync record
/// does not say `requestAccepted`, [reconcile], [selfUpdateIfDue] and the
/// removal queue return at once, with no list call and no commit.
///
/// **Where acceptance comes from.** The user's reply ([acceptForReply],
/// the sender's last gate, only from a [BudgetPriority.user] drain), the
/// user's own accept (Task 13 wires `MessagingRepository.onRequestAccepted`
/// to [onAccepted]), and the server's word: a `ListMessages` header or an
/// inbox row saying ACCEPTED while the stored record does not
/// ([noteAcceptedSeen], brief amendment 1; Task 13 sets it as
/// `ConversationContexts.onAcceptedSeen`). A `SendMessage` answer is never
/// one (amendment 2): its direction and state are not taken
/// (`ConversationContexts.note(peerOnly: true)`), and neither is a cached
/// row (review m5: only rows read from the server in this run count).
///
/// **The re-check timer (amendment 10).** At most one per conversation,
/// through the injected [schedule], keeping the EARLIEST due time (a later
/// re-check never delays an earlier one, review N3); cancelled by
/// [cancelScheduled] (the app is paused) and [reset] (sign-out). A paused
/// app re-checks at its next trigger. No loop.
///
/// **After an own commit (review I1).** A settled commit of this device
/// moves the pair, and no commit may follow until a live pull of the new
/// pair (`syncedSinceStart`). The pull takes the conversation lock itself,
/// so only the unheld [reconcile] can make it: after its pass's commit (or
/// resume) answered `applied` or `superseded`, it pulls between two holds
/// and runs ONE more pass. The re-check pulls first when not synced.
///
/// **A change that did not land (review I-A, audit L1, review m-1;
/// controller ruling C).** A pass that decided a change (or found one
/// pending) whose commit did not land arms one earliest-due re-check: the
/// change is left `pending` (due at the runner's not-before, else
/// [kRequestInFlightMargin] on), `superseded` with no further pass of its
/// own coming, `refused` (RATE_LIMITED: due at the server's retry time),
/// decided while not synced, or the live pull between the two passes
/// failed (each due [kPeerRemovalFetchGap] on). Why: a removal must not
/// wait for the user to reopen the conversation. A re-check that does not
/// land either arms one more, up to [kMaxChainedRechecks] chained ones;
/// then the outside triggers take over. Bounded, so it cannot loop.
///
/// Locking (plan "Global Constraints"): the public entries take the
/// conversation lock; the `...Locked` variants are for a caller that holds
/// it (the sender's drain). RPCs run under the lock and outside `runWrite`;
/// the ledger is asked before or after a body, never inside one.
///
/// Never logs; an unexpected failure is reported as [E2eePipelineError]
/// with a step name only. Defines no `toString`.
class MembershipUpkeep {
  /// [ownUserId]: the caller's own user reference as the client holds it
  /// (the own-side claim); null or empty: no own device is claimed.
  /// [removedElsewhere]: Task 12's fact. [schedule]: runs a callback later
  /// and answers a handle that cancels it (a [Timer] in production).
  MembershipUpkeep({
    required CommitRunner commits,
    required MessageReceiver receiver,
    required DailyLedger ledger,
    required ConversationCrypto crypto,
    required VaultSession session,
    required CryptoEngine Function() engine,
    required MessagingRepository messaging,
    required KeysRepository keys,
    required DeviceDirectory directory,
    required KnownConversations known,
    required ConversationLocks locks,
    required ConversationContexts contexts,
    required DateTime Function() now,
    required void Function(String conversationId) onChanged,
    required String? Function() ownUserId,
    required bool Function() removedElsewhere,
    void Function() Function(Duration delay, void Function() run)? schedule,
    void Function(Object error, StackTrace stack)? onUnexpectedError,
  }) : _commits = commits,
       _receiver = receiver,
       _ledger = ledger,
       _crypto = crypto,
       _session = session,
       _engine = engine,
       _messaging = messaging,
       _keys = keys,
       _directory = directory,
       _known = known,
       _locks = locks,
       _contexts = contexts,
       _now = now,
       _onChanged = onChanged,
       _ownUserId = ownUserId,
       _removedElsewhere = removedElsewhere,
       _schedule = schedule ?? ((delay, run) => Timer(delay, run).cancel),
       _onUnexpectedError = onUnexpectedError;

  final CommitRunner _commits;
  final MessageReceiver _receiver;
  final DailyLedger _ledger;
  final ConversationCrypto _crypto;
  final VaultSession _session;
  final CryptoEngine Function() _engine;
  final MessagingRepository _messaging;
  final KeysRepository _keys;
  final DeviceDirectory _directory;

  /// The app's one [KnownConversations]: its stored, first-write peer
  /// reference is the one a removal is decided against (audit L3).
  final KnownConversations _known;
  final ConversationLocks _locks;
  final ConversationContexts _contexts;
  final DateTime Function() _now;
  final void Function(String conversationId) _onChanged;
  final String? Function() _ownUserId;
  final bool Function() _removedElsewhere;
  final void Function() Function(Duration delay, void Function() run) _schedule;
  final void Function(Object error, StackTrace stack)? _onUnexpectedError;

  /// Task 11: the device ids queued for removal in a conversation. Each
  /// one that is a member is removed by the next [reconcile] (the
  /// acceptance's reconcile too, in its one commit; review I1 b).
  Set<Uint8List> Function(String conversationId)? queuedRemovals;

  /// Task 11 fix round 2, ruling 1: the signature key the fresh own list
  /// showed when the user removed [deviceId] (its "removed by the user"
  /// mark), or null without such a mark. A queued id pinned `unattributed`
  /// with exactly that key is the user's removed device, so it is removed:
  /// RemoveKeyDevice took it out of the own list, and no list can attribute
  /// it any more.
  Uint8List? Function(Uint8List deviceId)? removedKeyOf;

  /// Task 11 fix round 2, ruling 11: [deviceId] has a "removed by the
  /// user" mark. Only such a queued removal is exempt from the M5 pause
  /// (ruling H); the queue also holds own devices the own list no longer
  /// shows, which no user removed here. Null: none is.
  bool Function(Uint8List deviceId)? removedByUser;

  /// Conversation -> the one scheduled re-check, with its due time.
  final Map<String, _Recheck> _rechecks = {};

  /// Conversation -> the acceptance a header's ACCEPTED started.
  final Map<String, Future<void>> _sights = {};

  /// The re-checks whose timer fired and that are still running.
  final Set<Future<void>> _recheckRuns = {};

  /// Task 9 ruling O. Conversation -> no add is claimed before this time:
  /// the server's retry time of a RATE_LIMITED change that carried adds.
  /// Memory of this run (a restart only claims sooner); removals are never
  /// held by it.
  final Map<String, DateTime> _addsNotBefore = {};

  /// The app is paused: the re-check timers are cancelled (no network call
  /// while paused). Each conversation re-checks at its next trigger.
  void cancelScheduled() {
    final all = _rechecks.values.toList();
    _rechecks.clear();
    for (final r in all) {
      r.cancel();
    }
  }

  /// Sign-out or a new vault: every timer is cancelled and this run's
  /// memory forgotten.
  void reset() {
    cancelScheduled();
    _sights.clear();
    _addsNotBefore.clear();
  }

  /// Completes when no acceptance a header started, and no re-check whose
  /// timer fired, is running.
  @visibleForTesting
  Future<void> idle() async {
    while (_sights.isNotEmpty || _recheckRuns.isNotEmpty) {
      await Future.wait([..._sights.values, ..._recheckRuns]);
    }
  }

  // -------------------------------------------------------------------------
  // The public entries

  /// M3, M4, M2's removal and M1 for one conversation, then the self-update
  /// check (steps 1-5 of the plan's `reconcile`). A no-op, with no list
  /// call, unless the conversation is accepted (R10). A pending commit is
  /// settled first ([CommitRunner.resumePendingLocked]); `pending` ends
  /// here. When the pass's commit or resume answered `applied` or
  /// `superseded`, ONE live pull of the new pair runs between two holds and
  /// then ONE more pass on the caught-up group (no rebuilt add is sent;
  /// review I1 a). Takes the conversation lock (never call it with the lock
  /// held). Never throws.
  Future<void> reconcile(
    String conversationId, {
    BudgetPriority priority = BudgetPriority.background,
  }) => _reconcileUnheld(conversationId, priority, recheck: false);

  // Review m-5: no held `reconcileLocked` or `selfUpdateIfDueLocked` entry.
  // Nothing called them, and a held reconcile cannot pull, so it is the
  // weaker entry; the acceptance steps reach the held pass privately. Task
  // 13 wires the unheld [reconcile] and [selfUpdateIfDue].

  /// R9 and the R7 follow-up. Called when the conversation is opened and
  /// after a successful send in it (Task 13's wiring), and from
  /// [reconcile]'s step 4; never from a timer. Due when the last renewal is
  /// [kSelfUpdateEvery] old (a record with no time counts as renewed when
  /// first seen, audit L7), or, once per IST day, when a
  /// lost send left `epochMustAdvance` set and catch-up applied no commit.
  /// Always under [CommitRunner.mayCommit] (the 10-call rule). A no-op,
  /// with no list call, unless accepted. Takes the conversation lock.
  /// Never throws.
  Future<void> selfUpdateIfDue(
    String conversationId, {
    BudgetPriority priority = BudgetPriority.background,
  }) => _locks.run(
    conversationId,
    () => _selfUpdateGuarded(conversationId, priority, caughtUp: false),
  );

  /// R10: the conversation became accepted (the user accepted, or the
  /// server said so). In this order, before any encrypt: `requestAccepted`
  /// (sticky) with the own-device alerts of H2, in one transaction; the
  /// removal clock (`acceptedSeenAt`) and the direction in memory;
  /// attribution (rows are written from now on); [reconcile], whose ONE
  /// commit also carries the queued removals (review I1 b: a separate
  /// queued-removal commit would leave the reconcile unsynced, so it could
  /// commit nothing). Peer-side
  /// and unattributed removals wait for the removal clock (60 s after
  /// acceptance, then 2 minutes). Takes the conversation lock. Never
  /// throws.
  Future<void> onAccepted(
    String conversationId, {
    BudgetPriority priority = BudgetPriority.background,
  }) => _locks.run(conversationId, () async {
    try {
      await _onAcceptedLocked(conversationId, priority);
    } on Object catch (e, s) {
      _reportIfBug(e, s, 'upkeep.onAccepted');
    }
  });

  /// The acceptance an encrypted reply needs: `AcceptMessageRequest` for an
  /// unaccepted incoming request, then [onAccepted]'s steps. Takes the
  /// conversation lock. See [acceptForReplyLocked].
  Future<void> acceptForReply(
    String conversationId, {
    required BudgetPriority priority,
  }) => _locks.run(
    conversationId,
    () => _acceptForReplyLocked(conversationId, priority),
  );

  /// [acceptForReply] for a caller that ALREADY HOLDS the conversation lock:
  /// the sender's `acceptForReplyLocked` seam (Task 7's contract).
  ///
  /// Refused (a [StateError], with no call) unless: [priority] is
  /// [BudgetPriority.user] (brief amendment 5, audit M3: only the user's
  /// own send accepts; Task 13b's send path supplies it); the conversation
  /// is not accepted yet; a `ListMessages` header or an inbox row of THIS
  /// run showed it in this user's Requests folder (amendment 2: never the
  /// direction a send answer reported); the thread can be answered.
  ///
  /// Throws on any failure and has then changed nothing: a refused or
  /// failed `AcceptMessageRequest` writes no state and runs no acceptance
  /// step (amendment 4; the row waits). Its one RPC is bounded by
  /// [kMlsRpcTimeout]. On success the acceptance steps have run; when the
  /// server accepted but the steps could not store `requestAccepted` (the
  /// vault closed), it throws too, and the next header's ACCEPTED runs
  /// them. The accept-failure backoff (Task 7 review m2) is not built.
  Future<void> acceptForReplyLocked(
    String conversationId, {
    required BudgetPriority priority,
  }) {
    assert(
      _locks.isHeld(conversationId),
      'The caller must hold the conversation lock.',
    );
    return _acceptForReplyLocked(conversationId, priority);
  }

  /// Brief amendment 1 (Task 13 sets this as
  /// `ConversationContexts.onAcceptedSeen`): a `ListMessages` header or an
  /// inbox row said ACCEPTED. The acceptance steps run on the FIRST such
  /// sight for a conversation whose stored `requestAccepted` is false, not
  /// only on a transition this run observed (a settle without a server
  /// answer, Task 8's expiry and join paths, leaves it false and writes no
  /// own-device alert). At most one per conversation at a time, at
  /// background priority, after the caller let go of the lock (it runs in
  /// the root zone and waits for the lock). Returns at once.
  void noteAcceptedSeen(String conversationId) {
    if (_sights.containsKey(conversationId)) return;
    final run = Zone.root.run(
      () =>
          _locks.run(conversationId, () => _sawAcceptedLocked(conversationId)),
    );
    _sights[conversationId] = run;
    unawaited(
      run.whenComplete(() {
        if (identical(_sights[conversationId], run)) {
          _sights.remove(conversationId);
        }
      }),
    );
  }

  // -------------------------------------------------------------------------
  // Acceptance

  Future<void> _sawAcceptedLocked(String id) async {
    try {
      final vault = _session.vault;
      if (vault == null || _removedElsewhere()) return;
      final record = await vault.conversation(id);
      if (record?.sync.requestAccepted ?? false) {
        _contexts.of(id).acceptanceSettled = true;
        return;
      }
      // Only a conversation this vault keeps encrypted state for: a
      // plaintext conversation gets no sync record from a header.
      if (record == null && (await vault.groups(id)).isEmpty) return;
      await _onAcceptedLocked(id, BudgetPriority.background);
    } on Object catch (e, s) {
      _reportIfBug(e, s, 'upkeep.acceptedSeen');
    }
  }

  Future<void> _acceptForReplyLocked(String id, BudgetPriority priority) async {
    if (priority != BudgetPriority.user) {
      throw StateError('An accept needs the user\'s own send.');
    }
    if (_removedElsewhere()) throw StateError('Removed elsewhere.');
    final vault = _session.vault;
    if (vault == null) throw StateError('The vault is not ready.');
    if ((await vault.conversation(id))?.sync.requestAccepted ?? false) {
      // Accepted meanwhile: nothing to ask; the sender reads every gate.
      return;
    }
    final context = _contexts.of(id);
    if (context.incomingRequest != true ||
        !context.requestSeenInHeader ||
        !context.canReply) {
      throw StateError('No incoming request a header showed.');
    }
    final key = hexOf(await randomOf(_engine(), 16));
    // Nothing is written before the answer: a failure changes nothing.
    await _messaging
        .acceptMessageRequest(idempotencyKey: key, conversationId: id)
        .timeout(
          kMlsRpcTimeout,
          onTimeout: () => throw const NetworkException('timed out'),
        );
    if (!await _onAcceptedLocked(id, priority)) {
      throw StateError('The acceptance could not be stored.');
    }
  }

  /// False when `requestAccepted` could not be stored (nothing else ran).
  Future<bool> _onAcceptedLocked(String id, BudgetPriority priority) async {
    final mark = await _crypto.markAcceptedLocked(id, priority: priority);
    if (mark == AcceptanceMark.unavailable) return false;
    final context = _contexts.of(id)
      ..incomingRequest = false
      ..requestSeenInHeader = false
      ..acceptanceSettled = true;
    if (mark == AcceptanceMark.marked) {
      // The removal clock starts now (60 s, then 2 minutes).
      context.acceptedSeenAt = _now();
    } else {
      context.acceptedSeenAt ??= _now();
    }
    // The queued removals go in reconcile's one commit, after attribution
    // (the H2 alerts are already in the mark's transaction).
    await _crypto.attributeMembersLocked(id, priority: priority);
    await _reconcileLocked(id, priority, recheck: false);
    return true;
  }

  // -------------------------------------------------------------------------
  // Self-update (R9, R7)

  Future<void> _selfUpdateGuarded(
    String id,
    BudgetPriority priority, {
    required bool caughtUp,
  }) async {
    try {
      await _selfUpdateLocked(id, priority, caughtUp: caughtUp);
    } on Object catch (e, s) {
      _reportIfBug(e, s, 'upkeep.selfUpdate');
    }
  }

  /// [caughtUp]: the caller's catch-up of this hold just answered
  /// `current` (reconcile's step 4).
  Future<void> _selfUpdateLocked(
    String id,
    BudgetPriority priority, {
    required bool caughtUp,
  }) async {
    final vault = _session.vault;
    if (vault == null || _removedElsewhere()) return;
    var sync = (await vault.conversation(id))?.sync;
    // R10: nothing, and no call, while unaccepted.
    if (sync == null || !sync.requestAccepted) return;
    if (sync.lastSelfUpdateAtMicros == null) await _stampRenewal(id);
    if (!_selfUpdateWanted(sync, await _lostSendLeft(id, sync))) return;
    if (!caughtUp) {
      final caught = await _crypto.catchUpLocked(id, priority: priority);
      if (caught != CatchUpResult.current) return;
      if (!identical(_session.vault, vault)) return;
      sync = (await vault.conversation(id))?.sync;
      if (sync == null) return;
    }
    // R7: `epochMustAdvance` still set means the catch-up applied no
    // commit (every applied commit clears it).
    final lostSend = await _lostSendLeft(id, sync);
    if (!_selfUpdateWanted(sync, lostSend)) return;
    if (!await _commits.mayCommit(id, PendingKind.selfUpdate)) return;
    if (lostSend) {
      // Spent before the call, so a failure never repeats it today. After
      // it, nothing more until any commit clears the flag or the next IST
      // day.
      await _ledger.markLostSendUpdate(id);
    }
    await _commits.selfUpdateLocked(id, priority: priority);
  }

  /// Audit L7 (ruling K). A group's own leaf is fresh when it is created:
  /// the init settle (Task 8, `_settleOwnInitIn`) and the join
  /// (`conversation_join.dart`) store `lastSelfUpdateAtMicros` in their
  /// transactions, so a new conversation is not due at its first
  /// reconcile. Decision: those two stamps, not the group's creation time
  /// (a settled group record keeps none). A record without the time (one
  /// written before the stamps, or by a path that has none) counts as
  /// renewed when first seen: the time is stored now, so both sides do not
  /// self-update at their first reconcile, and the 30 days start then.
  bool _selfUpdateWanted(ConversationSync sync, bool lostSend) {
    if (lostSend) return true;
    final last = sync.lastSelfUpdateAtMicros;
    if (last == null) return false;
    final at = DateTime.fromMicrosecondsSinceEpoch(last, isUtc: true);
    return !_now().difference(at).isNegative &&
        _now().difference(at) >= kSelfUpdateEvery;
  }

  Future<bool> _lostSendLeft(String id, ConversationSync sync) async =>
      sync.epochMustAdvance && !await _ledger.lostSendUpdateDone(id);

  /// Stores `lastSelfUpdateAtMicros = now` for [id] when the record, read
  /// fresh in ONE `runWrite` body, still has none (see
  /// [_selfUpdateWanted]). A failed write changes nothing; the next look
  /// tries again.
  Future<void> _stampRenewal(String id) async {
    final vault = _session.vault;
    if (vault == null) return;
    try {
      await _session.runWrite((v) async {
        if (!identical(v, vault)) return;
        final sync = (await v.conversation(id))?.sync;
        if (sync == null || sync.lastSelfUpdateAtMicros != null) return;
        await v.transaction(
          (tx) => tx.putConversationSync(
            id,
            sync.copyWith(
              lastSelfUpdateAtMicros: _now().microsecondsSinceEpoch,
            ),
          ),
        );
      });
    } on Object catch (e, s) {
      _reportIfBug(e, s, 'upkeep.stampRenewal');
    }
  }

  // -------------------------------------------------------------------------
  // The re-check timer

  /// One re-check of [id] at [at], unless one is due no later. [depth]:
  /// how many re-checks chained for a change that did not land this one
  /// is (0 for one that waits on a clock, `kUnattributedRecheck` or the
  /// peer fetch gap; see [kMaxChainedRechecks]).
  void _scheduleRecheck(String id, DateTime at, {int depth = 0}) {
    final existing = _rechecks[id];
    if (existing != null && !existing.at.isAfter(at)) return;
    existing?.cancel();
    var delay = at.difference(_now());
    if (delay.isNegative) delay = Duration.zero;
    late final _Recheck entry;
    // In the root zone: the callback must not read as holding the lock of
    // whoever scheduled it.
    final cancel = Zone.root.run(
      () => _schedule(delay, () {
        if (!identical(_rechecks[id], entry)) return;
        _rechecks.remove(id);
        // Unheld: it may pull first (review I1 c).
        final run = _reconcileUnheld(
          id,
          BudgetPriority.background,
          recheck: true,
          depth: depth,
        );
        _recheckRuns.add(run);
        unawaited(run.whenComplete(() => _recheckRuns.remove(run)));
      }),
    );
    entry = _Recheck(at, cancel);
    _rechecks[id] = entry;
  }

  // -------------------------------------------------------------------------

  void _reportIfBug(Object e, StackTrace s, String step) {
    if (isPipelineBug(e)) {
      _onUnexpectedError?.call(E2eePipelineError(step), s);
    }
  }
}

/// One scheduled re-check: its due time and the handle that cancels it. No
/// `toString`.
class _Recheck {
  _Recheck(this.at, this.cancel);

  final DateTime at;
  final void Function() cancel;
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
