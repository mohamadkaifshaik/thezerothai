import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../../../../core/crypto/crypto_engine.dart';
import '../../../../core/crypto/crypto_types.dart';
import '../../../../core/crypto/mls_derivations.dart';
import '../../../../core/crypto/mls_pair.dart';
import '../../../../core/network/app_exception.dart';
import '../../../../core/vault/secure_vault.dart';
import '../../../../core/vault/vault_session.dart';
import '../../../../gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;
import '../../data/messaging_repository.dart';
import '../conversation_id.dart';
import 'conversation_context.dart';
import 'conversation_crypto.dart';
import 'conversation_locks.dart';
import 'e2ee_types.dart';
import 'message_content_codec.dart';
import 'message_receiver.dart';
import 'pipeline_support.dart';
import 'sync_budget.dart';

part 'encrypted_sender_rows.dart';
part 'encrypted_sender_send.dart';
part 'encrypted_sender_support.dart';

/// `STALE_EPOCH` answers handled in one drain; then the row waits for the
/// next trigger (Open question 4's default).
const int kStaleEpochRoundsPerDrain = 3;

/// The longest ciphertext an outbox row holds (shared with the starter).
const int _kMaxOutboxCiphertext = kMaxOutboxCiphertext;

/// Sending encrypted messages (Task 7, R7; security reads M1, M3, M10): a
/// durable outbox in the vault, the gates before an encrypt, the send, and
/// what each answer does to the row.
///
/// A row is saved at stage `plain` ([enqueue]), encrypted only when every
/// gate holds, saved at stage `encrypted` in the transaction that stores
/// the group state the engine returned, then checked with
/// [SecureVault.confirmStored]. Android has a durable commit here. On the
/// web, persistence before send remains a stated limit. A stage-`encrypted` row
/// is resent byte for byte under the same key until the server answers; it
/// goes back to stage `plain` only after a `STALE_EPOCH` whose catch-up
/// moved this device's pair past the one it was encrypted for. Audit M2 (a
/// ruling): it is not sent, for the first time or again, while a member is
/// unattributed (an unknown device is) or attribution is pending; it is
/// never encrypted again for that, and the same bytes go out once the
/// condition clears. `epochMustAdvance` holds no resend.
///
/// Keys. Every ciphertext goes out under a key made for it at the encrypt
/// (16 random bytes as 32 hex), never under the key its plain row was
/// stored with: a row put back to `plain` by any code (this class, a join
/// that discards a provisional group) can then never reuse a key that was
/// on the wire. The local id never changes and is never sent.
///
/// Locking (plan "Global Constraints"). [drain] works in steps, each one
/// hold of the conversation lock: the gates, the locked catch-up, the
/// acceptance, the encrypt (ONE `runWrite` body: fresh reads, the engine
/// call, ONE transaction) and the send RPC all run under it. The live pull
/// takes that lock itself, so it runs BETWEEN two steps, never inside one;
/// everything is read fresh again in the step after it. [enqueue] takes no
/// conversation lock (it must not wait behind a send in flight): it adds a
/// row under a new key in its own `runWrite` body.
///
/// A conversation this device has no group for: the row waits
/// (`waitingForWelcome`). Whether a conversation that is not encrypted yet
/// starts encryption or goes out in plaintext is decided before [enqueue]
/// (Task 8's routing, used by Task 13b); nothing is enqueued here for it.
///
/// Rows that carry an `init` (the first message of a provisional group) are
/// Task 8's: this class sends, retries and discards none of them, and
/// nothing behind one.
///
/// Never logs; an unexpected failure is reported as [E2eePipelineError]
/// with a step name only. Defines no `toString`.
class EncryptedSender {
  /// [acceptForReplyLocked] is Task 9's `acceptForReply` for a caller that
  /// HOLDS the conversation lock (`AcceptMessageRequest`, then the
  /// acceptance steps: `requestAccepted` with the own-device alerts,
  /// attribution, then reconcile, whose one commit also carries the queued
  /// removals). A throw leaves the row waiting; partial progress is safe
  /// (every gate is read again before an encrypt). It must bound its own
  /// waits: it runs under the conversation lock. It is handed the drain's
  /// priority and is called only from a [BudgetPriority.user] drain (Task 9
  /// brief amendment 5, audit M3: the user's intent to reply accepts; a
  /// background trigger never does). Task 13b's send path supplies the
  /// user priority; every automatic trigger (a push, a poll) must drain
  /// with [BudgetPriority.background], and the scheduled resend below
  /// never drains at user priority (a user drain's resend runs at
  /// [BudgetPriority.live], review m1).
  ///
  /// [removedElsewhere] is Task 12's fact: this device was removed from the
  /// account on another device (nothing is encrypted or sent while true).
  ///
  /// [schedule] runs a callback later (a timer in production): the one
  /// automatic resend after a server-chosen retry time. It returns `void`:
  /// a scheduled callback cannot be cancelled, and it is harmless after
  /// [reset] (it only starts a drain, which reads everything fresh).
  EncryptedSender({
    required ConversationCrypto crypto,
    required MessageReceiver receiver,
    required VaultSession session,
    required CryptoEngine Function() engine,
    required MessagingRepository messaging,
    required ConversationLocks locks,
    required ConversationContexts contexts,
    required DateTime Function() now,
    required void Function(String conversationId) onChanged,
    required Future<void> Function(
      String conversationId, {
      required BudgetPriority priority,
    })
    acceptForReplyLocked,
    required bool Function() removedElsewhere,
    void Function(Duration delay, void Function() run)? schedule,
    void Function(Object error, StackTrace stack)? onUnexpectedError,
  }) : _crypto = crypto,
       _receiver = receiver,
       _session = session,
       _engine = engine,
       _messaging = messaging,
       _locks = locks,
       _contexts = contexts,
       _now = now,
       _onChanged = onChanged,
       _acceptForReply = acceptForReplyLocked,
       _removedElsewhere = removedElsewhere,
       _schedule = schedule ?? ((delay, run) => Timer(delay, run)),
       _onUnexpectedError = onUnexpectedError;

  final ConversationCrypto _crypto;
  final MessageReceiver _receiver;
  final VaultSession _session;
  final CryptoEngine Function() _engine;
  final MessagingRepository _messaging;
  final ConversationLocks _locks;
  final ConversationContexts _contexts;
  final DateTime Function() _now;
  final void Function(String conversationId) _onChanged;
  final Future<void> Function(
    String conversationId, {
    required BudgetPriority priority,
  })
  _acceptForReply;
  final bool Function() _removedElsewhere;
  final void Function(Duration delay, void Function() run) _schedule;
  final void Function(Object error, StackTrace stack)? _onUnexpectedError;

  // Memory of this run, by conversation id or local id. Nothing here is a
  // fact a write relies on: after a restart a row is only resent sooner.

  /// The drain running per conversation (single flight), and the
  /// conversations a trigger came for while theirs ran, each with the
  /// strongest priority asked (the rerun's).
  final Map<String, Future<void>> _running = {};
  final Map<String, BudgetPriority> _again = {};

  /// Local id -> the typed refusal of its last send.
  final Map<String, AppException> _errors = {};

  /// Local ids whose outcome stayed unknown after the automatic resend:
  /// each later trigger makes one attempt.
  final Set<String> _unknown = {};

  /// The step names [_reportOnce] reported in this run.
  final Set<String> _reported = {};

  /// Local id -> no send before this time (the server's retry time).
  final Map<String, DateTime> _notBefore = {};

  /// Local id -> the send calls made for it in this run (a discard's live
  /// pull is only proof while no call was made after it began).
  final Map<String, int> _sendCalls = {};

  /// Conversation -> why its last drain stopped at a row no gate explains
  /// (the barrier, a failed accept, the round cap).
  final Map<String, SendBlock> _held = {};

  /// Conversation -> the local ids a send was made for in this run (only
  /// these have entries above); [_forgetGone] drops those whose row is gone.
  final Map<String, Set<String>> _sentFor = {};

  /// Sign-out or a new vault: forgets this run's memory.
  void reset() {
    _again.clear();
    _sentFor.clear();
    _errors.clear();
    _unknown.clear();
    _reported.clear();
    _notBefore.clear();
    _sendCalls.clear();
    _held.clear();
  }

  /// Task 8: the typed refusal of the row [localId], whose init the server
  /// refused (the row is stored failed, at stage `plain`, under its
  /// conversation id). Memory only, as every typed error here: [outgoing]
  /// shows it while this run remembers it.
  void rememberRefusal(String localId, AppException error) =>
      _errors[localId] = error;

  /// Task 8 (review F3): the row [localId] is an init row again (a new
  /// start took it), so the typed error of its earlier failure is
  /// forgotten. Why: [retry] returns at a row with an init before it
  /// clears anything, and a later failure with no typed error of its own
  /// would otherwise be shown with the old one. Memory only.
  void forgetRefusal(String localId) => _errors.remove(localId);

  // -------------------------------------------------------------------------
  // The public entries

  /// Saves a stage-plain row in the vault under the caller's [localId] (the
  /// port's `send(localId:)`, a UUID from the composer), then starts
  /// [drain] without waiting for it. No engine state call (the CSPRNG only:
  /// the report key and the row's key) and no RPC. [ArgumentError] when an
  /// unsent row already has that local id, the conversation id is invalid,
  /// or the content is over [kMaxMessageContentBytes]; [StateError] when
  /// the vault is not ready, or when the random source answers another
  /// length than was asked (audit L6). A random-source failure propagates.
  /// Nothing is saved in any of these cases.
  Future<void> enqueue({
    required String localId,
    required String conversationId,
    required String text,
    String sharedPostId = '',
  }) async {
    if (localId.isEmpty) throw ArgumentError('A row needs a local id.');
    if (!isConversationId(conversationId)) {
      throw ArgumentError('Invalid conversation id.');
    }
    final Uint8List reportKey;
    final String key;
    try {
      reportKey = await _random(kReportKeyBytes);
      key = _hexOf(await _random(16));
    } on _BadRandom {
      throw StateError('The random source answered another length.');
    }
    // The report key and the exact bytes are fixed here, once.
    final content = encodeMessageContent(
      text: text,
      sharedPostId: sharedPostId,
      reportKey: reportKey,
    );
    final op = await _start();
    if (op == null) throw StateError('The vault is not ready.');
    await _session.runWrite((v) async {
      if (!op.owns(v)) throw StateError('The vault is not ready.');
      final rows = (await v.outbox()).items;
      if (rows.any((r) => r.localId == localId)) {
        throw ArgumentError('An unsent row already has this local id.');
      }
      // Strictly after every waiting row of the conversation: rows go out
      // in the order they were saved, whatever their keys.
      var at = _now().microsecondsSinceEpoch;
      for (final r in rows) {
        if (r.conversationId == conversationId && r.createdAtMicros >= at) {
          at = r.createdAtMicros + 1;
        }
      }
      await v.transaction(
        (tx) => tx.putOutbox(
          OutboxItem(
            idempotencyKey: key,
            localId: localId,
            expectedMessageId: expectedMessageId(v.uid, key),
            conversationId: conversationId,
            generation: 0,
            epoch: 0,
            ciphertext: Uint8List(0),
            reportCommitment: Uint8List(0),
            content: content,
            createdAtMicros: at,
            stage: OutboxStage.plain,
          ),
        ),
      );
    });
    _onChanged(conversationId);
    // The user's own send (the composer's): user priority.
    unawaited(drain(conversationId, priority: BudgetPriority.user));
  }

  /// Encrypts and sends [conversationId]'s waiting rows in order. Returns
  /// when the head row cannot go now. Single flight: a call while a drain
  /// runs joins it, and that drain runs once more when it ends, with the
  /// strongest priority the joining calls asked for (a user's send that
  /// joins a background drain does not wait on the background budget).
  /// Takes the conversation lock (never call it with the lock held). Never
  /// throws.
  ///
  /// [priority] defaults to [BudgetPriority.background] (review m2): a
  /// user-priority drain may accept an incoming request (amendment 5), so
  /// only the user's own send and retry pass [BudgetPriority.user], and a
  /// caller that forgets the argument fails safe.
  Future<void> drain(
    String conversationId, {
    BudgetPriority priority = BudgetPriority.background,
  }) {
    final running = _running[conversationId];
    if (running != null) {
      _again[conversationId] = _stronger(_again[conversationId], priority);
      return running;
    }
    return _running[conversationId] = _drainAll(conversationId, priority);
  }

  /// Completes when no drain of [conversationId] is running (at once when
  /// none is). Starts none.
  @visibleForTesting
  Future<void> settled(String conversationId) =>
      _running[conversationId] ?? Future<void>.value();

  /// How many per-row entries this run's memory holds (errors, unknown
  /// outcomes, retry times, send counts). A count only.
  @visibleForTesting
  int get memoryEntries =>
      _errors.length + _unknown.length + _notBefore.length + _sendCalls.length;

  /// The user's retry of the row [localId]: a failed row is sent again with
  /// the same bytes, a waiting row is encrypted when it now may. An unknown
  /// id, and a thread that cannot be answered, are a no-op. The body is in
  /// the part `encrypted_sender_rows.dart`.
  Future<void> retry(String localId) => _retryRow(localId);

  /// Deletes the row [localId] when, as far as this device knows, the
  /// server has not accepted it. A stage-`plain` row was never sent. A
  /// stage-`encrypted` row may have been accepted: it goes only after one
  /// live pull that completed and found no echo (an echo completes the row
  /// instead; a pull that could not complete leaves it).
  ///
  /// Review F1 (Task 8, fix round 2), binding for Task 13b: this calls
  /// nothing of the starter. After a discard, Task 13b calls
  /// `GroupStarter.retryStart` for the local id of the conversation's new
  /// oldest row, so a row that waited behind the discarded one can start
  /// encryption (a no-op when that row is failed or needs no new start).
  /// The body is in the part `encrypted_sender_rows.dart`.
  Future<void> discard(String localId) => _discardRow(localId);

  /// The waiting rows of [conversationId], oldest first: `failed` (the
  /// typed error only while this run remembers it), `sending` (stage
  /// encrypted and not held by audit M2) or `waiting` with the gate that
  /// holds it. Reads only.
  ///
  /// An empty list always means "no rows", never a failed read (a ruling:
  /// a screen given an empty list during a keystore outage drops its
  /// pending bubbles, and the user sends the text twice). A failed read
  /// throws: [StateError] when the vault is not open, [VaultKeyException]
  /// when its cipher cannot run, any other exception of its reads as it is
  /// (a programming error is reported by its step name first). A single
  /// row that no longer opens is not listed; the drain stops at it. The body
  /// is in the part `encrypted_sender_rows.dart`.
  Future<List<OutgoingRow>> outgoing(String conversationId) =>
      _outgoingRows(conversationId);

  // -------------------------------------------------------------------------
  // The drain

  Future<void> _drainAll(String id, BudgetPriority first) async {
    var priority = first;
    try {
      while (true) {
        _held.remove(id);
        final run = _Run(priority);
        var next = _Next.again;
        while (next != _Next.stop) {
          next = await _locks.run(id, () => _step(id, run));
          // The live pull takes the conversation lock itself: it runs
          // between two holds, never inside one.
          if (next == _Next.pull) {
            final context = _contexts.of(id);
            if (run.catchUp == CatchUpResult.waitingForWelcome) {
              try {
                await _crypto.processWelcomes(priority: priority);
              } on Object catch (e, s) {
                // As the receiver's own unheld poll: the pull still runs.
                if (_isBug(e)) _reportOnce('send.welcomes', s);
              }
              // Joined by this poll or by one running beside it (whose
              // answer this poll never sees): the vault says.
              if (await _joinedAtServer(id)) {
                run.catchUp = await _locks.run(
                  id,
                  () => _crypto.catchUpLocked(id, priority: priority),
                );
              }
            }
            final pull = await _receiver.pullLive(id, priority: priority);
            if (run.catchUp != CatchUpResult.current ||
                pull.kind != ReceiveOutcomeKind.complete) {
              await _locks.run(id, () async {
                context.syncedSinceStart = false;
                _stop(id, SendBlock.notSynced);
              });
              next = _Next.stop;
            }
          }
        }
        // Scheduled here, outside the lock's zone: the resend it starts
        // must not read as holding the lock. A timer is no user intent, so
        // the resend never drains at user priority and never accepts a
        // request (amendment 5). Review m1: it keeps the drain's own
        // priority otherwise, so a user's message is resent at live (ahead
        // of the background sweep), and a background drain's stays
        // background.
        final wait = run.resendAfter;
        if (wait != null) {
          final later = priority == BudgetPriority.user
              ? BudgetPriority.live
              : priority;
          _schedule(wait, () => unawaited(drain(id, priority: later)));
        }
        await _forgetGone(id);
        // The calls that joined meanwhile: one more run, at their priority.
        final again = _again.remove(id);
        if (again == null) break;
        priority = again;
      }
    } on Object catch (e, s) {
      _reportIfBug(e, s, 'send.drain');
      // A failed read (a keystore outage) ended the drain: the rows wait,
      // and `outgoing` says why once it can read again.
      if (e is! Error) _stop(id, SendBlock.unavailable);
    } finally {
      // With no await after the loop's last check: a trigger that comes
      // now starts a new drain, and none is lost.
      _running.remove(id);
      _again.remove(id);
    }
  }

  /// The row waits: [block] is what `outgoing` says when no gate explains.
  _Next _stop(String id, [SendBlock block = SendBlock.none]) {
    if (block == SendBlock.none) {
      _held.remove(id);
    } else {
      _held[id] = block;
    }
    return _Next.stop;
  }

  /// One step, with the conversation lock held. Each step ends a row
  /// (`again`), asks for the live pull (`pull`: once for the sync, once
  /// more after a successful accept, and once per `STALE_EPOCH` answer), or
  /// stops the drain.
  Future<_Next> _step(String id, _Run run) async {
    final op = await _start();
    if (op == null) return _stop(id, SendBlock.unavailable);
    final read = await op.vault.outbox(conversationId: id);
    if (read.unreadableKeys.isNotEmpty) {
      // A row that no longer opens: its stage, init and error are not
      // known (only its place in the order is), so nothing of the
      // conversation is encrypted or sent past it. Decision: stop, not
      // skip, because skipping could send a later message ahead of an
      // earlier one the user still expects to go out. Known cost: the
      // conversation's sends stay blocked until the row is deleted by
      // key, which Task 13b must offer (a gate before the flag goes on).
      _reportOnce('send.outbox.unreadable');
      return _stop(id, SendBlock.unavailable);
    }
    final rows = read.items;

    // The catch-up and the live pull after a STALE_EPOCH answer are done.
    final stale = run.stale;
    if (stale != null) {
      run.stale = null;
      return _afterStale(op, id, rows, stale.key, stale.localId, run);
    }
    if (rows.isEmpty) return _stop(id);
    // Nothing goes past a failed head row; a row with an init is Task 8's.
    final head = rows.first;
    if (head.lastError != null) return _stop(id);
    if (head.init != null) return _stop(id, SendBlock.provisional);
    // Rows already encrypted are resent first, byte for byte.
    var row = head;
    for (final r in rows) {
      if (r.lastError != null || r.init != null) break;
      if (r.stage == OutboxStage.encrypted) {
        row = r;
        break;
      }
    }
    // Audit M2: an encrypted row is held while a member is not attributable.
    // The sync step below may conclude the attribution, as for a plain row.
    final owed =
        row.stage == OutboxStage.encrypted &&
        await _attributionOwed(op.vault, id);
    if (row.stage == OutboxStage.encrypted && !owed) {
      return _send(op, id, row, run);
    }

    // The gates of an encrypt, in order; the accept call is the last one.
    final context = _contexts.of(id);
    final gate = await _gate(op.vault, id);
    if (gate.block == SendBlock.unavailable ||
        gate.block == SendBlock.provisional) {
      return _stop(id, gate.block);
    }
    if (!run.synced &&
        (!context.syncedSinceStart || context.attributionPending)) {
      // Once per drain, and once more after a successful accept: commits to
      // the server's pair and attribution here, then one live pull. Both
      // must complete before this run can encrypt.
      run.synced = true;
      run.catchUp = await _crypto.catchUpLocked(id, priority: run.priority);
      return _Next.pull;
    }
    if (owed) return _stop(id, _owedReason(gate.block));
    if (gate.block != SendBlock.none) return _stop(id, gate.block);
    if (gate.needsAccept) {
      // M3: every other gate holds, and this run saw the server say REQUEST
      // with this user as the recipient. Once per drain.
      if (run.accepted) return _stop(id, SendBlock.notSynced);
      // Amendment 5 (audit M3, a gate): only the user's own send accepts.
      // A drain that is not the user's (a push, a poll, a scheduled
      // resend) leaves the row waiting until the user sends or retries.
      if (run.priority != BudgetPriority.user) {
        return _stop(id, SendBlock.notSynced);
      }
      run.accepted = true;
      try {
        await _acceptForReply(id, priority: run.priority);
      } on Object catch (e, s) {
        // The row waits. What the steps got done stays (it is safe): the
        // next drain reads every gate again.
        _reportIfBug(e, s, 'send.accept');
        return _stop(id, SendBlock.notSynced);
      }
      // The acceptance steps ran: every gate is read again before the
      // encrypt. Amendment 3 (review m1): they may have committed
      // (reconcile's one commit, queued removals included), which moves
      // the pair and clears
      // `syncedSinceStart`; this lets the same drain sync once more, so the
      // first reply goes out now. Bounded: the accept runs once per drain.
      run.synced = false;
      return _Next.again;
    }
    final encrypted = await _encrypt(op, id, row.idempotencyKey);
    final item = encrypted.row;
    if (item == null) return _stop(id, encrypted.block);
    _onChanged(id);
    return _send(op, id, item, run);
  }

  /// What holds an encrypt in [id] now (`none`: nothing; [needsAccept]: only
  /// the acceptance of an incoming request is missing). Reads only.
  Future<({SendBlock block, bool needsAccept})> _gate(
    SecureVault vault,
    String id,
  ) async {
    ({SendBlock block, bool needsAccept}) held(SendBlock block) =>
        (block: block, needsAccept: false);
    if (_removedElsewhere()) return held(SendBlock.unavailable);
    final context = _contexts.of(id);
    // No engine call while the receiver holds the engine back (device-level
    // trouble, or this conversation's group).
    final hold = context.engineHoldUntil;
    if (_receiver.engineHeldUntil != null ||
        (hold != null && _now().isBefore(hold))) {
      return held(SendBlock.unavailable);
    }
    // The vault and the engine usable, the group ready and not provisional,
    // synced since the start (M10), no member unattributed, the epoch not
    // owed, the thread answerable.
    final state = await _crypto.describeState(id);
    if (state.sendBlock != SendBlock.none) return held(state.sendBlock);
    if (state.phase != ConversationPhase.ready) {
      return held(SendBlock.waitingForWelcome);
    }
    final group = await _currentGroup(vault, id);
    // The core refuses an encrypt while this device's commit is pending.
    if (group == null ||
        group.hasPending ||
        state.unattributedPresent ||
        context.attributionPending) {
      return held(SendBlock.notSynced);
    }
    if (!state.requestAccepted) {
      final incoming = context.incomingRequest;
      // The direction is not known in this run: the row waits.
      if (incoming == null) return held(SendBlock.notSynced);
      if (incoming) return (block: SendBlock.none, needsAccept: true);
      // This user is the requester.
    }
    return held(SendBlock.none);
  }

  /// Audit M2: whether a member of [id] is not attributable now (the part
  /// of the encrypt gate that also holds a stage-encrypted row): a stored
  /// unattributed pin, an unknown device included, or an attribution this
  /// run has not concluded. Reads the pins fresh; a failed read throws.
  Future<bool> _attributionOwed(SecureVault vault, String id) async =>
      _contexts.of(id).attributionPending ||
      (await vault.members(id)).any((m) => m.side == MemberSide.unattributed);

  // -------------------------------------------------------------------------
  // Encrypt

  /// Encrypts the plain row [plainKey] in ONE `runWrite` body: the group,
  /// the device state and the row read fresh, the engine call, and ONE
  /// transaction with the group state after the encrypt, the row at stage
  /// `encrypted` under a key made here, and the sent digest.
  Future<({OutboxItem? row, SendBlock block})> _encrypt(
    _Op op,
    String id,
    String plainKey,
  ) async {
    ({OutboxItem? row, SendBlock block}) held(SendBlock block) =>
        (row: null, block: block);
    try {
      // The key this ciphertext goes out under: never one a row carried.
      final key = _hexOf(await _random(16));
      return await _session.runWrite((v) async {
        op.check(v);
        final groups = await v.groups(id);
        if (groups.any((g) => g.provisional)) {
          return held(SendBlock.provisional);
        }
        final group = groups.isEmpty ? null : groups.last;
        final sync =
            (await v.conversation(id))?.sync ?? const ConversationSync();
        final unattributed = (await v.members(id))
            .any((m) => m.side == MemberSide.unattributed);
        if (group == null ||
            group.hasPending ||
            sync.epochMustAdvance ||
            unattributed ||
            (!sync.requestAccepted &&
                _contexts.of(id).incomingRequest != false)) {
          return held(SendBlock.notSynced);
        }
        final row = await _rowOf(v, id, plainKey);
        final deviceState = await v.deviceState();
        if (row == null ||
            row.stage != OutboxStage.plain ||
            row.init != null ||
            deviceState == null) {
          return held(SendBlock.unavailable);
        }
        final pair = MlsPair(group.generation, group.epoch);
        final result = await _engine().encrypt(
          deviceState,
          group.state,
          row.content,
        );
        if (result.epoch != group.epoch ||
            result.ciphertext.isEmpty ||
            result.ciphertext.length > _kMaxOutboxCiphertext) {
          // Not an answer for this group's pair: nothing of it is stored.
          return held(SendBlock.unavailable);
        }
        final item = OutboxItem(
          idempotencyKey: key,
          localId: row.localId,
          expectedMessageId: expectedMessageId(v.uid, key),
          conversationId: id,
          generation: pair.generation,
          epoch: pair.epoch,
          ciphertext: result.ciphertext,
          reportCommitment: reportCommitment(row.content),
          content: row.content,
          createdAtMicros: row.createdAtMicros,
          attempts: row.attempts,
        );
        await v.transaction((tx) async {
          await tx.putGroup(
            GroupRecord(
              conversationId: id,
              generation: group.generation,
              epoch: group.epoch,
              state: result.groupState,
            ),
          );
          await tx.deleteOutbox(row.idempotencyKey);
          await tx.putOutbox(item);
          await tx.addSent(id, pair, sentDigest(result.ciphertext));
        });
        return (row: item, block: SendBlock.none);
      });
    } on _Stopped {
      return held(SendBlock.unavailable);
    } on _BadRandom {
      _reportOnce('send.encrypt.random');
      return held(SendBlock.unavailable);
    } on MlsException catch (e) {
      return held(
        e.code == MlsErrorCode.pendingCommit
            ? SendBlock.notSynced
            : SendBlock.unavailable,
      );
    } on Object catch (e, s) {
      // A vault error or a closed vault: the transaction stored nothing.
      _reportIfBug(e, s, 'send.encrypt');
      return held(SendBlock.unavailable);
    }
  }

  // Send: `_send`, `_delivered`, `_refused` and `_afterStale` are in the
  // part `encrypted_sender_send.dart`. Retry, discard, `outgoing`'s rows and
  // `_forgetGone` are in the part `encrypted_sender_rows.dart`.

  // -------------------------------------------------------------------------

  void _forget(String localId) {
    _errors.remove(localId);
    _unknown.remove(localId);
    _notBefore.remove(localId);
    _sendCalls.remove(localId);
  }

  /// The unsent row [localId] of any conversation, or null.
  Future<OutboxItem?> _find(String localId) async {
    final vault = _session.vault;
    if (vault == null) return null;
    try {
      for (final r in (await vault.outbox()).items) {
        if (r.localId == localId) return r;
      }
    } on Object catch (e, s) {
      _reportIfBug(e, s, 'send.find');
    }
    return null;
  }

  Future<_Op?> _start() async {
    final vault = _session.vault;
    if (vault == null) return null;
    try {
      final deviceId = await vault.deviceId();
      if (deviceId == null) return null;
      return _Op(_session, vault, vault.uid, deviceId);
    } on Object catch (e, s) {
      _reportIfBug(e, s, 'send.start');
      return null;
    }
  }

  /// [length] bytes of the engine's CSPRNG. Audit L6: an answer of another
  /// length is [_BadRandom], before anything is stored or encrypted with it.
  Future<Uint8List> _random(int length) => randomOf(_engine(), length);

  /// Reports [step] (a name only) the first time in this run.
  void _reportOnce(String step, [StackTrace? stack]) {
    if (_reported.add(step)) {
      _onUnexpectedError?.call(
        E2eePipelineError(step),
        stack ?? StackTrace.current,
      );
    }
  }

  /// Reports a programming error (never an expected failure) by its step
  /// name only; the error itself is never passed on.
  void _reportIfBug(Object e, StackTrace s, String step) {
    if (_isBug(e)) _onUnexpectedError?.call(E2eePipelineError(step), s);
  }

  /// Whether a final group of [id] is stored at (or past) the generation
  /// the last catch-up read from the server. A read only; no lock.
  Future<bool> _joinedAtServer(String id) async {
    final vault = _session.vault;
    final server = _contexts.of(id).serverPair;
    if (vault == null || server == null) return false;
    final group = await _currentGroup(vault, id);
    return group != null && group.generation >= server.generation;
  }
}
