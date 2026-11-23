import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../core/vault/vault_session.dart';
import '../../../../core/vault/vault_status.dart';
import '../conversation_id.dart';
import 'e2ee_pipeline.dart';
import 'e2ee_types.dart';
import 'encrypted_messaging.dart';
import 'group_starter.dart' show StartOutcome, StartResult;
import 'message_content_codec.dart';
import 'thread_view.dart';

/// Plan 5a Task 13b: the screens' port ([EncryptedMessaging], 5b's text)
/// over the pipeline ([E2eePipeline]). One for the app's lifetime, built by
/// `encryptedMessagingOver` in `app/e2ee_wiring.dart` where a vault is
/// supported; 5b's Task 14 hands it to the widget tree.
///
/// **Step 13b-i (this file as of that step):** the send path ([send],
/// [retrySend]), the unsent rows ([unsentEntries]), and the thin maps
/// ([removedElsewhere], [checkRemovedAgain], [setUpDeviceAgain],
/// [retryDeviceSetup], [hasLocal], [resetConversation]). The thread,
/// preview, search, security code, report and device-list members answer
/// their no-vault answers (an empty thread, no previews, no hits, no code,
/// no payload, no devices, nothing pending) while no vault is ready, and
/// are step 13b-ii's otherwise ([_step2]).
///
/// **R1: with no vault nothing runs.** With no ready vault every member
/// answers at once and calls nothing but [send]'s two cache reads (the
/// pinned inertness test): no engine, no vault, no key directory, no MLS
/// method.
///
/// Never logs; an unexpected failure is reported through the pipeline as
/// `E2eePipelineError` with a step name only, and the member gives its
/// "unavailable" answer. Defines no `toString`.
class EncryptedMessagingImpl implements EncryptedMessaging {
  EncryptedMessagingImpl(E2eePipeline pipeline) : _pipeline = pipeline;

  final E2eePipeline _pipeline;
  final StreamController<String> _previewChanged = StreamController.broadcast();
  final ValueNotifier<int> _noRemovals = ValueNotifier(0);

  VaultSession get _session => _pipeline.session;

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
    if (_pipeline.parts != null) _step2('watchThread');
    // Nothing is known with no ready vault: the empty thread the port
    // documents for a ref the pipeline knows nothing about.
    return Stream.value(
      EncryptedThread(
        conversationId: ref.conversationId,
        security: const ConversationSecurity(
          state: ConversationEncryptionState.ready,
        ),
      ),
    );
  }

  @override
  Future<void> loadOlder(ThreadRef ref) async {
    if (_pipeline.parts != null) _step2('loadOlder');
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
      final parts = _pipeline.parts;
      if (parts == null) {
        return await _sendWithoutVault(conversationId, recipient);
      }
      return await _sendRouted(
        parts,
        conversationId: conversationId,
        recipient: recipient,
        localId: localId,
        text: text,
        sharedPostId: sharedPostId,
      );
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

  static SendOutcome _refused(SendProblem problem, [AppException? error]) =>
      SendOutcome(SendOutcomeKind.refused, problem: problem, error: error);

  Future<SendOutcome> _sendWithoutVault(
    String? conversationId,
    String? recipient,
  ) async {
    final session = _session;
    // (1) C1 step 5: a vault on this device that is not ready (opening
    // included): no conversation can be classified.
    if (session.vaultKnown) return _refused(SendProblem.blocked);
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
        if (conversationId != null &&
            await _pipeline.messaging.cachedEverEncrypted(conversationId)) {
          return _refused(SendProblem.blocked);
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
  // Step 13b-ii members: their no-vault answers only (see the class doc).

  @override
  Future<SecurityCode> securityCode(String conversationId) async {
    if (_pipeline.parts != null) _step2('securityCode');
    return const SecurityCode(reason: NoCodeReason.unavailable);
  }

  @override
  Future<Map<String, ConversationPreview>> previews(
    Iterable<String> conversationIds,
  ) async {
    if (_pipeline.parts != null) _step2('previews');
    // Ids the vault does not know are left out: with no vault, every id.
    return const {};
  }

  @override
  Stream<String> get previewChanged => _previewChanged.stream;

  @override
  Future<List<EncryptedSearchHit>> search(
    String query, {
    String? conversationId,
    int limit = 200,
  }) async {
    if (_pipeline.parts != null) _step2('search');
    return const [];
  }

  @override
  Future<Uint8List?> reportPayload(
    String conversationId,
    String messageId,
  ) async {
    if (_pipeline.parts != null) _step2('reportPayload');
    return null;
  }

  @override
  Future<OwnDeviceList> ownDevices() async {
    if (_pipeline.parts != null) _step2('ownDevices');
    // Never from the directory alone: with no vault there is no membership
    // to merge with, and R1 makes no directory call.
    return const OwnDeviceList(directoryKnown: false);
  }

  @override
  Future<void> removeDevice(String ref) async {
    if (_pipeline.parts != null) _step2('removeDevice');
    // Gate item 37: only refs of the own list; with no vault it is empty.
    throw ArgumentError('Not a device of the own list.');
  }

  @override
  ValueListenable<int> get removalsPending {
    if (_pipeline.parts != null) _step2('removalsPending');
    return _noRemovals;
  }

  /// A member whose ready-vault behaviour is step 13b-ii's. Unreachable in
  /// the app until then: bootstrap holds the port and hands it to nothing
  /// (5b's Task 14 does, after step 13b-ii).
  static Never _step2(String member) =>
      throw UnimplementedError('EncryptedMessaging.$member: Task 13b-ii.');
}
