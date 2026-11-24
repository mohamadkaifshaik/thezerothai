import 'dart:async';
import 'dart:convert';
import 'dart:math' show Random;

import 'package:flutter/foundation.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../core/vault/secure_vault.dart';
import '../../../../core/vault/vault_session.dart';
import '../../../../core/vault/vault_status.dart';
import '../../../../gen/dzeroth/keys/v1/keys.pb.dart' as kpb;
import '../conversation_id.dart';
import 'e2ee_pipeline.dart';
import 'e2ee_types.dart';
import 'encrypted_messaging.dart';
import 'group_starter.dart' show InitDiscard, StartOutcome, StartResult;
import 'membership_rules.dart' show codeParties;
import 'message_content_codec.dart';
import 'pipeline_support.dart' show kServerRequestDeadline;
import 'thread_view.dart';

part 'encrypted_messaging_reads.dart';
part 'encrypted_messaging_threads.dart';

/// Plan 5a Task 13b: the screens' port ([EncryptedMessaging], 5b's text)
/// over the pipeline ([E2eePipeline]). One for the app's lifetime, built by
/// `encryptedMessagingOver` in `app/e2ee_wiring.dart` where a vault is
/// supported; 5b's Task 14 hands it to the widget tree.
///
/// This file: the send path ([send], [retrySend]), the unsent rows
/// ([unsentEntries]) and the thin maps (step 13b-i). The part
/// `encrypted_messaging_threads.dart`: [watchThread] and [loadOlder]; the
/// part `encrypted_messaging_reads.dart`: the code, previews, search,
/// reports and own devices (step 13b-ii).
///
/// **R1: with no vault nothing runs.** With no ready vault every member
/// answers at once and calls nothing but [send]'s two cache reads (the
/// pinned inertness test): no engine, no vault, no key directory, no MLS
/// method. The constructor only adds listeners.
///
/// **Memory across accounts (security read L3, gate item 30).** When the
/// session's vault changes (sign-out, another user, a lost lock, a new
/// vault object), every thread stream is closed and the bound recipient
/// refs and the last own-device list are forgotten ([_checkVault]); the
/// known set is the pipeline's, per vault.
///
/// Never logs; an unexpected failure is reported through the pipeline as
/// `E2eePipelineError` with a fixed step name only, and the member gives
/// its "unavailable" answer. Defines no `toString`.
class EncryptedMessagingImpl implements EncryptedMessaging {
  /// [partsWait]: how long a send waits for the parts of a ready vault
  /// (13b-i review M3); tests shorten it.
  EncryptedMessagingImpl(
    E2eePipeline pipeline, {
    Duration partsWait = kServerRequestDeadline,
  }) : _pipeline = pipeline,
       _partsWait = partsWait {
    _pipeline.changes.listen(_onChanged);
    _pipeline.resumed.listen((_) {
      for (final t in [..._threads.values]) {
        t.armClock();
      }
    });
    _session.status.addListener(_onStatus);
    _pipeline.deviceKeys.status.addListener(_onStatus);
    _pipeline.deviceKeys.removedElsewhereFact.addListener(_onStatus);
  }

  final E2eePipeline _pipeline;
  final Duration _partsWait;
  final StreamController<String> _previewChanged = StreamController.broadcast();

  VaultSession get _session => _pipeline.session;

  /// The open threads, one per ref (gate item 29).
  final Map<ThreadRef, _Thread> _threads = {};

  /// How many threads this port holds (branch review m1: none once their
  /// last listener left).
  @visibleForTesting
  int get threadCountForTest => _threads.length;

  /// K2: recipient ref -> the conversation id a send (or the vault) bound
  /// it to.
  final Map<String, String> _bound = {};

  /// The refs of the last [ownDevices] answer (gate item 37) and the last
  /// readable directory list (a rate limit answers it again).
  Set<String>? _ownRefs;
  List<kpb.KeyDevice>? _lastDirectory;

  /// SA L2 (flag-on gate G3): the screens' handles of unreadable unsent
  /// rows ([EncryptedThread.unreadableUnsent]), random per run, mapped here
  /// to the row's conversation and outbox key. The key itself (the
  /// idempotency key sent on the wire) never leaves the port. Forgotten
  /// with the vault (L3) and when the row is deleted.
  final Map<String, ({String conversationId, String key})> _unreadableRows = {};
  final Map<String, String> _unreadableHandleOf = {};
  final Random _handles = Random.secure();

  /// How many unreadable-row handles this port holds (the code seat's nit:
  /// none for rows deleted another way once their thread is rebuilt).
  @visibleForTesting
  int get unreadableHandleCountForTest => _unreadableRows.length;

  /// The vault the memory above belongs to (L3).
  SecureVault? _vaultSeen;

  /// L3: a vault other than the one the memory belongs to forgets it all
  /// (every thread stream closes: its screen opens a new one).
  void _checkVault() {
    final v = _session.vault;
    if (identical(v, _vaultSeen)) return;
    final had = _vaultSeen != null;
    _vaultSeen = v;
    if (!had) return;
    final threads = [..._threads.values];
    _threads.clear();
    _bound.clear();
    _ownRefs = null;
    _lastDirectory = null;
    _unreadableRows.clear();
    _unreadableHandleOf.clear();
    for (final t in threads) {
      t.close();
    }
  }

  void _onStatus() {
    _checkVault();
    for (final t in [..._threads.values]) {
      t.refreshIfWatched();
    }
  }

  void _onChanged(String conversationId) {
    _checkVault();
    if (!_previewChanged.isClosed) _previewChanged.add(conversationId);
    for (final t in [..._threads.values]) {
      if (t.shows(conversationId)) t.refreshIfWatched();
    }
  }

  /// SA L2: the handle of the unreadable row [key] of [conversationId], the
  /// same one for the whole run (128 random bits, hex).
  String _unreadableHandle(String conversationId, String key) =>
      _unreadableHandleOf.putIfAbsent(key, () {
        final handle = [
          for (var i = 0; i < 16; i++)
            _handles.nextInt(256).toRadixString(16).padLeft(2, '0'),
        ].join();
        _unreadableRows[handle] = (conversationId: conversationId, key: key);
        return handle;
      });

  /// Code seat nit: after a fresh read of [conversationId]'s unreadable
  /// keys, the handles of that conversation whose key is no longer listed
  /// go (a row deleted another way: delete-for-me, a drain).
  void _pruneUnreadable(String conversationId, Iterable<String> keys) {
    final live = keys.toSet();
    _unreadableRows.removeWhere((handle, row) {
      if (row.conversationId != conversationId || live.contains(row.key)) {
        return false;
      }
      _unreadableHandleOf.remove(row.key);
      return true;
    });
  }

  /// K2: [recipient]'s thread continues under [conversationId].
  void _bind(String recipient, String conversationId) {
    _bound[recipient] = conversationId;
    for (final t in [..._threads.values]) {
      if (t.ref.recipientUserId == recipient) t.refreshIfWatched();
    }
  }

  /// A programming error, reported (with a fixed step literal at each call
  /// site: Task 15 forbids interpolated text); a closed vault (StateError)
  /// or a failed read (an Exception) is quiet and gives the member's
  /// "unavailable" answer.
  static bool _isBug(Object error) => error is Error && error is! StateError;

  // -------------------------------------------------------------------------
  // This device (gate items 34, 35)

  @override
  ValueListenable<bool> get removedElsewhere =>
      _pipeline.deviceKeys.removedElsewhereFact;

  /// Security read M5: one `ListMyKeyDevices` read now, only while removed
  /// elsewhere; nothing at all otherwise (the inertness test: no vault, no
  /// call).
  @override
  Future<void> checkRemovedAgain() async {
    final keys = _pipeline.deviceKeys;
    if (!keys.removedElsewhere) return;
    await keys.checkAgainNow();
  }

  /// R17: [FeatureDisabledException] unless the flag is on, [StateError]
  /// unless removed elsewhere (both before anything is written), then the
  /// pipeline's set up again (`DeviceReset.setUpAgain` with the crypto's
  /// key history, gate item 34). An unexpected failure is reported and
  /// surfaces as a [StateError].
  @override
  Future<void> setUpDeviceAgain() async {
    if (!_session.mayStart) {
      throw const FeatureDisabledException('Encrypted messages are not on.');
    }
    if (!_pipeline.deviceKeys.removedElsewhere) {
      throw StateError('This device is not removed elsewhere.');
    }
    try {
      await _pipeline.setUpAgain();
    } on AppException {
      rethrow;
    } on StateError {
      rethrow;
    } on Object catch (_, s) {
      _pipeline.reportPortError('port.setUpAgain', s);
      throw StateError('Set up again did not complete.');
    }
  }

  /// A7: `DeviceKeysService.retryNow` for the open vault. Gate item 35:
  /// with no open vault nothing runs (R1: nothing is generated or sent for
  /// a device with no vault).
  @override
  Future<void> retryDeviceSetup() async {
    if (_session.vault == null) return;
    await _pipeline.deviceKeys.retryNow();
  }

  // -------------------------------------------------------------------------
  // Threads

  /// The vault's known set (security read C1); false before it is ready.
  @override
  bool hasLocal(String conversationId) {
    final parts = _pipeline.parts;
    return parts != null &&
        parts.known.isLoadedFor(parts.vault) &&
        parts.known.contains(conversationId);
  }

  @override
  Stream<EncryptedThread> watchThread(ThreadRef ref) {
    _checkVault();
    return _threads.putIfAbsent(ref, () => _Thread(this, ref)).stream;
  }

  /// Widens [ref]'s window by [kThreadPage] rows and re-emits; nothing for
  /// a thread nobody watches. No network.
  @override
  Future<void> loadOlder(ThreadRef ref) async {
    _checkVault();
    final t = _threads[ref];
    // Branch review n2: a thread nobody watches reads nothing.
    if (t == null || !t.watched) return;
    t.window += kThreadPage;
    await t.refresh();
  }

  /// Plan Task 13b order, security reads C1 and H1, re-reads R1 and R2.
  ///
  /// [ArgumentError] first, whatever the state (programming errors): an
  /// empty [localId], content over [kMaxMessageContentBytes], an invalid
  /// conversation id, an empty recipient; and (from the sender or the
  /// starter) a [localId] an unsent row already has. Then:
  /// 1. no ready vault ([_sendWithoutVault]): `refused(blocked)` while a
  ///    vault is known on this device; `refused(retryable)` while the
  ///    session cannot say whether one exists (F5: "try again");
  ///    otherwise the cache's sticky encrypted marker decides between
  ///    `refused(blocked)` and `notEncrypted` (R1's inert case);
  /// 2. a ready vault ([_sendRouted]): `GroupStarter.startOrRoute`, which
  ///    asks the known set and the cache before the flag and any lookup.
  ///
  /// Gate item 2: `startOrRoute` is called only with a ready vault, which
  /// exists only after the session's sign-in step completed (a vault opens
  /// from `onSignedIn`, a flag answer or a retry, all queued after it).
  @override
  Future<SendOutcome> send({
    required ThreadRef to,
    required String localId,
    required String text,
    String sharedPostId = '',
  }) async {
    if (localId.isEmpty) throw ArgumentError('A row needs a local id.');
    // Throws ArgumentError over the limit; the bytes are not kept.
    encodeMessageContent(
      text: text,
      sharedPostId: sharedPostId,
      reportKey: Uint8List(kReportKeyBytes),
    );
    final conversationId = to.conversationId;
    final recipient = to.recipientUserId;
    if (conversationId != null && !isConversationId(conversationId)) {
      throw ArgumentError('Invalid conversation id.');
    }
    if (conversationId == null && (recipient == null || recipient.isEmpty)) {
      throw ArgumentError('A recipient needs a reference.');
    }
    try {
      final parts = await _partsForSend();
      if (parts == null) {
        return await _sendWithoutVault(conversationId, recipient);
      }
      final out = await _sendRouted(
        parts,
        conversationId: conversationId,
        recipient: recipient,
        localId: localId,
        text: text,
        sharedPostId: sharedPostId,
      );
      // K2 (gate item 29): the recipient's thread continues under the id.
      final bound = out.conversationId;
      if (recipient != null &&
          out.kind == SendOutcomeKind.queued &&
          bound != null) {
        _checkVault();
        _bind(recipient, bound);
      }
      return out;
    } on ArgumentError {
      rethrow;
    } on StateError {
      // The vault closed meanwhile: nothing was saved, and no conversation
      // can be classified now (C1 step 5).
      return _refused(SendProblem.blocked);
    } on Object catch (_, s) {
      // Fail closed: never plaintext in doubt; the user may try again.
      _pipeline.reportPortError('port.send', s);
      return _refused(SendProblem.retryable);
    }
  }

  /// 13b-i review M3, decision: while the session's vault is ready and its
  /// parts are not built yet (they come after the device keys' network
  /// run, at every launch), a send waits for them, at most [_partsWait]
  /// (the server request deadline), and gives up at once when the status
  /// leaves `ready`. Why: the hook order stays fail-closed (parts after the
  /// device check), and a send typed right after launch no longer needs a
  /// resend by hand. With no parts after the wait, [_sendWithoutVault]
  /// answers `refused(blocked)` as before (the vault is known).
  Future<PipelineParts?> _partsForSend() async {
    final now = _pipeline.parts;
    final status = _session.status;
    if (now != null || status.value != VaultStatus.ready) return now;
    final done = Completer<void>();
    void finish() {
      if (!done.isCompleted) done.complete();
    }

    void onStatus() {
      if (status.value != VaultStatus.ready) finish();
    }

    // Subscribed with no await after the check above: parts built from
    // here on are seen.
    final sub = _pipeline.partsBuilt.listen((_) => finish(), onDone: finish);
    status.addListener(onStatus);
    final timer = Timer(_partsWait, finish);
    try {
      await done.future;
    } finally {
      timer.cancel();
      status.removeListener(onStatus);
      await sub.cancel();
    }
    return _pipeline.parts;
  }

  static SendOutcome _refused(SendProblem problem, [AppException? error]) =>
      SendOutcome(SendOutcomeKind.refused, problem: problem, error: error);

  Future<SendOutcome> _sendWithoutVault(
    String? conversationId,
    String? recipient,
  ) async {
    final session = _session;
    // Branch audit L1, decision: the answer is bound to the account the
    // send began under (the authenticated uid at entry); an account that
    // changed before the answer (a direct switch during a cache read wipes
    // the cache) is "try again", never plaintext. No account: "try again".
    final account = _pipeline.authenticatedUid;
    if (account == null) return _refused(SendProblem.retryable);
    // (1) C1 step 5: a vault on this device that is not ready (opening
    // included): no conversation can be classified.
    if (session.vaultKnown) return _refused(SendProblem.blocked);
    // 13b-i review M4 (Task 8 review N2): before the signed-in user's
    // sign-in step finished, the status is the initial `off`, which cannot
    // be told from "no vault here" (a vault-known conversation whose cache
    // mark is gone would go out plaintext): "try again". No send can be
    // made before sign-in, so this costs nothing.
    if (!session.signInStepDone) return _refused(SendProblem.retryable);
    // F5 / Task 8 review N2: "no vault" only from a session that says so
    // (`off`, or `unsupported`). A marker that could not be read (or a
    // vault being created) may hide a vault: "try again", never plaintext.
    final status = session.status.value;
    if (status != VaultStatus.off && status != VaultStatus.unsupported) {
      return _refused(SendProblem.retryable);
    }
    // (2) No vault on this device: the cache's sticky marker (C1), for a
    // recipient through the row cached with that person (re-read R1).
    final messaging = _pipeline.messaging;
    if (conversationId != null) {
      if (await messaging.cachedEverEncrypted(conversationId)) {
        return _refused(SendProblem.blocked);
      }
    } else {
      final row = await messaging.cachedConversationWith(recipient!);
      if (row != null &&
          row.id.isNotEmpty &&
          await messaging.cachedEverEncrypted(row.id)) {
        return _refused(SendProblem.blocked);
      }
    }
    // A vault that became known during the reads above.
    if (session.vaultKnown || _pipeline.parts != null) {
      return _refused(SendProblem.blocked);
    }
    // L1: no await from here to the answer.
    if (_pipeline.authenticatedUid != account || !session.signInStepDone) {
      return _refused(SendProblem.retryable);
    }
    return SendOutcome(
      SendOutcomeKind.notEncrypted,
      conversationId: conversationId,
    );
  }

  /// (3) A ready vault. The peer of a conversation is the one the vault
  /// stored for it (gate item 6: a thread sends only to `peerOf(X)`; the
  /// starter refuses a stored ref of the same id kind that names someone
  /// else), else its cached header's.
  Future<SendOutcome> _sendRouted(
    PipelineParts parts, {
    required String? conversationId,
    required String? recipient,
    required String localId,
    required String text,
    required String sharedPostId,
  }) async {
    final known = parts.known;
    if (!known.isLoadedFor(parts.vault)) await known.load(parts.vault);
    var peer = recipient ?? '';
    if (conversationId != null) {
      peer = known.peerOf(conversationId) ?? '';
      if (peer.isEmpty) {
        final row = await _pipeline.messaging.cachedConversation(
          conversationId,
        );
        if (row != null && row.hasPeer()) peer = row.peer.userId;
      }
      if (peer.isEmpty) {
        return _sendUnaddressed(
          parts,
          conversationId,
          localId,
          text,
          sharedPostId,
        );
      }
    }
    final outcome = await parts.starter.startOrRoute(
      localId: localId,
      peerUserId: peer,
      conversationId: conversationId,
      text: text,
      sharedPostId: sharedPostId,
    );
    return _outcomeOf(parts, outcome, conversationId, peer);
  }

  /// A conversation with no stored peer and no cached header: it cannot be
  /// routed. One this device ever knew as encrypted takes the row with the
  /// sender (it waits or goes out in the existing group; never plaintext);
  /// any other is "try again" (the header arrives with the thread's sync).
  Future<SendOutcome> _sendUnaddressed(
    PipelineParts parts,
    String conversationId,
    String localId,
    String text,
    String sharedPostId,
  ) async {
    final encrypted =
        parts.known.contains(conversationId) ||
        await _pipeline.messaging.cachedEverEncrypted(conversationId);
    if (!encrypted) return _refused(SendProblem.retryable);
    if (_pipeline.deviceKeys.stopsPipeline) {
      return _refused(SendProblem.blocked);
    }
    await parts.sender.enqueue(
      localId: localId,
      conversationId: conversationId,
      text: text,
      sharedPostId: sharedPostId,
    );
    return SendOutcome(SendOutcomeKind.queued, conversationId: conversationId);
  }

  /// The starter's answer as the port's. Gate item 10: the outcome and its
  /// cause are never logged or interpolated.
  Future<SendOutcome> _outcomeOf(
    PipelineParts parts,
    StartOutcome outcome,
    String? conversationId,
    String peer,
  ) async {
    switch (outcome.result) {
      case StartResult.started:
      case StartResult.joinedExisting:
        return SendOutcome(
          SendOutcomeKind.queued,
          conversationId: outcome.conversationId ?? conversationId,
        );
      case StartResult.plaintext:
        // Gate item 3: asked once more right before the caller's plaintext
        // call (the cache first, then the known set with no await after
        // it): a welcome joined during the routing is never sent around.
        final messaging = _pipeline.messaging;
        if (conversationId != null &&
            await messaging.cachedEverEncrypted(conversationId)) {
          return _refused(SendProblem.blocked);
        }
        // 13b-i review M1: a recipient's cached row is read again too (it
        // may have arrived, marked encrypted, during the lookup).
        if (conversationId == null) {
          final row = await messaging.cachedConversationWith(peer);
          if (row != null &&
              row.id.isNotEmpty &&
              (parts.known.contains(row.id) ||
                  await messaging.cachedEverEncrypted(row.id))) {
            return _refused(SendProblem.blocked);
          }
        }
        final known = parts.known;
        if (!parts.live ||
            (conversationId != null && known.contains(conversationId)) ||
            known.ids.any((id) => known.peerOf(id) == peer)) {
          return _refused(SendProblem.blocked);
        }
        return SendOutcome(
          SendOutcomeKind.notEncrypted,
          conversationId: conversationId,
        );
      case StartResult.peerHasNoDevice:
        return _refused(SendProblem.peerHasNoDevice);
      case StartResult.tryAgainTomorrow:
        return _refused(SendProblem.tryTomorrow);
      case StartResult.lookupFailed:
        // H1: an unreadable lookup sends nothing; the user may try again.
        // CANNOT_MESSAGE is the lasting refusal with its typed error.
        final cause = outcome.cause;
        return cause is CannotMessageException
            ? _refused(SendProblem.refused, cause)
            : _refused(SendProblem.retryable);
      case StartResult.unavailable:
        return _refused(SendProblem.blocked);
    }
  }

  /// Gate items 14 and 15 (port additions). A pending init row (the first
  /// message of a new encrypted conversation) goes through the starter's
  /// `discardInit`, with its rules; any other row through the sender's
  /// `discard`, and after a deletion the conversation's new oldest row
  /// through `retryStart` (review F1). Never throws: a failure in doubt is
  /// `notDecided` (nothing is claimed), a bug is reported first.
  @override
  Future<UnsentDiscard> discardUnsent(String localId) async {
    _checkVault();
    final parts = _pipeline.parts;
    if (localId.isEmpty || parts == null) return UnsentDiscard.none;
    try {
      final row = await _outboxRow(parts, localId);
      if (row == null) return UnsentDiscard.none;
      if (row.init != null) return await _discardInit(parts, row);
      final id = row.conversationId;
      // A row with no conversation id yet is not the sender's to discard;
      // it goes once its start names the conversation.
      if (id == null) return UnsentDiscard.notDecided;
      final deleted = await parts.sender.discard(localId);
      // CR n1: the discard failed (a write that did not go through): what
      // happened to the row is not known, so nothing is claimed.
      if (deleted == null) return UnsentDiscard.notDecided;
      if (!deleted) {
        // Kept (it may have been accepted, or a send of it is running), or
        // gone meanwhile (delivered, or deleted with its conversation).
        return await _outboxRow(parts, localId) == null
            ? UnsentDiscard.none
            : UnsentDiscard.held;
      }
      await _restartAfterDiscard(parts, id);
      return UnsentDiscard.discarded;
    } on Object catch (e, s) {
      if (_isBug(e)) _pipeline.reportPortError('port.discardUnsent', s);
      return UnsentDiscard.notDecided;
    }
  }

  /// The outbox row [localId] of the open vault, or null.
  static Future<OutboxItem?> _outboxRow(
    PipelineParts parts,
    String localId,
  ) async {
    for (final r in (await parts.vault.outbox()).items) {
      if (r.localId == localId) return r;
    }
    return null;
  }

  /// Gate item 15: [row] is an init row; only while it is the pending init
  /// of its conversation is it discarded, by the starter (offered on a
  /// pending init row only).
  ///
  /// SA L1 (flag-on gate G1): the init discard makes MLS calls, so it runs
  /// only while the pipeline is started and nothing stops it, the rule the
  /// pipeline's own delete-for-me uses (`_discardOrOwe`); otherwise
  /// `notDecided` ("try again") with no call. The starter checks the
  /// stopped fact itself too.
  Future<UnsentDiscard> _discardInit(
    PipelineParts parts,
    OutboxItem row,
  ) async {
    if (!_pipeline.started || _pipeline.deviceKeys.stopsPipeline) {
      return UnsentDiscard.notDecided;
    }
    final id = row.conversationId;
    final recipient = row.recipientUserId;
    final pending = id != null
        ? await parts.starter.pendingInit(conversationId: id)
        : (recipient == null || recipient.isEmpty)
        ? null
        : await parts.starter.pendingInit(recipientUserId: recipient);
    final conversation = pending?.conversationId;
    if (pending == null ||
        pending.localId != row.localId ||
        conversation == null) {
      // Settled or discarded meanwhile, or not decided yet.
      return await _outboxRow(parts, row.localId) == null
          ? UnsentDiscard.none
          : UnsentDiscard.notDecided;
    }
    return switch (await parts.starter.discardInit(conversation)) {
      InitDiscard.discarded => UnsentDiscard.stopped,
      InitDiscard.settled => UnsentDiscard.delivered,
      InitDiscard.held => UnsentDiscard.held,
      InitDiscard.notDecided => UnsentDiscard.notDecided,
      InitDiscard.none => UnsentDiscard.none,
    };
  }

  /// Review F1 (Task 8, binding for 13b; gate item 14): after a deletion,
  /// the conversation's new oldest row is started again, so a row that
  /// waited behind the discarded one does not read "waiting" with no
  /// control (a no-op when that row is failed). A failure here is quiet:
  /// the row was deleted all the same.
  Future<void> _restartAfterDiscard(PipelineParts parts, String id) async {
    try {
      final rows = await parts.sender.outgoing(id);
      if (rows.isNotEmpty) await parts.starter.retryStart(rows.first.localId);
    } on Object catch (e, s) {
      if (_isBug(e)) _pipeline.reportPortError('port.discardUnsent.next', s);
    }
  }

  /// Gate item 18 (port additions): the sender deletes the row only while
  /// it is still unreadable, under the conversation lock; no network, no
  /// plaintext. False with no ready vault, an invalid id, and a [ref] that
  /// is not a handle this run gave out for that conversation (SA L2: an
  /// outbox key itself, an unknown or a stale handle).
  @override
  Future<bool> deleteUnreadableUnsent(String conversationId, String ref) async {
    _checkVault();
    final parts = _pipeline.parts;
    if (parts == null || ref.isEmpty || !isConversationId(conversationId)) {
      return false;
    }
    final row = _unreadableRows[ref];
    if (row == null || row.conversationId != conversationId) return false;
    final deleted = await parts.sender.deleteUnreadable(
      conversationId,
      row.key,
    );
    if (deleted) {
      _unreadableRows.remove(ref);
      _unreadableHandleOf.remove(row.key);
    }
    return deleted;
  }

  /// Gate item 13: every retry of an unsent row goes through the starter's
  /// `retryStart` (it resends an init, starts again from fresh claims when
  /// allowed, or hands the row to the sender's retry). Unknown id, or no
  /// ready vault: a no-op. Never throws.
  @override
  Future<void> retrySend(String localId) async {
    if (localId.isEmpty) return;
    final parts = _pipeline.parts;
    if (parts == null) return;
    await parts.starter.retryStart(localId);
  }

  /// The own unsent rows of [ref], oldest first, as the port's entries
  /// (Task 13b step 13b-ii's `watchThread` shows them newest first).
  ///
  /// Gate item 12: the starter's pending init row is merged AHEAD of the
  /// sender's rows (a recipient-addressed init is invisible to
  /// `outgoing` while its group is provisional), and a row listed by both
  /// is shown once, as the init. Gate item 17: null when the rows cannot be
  /// read now (no ready vault, a vault whose cipher cannot run): never an
  /// empty list, which always means "no unsent rows".
  ///
  /// 13b-i review N2, decision: also null when the rows were read and only
  /// `describeState` failed. Why: each entry's status depends on the
  /// conversation's state (a blocked row says why), and an entry built from
  /// a guessed state could say "sending" for a row that cannot go; the
  /// caller already treats null as "can't tell now" and keeps what it shows.
  Future<List<DecryptedMessage>?> unsentEntries(ThreadRef ref) async {
    final parts = _pipeline.parts;
    if (parts == null) return null;
    try {
      var id = ref.conversationId;
      final OutgoingRow? init;
      if (id != null) {
        init = await parts.starter.pendingInit(conversationId: id);
      } else {
        final recipient = ref.recipientUserId!;
        init = await parts.starter.pendingInit(recipientUserId: recipient);
        id =
            init?.conversationId ??
            await parts.known.conversationForPeer(parts.vault, recipient);
      }
      final rows = id == null
          ? const <OutgoingRow>[]
          : await parts.sender.outgoing(id);
      final state = id == null
          ? ConversationCryptoState.initial
          : await parts.crypto.describeState(id);
      return [
        if (init != null) entryOfOutgoing(init, state),
        for (final r in rows)
          if (r.localId != init?.localId) entryOfOutgoing(r, state),
      ];
    } on Object catch (e, s) {
      // A closed vault (StateError) or a vault whose cipher cannot run (an
      // Exception) is quiet; only a programming error is reported.
      if (e is Error && e is! StateError) {
        _pipeline.reportPortError('port.unsent', s);
      }
      return null;
    }
  }

  /// Gate item 33, plan Difference 3: the starter's reset, with its two
  /// refusals the server's errors do not cover as [ResetRefusedException];
  /// [FeatureDisabledException] with the flag not on; an internal
  /// `unavailable` stays [E2eeActionException]. [RateLimitedException] and
  /// the server's typed [AppException]s pass through.
  @override
  Future<void> resetConversation(String conversationId) async {
    if (!_session.mayStart) {
      throw const FeatureDisabledException('Encrypted messages are not on.');
    }
    final parts = _pipeline.parts;
    if (parts == null) {
      throw const E2eeActionException(E2eeRefusal.unavailable);
    }
    try {
      await parts.starter.resetConversation(conversationId);
    } on E2eeActionException catch (e) {
      switch (e.refusal) {
        case E2eeRefusal.notAccepted:
          throw const ResetRefusedException(ResetRefusal.notAccepted);
        case E2eeRefusal.peerHasNoDevice:
          throw const ResetRefusedException(ResetRefusal.peerHasNoDevice);
        case E2eeRefusal.flagOff:
          throw const FeatureDisabledException(
            'Encrypted messages are not on.',
          );
        case E2eeRefusal.unavailable:
        case E2eeRefusal.notMember:
        case E2eeRefusal.tryAgainTomorrow:
        case E2eeRefusal.refusedByServer:
          rethrow;
      }
    } on AppException {
      rethrow;
    } on ArgumentError {
      rethrow;
    } on StateError {
      throw const E2eeActionException(E2eeRefusal.unavailable);
    } on Object catch (_, s) {
      _pipeline.reportPortError('port.reset', s);
      throw const E2eeActionException(E2eeRefusal.unavailable);
    }
  }

  // -------------------------------------------------------------------------
  // Step 13b-ii: the bodies are in the part encrypted_messaging_reads.dart.

  @override
  Future<SecurityCode> securityCode(String conversationId) {
    _checkVault();
    return _securityCode(conversationId);
  }

  @override
  Future<Map<String, ConversationPreview>> previews(
    Iterable<String> conversationIds,
  ) {
    _checkVault();
    return _previews(conversationIds);
  }

  /// The conversation id after every pipeline change of it (a superset of
  /// "its newest row changed": a stored message, a delete, an outgoing row,
  /// a state change). Never carries content.
  @override
  Stream<String> get previewChanged => _previewChanged.stream;

  @override
  Future<List<EncryptedSearchHit>> search(
    String query, {
    String? conversationId,
    int limit = 200,
  }) {
    _checkVault();
    return _search(query, conversationId: conversationId, limit: limit);
  }

  @override
  Future<Uint8List?> reportPayload(String conversationId, String messageId) {
    _checkVault();
    return _storedPayload(conversationId, messageId);
  }

  @override
  Future<OwnDeviceList> ownDevices() {
    _checkVault();
    return _ownDevices();
  }

  @override
  Future<DeviceRemoval> removeDevice(String ref) {
    _checkVault();
    return _removeDevice(ref);
  }

  /// The open vault's removal queue count (the pipeline follows each
  /// vault's parts); 0 with no vault.
  @override
  ValueListenable<int> get removalsPending => _pipeline.removalsPending;

  /// Lane D (port additions): the open vault's runner's ask, followed by
  /// the pipeline across vaults; false with no vault.
  @override
  ValueListenable<bool> get needsReauth => _pipeline.removalNeedsReauth;

  @override
  ValueListenable<List<String>> get parkedRemovals => _pipeline.parkedRemovals;

  @override
  Future<void> dropRemoval(String ref) {
    _checkVault();
    return _dropRemoval(ref);
  }
}
