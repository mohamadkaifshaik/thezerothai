import 'dart:async';
import 'dart:collection';
import 'dart:math';
import 'dart:typed_data';

import 'package:fixnum/fixnum.dart';

import '../../../../core/crypto/crypto_engine.dart';
import '../../../../core/crypto/crypto_types.dart';
import '../../../../core/crypto/mls_derivations.dart' show sentDigest;
import '../../../../core/crypto/mls_pair.dart';
import '../../../../core/network/app_exception.dart';
import '../../../../core/vault/secure_vault.dart';
import '../../../../core/vault/vault_session.dart';
import '../../../../gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;
import '../../../../gen/dzeroth/messaging/v1/messaging.pbenum.dart';
import '../../data/messaging_repository.dart';
import 'conversation_context.dart';
import 'conversation_crypto.dart';
import 'conversation_locks.dart';
import 'daily_ledger.dart';
import 'deferred_record.dart';
import 'e2ee_types.dart';
import 'message_content_codec.dart';
import 'receive_record.dart';
import 'sync_budget.dart';

part 'message_receiver_failures.dart';
part 'message_receiver_reconcile.dart';
part 'message_receiver_sink.dart';
part 'message_receiver_walks.dart';

/// The contract's page size for `ListEpochMessages` (at most 50). A page
/// with more messages is refused (§3.3).
const int kEpochPageSize = 50;

/// A ciphertext longer than this is never given to the engine: it is an
/// undecryptable row (M1). One number with the deferred record's bound
/// ([kMaxDeferredCiphertextBytes]): what may reach the engine may be
/// deferred, and nothing longer is ever held.
const int kMaxCiphertextBytes = kMaxDeferredCiphertextBytes;

/// Epoch pages the sink lists per conversation lock hold (§2, §9).
const int kSinkPagesPerHold = 2;

/// Walk pages one pass lists across its close, orphan and open walks (§9);
/// twice that at user priority.
const int kWalkPagesPerPass = 10;

/// Tombstone pages one pass lists for the reconcile walk (§8.2, §9): a
/// throttle, not a cap (the next pass continues from the sealed cursor).
const int kReconcilePagesPerPass = 10;

/// The page size asked of `ListMessageTombstones` (the contract's maximum).
/// A page with more tombstones is refused.
const int kTombstonePageSize = 100;

/// A reconcile listing longer than this many pages (a million tombstones)
/// is treated as one that can never complete: counted as a failure and
/// begun again from the top (a ruling of step 2b: no sequence of server
/// answers lists without end).
const int kReconcilePagesMax = 10000;

/// Refused page tokens a walk restarts from per run (§3.2).
const int kWalkRestartsPerRun = 2;

/// The first backoff after an order violation, a missing order echo or the
/// restart cap (§3.3); it doubles up to [kWalkBackoffMax].
const Duration kWalkBackoff = Duration(minutes: 1);
const Duration kWalkBackoffMax = Duration(hours: 1);

/// At most one refused page of an undecryptable walk is counted towards its
/// abandonment per this long, across app runs (`kWalkGiveUpAfter` in the
/// receive record's file; a ruling after the design).
const Duration kWalkRefusalSpacing = Duration(hours: 1);

/// The first wait after an engine answer that stopped a pass (§7.2). It
/// doubles up to [kWalkBackoffMax]: receiver-wide on consecutive
/// device-level results (the device is down, the breaker, an unwitnessed
/// crash), and per conversation with the count of group-level failures.
const Duration kEngineBackoff = Duration(minutes: 1);

/// The open walk runs one listing from its settle token on a fast-path pass
/// at most this often (§4, the settle refresh; local clock).
const Duration kOpenSettleEvery = Duration(minutes: 10);

/// How many message ids handled without a row (a forgery, this device's own
/// message already in its sent log) are remembered this run, so a second
/// listing of the same message neither counts it again nor turns it into an
/// `undecryptable` row once its pair is behind the group.
const int _kRowlessRemembered = 4096;

/// How many tombstone states seen this run are remembered per conversation
/// (§7.4 check 2).
const int _kTombstonedRemembered = 4096;

final RegExp _messageIdShape = RegExp(r'^[0-9a-f]{32}$');

/// What one receive pass ended with (§2). `complete`: the since token is
/// saved (or already stored) and no walk has pages left; `more`: work is
/// left (the allowance was spent, a page was discarded, a token was
/// retired); `held`: rate limited or the budget is paused, until [until];
/// `stopped`: a failure or a backoff, not before [until]. Never names a
/// conversation, a message or a key.
class ReceiveOutcome {
  const ReceiveOutcome._(this.kind, this.until);

  static const ReceiveOutcome complete = ReceiveOutcome._(
    ReceiveOutcomeKind.complete,
    null,
  );
  static const ReceiveOutcome more = ReceiveOutcome._(
    ReceiveOutcomeKind.more,
    null,
  );

  factory ReceiveOutcome.held(DateTime until) =>
      ReceiveOutcome._(ReceiveOutcomeKind.held, until);

  factory ReceiveOutcome.stopped(DateTime until) =>
      ReceiveOutcome._(ReceiveOutcomeKind.stopped, until);

  final ReceiveOutcomeKind kind;
  final DateTime? until;

  @override
  String toString() => 'ReceiveOutcome(${kind.name})';
}

enum ReceiveOutcomeKind { complete, more, held, stopped }

/// Receiving encrypted messages (Task 6, R7, R8, R12, R13, spec 7.5; the
/// walks of receive-walks design rev 3): decrypts, checks and stores each
/// message of a conversation in the vault.
///
/// A pass ([pullLive]) probes `ListMessages` on the read budget, then walks
/// the close, orphan and open pairs with ordered, resumable
/// `ListEpochMessages` pages whose cursors live in the sealed receive record
/// (`messages.e2ee.receive.<id>`). Pages are listed WITHOUT the lock and
/// applied under it after a re-validation; each message is one `runWrite`
/// body (read fresh, the engine call, ONE transaction with its result, and
/// for a page's last message the walk's new entry).
///
/// The sink methods ([completeEpoch], [markEpochUndecryptable]) are called
/// by catch-up WITH the lock held: they take no lock, never run catch-up and
/// list at most [kSinkPagesPerHold] pages per hold (never waiting for the
/// budget); an unfinished walk throws, so catch-up ends `interrupted` and
/// the commit waits for the next pass to continue it.
///
/// Never logs; decrypted bytes live only in the vault's sealed rows. An
/// unexpected failure is reported as [E2eePipelineError] with a step name.
class MessageReceiver implements EpochMessageSink {
  MessageReceiver({
    required ConversationCrypto crypto,
    required VaultSession session,
    required CryptoEngine Function() engine,
    required MessagingRepository messaging,
    required SyncBudget syncBudget,
    required SyncBudget readBudget,
    required ConversationLocks locks,
    required ConversationContexts contexts,
    required DateTime Function() now,
    required void Function(String conversationId) onChanged,
    required DailyLedger ledger,
    void Function(Object error, StackTrace stack)? onUnexpectedError,
    int epochPageSize = kEpochPageSize,
  }) : assert(
         epochPageSize >= 1 && epochPageSize <= kEpochPageSize,
         'The contract allows 1 to 50.',
       ),
       _pageSize = epochPageSize,
       _crypto = crypto,
       _session = session,
       _engine = engine,
       _messaging = messaging,
       _syncBudget = syncBudget,
       _readBudget = readBudget,
       _locks = locks,
       _contexts = contexts,
       _now = now,
       _onChanged = onChanged,
       ledger = ledger,
       _records = ReceiveRecords(onUnexpectedError: onUnexpectedError),
       _deferred = DeferredRecords(onUnexpectedError: onUnexpectedError),
       _onUnexpectedError = onUnexpectedError;

  /// The ordered walks' page size ([kEpochPageSize] in production; tests
  /// pass a smaller one). A page with more messages is refused (§3.3), and
  /// a shorter one never carries a next token.
  final int _pageSize;
  final ConversationCrypto _crypto;
  final VaultSession _session;
  final CryptoEngine Function() _engine;
  final MessagingRepository _messaging;
  final SyncBudget _syncBudget;
  final SyncBudget _readBudget;
  final ConversationLocks _locks;
  final ConversationContexts _contexts;
  final DateTime Function() _now;
  final void Function(String conversationId) _onChanged;
  final ReceiveRecords _records;
  final void Function(Object error, StackTrace stack)? _onUnexpectedError;

  /// The daily ledger of the lost-send follow-up (R7): Task 9's self-update
  /// reads it; nothing here writes it.
  final DailyLedger ledger;

  int _forgeries = 0;

  /// The receiver's call sequence (probe and listing order, §4 rule 2).
  int _seq = 0;

  /// The sink's pages per lock hold (keyed by [ConversationLocks.holdToken],
  /// so holds of different conversations never reset each other's count).
  final Expando<int> _sinkPagesByHold = Expando();

  /// `uid|conversationId|messageId` of messages handled without a row this
  /// run (oldest first, at most [_kRowlessRemembered]).
  final LinkedHashSet<String> _rowless = LinkedHashSet();

  /// Own-leaf results without `from_self` (C3), counted once per message per
  /// run; never shown.
  int get forgeriesSkipped => _forgeries;

  // --- the failure rule (§7; memory of this run) ---------------------------

  final DeferredRecords _deferred;

  /// Every engine success of the receiver this run, in any conversation,
  /// probes included (§7.1): the device-level witness.
  int _okSeq = 0;

  /// The run id (§7.3): 64 random bits as 16 hex, new at every
  /// [onAppResumed]. A deferred item is attempted at most once per run.
  String _runId = _newRunId();

  /// A crash-class retry ran this run (§7.4: at most one, device-wide).
  bool _crashRetryUsed = false;

  /// The engine answered `deadline` this run: no crash-class retry after.
  bool _deadlineThisRun = false;

  /// The RECEIVER-WIDE engine hold (a ruling after the design, fix round 1;
  /// it amends §7.2's per-conversation stop): a device-level result (an
  /// `unavailable` answer, the device-level breaker, an unwitnessed crash)
  /// seen by ANY conversation holds the engine work of EVERY conversation
  /// of this receiver until this time, since a hung engine holds the
  /// user's one vault write lock while it is waited for. Listing is not
  /// gated. [_engineHoldBackoff] is its last wait: [kEngineBackoff],
  /// doubling up to [kWalkBackoffMax] on consecutive device-level results;
  /// any engine success of the receiver clears both, and so does
  /// [onAppResumed]. Memory only.
  DateTime? _engineHeldUntil;
  Duration? _engineHoldBackoff;

  /// When the receiver-wide engine hold ends (null: none set, cleared, or
  /// its time has passed: never a time in the past). A time only.
  DateTime? get engineHeldUntil {
    final until = _engineHeldUntil;
    return until != null && _now().isBefore(until) ? until : null;
  }

  int _deferredTotal = 0;
  int _evictedTotal = 0;
  int _breakerOpen = 0;

  /// Counters of this run (never shown): messages deferred, deferred
  /// messages evicted to a row by an overflow, and passes the device-level
  /// breaker stopped.
  int get deferredCount => _deferredTotal;
  int get evictedCount => _evictedTotal;
  int get breakerOpened => _breakerOpen;

  /// The app resumed (call right after the engine's own `onAppResumed`): a
  /// new run. Each deferred item may be attempted once more, one
  /// crash-class retry is allowed again, and every engine hold is cleared
  /// (the receiver-wide one with its doubling, and each conversation's own:
  /// the resume replaced a crashed engine, so the next pass may try). The
  /// record of messages deferred unwitnessed is kept: an engine success
  /// after the resume still promotes them.
  void onAppResumed() {
    _runId = _newRunId();
    _crashRetryUsed = false;
    _deadlineThisRun = false;
    _engineHeldUntil = null;
    _engineHoldBackoff = null;
    _contexts.clearEngineHolds();
  }

  /// How many undecryptable walks of [conversationId] were given up (step
  /// 2 carry-over 4; the count is in the sealed receive record, bounded):
  /// messages of an epoch this device could not decrypt anyway, whose ids
  /// the server never gave, are counted here and never shown. 0 when the
  /// vault is closed.
  Future<int> abandonedWalks(String conversationId) async {
    final vault = _session.vault;
    if (vault == null) return 0;
    try {
      return (await _records.read(vault, conversationId)).abandoned;
    } on Object catch (e, s) {
      _reportIfBug(e, s, 'receive.walk.abandoned.read');
      return 0;
    }
  }

  /// §10: what the screens need to draw the placeholder rows of
  /// [conversationId]: the id and server time of every deferred message,
  /// newest first, leaving out those at or before `cleared_at`. No bytes.
  /// `onChanged(conversationId)` fires after every deferral and every item
  /// removal. Never throws (empty when the vault is closed or the record
  /// does not read).
  Future<List<DeferredView>> deferredView(String conversationId) async {
    final vault = _session.vault;
    if (vault == null) return const [];
    try {
      final read = await _deferred.read(vault, conversationId);
      final cleared = (await vault.conversation(conversationId))
          ?.sync
          .clearedAtMicros;
      return read.record.view(clearedAtMicros: cleared);
    } on Object catch (e, s) {
      _reportIfBug(e, s, 'receive.deferred.view');
      return const [];
    }
  }

  /// §7.6 end 5: removes the deferred items of [conversationId] created at
  /// or before [upToCreatedAtMicros] in the caller's transaction [tx], for
  /// every vault-row delete that leaves settings behind (`cleared_at` here;
  /// Task 13's `noteDeleted`). Call inside a `runWrite` body with that
  /// body's [vault], at most once per transaction, with the conversation
  /// lock held. No row is written. An unreadable record is left to the
  /// next pass (which replaces it).
  Future<void> purgeDeferredIn(
    SecureVault vault,
    VaultTx tx,
    String conversationId,
    int upToCreatedAtMicros,
  ) async {
    final read = await _deferred.read(vault, conversationId);
    if (read.unreadable) return;
    final gone = [
      for (final i in read.record.items)
        if (i.at <= upToCreatedAtMicros) i.id,
    ];
    if (gone.isEmpty) return;
    final rest = read.record.without(gone);
    await _deferred.putIn(tx, conversationId, rest);
    final context = _contexts.of(conversationId);
    context.deferredEmpty = rest.items.isEmpty ? null : false;
    gone.forEach(context.unwitnessed.remove);
  }

  static String _newRunId() {
    final random = Random.secure();
    return [
      for (var i = 0; i < 8; i++)
        random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ].join();
  }

  // -------------------------------------------------------------------------
  // The pass

  /// One bounded receive pass for [conversationId] (§2): the probe, the
  /// close walk, the orphan walk and the open walk, each at most one
  /// allowance. Single flight: a call while a pass runs joins it. Never
  /// loops, never schedules, never throws. Takes the conversation lock (never
  /// call it with the lock held).
  Future<ReceiveOutcome> pullLive(
    String conversationId, {
    BudgetPriority priority = BudgetPriority.background,
  }) {
    final context = _contexts.of(conversationId);
    final running = context.running;
    if (running != null) return running.then((o) => o! as ReceiveOutcome);
    final pass = _runPass(conversationId, priority);
    context.running = pass;
    // However the pass ended: one that threw (only its error reporter can
    // make it) must not stay the running pass, or every later call would
    // join it for good. The caller gets the pass itself, error included.
    pass.whenComplete(() {
      if (identical(context.running, pass)) context.running = null;
    }).ignore();
    return pass;
  }

  /// One allowance of the reconcile walk of [conversationId] alone (§8.2:
  /// step 2 of a pass, without its probe and its walks), for a scheduler
  /// that wants removed text cleared while no pass is due. `complete`: no
  /// reconcile entry is armed, or its listing ended; otherwise as a pass.
  /// No engine call. Takes the conversation lock (never call it with the
  /// lock held). Never throws.
  Future<ReceiveOutcome> reconcile(
    String conversationId, {
    BudgetPriority priority = BudgetPriority.background,
  }) => _reconcileAlone(conversationId, priority);

  /// [conversationId]'s close (or orphan) walk for [pair] reached its end
  /// (read from the receive record). True for a pair no member can have
  /// sent in (generation or epoch below 1).
  @override
  Future<bool> epochWalkDone(String conversationId, MlsPair pair) async {
    if (pair.generation < 1 || pair.epoch < 1) return true;
    final vault = _session.vault;
    if (vault == null) return false;
    final record = await _readReceive(vault, conversationId);
    for (final w in [record.close, record.orphan]) {
      if (w != null && w.pair == pair) return w.end;
    }
    return false;
  }

  // -------------------------------------------------------------------------
  // The sink (called by catch-up with the conversation lock held)

  /// The close walk of [pair] (the orphan walk below the current
  /// generation), each message through the one-message rules; idempotent.
  /// Throws (an [Exception], so catch-up ends `interrupted` and the commit
  /// waits) while the walk has not ended; the next pass continues it.
  @override
  Future<void> completeEpoch(
    String conversationId,
    MlsPair pair, {
    required BudgetPriority priority,
  }) => _sinkWalk(conversationId, pair, priority, WalkMode.decrypt);

  /// As [completeEpoch] in mode `u`: every unstored message of [pair]
  /// becomes an `undecryptable` row (tombstones, skips and the echo rules as
  /// for any message); the engine is never called.
  @override
  Future<void> markEpochUndecryptable(
    String conversationId,
    MlsPair pair, {
    required BudgetPriority priority,
  }) => _sinkWalk(conversationId, pair, priority, WalkMode.undecryptable);

  // -------------------------------------------------------------------------
  // cleared_at (R8)

  /// R8: once per app run per conversation, one ListEpochMessages call for
  /// the current pair (listed WITHOUT the lock); deletes local copies created
  /// at or before `cleared_at` under the lock. A `cleared_at` in the future
  /// is ignored. The call takes one unit of the sync budget at [priority]
  /// (user by default: the conversation is being opened), and a
  /// rate-limited answer pauses that budget as every other listing does.
  /// Never throws.
  Future<void> applyClearedAtOnce(
    String conversationId, {
    BudgetPriority priority = BudgetPriority.user,
  }) async {
    final id = conversationId;
    if (_contexts.of(id).clearedAtReadThisRun) return;
    try {
      final pass = await _start();
      if (pass == null) return;
      final pair = await _currentPair(pass.vault, id);
      if (pair == null || pair.epoch < 1) return;
      if (!await _takeUnit(_syncBudget, priority, id)) return;
      final pb.ListEpochMessagesResponse page;
      try {
        page = await _messaging.listEpochMessages(
          conversationId: id,
          pair: pair,
          pageSize: kEpochPageSize,
        );
      } on RateLimitedException catch (e) {
        // As every other listing: the budget is paused until the server's
        // time. Not read: a later call of this run asks again.
        _syncBudget.pauseUntil(_retryAt(e));
        return;
      } on Object catch (e, s) {
        _reportIfBug(e, s, 'receive.clearedAt');
        return;
      }
      final cleared = _clearedAtOf(page);
      await _locks.run(id, () async {
        final context = _contexts.of(id);
        if (context.clearedAtReadThisRun || !pass.live) return;
        if (cleared == null) {
          // Read: not again this run (unset, or in the future: ignored).
          context.clearedAtReadThisRun = true;
          return;
        }
        await _session.runWrite((v) async {
          pass.check(v);
          final sync =
              (await v.conversation(id))?.sync ?? const ConversationSync();
          final stored = sync.clearedAtMicros;
          await v.transaction((tx) async {
            await tx.deleteConversation(id, upToCreatedAtMicros: cleared);
            // §7.6 end 5: the deferred copies go with the rows.
            await purgeDeferredIn(v, tx, id, cleared);
            if (stored == null || cleared > stored) {
              await tx.putConversationSync(
                id,
                sync.copyWith(clearedAtMicros: cleared),
              );
            }
          });
        });
        // Only once the delete committed: a failed write is retried at the
        // next call of this run.
        context.clearedAtReadThisRun = true;
        _onChanged(id);
      });
    } on _Stopped {
      return;
    } on Object catch (e, s) {
      _reportIfBug(e, s, 'receive.clearedAt');
    }
  }

  /// The response's `cleared_at` in microseconds, or null when unset or in
  /// the future.
  int? _clearedAtOf(pb.ListEpochMessagesResponse page) {
    if (!page.hasClearedAt()) return null;
    final micros = _micros(page.clearedAt.seconds, page.clearedAt.nanos);
    if (micros == null || micros > _now().microsecondsSinceEpoch) return null;
    return micros;
  }

  /// Saves [cleared] in the sync record when it is later than the stored
  /// one (never moved back).
  Future<void> _saveClearedAt(
    _Pass pass,
    String id,
    int cleared,
  ) => _session.runWrite((v) async {
    pass.check(v);
    final sync = (await v.conversation(id))?.sync ?? const ConversationSync();
    final stored = sync.clearedAtMicros;
    if (stored != null && stored >= cleared) return;
    await v.transaction(
      (tx) =>
          tx.putConversationSync(id, sync.copyWith(clearedAtMicros: cleared)),
    );
  });

  // -------------------------------------------------------------------------
  // A probe batch (the fast path, §4 rule 1)

  /// Runs [messages] (sorted) in order, with the lock held. A message of a
  /// later pair runs one catch-up (through the locked entry; its commits
  /// come first) and stops the batch without saving. [token] is saved (by
  /// compare-and-set on the stored token) with the last message's
  /// transaction, or alone after it.
  Future<_BatchEnd> _runBatch(
    _Pass pass,
    String id,
    List<pb.Message> messages, {
    required BudgetPriority priority,
    required _TokenSave token,
  }) async {
    var waiting = false;
    var changed = false;
    var completed = false;
    var caughtUp = false;
    try {
      var all = true;
      var tokenSaved = false;
      for (var i = 0; i < messages.length; i++) {
        final last = i == messages.length - 1;
        final step = await _one(
          pass,
          id,
          messages[i],
          _Mode.live,
          null,
          token: last ? token : null,
        );
        if (step == _Step.later) {
          // Commits first; the batch stops without saving the token (the
          // new pair's open walk lists its messages, §4).
          caughtUp = true;
          final result = await _crypto.catchUpLocked(id, priority: priority);
          if (result == CatchUpResult.waitingForWelcome) waiting = true;
          all = false;
          break;
        }
        if (step == _Step.stop) {
          all = false;
          break;
        }
        if (step == _Step.wrote) {
          changed = true;
          if (last) tokenSaved = true;
        }
      }
      if (all && !tokenSaved) await _saveToken(pass, id, token);
      completed = all;
    } on _Stopped {
      completed = false;
    } on Object catch (e, s) {
      _reportIfBug(e, s, 'receive.batch');
      completed = false;
    }
    if (changed) _onChanged(id);
    return _BatchEnd(
      completed: completed,
      waitingForWelcome: waiting,
      caughtUp: caughtUp,
    );
  }

  /// Saves the since token alone, by compare-and-set on the stored one.
  Future<void> _saveToken(
    _Pass pass,
    String id,
    _TokenSave token,
  ) => _session.runWrite((v) async {
    pass.check(v);
    final sync = (await v.conversation(id))?.sync ?? const ConversationSync();
    // An answer without a since token keeps the stored one.
    if (token.token.isEmpty ||
        sync.sinceToken != token.expect ||
        sync.sinceToken == token.token) {
      return;
    }
    await v.transaction(
      (tx) =>
          tx.putConversationSync(id, sync.copyWith(sinceToken: token.token)),
    );
    // The pass's own save: its freshness witness follows the token.
    _contexts.of(id).noteSinceTokenSaved(pass, sync.sinceToken, token.token);
  });

  // -------------------------------------------------------------------------
  // One message

  /// One message, under the conversation lock, in ONE `runWrite` body.
  /// [token]: the probe batch's since token, saved by compare-and-set with
  /// this message's transaction. [record]: a page's walk entry, computed in
  /// this body from the record read fresh here and written with this
  /// message's transaction.
  Future<_Step> _one(
    _Pass pass,
    String id,
    pb.Message m,
    _Mode mode,
    MlsPair? epoch, {
    _TokenSave? token,
    _RecordUpdate? record,
  }) async {
    final mid = m.id;
    // Not a message of this conversation the vault can key: nothing of it.
    if (!_messageIdShape.hasMatch(mid) ||
        (m.conversationId.isNotEmpty && m.conversationId != id)) {
      return _Step.skipped;
    }
    final g = pairComponentFromInt64(m.mlsGeneration);
    final e = pairComponentFromInt64(m.mlsEpoch);
    final pair = g == null || e == null ? null : MlsPair(g, e);
    final at = _createdMicros(m);
    final ciphertext = Uint8List.fromList(m.ciphertext);
    final rowlessKey = '${pass.uid}|$id|$mid';
    final context = _contexts.of(id);
    // An item was deferred by a transaction of its own (the pass stops).
    var notify = false;
    try {
      final step = await _session.runWrite<_Step>((v) async {
        pass.check(v);
        final stored = await v.conversation(id);
        final sync = stored?.sync ?? const ConversationSync();
        final cleared = sync.clearedAtMicros;
        // 8. At or before cleared_at: processed, never stored.
        final hidden = cleared != null && at <= cleared;
        final update = record == null ? null : await record(v, sync);
        final saveToken = token != null && sync.sinceToken == token.expect
            ? token.token
            : update?.sinceToken;
        final write = _Write(
          v,
          id,
          sync,
          saveToken,
          hidden,
          update?.record,
          // The pass's own save: its freshness witness follows the token.
          (to) => context.noteSinceTokenSaved(pass, sync.sinceToken, to),
        );

        // 1. A tombstone clears a stored copy and stores nothing new.
        if (m.state == MessageState.MESSAGE_STATE_REMOVED ||
            m.state == MessageState.MESSAGE_STATE_DELETED_ACCOUNT) {
          final state = m.state == MessageState.MESSAGE_STATE_REMOVED
              ? StoredMessageState.removed
              : StoredMessageState.deletedAccount;
          // Seen this run: a deferred copy of it is never tried again.
          _noteTombstone(context, mid, state);
          if (await v.hasMessage(id, mid)) {
            return write.commit(tombstone: (mid, state));
          }
          // §8.1: a deferred message that was taken down ends as its
          // tombstone row (none at or before cleared_at), and its item goes
          // in the same transaction; the row then stops a replayed record.
          final held = await _deferredLookup(v, id);
          final item = held.of(mid);
          if (item == null) return _Step.skipped;
          final rest = held.without([mid]);
          final wrote = await write.commit(
            deferred: rest,
            rows: [?await _itemRow(v, id, cleared, item)],
          );
          // The hint only after the transaction committed: a failed write
          // leaves the item, and the hint must not say the record is empty.
          context.deferredEmpty = rest.items.isEmpty;
          return wrote;
        }

        StoredMessage undecryptable({bool mine = false}) => StoredMessage(
          conversationId: id,
          messageId: mid,
          createdAtMicros: at,
          mine: mine,
          state: StoredMessageState.undecryptable,
          generation: pair?.generation ?? 0,
          epoch: pair?.epoch ?? 0,
          content: null,
        );

        // 2. An epoch before this device joined: nothing, unless it is the
        // pair being walked (the last epoch of a kept older generation, §6).
        final joined = stored?.joinHighWater;
        if (pair != null &&
            joined != null &&
            pair.compareTo(joined.next) < 0 &&
            pair != epoch) {
          return _Step.skipped;
        }
        // 3. Stored (any state): no engine call.
        if (await v.hasMessage(id, mid)) return _Step.skipped;
        // Deferred (§7.3): its retries own it; a walk never gives it to the
        // engine twice. The cursor passes it.
        if ((await _deferredLookup(v, id)).of(mid) != null) {
          return write.commit();
        }
        // Met before this run without a row (forgery, own message sent).
        if (_rowless.contains(rowlessKey)) return _Step.skipped;

        // 4. The echo of an outbox row: the same id AND the same bytes.
        final echo = await _echoOf(v, id, mid, ciphertext);
        if (echo != null) {
          return write.commit(
            row: StoredMessage(
              conversationId: id,
              messageId: mid,
              createdAtMicros: at,
              mine: true,
              state: StoredMessageState.visible,
              generation: echo.generation,
              epoch: echo.epoch,
              content: echo.content,
              senderDeviceId: pass.deviceId,
            ),
            deleteOutbox: echo.idempotencyKey,
          );
        }
        // M2: this device's own send (its digest is in the sent log): never
        // given to the engine; no row.
        if (pair != null &&
            ciphertext.isNotEmpty &&
            await v.hasSent(id, pair, sentDigest(ciphertext))) {
          _remember(rowlessKey);
          return write.commit();
        }

        // 5. Nothing to decrypt, or more than the engine is given (M1).
        if (m.ciphertextRemoved ||
            ciphertext.isEmpty ||
            ciphertext.length > kMaxCiphertextBytes ||
            pair == null) {
          return write.commit(row: undecryptable());
        }

        // An epoch this device can no longer decrypt.
        if (mode == _Mode.undecryptable) {
          if (pair.compareTo(epoch!) > 0) return write.commit();
          return write.commit(row: undecryptable());
        }

        // 6. The device's group at P.
        final GroupRecord? group;
        if (mode == _Mode.epoch) {
          group = await v.group(id, epoch!.generation);
        } else {
          group = await _currentGroup(v, id);
        }
        if (group == null || group.provisional) return _Step.stop;
        final p = MlsPair(group.generation, group.epoch);
        final order = pair.compareTo(p);
        if (order > 0) {
          // Live: catch-up first (not while an engine hold stands: applying
          // a commit is engine work too). An epoch walk never runs
          // catch-up: the message is left for its own epoch.
          if (mode != _Mode.live) return write.commit();
          return _engineHoldOf(context) != null ? _Step.stop : _Step.later;
        }
        if (order < 0) {
          // Its keys are gone: never given to the engine; no side.
          return write.commit(row: undecryptable());
        }

        // 7. The engine, and ONE transaction with its result. No engine
        // call while an engine hold stands (the receiver-wide one, or this
        // conversation's own): the batch or page stops here, the cursor
        // kept.
        if (_engineHoldOf(context) != null) return _Step.stop;
        final deviceState = await v.deviceState();
        if (deviceState == null) return _Step.stop;
        final commitment = Uint8List.fromList(m.reportCommitment);
        final a = await _attempt(
          v,
          pass,
          id,
          group,
          deviceState,
          mid: mid,
          at: at,
          ciphertext: ciphertext,
          commitment: commitment,
          fromSelf: m.fromSelf,
        );
        final code = a.code;
        if (code != null) {
          // §7.2: `internal`, `deadline` or `unavailable`.
          return _firstSightFailure(
            v,
            id,
            write,
            group,
            code,
            mid: mid,
            at: at,
            ciphertext: ciphertext,
            commitment: commitment,
            fromSelf: m.fromSelf,
            onDeferred: () => notify = true,
          );
        }
        final advanced = a.group;
        final cleared0 = advanced == null
            ? null
            : await _groupFailuresCleared(v, id, p, write.record);
        final wrote = await write.commit(
          group: advanced,
          row: a.row,
          epochMustAdvance: a.epochMustAdvance,
          recordOverride: cleared0,
        );
        // A receive record written outside a page's own update.
        if (cleared0 != null && write.record == null) context.serial++;
        return wrote;
      });
      if (notify) _onChanged(id);
      return step;
    } on _Stopped {
      return _Step.stop;
    } on _DeferredUnreadable {
      // Nothing written: the next pass replaces the record (§7.3).
      return _Step.stop;
    } on Object catch (err, s) {
      // A vault error or a closed vault: nothing stored; retried later.
      _reportIfBug(err, s, 'receive.message');
      return _Step.stop;
    }
  }

  /// Remembers a message handled without a row; false when it already was.
  bool _remember(String key) {
    if (!_rowless.add(key)) return false;
    while (_rowless.length > _kRowlessRemembered) {
      _rowless.remove(_rowless.first);
    }
    return true;
  }

  // -------------------------------------------------------------------------

  /// The receive record of [id], read with [vault] (the caller's body vault
  /// for a write) and normalized against the vault (§3.4).
  Future<ReceiveRecord> _readReceive(SecureVault vault, String id) async {
    final raw = await _records.read(vault, id);
    final sync =
        (await vault.conversation(id))?.sync ?? const ConversationSync();
    return raw.normalized(sync: sync, groups: await vault.groups(id));
  }

  Future<_Pass?> _start() async {
    final vault = _session.vault;
    if (vault == null) return null;
    try {
      final deviceId = await vault.deviceId();
      if (deviceId == null) return null;
      return _Pass(_session, vault, vault.uid, deviceId);
    } on Object catch (e, s) {
      _reportIfBug(e, s, 'receive.start');
      return null;
    }
  }

  /// The highest stored non-provisional group's pair, or null.
  Future<MlsPair?> _currentPair(SecureVault vault, String id) async {
    final group = await _currentGroup(vault, id);
    return group == null ? null : MlsPair(group.generation, group.epoch);
  }

  Future<GroupRecord?> _currentGroup(SecureVault vault, String id) async {
    GroupRecord? current;
    for (final group in await vault.groups(id)) {
      if (!group.provisional) current = group; // ascending generation
    }
    return current;
  }

  /// One unit of [budget] for the conversation [lane] (waiting is allowed:
  /// call with no lock held; background calls are served round-robin by
  /// conversation, and one unit a minute is left to user priority, §9);
  /// false (make no call) while paused or after a reset.
  Future<bool> _takeUnit(
    SyncBudget budget,
    BudgetPriority priority,
    String lane,
  ) async {
    if (budget.paused) return false;
    try {
      await budget.take(priority, lane: lane);
      return true;
    } on BudgetPaused {
      return false;
    } on StateError {
      return false;
    }
  }

  /// Reports a programming error (never an expected failure) by its step
  /// name only; the error itself is never passed on.
  void _reportIfBug(Object e, StackTrace s, String step) {
    if (e is Error && e is! StateError) {
      _onUnexpectedError?.call(E2eePipelineError(step), s);
    }
  }
}

/// `created_at`, then id.
void _sort(List<pb.Message> messages) {
  messages.sort((a, b) => _posOf(a).compareTo(_posOf(b)));
}

/// A message's listing position (`created_at` micros, then id).
WalkPos _posOf(pb.Message m) => WalkPos(_createdMicros(m), m.id);

/// The largest whole second whose microseconds stay exact on the web
/// (below 2^53).
final Int64 _maxSeconds = Int64(9007199254);

/// A server time in microseconds since the epoch; null when it is not a
/// time this client holds exactly (negative, nanos out of range, or above
/// [kMaxPairComponent] = 2^53 - 1 microseconds, the bound the receive
/// record's decoder holds a position time to). Never throws (a server value
/// never reaches `DateTime`).
int? _micros(Int64 seconds, int nanos) {
  if (seconds.isNegative || seconds > _maxSeconds) return null;
  if (nanos < 0 || nanos > 999999999) return null;
  // At most 9007199254 * 10^6 + 999999, below 2^63: exact on the VM; on
  // the web a result above 2^53 may round, but stays above the bound.
  final micros = seconds.toInt() * 1000000 + nanos ~/ 1000;
  return micros > kMaxPairComponent ? null : micros;
}

/// A message's `created_at` in microseconds: 0 (the oldest possible) when it
/// is unset or out of range, so such a message sorts first and is hidden by
/// any `cleared_at`. An ordered epoch page never carries an out-of-range
/// time (the order check refuses the page), so a recorded position always
/// decodes.
int _createdMicros(pb.Message m) =>
    m.hasCreatedAt() ? _micros(m.createdAt.seconds, m.createdAt.nanos) ?? 0 : 0;

/// [m]'s `created_at` is unset or a time [_micros] holds.
bool _timeConverts(pb.Message m) =>
    !m.hasCreatedAt() ||
    _micros(m.createdAt.seconds, m.createdAt.nanos) != null;

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

enum _Mode { live, epoch, undecryptable }

/// `wrote`: one transaction ran; `skipped`: nothing was written; `later`: a
/// pair above the group's (live only); `stop`: the batch ends here.
enum _Step { wrote, skipped, later, stop }

/// A since token to save, only when the stored token is still [expect].
typedef _TokenSave = ({String token, String expect});

/// What a page's last transaction writes besides its message, computed in
/// the write body from the record read fresh there: the record and a since
/// token (§4 rule 2). Null: the walk's entry is no longer the one the page
/// was listed for; write nothing. (The page that ends a close or orphan
/// walk has no such update: its end is a transaction of its own, after the
/// final attempts of its deferred messages.)
typedef _RecordUpdate =
    Future<({ReceiveRecord record, String? sinceToken})?> Function(
      SecureVault v,
      ConversationSync sync,
    );

class _BatchEnd {
  const _BatchEnd({
    required this.completed,
    required this.waitingForWelcome,
    required this.caughtUp,
  });

  final bool completed;
  final bool waitingForWelcome;

  /// The batch ran its one catch-up (a message of a later pair).
  final bool caughtUp;
}

/// The vault the operation started with is no longer the session's.
/// Carries nothing.
class _Stopped implements Exception {
  const _Stopped();
}

/// One operation's vault, user and device; no `toString`.
class _Pass {
  _Pass(this.session, this.vault, this.uid, this.deviceId);

  final VaultSession session;
  final SecureVault vault;
  final String uid;
  final Uint8List deviceId;

  bool get live {
    final v = session.vault;
    return identical(v, vault) && v?.uid == uid;
  }

  /// The first thing every runWrite body does.
  void check(SecureVault v) {
    if (!identical(v, vault) || v.uid != uid || !live) throw const _Stopped();
  }
}

/// The one transaction of one message, inside its runWrite body: the row
/// (dropped at or before cleared_at), the group state, the outbox delete,
/// the sync record (a since token, "epoch must advance"), the receive record
/// and the deferred record, all read or computed fresh in that body.
/// No `toString`.
class _Write {
  _Write(
    this.vault,
    this.id,
    this.sync,
    this.token,
    this.hidden,
    this.record,
    this.onTokenSaved,
  );

  final SecureVault vault;
  final String id;
  final ConversationSync sync;
  final String? token;
  final bool hidden;
  final ReceiveRecord? record;

  /// Called with the since token a transaction of [commit] saved over
  /// [sync]'s, once that transaction committed.
  final void Function(String token) onTokenSaved;

  /// [deferred]: the deferred record to write (an item added or removed
  /// with this message); [rows]: rows of other messages that end with this
  /// transaction (an evicted deferred item; the caller already left out any
  /// that is stored or hidden); [recordOverride]: the receive record to
  /// write instead of [record] (the same record with its group failure
  /// count changed). Each sealed setting is written at most once.
  Future<_Step> commit({
    StoredMessage? row,
    GroupRecord? group,
    String? deleteOutbox,
    (String, String)? tombstone,
    bool epochMustAdvance = false,
    DeferredRecord? deferred,
    List<StoredMessage> rows = const [],
    ReceiveRecord? recordOverride,
  }) async {
    final keptRow = hidden ? null : row;
    final newRecord = recordOverride ?? record;
    // An answer without a since token keeps the stored one.
    final newToken = token != null && token!.isNotEmpty ? token : null;
    final needSync =
        (newToken != null && newToken != sync.sinceToken) ||
        (epochMustAdvance && !sync.epochMustAdvance);
    if (keptRow == null &&
        group == null &&
        deleteOutbox == null &&
        tombstone == null &&
        newRecord == null &&
        deferred == null &&
        rows.isEmpty &&
        !needSync) {
      return _Step.skipped;
    }
    await vault.transaction((tx) async {
      if (group != null) await tx.putGroup(group);
      if (keptRow != null) await tx.putMessage(keptRow);
      for (final other in rows) {
        await tx.putMessage(other);
      }
      if (tombstone != null) {
        await tx.setMessageState(id, tombstone.$1, tombstone.$2);
      }
      if (deleteOutbox != null) await tx.deleteOutbox(deleteOutbox);
      if (deferred != null) {
        await tx.putSetting(DeferredRecords.keyOf(id), deferred.encode());
      }
      if (newRecord != null) {
        await tx.putSetting(ReceiveRecords.keyOf(id), newRecord.encode());
      }
      if (needSync) {
        await tx.putConversationSync(
          id,
          sync.copyWith(
            sinceToken: newToken,
            epochMustAdvance: epochMustAdvance ? true : null,
          ),
        );
      }
    });
    if (newToken != null && newToken != sync.sinceToken) {
      onTokenSaved(newToken);
    }
    return _Step.wrote;
  }
}
