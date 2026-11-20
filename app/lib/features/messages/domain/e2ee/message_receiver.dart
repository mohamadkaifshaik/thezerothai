import 'dart:collection';
import 'dart:typed_data';

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
import 'e2ee_types.dart';
import 'message_content_codec.dart';
import 'sync_budget.dart';

/// The contract's page size for `ListEpochMessages` (at most 50).
const int kEpochPageSize = 50;

/// The most `ListEpochMessages` pages one epoch walk reads (50 messages a
/// page, restarts included). An epoch longer than that is not complete: the
/// walk stops (the commit after it waits), so a server that always answers
/// another page cannot hold the conversation lock forever.
const int _kEpochPagesMax = 100;

/// The most gap pages one live pull follows after its since page. At the cap
/// the pull is interrupted (nothing of it is processed, the token is kept).
const int _kLiveGapPagesMax = 20;

/// The most pages the walk after a retired since token reads (first page
/// included). Older tombstones are not reconciled past it (Open question 5:
/// the whole thread by default; this bound keeps one pass finite).
const int _kRetiredWalkPagesMax = 40;

/// How many message ids handled without a row (a forgery, this device's own
/// message already in its sent log) are remembered this run, so a second
/// listing of the same message neither counts it again nor turns it into an
/// `undecryptable` row once its pair is behind the group.
const int _kRowlessRemembered = 4096;

final RegExp _messageIdShape = RegExp(r'^[0-9a-f]{32}$');

/// Receiving encrypted messages (Task 6, R7, R8, R12, R13, spec 7.5):
/// decrypts, checks and stores each message of a conversation in the vault,
/// as the live pull and as the sink of catch-up's epoch walks.
///
/// Locking: [pullLive] and [applyClearedAtOnce] take the conversation lock;
/// the sink methods ([completeEpoch], [markEpochUndecryptable]) are called by
/// catch-up WITH it held, take no lock and never run catch-up. Inside the
/// lock each message is one `runWrite` body: read fresh, the engine call,
/// and ONE transaction with its result (the new group state and the row).
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
    required ConversationLocks locks,
    required ConversationContexts contexts,
    required DateTime Function() now,
    required void Function(String conversationId) onChanged,
    required DailyLedger ledger,
    void Function(Object error, StackTrace stack)? onUnexpectedError,
  }) : _crypto = crypto,
       _session = session,
       _engine = engine,
       _messaging = messaging,
       _syncBudget = syncBudget,
       _locks = locks,
       _contexts = contexts,
       _now = now,
       _onChanged = onChanged,
       ledger = ledger,
       _onUnexpectedError = onUnexpectedError;

  final ConversationCrypto _crypto;
  final VaultSession _session;
  final CryptoEngine Function() _engine;
  final MessagingRepository _messaging;
  final SyncBudget _syncBudget;
  final ConversationLocks _locks;
  final ConversationContexts _contexts;
  final DateTime Function() _now;
  final void Function(String conversationId) _onChanged;
  final void Function(Object error, StackTrace stack)? _onUnexpectedError;

  /// The daily ledger of the lost-send follow-up (R7): Task 9's self-update
  /// reads it; nothing here writes it.
  final DailyLedger ledger;

  int _forgeries = 0;

  /// `uid|conversationId|messageId` of messages handled without a row this
  /// run (oldest first, at most [_kRowlessRemembered]).
  final LinkedHashSet<String> _rowless = LinkedHashSet();

  /// Own-leaf results without `from_self` (C3), counted once per message per
  /// run; never shown.
  int get forgeriesSkipped => _forgeries;

  // -------------------------------------------------------------------------
  // Live messages

  /// Live messages: ListMessages with the stored since token; commits first
  /// when a message of a later pair appears.
  Future<void> pullLive(
    String conversationId, {
    BudgetPriority priority = BudgetPriority.background,
  }) async {
    var welcomes = false;
    await _locks.run(conversationId, () async {
      welcomes = await _pullLocked(conversationId, priority);
    });
    // Catch-up's held poll stops at a page that lacks the welcome: a welcome
    // it did not find is looked for by an unheld poll, after the lock is
    // released (never a public entry under a held lock).
    if (welcomes) {
      try {
        await _crypto.processWelcomes(priority: priority);
      } on Object catch (e, s) {
        _reportIfBug(e, s, 'receive.welcomes');
      }
    }
  }

  /// One live pull with the lock held; true when catch-up ended waiting for
  /// a welcome. Never throws.
  Future<bool> _pullLocked(String id, BudgetPriority priority) async {
    try {
      final pass = await _start();
      if (pass == null) return false;
      // A provisional group only, or none: catch-up and the welcomes own it.
      if (await _currentPair(pass.vault, id) == null) return false;
      final token = (await pass.vault.conversation(id))?.sync.sinceToken ?? '';
      final listed = await _listLive(pass, id, token, priority);
      if (listed == null) return false;
      _sort(listed.messages);
      final end = await _runBatch(
        pass,
        id,
        listed.messages,
        mode: _Mode.live,
        priority: priority,
        token: listed.sinceToken,
      );
      if (end.completed) {
        // M10: a completed pull at the group's current pair.
        final pair = await _currentPair(pass.vault, id);
        final context = _contexts.of(id);
        if (pair != null) {
          context
            ..livePulledAt = pair
            ..syncedSinceStart =
                !context.attributionPending && context.serverPair == pair;
        }
      }
      return end.waitingForWelcome;
    } on Object catch (e, s) {
      _reportIfBug(e, s, 'receive.live');
      return false;
    }
  }

  /// The batch of one live pull: the since page and its gap pages, or (no
  /// token, or a retired one) the first page, then for a retired token every
  /// older page to the end of the thread (bounded). Null: interrupted.
  Future<({List<pb.Message> messages, String sinceToken})?> _listLive(
    _Pass pass,
    String id,
    String token,
    BudgetPriority priority,
  ) async {
    final messages = <pb.Message>[];
    if (token.isNotEmpty) {
      final first = await _listMls(priority, id, sinceToken: token);
      if (first == _retired) {
        return _walkRetired(pass, id, priority);
      }
      if (first == null) return null;
      messages.addAll(first.messages);
      var gap = first.gapPageToken;
      var pages = 0;
      final seen = <String>{};
      while (gap.isNotEmpty) {
        if (++pages > _kLiveGapPagesMax || !seen.add(gap)) return null;
        final next = await _listMls(priority, id, pageToken: gap);
        if (next == null || next == _retired) return null;
        messages.addAll(next.messages);
        gap = next.nextPageToken;
      }
      return (messages: messages, sinceToken: first.sinceToken);
    }
    final first = await _listMls(priority, id);
    if (first == null || first == _retired) return null;
    if (first.hasConversation()) _contexts.note(first.conversation);
    return (messages: [...first.messages], sinceToken: first.sinceToken);
  }

  /// A retired since token: the token is not used again; the thread is read
  /// from the first page following `next_page_token`, and every message
  /// goes through the one-message rules, which reconcile by id (REMOVED or
  /// DELETED_ACCOUNT clears a stored copy; a stored id is skipped). Nothing
  /// is deleted. Paced by the sync budget (user reads first) and the
  /// repository's read hold.
  Future<({List<pb.Message> messages, String sinceToken})?> _walkRetired(
    _Pass pass,
    String id,
    BudgetPriority priority,
  ) async {
    final first = await _listMls(priority, id);
    if (first == null || first == _retired) return null;
    if (first.hasConversation()) _contexts.note(first.conversation);
    final messages = [...first.messages];
    var next = first.nextPageToken;
    var pages = 1;
    final seen = <String>{};
    while (next.isNotEmpty && pages < _kRetiredWalkPagesMax) {
      if (!seen.add(next)) break;
      final page = await _listMls(priority, id, pageToken: next);
      if (page == null || page == _retired) return null;
      pages++;
      messages.addAll(page.messages);
      next = page.nextPageToken;
    }
    return (messages: messages, sinceToken: first.sinceToken);
  }

  /// One `ListMessages` call (one sync-budget unit). Null when it could not
  /// be made or failed; [_retired] for a refused since token.
  Future<pb.ListMessagesResponse?> _listMls(
    BudgetPriority priority,
    String id, {
    String sinceToken = '',
    String pageToken = '',
  }) async {
    if (!await _takeUnit(priority)) return null;
    try {
      return await _messaging.listMlsMessages(
        conversationId: id,
        sinceToken: sinceToken,
        pageToken: pageToken,
      );
    } on ValidationException catch (e) {
      if (sinceToken.isNotEmpty && e.field == 'since_token') return _retired;
      return null;
    } on Object catch (e, s) {
      _reportIfBug(e, s, 'receive.listMessages');
      return null;
    }
  }

  // -------------------------------------------------------------------------
  // cleared_at (R8)

  /// R8: once per app run per conversation, one ListEpochMessages call for
  /// the current pair; deletes local copies created at or before
  /// `cleared_at`. A `cleared_at` in the future is ignored. Never throws.
  Future<void> applyClearedAtOnce(String conversationId) async {
    final id = conversationId;
    if (_contexts.of(id).clearedAtReadThisRun) return;
    await _locks.run(id, () async {
      final context = _contexts.of(id);
      if (context.clearedAtReadThisRun) return;
      try {
        final pass = await _start();
        if (pass == null) return;
        final pair = await _currentPair(pass.vault, id);
        if (pair == null || pair.epoch < 1) return;
        if (!await _takeUnit(BudgetPriority.user)) return;
        final pb.ListEpochMessagesResponse page;
        try {
          page = await _messaging.listEpochMessages(
            conversationId: id,
            pair: pair,
            pageSize: kEpochPageSize,
          );
        } on Object catch (e, s) {
          _reportIfBug(e, s, 'receive.clearedAt');
          return;
        }
        // Read: not again this run, whatever the value says.
        context.clearedAtReadThisRun = true;
        final cleared = _clearedAtOf(page);
        if (cleared == null) return;
        await _session.runWrite((v) async {
          pass.check(v);
          final sync =
              (await v.conversation(id))?.sync ?? const ConversationSync();
          final stored = sync.clearedAtMicros;
          await v.transaction((tx) async {
            await tx.deleteConversation(id, upToCreatedAtMicros: cleared);
            if (stored == null || cleared > stored) {
              await tx.putConversationSync(
                id,
                sync.copyWith(clearedAtMicros: cleared),
              );
            }
          });
        });
        _onChanged(id);
      } on _Stopped {
        return;
      } on Object catch (e, s) {
        _reportIfBug(e, s, 'receive.clearedAt');
      }
    });
  }

  /// The response's `cleared_at` in microseconds, or null when unset or in
  /// the future.
  int? _clearedAtOf(pb.ListEpochMessagesResponse page) {
    if (!page.hasClearedAt()) return null;
    final at = page.clearedAt.toDateTime();
    if (at.isAfter(_now())) return null;
    final micros = at.microsecondsSinceEpoch;
    return micros < 0 ? null : micros;
  }

  // -------------------------------------------------------------------------
  // The sink (called by catch-up with the conversation lock held)

  /// Every message of [pair] (all pages), sorted by `created_at` then id,
  /// each through the one-message rules. Idempotent. Throws (an
  /// [Exception], so catch-up ends `interrupted` and the commit waits) when
  /// the epoch could not be walked to its end.
  @override
  Future<void> completeEpoch(
    String conversationId,
    MlsPair pair, {
    required BudgetPriority priority,
  }) => _walkEpoch(conversationId, pair, priority, _Mode.epoch);

  /// Every message of [pair] not stored yet becomes an `undecryptable` row
  /// (tombstones, skips and the echo rules as for any message); the engine
  /// is never called. Idempotent; throws like [completeEpoch].
  @override
  Future<void> markEpochUndecryptable(
    String conversationId,
    MlsPair pair, {
    required BudgetPriority priority,
  }) => _walkEpoch(conversationId, pair, priority, _Mode.undecryptable);

  Future<void> _walkEpoch(
    String id,
    MlsPair pair,
    BudgetPriority priority,
    _Mode mode,
  ) async {
    assert(_locks.isHeld(id), 'The caller must hold the conversation lock.');
    // No member can have sent in epoch 0 (the contract lists pairs >= 1).
    if (pair.generation < 1 || pair.epoch < 1) return;
    final pass = await _start();
    if (pass == null) throw const _Stopped();
    final listed = await _listEpoch(id, pair, priority);
    if (listed.clearedAt != null) {
      await _saveClearedAt(pass, id, listed.clearedAt!);
    }
    _sort(listed.messages);
    final end = await _runBatch(
      pass,
      id,
      listed.messages,
      mode: mode,
      priority: priority,
      epoch: pair,
    );
    if (!end.completed) throw const _Stopped();
  }

  /// Every page of [pair]'s messages. A refused page token starts the
  /// listing again once; anything else that fails stops the walk.
  Future<({List<pb.Message> messages, int? clearedAt})> _listEpoch(
    String id,
    MlsPair pair,
    BudgetPriority priority,
  ) async {
    final out = <pb.Message>[];
    int? cleared;
    var token = '';
    var restarted = false;
    var pages = 0;
    final seen = <String>{};
    while (true) {
      if (++pages > _kEpochPagesMax) throw const _Stopped();
      if (!await _takeUnit(priority)) throw const _Stopped();
      final pb.ListEpochMessagesResponse page;
      try {
        page = await _messaging.listEpochMessages(
          conversationId: id,
          pair: pair,
          pageSize: kEpochPageSize,
          pageToken: token,
        );
      } on ValidationException {
        if (token.isEmpty || restarted) throw const _Stopped();
        restarted = true;
        token = '';
        out.clear();
        seen.clear();
        continue;
      } on Object catch (e, s) {
        _reportIfBug(e, s, 'receive.listEpochMessages');
        throw const _Stopped();
      }
      cleared = _clearedAtOf(page) ?? cleared;
      out.addAll(page.messages);
      final next = page.nextPageToken;
      if (next.isEmpty) break;
      if (!seen.add(next)) throw const _Stopped();
      token = next;
    }
    return (messages: out, clearedAt: cleared);
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
  // A batch

  /// Runs [messages] (sorted) in order. Live: a message of a later pair
  /// stops the batch for one catch-up (through the locked entry; its commits
  /// come first), then the batch goes on; a second one stops it. [token]
  /// (live) is saved with the last message's transaction, or alone after it.
  Future<_BatchEnd> _runBatch(
    _Pass pass,
    String id,
    List<pb.Message> messages, {
    required _Mode mode,
    required BudgetPriority priority,
    MlsPair? epoch,
    String? token,
  }) async {
    var caughtUp = false;
    var waiting = false;
    var changed = false;
    var completed = false;
    try {
      var all = true;
      var tokenSaved = false;
      for (var i = 0; i < messages.length; i++) {
        final last = i == messages.length - 1;
        final saveToken = last ? token : null;
        var step = await _one(pass, id, messages[i], mode, epoch, saveToken);
        if (step == _Step.later) {
          // One catch-up per pull: a second later pair waits for the next.
          if (caughtUp) throw const _Stopped();
          caughtUp = true;
          final result = await _crypto.catchUpLocked(id, priority: priority);
          if (result == CatchUpResult.waitingForWelcome) waiting = true;
          if (!pass.live) throw const _Stopped();
          step = await _one(pass, id, messages[i], mode, epoch, saveToken);
          // Still above the group after one catch-up: the next pull.
          if (step == _Step.later) step = _Step.stop;
        }
        if (step == _Step.stop) {
          all = false;
          break;
        }
        if (step == _Step.wrote) {
          changed = true;
          if (saveToken != null) tokenSaved = true;
        }
      }
      // The token goes with the last message's transaction; when that wrote
      // nothing (or the batch is empty), alone after it.
      if (all && token != null && !tokenSaved) {
        await _saveToken(pass, id, token);
      }
      completed = all;
    } on _Stopped {
      completed = false;
    } on Object catch (e, s) {
      _reportIfBug(e, s, 'receive.batch');
      completed = false;
    }
    if (changed) _onChanged(id);
    return _BatchEnd(completed: completed, waitingForWelcome: waiting);
  }

  /// Saves the live since token alone (no message of the batch wrote).
  Future<void> _saveToken(_Pass pass, String id, String token) =>
      _session.runWrite((v) async {
        pass.check(v);
        final sync =
            (await v.conversation(id))?.sync ?? const ConversationSync();
        if (sync.sinceToken == token) return;
        await v.transaction(
          (tx) => tx.putConversationSync(id, sync.copyWith(sinceToken: token)),
        );
      });

  // -------------------------------------------------------------------------
  // One message

  /// One message, under the conversation lock, in ONE `runWrite` body.
  Future<_Step> _one(
    _Pass pass,
    String id,
    pb.Message m,
    _Mode mode,
    MlsPair? epoch,
    String? saveToken,
  ) async {
    final mid = m.id;
    // Not a message of this conversation the vault can key: nothing of it.
    if (!_messageIdShape.hasMatch(mid) ||
        (m.conversationId.isNotEmpty && m.conversationId != id)) {
      return _Step.skipped;
    }
    final g = pairComponentFromInt64(m.mlsGeneration);
    final e = pairComponentFromInt64(m.mlsEpoch);
    final pair = g == null || e == null ? null : MlsPair(g, e);
    final created = m.hasCreatedAt()
        ? m.createdAt.toDateTime().microsecondsSinceEpoch
        : 0;
    final at = created < 0 ? 0 : created;
    final ciphertext = Uint8List.fromList(m.ciphertext);
    final rowlessKey = '${pass.uid}|$id|$mid';
    try {
      return await _session.runWrite((v) async {
        pass.check(v);
        final record = await v.conversation(id);
        final sync = record?.sync ?? const ConversationSync();
        final cleared = sync.clearedAtMicros;
        // 8. At or before cleared_at: processed, never stored.
        final hidden = cleared != null && at <= cleared;
        final write = _Write(v, id, sync, saveToken, hidden);

        // 1. A tombstone clears a stored copy and stores nothing new.
        if (m.state == MessageState.MESSAGE_STATE_REMOVED ||
            m.state == MessageState.MESSAGE_STATE_DELETED_ACCOUNT) {
          if (!await v.hasMessage(id, mid)) return _Step.skipped;
          final state = m.state == MessageState.MESSAGE_STATE_REMOVED
              ? StoredMessageState.removed
              : StoredMessageState.deletedAccount;
          return write.commit(tombstone: (mid, state));
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

        // 2. An epoch before this device joined: nothing.
        final joined = record?.joinHighWater;
        if (pair != null && joined != null && pair.compareTo(joined.next) < 0) {
          return _Step.skipped;
        }
        // 3. Stored (any state): no engine call.
        if (await v.hasMessage(id, mid)) return _Step.skipped;
        // Met before this run without a row (forgery, own message sent).
        if (_rowless.contains(rowlessKey)) return _Step.skipped;

        // 4. The echo of an outbox row: the same id AND the same bytes.
        if (ciphertext.isNotEmpty && await v.hasOutboxExpecting(mid)) {
          for (final item in (await v.outbox()).items) {
            if (item.expectedMessageId != mid ||
                item.stage != OutboxStage.encrypted ||
                (item.conversationId != null && item.conversationId != id) ||
                !_sameBytes(item.ciphertext, ciphertext)) {
              continue;
            }
            return write.commit(
              row: StoredMessage(
                conversationId: id,
                messageId: mid,
                createdAtMicros: at,
                mine: true,
                state: StoredMessageState.visible,
                generation: item.generation,
                epoch: item.epoch,
                content: item.content,
                senderDeviceId: pass.deviceId,
              ),
              deleteOutbox: item.idempotencyKey,
            );
          }
        }

        // 5. Nothing to decrypt.
        if (m.ciphertextRemoved || ciphertext.isEmpty || pair == null) {
          return write.commit(row: undecryptable());
        }

        // An epoch this device can no longer decrypt.
        if (mode == _Mode.undecryptable) {
          if (pair.compareTo(epoch!) > 0) return _Step.skipped;
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
          // Live: catch-up first. An epoch walk never runs catch-up: the
          // message is left for its own epoch.
          return mode == _Mode.live ? _Step.later : _Step.skipped;
        }
        if (order < 0) {
          // Its keys are gone: never given to the engine; no side.
          return write.commit(row: undecryptable());
        }

        // 7. The engine, and ONE transaction with its result.
        final deviceState = await v.deviceState();
        if (deviceState == null) return _Step.stop;
        final ProcessResult result;
        try {
          result = await _engine().process(
            deviceState,
            group.state,
            ciphertext,
          );
        } on MlsException catch (err) {
          switch (err.code) {
            case MlsErrorCode.ownLeaf:
              if (!m.fromSelf) {
                // C3: unauthenticated; a forgery. Counted, never shown.
                if (_remember(rowlessKey)) _forgeries++;
                return _Step.skipped;
              }
              if (await v.hasOutboxExpecting(mid) ||
                  await v.hasSent(id, p, sentDigest(ciphertext))) {
                // Sent by this device (its echo comes, or came, by bytes).
                _remember(rowlessKey);
                return _Step.skipped;
              }
              // R7: a lost send. The epoch must advance before the next
              // encrypt.
              return write.commit(
                row: undecryptable(mine: true),
                epochMustAdvance: true,
              );
            case MlsErrorCode.internal:
            case MlsErrorCode.deadline:
            case MlsErrorCode.unavailable:
              // Transient: nothing stored; the next pull retries.
              return _Step.stop;
            case MlsErrorCode.duplicate:
            case MlsErrorCode.badInput:
            case MlsErrorCode.wrongEpoch:
            case MlsErrorCode.evicted:
            case MlsErrorCode.corruptState:
            case MlsErrorCode.pendingCommit:
            case MlsErrorCode.noPendingCommit:
              // The group state is not changed.
              return write.commit(row: undecryptable());
          }
        }
        final event = result.event;
        if (event is! MlsMessageEvent) {
          // A commit in a message slot: never applied outside catch-up.
          return write.commit(row: undecryptable());
        }
        MemberRecord? sender;
        for (final pin in await v.members(id)) {
          if (_sameBytes(pin.deviceId, event.senderDeviceId)) sender = pin;
        }
        if (sender == null) {
          // Not a pinned member: not believed; the group state is kept.
          return write.commit(row: undecryptable());
        }
        final plaintext = event.plaintext;
        final check = checkMessageContent(
          plaintext,
          Uint8List.fromList(m.reportCommitment),
        );
        return write.commit(
          group: GroupRecord(
            conversationId: id,
            generation: group.generation,
            epoch: group.epoch,
            state: result.groupState,
            pending: group.pending,
          ),
          row: StoredMessage(
            conversationId: id,
            messageId: mid,
            createdAtMicros: at,
            // Direction from the sender device's pinned side, never from
            // the server's from_self.
            mine: sender.side == MemberSide.mine,
            state: StoredMessageState.visible,
            generation: p.generation,
            epoch: p.epoch,
            content: plaintext,
            check: check.name,
            senderDeviceId: event.senderDeviceId,
          ),
        );
      });
    } on _Stopped {
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

  /// One unit of the sync budget; false (make no call) while paused or
  /// after a reset.
  Future<bool> _takeUnit(BudgetPriority priority) async {
    if (_syncBudget.paused) return false;
    try {
      await _syncBudget.take(priority);
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
  messages.sort((a, b) {
    final ta = a.hasCreatedAt()
        ? a.createdAt.toDateTime().microsecondsSinceEpoch
        : 0;
    final tb = b.hasCreatedAt()
        ? b.createdAt.toDateTime().microsecondsSinceEpoch
        : 0;
    final t = ta.compareTo(tb);
    return t != 0 ? t : a.id.compareTo(b.id);
  });
}

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

/// A refused since token (distinct from a failed call).
final pb.ListMessagesResponse _retired = pb.ListMessagesResponse();

enum _Mode { live, epoch, undecryptable }

/// `wrote`: one transaction ran; `skipped`: nothing was written; `later`: a
/// pair above the group's (live only); `stop`: the batch ends here.
enum _Step { wrote, skipped, later, stop }

class _BatchEnd {
  const _BatchEnd({required this.completed, required this.waitingForWelcome});

  final bool completed;
  final bool waitingForWelcome;
}

/// The vault the operation started with is no longer the session's, or an
/// epoch walk could not reach its end. Carries nothing.
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
/// the sync record (the since token of the batch's last message, "epoch
/// must advance"), read fresh in that body. No `toString`.
class _Write {
  _Write(this.vault, this.id, this.sync, this.token, this.hidden);

  final SecureVault vault;
  final String id;
  final ConversationSync sync;
  final String? token;
  final bool hidden;

  Future<_Step> commit({
    StoredMessage? row,
    GroupRecord? group,
    String? deleteOutbox,
    (String, String)? tombstone,
    bool epochMustAdvance = false,
  }) async {
    final keptRow = hidden ? null : row;
    final needSync =
        (token != null && token != sync.sinceToken) ||
        (epochMustAdvance && !sync.epochMustAdvance);
    if (keptRow == null &&
        group == null &&
        deleteOutbox == null &&
        tombstone == null &&
        !needSync) {
      return _Step.skipped;
    }
    await vault.transaction((tx) async {
      if (group != null) await tx.putGroup(group);
      if (keptRow != null) await tx.putMessage(keptRow);
      if (tombstone != null) {
        await tx.setMessageState(id, tombstone.$1, tombstone.$2);
      }
      if (deleteOutbox != null) await tx.deleteOutbox(deleteOutbox);
      if (needSync) {
        await tx.putConversationSync(
          id,
          sync.copyWith(
            sinceToken: token,
            epochMustAdvance: epochMustAdvance ? true : null,
          ),
        );
      }
    });
    return _Step.wrote;
  }
}
