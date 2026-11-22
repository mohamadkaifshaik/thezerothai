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

part 'group_starter_discard.dart';
part 'group_starter_expiry.dart';
part 'group_starter_recovery.dart';
part 'group_starter_reset.dart';
part 'group_starter_reset_resume.dart';
part 'group_starter_restart.dart';
part 'group_starter_route.dart';
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

/// Task 8 audit L1: the least time between two 24 h rebuilds of one
/// conversation's provisional group ([DailyLedger.takeRebuild]). Why: a
/// rebuild that fails after its claim (a replace refused under the lock, a
/// state in doubt) would otherwise claim again at every resume, spending
/// the peer's one-time packages and the claim caps.
const Duration kRebuildSpacing = Duration(hours: 1);

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

/// Gate 6 (audit L10): the stored error name of a row whose pending init
/// the user discarded ([GroupStarter.discardInit]). As with
/// [kStartErrorPeerHasNoDevice]: `failed`, retryable, a null `error`; the
/// user's retry starts again from fresh claims ([GroupStarter.retryStart]).
const String kStartErrorInitDiscarded = 'InitDiscarded';

/// What [GroupStarter.discardInit] did.
///
/// `discarded`: the provisional group is gone and its init row failed with
/// [kStartErrorInitDiscarded]; or (fix round 2, ruling 7) another device's
/// commit was first, so the row did NOT fail: the winner's welcome was
/// joined and the row waits for the sender, which encrypts it again in
/// that group under a new key. `settled`: the server's first page held the
/// message, so the group settled with that answer instead (nothing to
/// discard). `held`: the server holds the init as this device's and an
/// answer may still come (the group is younger than [kProvisionalExpiry],
/// a call of it may still land, or no replay of it was refused in this
/// run, pre-flag-on review I-1), or (fix round 2, ruling 3) an earlier run
/// sent it and this run began less than [kInitResendMargin] ago: nothing
/// changed; the UI explains that
/// the message is being delivered. `notDecided`: what the server holds
/// could not be read now (the commits, or the page): nothing changed, the
/// user may try again. `none`: no pending init row for that conversation.
enum InitDiscard { discarded, settled, held, notDecided, none }

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
    // Task 8 concern 4: the join path left this device's own stored init
    // unanswered (a row still carries it); the resume replays it.
    crypto.onOwnInitUnanswered = _resumeAfterJoin;
    _runStartedAt = now();
  }

  /// Task 8 concern 4. Decision: one resume of [id], unawaited and started
  /// outside the conversation lock's zone (the join path calls this with
  /// the lock held, and the resume takes it itself), at background
  /// priority (no user intent). Why: the join code leaves such a group
  /// provisional for the starter (review W1); without this the group
  /// waited for the next vault-ready, send or retry, holding every row of
  /// the conversation meanwhile.
  ///
  /// Pre-flag-on fix round 2, ruling 5 (code review m-C). Decision: when a
  /// resume of [id] is running, this one starts AFTER it (its
  /// `whenComplete`), never joins it; an end after [reset] starts nothing.
  /// Why: the running resume read the group before the join's settle left
  /// it unanswered, so joining it asked nothing again and the group waited
  /// for an unrelated trigger (the same reason as [_armMarginResume]).
  void _resumeAfterJoin(String id) {
    final serial = _runSerial;
    Zone.root.run(() {
      final running = _running[id];
      if (running == null) {
        unawaited(_resume(id, BudgetPriority.background));
        return;
      }
      unawaited(
        running.whenComplete(() {
          if (serial != _runSerial) return;
          unawaited(_resume(id, BudgetPriority.background));
        }),
      );
    });
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

  /// Audit L2: peer reference -> the routing of [startOrRoute] running for
  /// it (single flight). Not cleared by [reset]: a routing in flight
  /// removes its own entry when it ends.
  final Map<String, Future<void>> _routing = {};

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

  /// Task 9 concern 1. Conversation -> the start of the last init call
  /// whose outcome stayed unknown in this run: a "not stored" read decides
  /// nothing until [kInitResendMargin] after it.
  final Map<String, DateTime> _initUnknownStartedAt = {};

  /// Conversations with one resume armed for the end of that margin.
  final Set<String> _marginArmed = {};

  /// Pre-flag-on review I-1. Local ids whose LAST request in this run was
  /// the replay of a stored init (review W1) and was refused by the server
  /// with a lasting answer (fix round 2, ruling 2: a STALE_EPOCH naming this
  /// conversation, CANNOT_MESSAGE, FEATURE_DISABLED or NOT_FOUND, never one
  /// with a retry time; a rate limit, a quota, degraded mode and the other
  /// checks made before the replay lookup are unknown outcomes). The only
  /// evidence on which [discardInit] discards a group
  /// the server holds as this device's. Cleared before each request of the
  /// row, by its settle or discard ([_forget]) and by [reset].
  final Set<String> _replayRefused = {};

  /// Pre-flag-on fix round 2, ruling 3 (code review m-A, audit L-a): when
  /// this run began (the construction, or the last [reset]), and the keys
  /// of the init rows this run sent a request of. A row with stored
  /// attempts and no request in this run was sent by an earlier run, whose
  /// request may still land until [kInitResendMargin] after this time
  /// ([discardInit] is held until then).
  late DateTime _runStartedAt;
  final Set<String> _sentThisRun = {};

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
  ///
  /// Binding for Task 13 (pre-flag-on fix round 2, ruling 6, code review
  /// m-D): sign-out, and a new vault, call BOTH this and
  /// `CommitRunner.reset()` (which clears the join code's own-commit memory,
  /// `ConversationCrypto.forgetOwnCommits`). Why: each forgets one half of
  /// the run. With only this one, the join code keeps the groups it already
  /// handed over (pre-flag-on review m-2) and never hands them to the new
  /// run; with only the other, this class keeps the refused-replay evidence
  /// and the margins of the earlier user's run.
  void reset() {
    _unknown.clear();
    _notBefore.clear();
    _reported.clear();
    _initCallsOut.clear();
    _initCallEndedAt.clear();
    _initUnknownStartedAt.clear();
    _marginArmed.clear();
    _replayRefused.clear();
    _sentThisRun.clear();
    _runStartedAt = _now();
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
  /// the user's tap), or while a reset is in progress. The automatic reset
  /// adds no device this device removed from the conversation today (audit
  /// L4; a manual reset is the user's choice). Never throws.
  Future<void> repairIfStuck(String conversationId) =>
      _repairIfStuck(conversationId);

  /// Completes when no resume of [conversationId] is running (at once when
  /// none is). Starts none.
  @visibleForTesting
  Future<void> settled(String conversationId) =>
      _running[conversationId] ?? Future<void>.value();

  /// R6 step 4: called at vault ready and before any send. Every provisional
  /// group this class owns is resumed, one conversation lock at a time.
  /// Never throws.
  ///
  /// An INIT: its init is resent byte for byte under the same key, until
  /// [kInitResendMargin] before [kProvisionalExpiry]; once
  /// [kProvisionalExpiry] old it is decided by the server's first stored
  /// commit. That commit is this init: the identical request is sent once
  /// more and the group is cleared with the server's replayed answer (review
  /// W1; with no answer nothing changes). Else it is replaced by a new group
  /// from fresh claims (claimed first; a failed claim changes nothing).
  ///
  /// A RESET (Task 10 amendment 4, review m-3): its record at (g + 1, 0)
  /// decides, at any age. This device's: settled (the server holds it, so
  /// it is never sent again, audit M1). Another record, or the server past
  /// g + 1: the group goes and the winner's welcome is joined. Not stored:
  /// a young reset is resent with the same bytes (spaced, counted, never
  /// inside the margin before expiry, never after a refusal of them); a
  /// [kProvisionalExpiry] old one, or one whose resend was refused, goes
  /// only on a listing that started after [kRequestInFlightMargin] with no
  /// call of it still out. A record the server could not answer: resent at
  /// most once per margin; one the local budget kept from being asked:
  /// nothing. Nothing is done while a call of it may still land, or while
  /// its wait after an unknown outcome runs (review m-5).
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

  /// Gate 6 (audit L10, Task 8 concern 1): the user's discard of the
  /// pending init row of [conversationId] ([pendingInit]), for an init
  /// whose replay keeps being refused, or which stays provisional. Takes
  /// the conversation lock. [ArgumentError] for an invalid id; never
  /// throws otherwise (a failure is [InitDiscard.notDecided]).
  ///
  /// The group is discarded, and the row fails with
  /// [kStartErrorInitDiscarded] (and `InitSettle.replay`'s endless retry
  /// ends), only when:
  /// - the server's record says this init is NOT stored (the stored
  ///   commits, read with the margin rules: no call of it may still land);
  ///   when that record shows another device's commit first (fix round 2,
  ///   ruling 7) the row does not fail: the winner's welcome is joined, as
  ///   the resume's STALE_EPOCH path does, and the row goes out in it;
  /// - or the server holds it as this device's, the group is
  ///   [kProvisionalExpiry] old with no answer for its message (the first
  ///   `ListMessages` page does not hold it), no call of it is out, the
  ///   margin after the last one has passed, and (pre-flag-on review I-1)
  ///   this run's last request of the row was its replay and the server
  ///   refused it with a lasting answer (fix round 2, ruling 2: STALE_EPOCH
  ///   naming this conversation, CANNOT_MESSAGE, FEATURE_DISABLED or
  ///   NOT_FOUND; a rate limit, a quota or another check the server makes
  ///   before its replay lookup is no such answer); without it it is
  ///   [InitDiscard.held];
  /// - or the marks are already at or past the init (`InitSettle.replay`):
  ///   it can never be settled, whatever the server holds.
  ///
  /// Never for a group the server holds as this device's while an answer
  /// may still come ([InitDiscard.held]), and (fix round 2, ruling 3) never
  /// for a row an earlier run sent and this run did not, until
  /// [kInitResendMargin] after this run began. A page that holds the message
  /// settles the group with it ([InitDiscard.settled]).
  ///
  /// Binding for Task 13b: offer this on a pending init row only; after
  /// `discarded` the row is the sender's (failed, retryable): a retry goes
  /// through [retryStart], and a discard of the row through
  /// `EncryptedSender.discard`. Show `held` as "still being delivered" and
  /// `notDecided` as "try again".
  Future<InitDiscard> discardInit(String conversationId) {
    if (!isConversationId(conversationId)) {
      throw ArgumentError('Invalid conversation id.');
    }
    return _discardInit(conversationId);
  }

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
    // Audit L2. Decision: one routing per peer ref at a time; a start for a
    // peer whose routing runs waits for it and is then routed afresh (the
    // conversation is then known, so its row goes to the sender). Why: two
    // fresh starts for one peer each claimed the peer's one-time packages
    // (and one of the 20 claims per target a day), and the second claim
    // was always wasted: the lock then found the first one's group. Keyed
    // on the reference exactly as given (another id kind of the same
    // person is not joined). Every routing of the peer waits, not only a
    // fresh one: which path a routing takes is known only after its reads,
    // and the order the user typed is kept that way.
    while (true) {
      final running = _routing[peerUserId];
      if (running == null) break;
      await running;
    }
    final routed = Completer<void>();
    _routing[peerUserId] = routed.future;
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
    } finally {
      if (identical(_routing[peerUserId], routed.future)) {
        _routing.remove(peerUserId);
      }
      routed.complete();
    }
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
