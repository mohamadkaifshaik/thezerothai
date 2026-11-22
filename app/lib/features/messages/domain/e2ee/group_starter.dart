import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:fixnum/fixnum.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import '../../../../core/crypto/crypto_engine.dart';
import '../../../../core/crypto/crypto_types.dart';
import '../../../../core/crypto/guarded_crypto_engine.dart';
import '../../../../core/crypto/mls_derivations.dart';
import '../../../../core/crypto/mls_pair.dart';
import '../../../../core/network/app_exception.dart';
import '../../../../core/vault/secure_vault.dart';
import '../../../../core/vault/vault_session.dart';
import '../../../../core/vault/vault_status.dart';
import '../../../../gen/dzeroth/keys/v1/keys.pb.dart' as kpb;
import '../../../../gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;
import '../../../../gen/dzeroth/messaging/v1/messaging.pbenum.dart';
import '../../../keys/data/keys_repository.dart';
import '../../data/messaging_repository.dart';
import '../conversation_id.dart';
import 'commit_call_tracker.dart';
import 'commit_runner.dart' show kCommitCallsPerConversationPerDay;
import 'conversation_context.dart';
import 'conversation_crypto.dart';
import 'conversation_locks.dart';
import 'daily_ledger.dart';
import 'device_directory.dart';
import 'device_key_history.dart';
import 'e2ee_types.dart';
import 'encrypted_sender.dart';
import 'former_pins.dart';
import 'known_conversations.dart';
import 'membership_rules.dart';
import 'message_content_codec.dart';
import 'message_receiver.dart';
import 'pipeline_support.dart';
import 'sync_budget.dart';

// The server's request deadline moved to the shared helpers with the margin
// built on it; it is still read through this file.
export 'pipeline_support.dart' show kServerRequestDeadline;

part 'group_starter_recovery.dart';
part 'group_starter_reset.dart';
part 'group_starter_restart.dart';
part 'group_starter_start.dart';

/// R6: the age at which the stored commits decide what became of a
/// provisional group. Its init is resent until [kInitResendMargin] before
/// that.
const Duration kProvisionalExpiry = Duration(hours: 24);

/// Audit M3. How long before [kProvisionalExpiry] an init is sent no more:
/// the server's request deadline ([kServerRequestDeadline]) plus the
/// client's own wait for an answer ([kMlsRpcTimeout]), the pipeline's one
/// [kRequestInFlightMargin] (the commit runner waits the same time before
/// a discard). Why: at expiry the stored commits decide, and a
/// "not stored" there deletes the group; a request still in flight could
/// be stored after that answer, and the server would then hold a group
/// its creator deleted (no welcome exists for a creator). With this margin
/// the last request left the client, and the server, before the commits
/// are asked. Task 9 audit M2: that holds only for a request that left the
/// client when its call started; an init call whose client wait ran out
/// while it still ran holds the expiry until this margin has passed after
/// it really ended (`MessagingRepository.abandonedMlsCall`).
final Duration kInitResendMargin = kRequestInFlightMargin;

/// The `limit_name` of the two daily claim caps (KP): 20 claims per target,
/// 300 claims in all.
const String kLimitClaimsPerTargetDaily = 'keys_claims_per_target_daily';
const String kLimitClaimsDaily = 'keys_claims_daily';

/// The stored error name of a row whose expired provisional group could
/// not be rebuilt because the peer lists no usable device (review N5). No
/// typed error goes with it: `outgoing` shows the row `failed`, retryable,
/// with a null `error`, and the user's retry starts again ([retryStart]).
const String kStartErrorPeerHasNoDevice = 'PeerHasNoDevice';

/// The stored error names of a head row whose new start, asked for by the
/// user (a new send or a retry), could not be made and gave no typed error
/// (review W2): the peer's list or the claim could not be had, or nothing
/// can be started now (a state in doubt, a vault that closed). As with
/// [kStartErrorPeerHasNoDevice]: `failed`, retryable, a null `error`.
const String kStartErrorLookupFailed = 'LookupFailed';
const String kStartErrorUnavailable = 'StartUnavailable';

/// What [GroupStarter.startOrRoute] did with a first message.
///
/// `started`: this device created a provisional group; the row is saved and
/// its init is being sent. `joinedExisting`: the conversation is (or was
/// ever) encrypted here; the row is saved with the sender and goes out, or
/// waits. `plaintext`: nothing is saved; the caller sends it in plaintext.
/// Every other value: nothing is saved and nothing is sent.
/// `lookupFailed` (security read H1): the peer's list could not be read;
/// `cause` carries a [CannotMessageException] when the lookup answered
/// CANNOT_MESSAGE, and a failed claim's error.
enum StartResult {
  started,
  joinedExisting,
  plaintext,
  peerHasNoDevice,
  tryAgainTomorrow,
  unavailable,
  lookupFailed,
}

/// What [GroupStarter.startOrRoute] answered. Review M9: a class, not the
/// brief's record: a record's built-in `toString` prints the conversation
/// id, and no scan sees a record. It defines no `toString`.
class StartOutcome {
  const StartOutcome({required this.result, this.conversationId, this.cause});

  final StartResult result;

  /// The conversation the row was saved for; null when nothing was saved.
  final String? conversationId;

  /// The typed error behind `lookupFailed` and `tryAgainTomorrow`.
  final AppException? cause;
}

/// The server's deterministic id of the 1:1 conversation of the raw uids
/// [a] and [b] (`backend/internal/messaging/model.go`, `ConversationID`):
/// the first 32 lower-case hex characters of SHA-256 of
/// `"dm1|" + lo + "|" + hi`, the uids in byte order (uids are ASCII, so
/// `String.compareTo` is byte order). Only for raw uids: a public id gives
/// another value.
String dmConversationId(String a, String b) {
  final swap = b.compareTo(a) < 0;
  final lo = swap ? b : a;
  final hi = swap ? a : b;
  return sha256.convert(utf8.encode('dm1|$lo|$hi')).toString().substring(0, 32);
}

/// Starting encryption in a conversation (Task 8; R6 steps 1 to 4, K2, R3,
/// R11; security reads C1, H1, H2): where a first message goes (encrypted,
/// plaintext or nowhere), the claim of key packages, the provisional group
/// with its `mls_init`, and what each answer does to it.
///
/// Routing never answers `plaintext` for a conversation or a person this
/// device ever knew as encrypted, with a vault that is not usable, on an
/// unreadable or deferred lookup, or when anything is in doubt: only on a
/// flag that is not on, or a READABLE, EMPTY device list.
///
/// A provisional group, its pending init, the pins, the device key history
/// and the stage-`encrypted` row are stored in ONE transaction of ONE
/// `runWrite` body, with no mark. The row then goes out with its init,
/// byte for byte under the same key, until the server answers. This class
/// owns every row that carries an `init`; [EncryptedSender] sends none of
/// them and nothing behind one. A row loses its init only with the
/// server's answer for its message or with the discard of its group
/// (review W1: its key never goes out without the init). The two ends of a provisional group are
/// [ConversationCrypto.settleOwnInitLocked] (the one success function, also
/// the join code's) and [ConversationCrypto.discardProvisionalLocked].
///
/// Locking (plan "Global Constraints"). Lookups and claims run under no
/// lock (the conversation id is not known before the claim). The group is
/// created under the conversation lock, in ONE `runWrite` body. The init is
/// sent in another hold of that lock, and what follows a discard (the
/// welcome poll, catch-up, the sender's drain) runs after the hold through
/// the public, lock-taking entries: never inside it.
///
/// Seams of later tasks, injected: [removedElsewhere] (Task 12),
/// [ownUserId] and [publicIdsOff] (Task 13's wiring). A provisional group
/// whose pending commit is a reset is Task 10's ([resetConversation], the
/// part `group_starter_reset.dart`); [resumeProvisional] resumes both
/// kinds. Never logs; an unexpected failure is reported as
/// [E2eePipelineError] with a step name only. Defines no `toString`.
class GroupStarter {
  /// [ownUserId]: the caller's own user reference as the client holds it
  /// (null when not known: no claim is made for the own devices then).
  ///
  /// [publicIdsOff]: true only while `public_ids` is KNOWN off for this
  /// user (`enabled_features`): both references are raw uids then, and the
  /// claim's conversation id is checked against [dmConversationId]. False
  /// (on, or not known): that check cannot be made.
  ///
  /// [schedule] runs a callback later (a timer in production): the one
  /// automatic resend after a server-chosen retry time.
  GroupStarter({
    required ConversationCrypto crypto,
    required EncryptedSender sender,
    required MessageReceiver receiver,
    required VaultSession session,
    required CryptoEngine Function() engine,
    required MessagingRepository messaging,
    required KeysRepository keys,
    required DeviceDirectory directory,
    required DailyLedger ledger,
    required KnownConversations known,
    required SyncBudget syncBudget,
    required ConversationLocks locks,
    required ConversationContexts contexts,
    required DateTime Function() now,
    required void Function(String conversationId) onChanged,
    required bool Function() removedElsewhere,
    required String? Function() ownUserId,
    required bool Function() publicIdsOff,
    void Function(Duration delay, void Function() run)? schedule,
    void Function(Object error, StackTrace stack)? onUnexpectedError,
  }) : _crypto = crypto,
       _sender = sender,
       _receiver = receiver,
       _session = session,
       _engine = engine,
       _messaging = messaging,
       _keys = keys,
       _directory = directory,
       _ledger = ledger,
       _known = known,
       _syncBudget = syncBudget,
       _locks = locks,
       _contexts = contexts,
       _now = now,
       _onChanged = onChanged,
       _removedElsewhere = removedElsewhere,
       _ownUserId = ownUserId,
       _publicIdsOff = publicIdsOff,
       _schedule = schedule ?? ((delay, run) => Timer(delay, run)),
       _onUnexpectedError = onUnexpectedError,
       _resetCalls = CommitCallTracker(messaging: messaging, now: now) {
    // Audit L6: the join path ends this device's own reset without this
    // class (it settles or discards it from the server's first commit of
    // its generation); what this run remembers for it goes then. Decision:
    // a callback, not a check at the next touch. Why: a check would keep
    // the reset's device lists in memory until this conversation is
    // touched again, and every later reader would have to remember to make
    // it. One starter per session (Task 13), so one callback.
    crypto.onOwnResetEnded = _forgetReset;
  }

  final ConversationCrypto _crypto;
  final EncryptedSender _sender;
  final MessageReceiver _receiver;
  final VaultSession _session;
  final CryptoEngine Function() _engine;
  final MessagingRepository _messaging;
  final KeysRepository _keys;
  final DeviceDirectory _directory;
  final DailyLedger _ledger;
  final KnownConversations _known;
  final SyncBudget _syncBudget;
  final ConversationLocks _locks;
  final ConversationContexts _contexts;
  final DateTime Function() _now;
  final void Function(String conversationId) _onChanged;
  final bool Function() _removedElsewhere;
  final String? Function() _ownUserId;
  final bool Function() _publicIdsOff;
  final void Function(Duration delay, void Function() run) _schedule;
  final void Function(Object error, StackTrace stack)? _onUnexpectedError;

  static const FormerPins _former = FormerPins();

  // Memory of this run. Nothing here is a fact a write relies on: after a
  // restart an init is only resent sooner.

  /// The resume running per conversation (single flight).
  final Map<String, Future<void>> _running = {};

  /// The conversations a new start of a known conversation is running for
  /// ([_restartKnown], single flight). Not cleared by [reset]: a start in
  /// flight removes its own entry when it ends.
  final Set<String> _restarting = {};

  /// Local ids whose init's outcome stayed unknown after the automatic
  /// resend: each later trigger makes one attempt.
  final Set<String> _unknown = {};

  /// Local id -> no send before this time (the server's retry time).
  final Map<String, DateTime> _notBefore = {};

  /// The step names [_reportOnce] reported in this run.
  final Set<String> _reported = {};

  /// Task 9 audit M2. Conversation -> the init sends of its provisional
  /// group whose client wait ran out while the call still ran
  /// (`MessagingRepository.abandonedMlsCall`): such a request may not have
  /// left the client yet, so [kInitResendMargin] has not started for it.
  final Map<String, int> _initCallsOut = {};

  /// Conversation -> when the last such call really ended: the expiry's
  /// margin counts from then.
  final Map<String, DateTime> _initCallEndedAt = {};

  /// Bumped by [reset]: the end of a call tracked before it changes
  /// nothing.
  int _runSerial = 0;

  /// Task 10 amendment 1: the call rules of a reset's `CommitConversation`
  /// calls, the commit runner's ([CommitCallTracker]).
  final CommitCallTracker _resetCalls;

  /// Conversation -> the fresh lists the reset made in this run was checked
  /// against, for the settle's attribution.
  final Map<String, _ResetLists> _resetLists = {};

  /// Conversation -> the bytes of a reset a call that was not the first was
  /// refused for: never sent again; dropped once the margin has passed.
  final Map<String, Uint8List> _resetRefused = {};

  /// Audit M1. Conversation -> the bytes of a reset the server HOLDS: a
  /// call of them answered (g + 1, e >= 1), or a listing showed them at
  /// (g + 1, 0). While set, no call of them is made again; a resume only
  /// retries the settle. Why: the server draws both of its caps before it
  /// recognises a retry, and the reset cap (10 a day) is shared by every
  /// conversation of the user. Memory of this run: after a restart the
  /// record is listed again (once per margin at most, review I1).
  final Map<String, Uint8List> _resetHeld = {};

  /// The conversations a [repairIfStuck] runs for (single flight).
  final Set<String> _repairing = {};

  /// Sign-out or a new vault: forgets this run's memory.
  void reset() {
    _unknown.clear();
    _notBefore.clear();
    _reported.clear();
    _initCallsOut.clear();
    _initCallEndedAt.clear();
    _resetCalls.clear();
    _resetLists.clear();
    _resetRefused.clear();
    _resetHeld.clear();
    _runSerial++;
  }

  /// [id]'s provisional reset is gone (settled or discarded, here or by the
  /// join path, audit L6): what this run remembered for it goes.
  void _forgetReset(String id) {
    _resetCalls.forget(id);
    _resetLists.remove(id);
    _resetRefused.remove(id);
    _resetHeld.remove(id);
  }

  /// R6 step 5 (Task 10): this device resets [conversationId] into the next
  /// generation g + 1: the server's current generation g from a commit
  /// listing, fresh lists, claims for the peer and this user's other
  /// devices, the provisional group of g + 1 with its pending reset (and
  /// the call counted) in ONE transaction, then `CommitConversation` with
  /// `reset`. The answer (g + 1, 1) settles it (g walked to its end first;
  /// the pins replaced by g + 1's members); a later pair, STALE_EPOCH or an
  /// outcome still unknown after one identical resend is decided by the
  /// record at (g + 1, 0) (this device's: settled; another's: the group
  /// goes and the winner's welcome is joined; none: it stays provisional and
  /// [resumeProvisional] resends or expires it). Returns once the call has
  /// an answer, or is left to the resume.
  ///
  /// Allowed only with `describeState(...).canReset` (stuck, waiting past
  /// [kResetWaitWithoutWelcome], the M5 pause); a reset already in progress
  /// is resumed instead (never a second one). Manual resets are not counted
  /// against `kAutoResetsPerDay` or `kAutoResetsPerUserPerDay`.
  ///
  /// Throws, as the port documents: [FeatureDisabledException] while the
  /// flag is not on (nothing is listed or claimed); [RateLimitedException]
  /// at a daily cap (the reset cap `messages_resets_daily`, the commit cap
  /// of the conversation, or a claim cap; the provisional group is gone);
  /// the server's typed [AppException] for another refusal (or a failed
  /// claim); and [E2eeActionException] with `notAccepted`,
  /// `peerHasNoDevice` or `unavailable` (plan Difference 3: the port has no
  /// type for them). [ArgumentError] for an invalid id.
  ///
  /// Named `resetConversation`, not the plan's `reset`: this class already
  /// has [reset] (sign-out), and Dart has no overloads; the port's method
  /// has this name.
  Future<void> resetConversation(
    String conversationId, {
    BudgetPriority priority = BudgetPriority.user,
  }) => _resetConversation(conversationId, priority);

  /// The recovery table's stuck-member response (Task 10, Open question 3):
  /// when [conversationId] is `stuck` and `canReset`, one reset by itself,
  /// at most `kAutoResetsPerDay` per conversation and (audit L1)
  /// `kAutoResetsPerUserPerDay` across conversations per IST day (security
  /// read M9; both counted before the first claim). Otherwise it stays
  /// `stuck`: with the flag off, removed elsewhere or a failed engine
  /// (`canReset` false; nothing is counted), at a limit (`canReset` true:
  /// the user's tap), or while a reset is in progress. Never throws.
  Future<void> repairIfStuck(String conversationId) =>
      _repairIfStuck(conversationId);

  /// Completes when no resume of [conversationId] is running (at once when
  /// none is). Starts none.
  @visibleForTesting
  Future<void> settled(String conversationId) =>
      _running[conversationId] ?? Future<void>.value();

  /// R6 step 4: called at vault ready and before any send. Every provisional
  /// group whose pending commit is an init is resumed (its init resent byte
  /// for byte under the same key, until [kInitResendMargin] before
  /// [kProvisionalExpiry]) or, once [kProvisionalExpiry] old, decided by
  /// the server's first stored commit. That commit is this init: the
  /// identical request is sent once more and the group is cleared with the
  /// server's replayed answer (review W1; with no answer nothing changes).
  /// Else it is replaced by a new group from fresh claims (claimed first;
  /// a failed claim changes nothing). One conversation lock at a time.
  /// Never throws.
  Future<void> resumeProvisional({
    BudgetPriority priority = BudgetPriority.background,
  }) => _resumeAll(priority);

  /// The first message of a provisional group, while its init is not
  /// answered: the row that carries the init of [conversationId], or of the
  /// conversation started with [recipientUserId] (exactly one of the two).
  /// Null when there is none (never started, settled, or discarded: the
  /// message or the failed row is then in the vault or with the sender).
  ///
  /// Review I4: `EncryptedSender.outgoing` cannot list this row (it may be
  /// addressed by recipient, and the sender owns no init row). Task 13b's
  /// `watchThread` MUST merge this ahead of `outgoing`, or the first bubble
  /// of a draft thread disappears until the init lands and the user sends
  /// the text again.
  ///
  /// `sending`, or `waiting` with why the init is held: `unavailable` (the
  /// flag is not on, or this device was removed elsewhere), `cannotMessage`,
  /// `notSynced` (a member is not attributable), `provisional` (review N5:
  /// the group is within [kInitResendMargin] of [kProvisionalExpiry] or
  /// older, its init is sent no more, and the stored commits, a replay or
  /// a rebuild decide at the next resume).
  /// Always `retryable: false`, never `failed`: a row that failed is no
  /// longer an init row, and `outgoing` lists it. The user's retry of this
  /// row goes through [retryStart] like every other (it resumes the init).
  /// Reads only. A failed read throws, as `outgoing` does: null always
  /// means "no such row".
  Future<OutgoingRow?> pendingInit({
    String? conversationId,
    String? recipientUserId,
  }) async {
    if ((conversationId == null) == (recipientUserId == null)) {
      throw ArgumentError('Exactly one of the two addresses.');
    }
    final vault = _session.vault;
    if (vault == null) throw StateError('The vault is not ready.');
    if (!_known.isLoadedFor(vault)) await _known.load(vault);
    // Review N7. Decision: the row is found from the conversation that
    // holds the provisional group, with [_initRow]'s predicate (the one the
    // resume, the settle and the discard use), never by resolving the row's
    // recipient with `conversationForPeer`: when one ref is stored for two
    // ids that resolves to the other id, and the conversation that has the
    // row would answer null (the bubble disappears).
    final ids = conversationId != null
        ? [conversationId]
        : [
            for (final id in _known.ids)
              if (_known.peerOf(id) == recipientUserId) id,
          ];
    for (final id in ids) {
      GroupRecord? group;
      for (final g in await vault.groups(id)) {
        if (g.provisional) group = g;
      }
      if (group == null) continue;
      final r = await _initRow(vault, id, group.generation);
      if (r == null) continue;
      // The age that [_resumeLocked] sends by: a group within
      // [kInitResendMargin] of [kProvisionalExpiry] or older (or with no
      // creation time) has its init sent no more.
      final expired = _sendsNoMore(group);
      final SendBlock held;
      if (!_session.mayStart || _removedElsewhere()) {
        held = SendBlock.unavailable;
      } else if (!_contexts.of(id).canReply) {
        held = SendBlock.cannotMessage;
      } else if ((await vault.members(id))
          .any((m) => m.side == MemberSide.unattributed)) {
        held = SendBlock.notSynced;
      } else if (expired) {
        // Review N5. Decision: never `sending` for an expired group. Its
        // init is not sent again; the stored commits and a rebuild decide,
        // and until one of them can be had the fate of the group is not
        // known: `provisional`, the reason rows behind it wait with.
        held = SendBlock.provisional;
      } else {
        held = SendBlock.none;
      }
      return OutgoingRow(
        localId: r.localId,
        conversationId: id,
        content: r.content,
        createdAt: DateTime.fromMicrosecondsSinceEpoch(
          r.createdAtMicros,
          isUtc: true,
        ),
        status: held == SendBlock.none
            ? OutgoingStatus5a.sending
            : OutgoingStatus5a.waiting,
        waitingOn: held,
        error: null,
        retryable: false,
        tryTomorrow: false,
      );
    }
    return null;
  }

  /// The user's retry of the unsent row [localId]. Task 13b's `retrySend`
  /// calls this for EVERY retry of an unsent row, never the sender's
  /// `retry` (which would clear the failure of a row only a new start can
  /// send). A row that still carries its init has it resent; a waiting or
  /// failed row of a conversation whose init was refused or abandoned
  /// starts again from fresh claims when [_neverMember] allows it (review
  /// F1, option c); every other row is the sender's retry. An unknown id is
  /// a no-op. Never throws.
  ///
  /// Review F1 (fix round 2), binding for Task 13b: after the user discards
  /// an unsent row (`EncryptedSender.discard`), call this for the local id
  /// of the conversation's NEW oldest row. Why: under review 3d nothing
  /// passes a failed head row without a touch, and the discard is that
  /// touch; without this call the rows behind the discarded one read
  /// "waiting" with no control until the user types again. It starts when
  /// that row is not failed and is a no-op otherwise.
  ///
  /// The new start is made with the conversation's OLDEST waiting row (the
  /// order the user typed is kept), which is [localId]'s row, or an older
  /// row that is not failed; an older FAILED row is never sent by the retry
  /// of another row (review 3d), and nothing starts then.
  ///
  /// Review N1. A start that could be made here and was not (the lookup or
  /// the claim failed, no device, a daily cap, another start running)
  /// leaves a failed row as it is: failed, with its reason, or the cap's.
  /// Why: the sender's `retry` clears the failure, and the row would then
  /// read "waiting" with no reason and no retry control, for good. Review
  /// W2: for the same reason a head row that was NOT failed gets a failure
  /// when the start it asked for cannot be made ([_restartKnown]).
  ///
  /// The body, and the new start it may make, are in the part file
  /// `group_starter_restart.dart`.
  Future<void> retryStart(String localId) => _retryStart(localId);

  // -------------------------------------------------------------------------
  // Routing

  /// The first message to a peer, or into a conversation that is not
  /// encrypted. [conversationId] is null for a recipient-addressed draft.
  /// Saves the row and returns (the init is sent after it returned);
  /// [StartResult.plaintext] saves nothing.
  ///
  /// Review N2, binding for Task 13b: call this only AFTER the session's
  /// sign-in step (`VaultSession.onSignedIn`) completed for the signed-in
  /// user. Before it the session's status is still its initial `off`, which
  /// cannot be told from "this device has no vault" here: a send routed in
  /// that window on a flag that is off or unknown could be plaintext for a
  /// conversation only the vault knows as encrypted.
  ///
  /// [ArgumentError], with nothing saved, for an empty local id or peer, an
  /// invalid conversation id, content over [kMaxMessageContentBytes], or a
  /// local id an unsent row already has. Never throws otherwise: a failure
  /// is [StartResult.unavailable].
  Future<StartOutcome> startOrRoute({
    required String localId,
    required String peerUserId,
    String? conversationId,
    required String text,
    String sharedPostId = '',
  }) async {
    if (localId.isEmpty) throw ArgumentError('A row needs a local id.');
    if (peerUserId.isEmpty) throw ArgumentError('A start needs a peer.');
    if (conversationId != null && !isConversationId(conversationId)) {
      throw ArgumentError('Invalid conversation id.');
    }
    try {
      return await _route(
        localId: localId,
        peer: peerUserId,
        conversationId: conversationId,
        text: text,
        sharedPostId: sharedPostId,
      );
    } on ArgumentError {
      rethrow;
    } on _BadRandom {
      _reportOnce('start.random');
      return _out(StartResult.unavailable);
    } on Object catch (e, s) {
      // Fail closed: a failed read or an engine failure is never plaintext.
      _reportIfBug(e, s, 'start.route');
      return _out(StartResult.unavailable);
    }
  }

  Future<StartOutcome> _route({
    required String localId,
    required String peer,
    required String? conversationId,
    required String text,
    required String sharedPostId,
  }) async {
    final vault = _session.vault;
    // Review I1. Decision: a vault exists on this device and cannot be
    // asked now (opening, a key outage, a lost lock): its known set is the
    // only record that a conversation is encrypted, so nothing is routed
    // without it. Never plaintext, whatever the flag says; with no vault
    // on the device at all the flag decides as before (R1's inertness).
    //
    // Review N2. Decision: "no vault on the device" is taken only from a
    // session that SAYS so (status `off`, or `unsupported`: no vault can
    // exist on this platform). `vaultKnown` is false as well when the
    // marker could not be read (status `unavailable`), and a vault that
    // may exist is treated as one that does: never plaintext in doubt.
    if (vault == null) {
      final status = _session.status.value;
      if (_session.vaultKnown ||
          (status != VaultStatus.off && status != VaultStatus.unsupported)) {
        return _out(StartResult.unavailable);
      }
    }
    if (vault != null && !_known.isLoadedFor(vault)) await _known.load(vault);

    // 1. Known first (security read C1): the known set and the cache's
    // sticky marker are asked BEFORE the flag and before any lookup.
    String? known;
    if (conversationId != null) {
      if (_known.contains(conversationId) ||
          await _messaging.cachedEverEncrypted(conversationId)) {
        known = conversationId;
      } else if (vault != null &&
          await _known.conversationForPeer(vault, peer) != null) {
        // Review M2. Decision: the id is not known, but the vault stores
        // this peer for ANOTHER conversation. An honest server cannot
        // produce that (the id is deterministic): nothing is started and
        // nothing is plaintext.
        return _out(StartResult.unavailable);
      }
    } else if (vault != null) {
      known = await _known.conversationForPeer(vault, peer);
    }
    if (known != null) {
      final saved = await _viaSender(
        known,
        localId: localId,
        text: text,
        sharedPostId: sharedPostId,
      );
      // Review F1 (c): a new send is an explicit trigger. When the vault
      // shows this device was never a member (its own init was refused or
      // abandoned), encryption starts again here; else the row waits.
      if (saved.result == StartResult.joinedExisting) {
        await _restartKnown(known, peer);
      }
      return saved;
    }
    if (conversationId == null) {
      // Second re-read R1: a recipient the stored refs do not resolve,
      // whose cached row is of a conversation ever known as encrypted (the
      // stored ref and this one may be of different id kinds). Nothing is
      // started and nothing is plaintext.
      final row = await _messaging.cachedConversationWith(peer);
      if (row != null &&
          row.id.isNotEmpty &&
          (_known.contains(row.id) ||
              await _messaging.cachedEverEncrypted(row.id))) {
        return _out(StartResult.unavailable);
      }
    }

    // 2. A device whose flag is off or unknown never claims or inits.
    if (!_session.mayStart) return _plaintextUnlessKnown(conversationId, peer);
    // The flag is on but nothing can be started here now (no usable vault
    // or engine, or this device was removed elsewhere). Decision: never
    // plaintext in doubt; the caller may try again.
    if (vault == null || _removedElsewhere() || _engineDown()) {
      return _out(StartResult.unavailable);
    }

    // 3. The peer's device list (security read H1): plaintext ONLY on a
    // readable, empty answer.
    final list = await _directory.peer(peer, priority: BudgetPriority.user);
    switch (list.state) {
      case ListState.readable:
        if (list.devices.isEmpty) {
          return _plaintextUnlessKnown(conversationId, peer);
        }
      case ListState.unreadable:
        return _lookupFailed(peer);
      case ListState.deferred:
        // Review 3b, the brief as amended: deferred -> start only when the
        // last readable list is younger than `kDeviceListReuse`, else
        // `lookupFailed`. Here: no kept list, or an empty one, ends now;
        // a non-empty one lets the start's own fresh lookup try, and
        // [_lastReadable] refuses a kept list that is too old. Why: fail
        // closed; the old clause trusted a list of any age.
        if (list.fetchedAt == null || list.devices.isEmpty) {
          return _out(StartResult.lookupFailed);
        }
    }

    // The report key and the exact bytes are fixed here, once.
    final content = encodeMessageContent(
      text: text,
      sharedPostId: sharedPostId,
      reportKey: await _random(kReportKeyBytes),
    );
    final outcome = await _begin(
      peer,
      _Draft(
        localId: localId,
        content: content,
        text: text,
        sharedPostId: sharedPostId,
        recipient: conversationId == null ? peer : null,
        conversationId: conversationId,
      ),
    );
    final id = outcome.conversationId;
    if (outcome.result == StartResult.started && id != null) {
      _onChanged(id);
      // The init goes out after this call returned (it may take 30 s).
      unawaited(_resume(id, BudgetPriority.user));
    }
    return outcome;
  }

  /// A conversation this device ever knew as encrypted: the row goes to the
  /// sender under [id] (it is sent in an existing group, or waits for a
  /// welcome); never plaintext.
  Future<StartOutcome> _viaSender(
    String id, {
    required String localId,
    required String text,
    required String sharedPostId,
  }) async {
    if (_session.vault == null || _removedElsewhere() || _engineDown()) {
      return _out(StartResult.unavailable, id);
    }
    try {
      await _sender.enqueue(
        localId: localId,
        conversationId: id,
        text: text,
        sharedPostId: sharedPostId,
      );
    } on StateError {
      // The vault closed meanwhile: nothing was saved.
      return _out(StartResult.unavailable, id);
    }
    return _out(StartResult.joinedExisting, id);
  }

  /// An unreadable lookup: with the typed cause when it answered
  /// CANNOT_MESSAGE (the directory parks the peer then).
  StartOutcome _lookupFailed(String peer) => _out(
    StartResult.lookupFailed,
    null,
    _directory.isParked(peer) ? const CannotMessageException() : null,
  );

  /// Review M1. `plaintext`, unless the conversation is known NOW. The
  /// known check of step 1 and this answer are separated by awaits (a
  /// lookup of up to 30 s) in which a welcome can be joined: the
  /// synchronous part of step 1 is asked again right before answering,
  /// so the server's ENCRYPTION_REQUIRED is not what stops it.
  StartOutcome _plaintextUnlessKnown(String? conversationId, String peer) {
    final known =
        (conversationId != null && _known.contains(conversationId)) ||
        _known.ids.any((id) => _known.peerOf(id) == peer);
    return _out(known ? StartResult.unavailable : StartResult.plaintext);
  }

  StartOutcome _out(
    StartResult result, [
    String? conversationId,
    AppException? cause,
  ]) => StartOutcome(
    result: result,
    conversationId: conversationId,
    cause: cause,
  );

  bool _engineDown() {
    final engine = _engine();
    return engine is GuardedCryptoEngine && engine.unavailable.value;
  }

  // -------------------------------------------------------------------------

  Future<_Op?> _op() async {
    final vault = _session.vault;
    if (vault == null) return null;
    try {
      final deviceId = await vault.deviceId();
      if (deviceId == null) return null;
      // Loaded for THIS vault: a set of another vault is never written.
      if (!_known.isLoadedFor(vault)) await _known.load(vault);
      return _Op(_session, vault, vault.uid, deviceId);
    } on Object catch (e, s) {
      _reportIfBug(e, s, 'start.op');
      return null;
    }
  }

  /// [length] bytes of the engine's CSPRNG; an answer of another length is
  /// [_BadRandom], before anything is stored or encrypted with it.
  Future<Uint8List> _random(int length) => randomOf(_engine(), length);

  /// One unit of the sync budget; false (make no call) while paused.
  Future<bool> _takeSyncUnit(BudgetPriority priority) async {
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
    if (e is Error && e is! StateError) {
      _onUnexpectedError?.call(E2eePipelineError(step), s);
    }
  }
}

/// The first message of a start: a new draft, or the row [replaces] that
/// this start encrypts again: the waiting stage-plain row of a known
/// conversation ([_Mode.restart]), or the init row of the expired
/// provisional group the start replaces ([_Mode.replace]; that group is
/// not discarded first, it goes in the creating transaction). No
/// `toString`.
class _Draft {
  const _Draft({
    required this.localId,
    required this.content,
    this.text,
    this.sharedPostId = '',
    this.recipient,
    this.conversationId,
    this.replaces,
    this.createdAtMicros,
    this.expectId,
    this.replacesCommit,
  });

  final String localId;
  final Uint8List content;

  /// The typed text of a new draft (for the sender, when the conversation
  /// turns out to exist); null for a rebuild.
  final String? text;
  final String sharedPostId;

  /// The recipient reference exactly as sent, for a draft addressed by
  /// recipient; null for one addressed by [conversationId].
  final String? recipient;
  final String? conversationId;

  /// The key of the row this start encrypts again (it is replaced by a row
  /// under a NEW key in the same transaction): a stage-plain row
  /// ([_Mode.restart]), or the old init row ([_Mode.replace]).
  final String? replaces;
  final int? createdAtMicros;

  /// The conversation id the claim must answer, for a row addressed by
  /// recipient whose conversation is already known ([_Mode.replace]).
  final String? expectId;

  /// [_Mode.replace]: the pending commit of the provisional group this
  /// start replaces (the group is replaced only while it is still that one).
  final Uint8List? replacesCommit;
}

/// How a start treats what the vault already holds for the claim's id.
///
/// `fresh`: a first message; a known id or a stored group takes the row
/// instead. `restart`: a known conversation this device was never a member
/// of (review F1, option c). `replace`: the 24 h rebuild (review I3): the
/// old provisional group is replaced in the creating transaction.
enum _Mode { fresh, restart, replace }

// One body each, shared with the sender (`pipeline_support.dart`).
typedef _Stopped = PipelineStopped;
typedef _BadRandom = BadRandom;
typedef _Op = PipelineOp;

String _hexOf(List<int> b) => hexOf(b);

int? _microsOf(pb.Message m) => serverMicros(m);

Duration? _retryAfterOf(AppException e) => retryAfterOf(e);

/// Constant-time equality of two byte lists (the length is not secret).
bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}
