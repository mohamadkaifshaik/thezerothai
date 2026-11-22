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
import '../../../../gen/dzeroth/keys/v1/keys.pb.dart' as kpb;
import '../../../../gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;
import '../../../../gen/dzeroth/messaging/v1/messaging.pbenum.dart';
import '../../../keys/data/keys_repository.dart';
import '../../data/messaging_repository.dart';
import '../conversation_id.dart';
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

part 'group_starter_recovery.dart';
part 'group_starter_start.dart';

/// R6: how long a provisional group's init is resent before the stored
/// commits decide what became of it.
const Duration kProvisionalExpiry = Duration(hours: 24);

/// The `limit_name` of the two daily claim caps (KP): 20 claims per target,
/// 300 claims in all.
const String kLimitClaimsPerTargetDaily = 'keys_claims_per_target_daily';
const String kLimitClaimsDaily = 'keys_claims_daily';

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

typedef StartOutcome = ({
  StartResult result,
  String? conversationId,
  AppException? cause,
});

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
/// them and nothing behind one. The two ends of a provisional group are
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
/// whose pending commit is not an init (Task 10's reset) is left alone
/// here. Never logs; an unexpected failure is reported as
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
       _onUnexpectedError = onUnexpectedError;

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

  /// Local ids whose init's outcome stayed unknown after the automatic
  /// resend: each later trigger makes one attempt.
  final Set<String> _unknown = {};

  /// Local id -> no send before this time (the server's retry time).
  final Map<String, DateTime> _notBefore = {};

  /// The step names [_reportOnce] reported in this run.
  final Set<String> _reported = {};

  /// Sign-out or a new vault: forgets this run's memory.
  void reset() {
    _unknown.clear();
    _notBefore.clear();
    _reported.clear();
  }

  /// Completes when no resume of [conversationId] is running (at once when
  /// none is). Starts none.
  @visibleForTesting
  Future<void> settled(String conversationId) =>
      _running[conversationId] ?? Future<void>.value();

  /// R6 step 4: called at vault ready and before any send. Every provisional
  /// group whose pending commit is an init is resumed (its init resent byte
  /// for byte under the same key) or, once older than [kProvisionalExpiry],
  /// settled from the server's first stored commit: cleared when that
  /// commit is this init, else discarded and started again from fresh
  /// claims. One conversation lock at a time. Never throws.
  Future<void> resumeProvisional({
    BudgetPriority priority = BudgetPriority.background,
  }) => _resumeAll(priority);

  // -------------------------------------------------------------------------
  // Routing

  /// The first message to a peer, or into a conversation that is not
  /// encrypted. [conversationId] is null for a recipient-addressed draft.
  /// Saves the row and returns (the init is sent after it returned);
  /// [StartResult.plaintext] saves nothing.
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
    if (vault != null && !_known.isLoadedFor(vault)) await _known.load(vault);

    // 1. Known first (security read C1): the known set and the cache's
    // sticky marker are asked BEFORE the flag and before any lookup.
    String? known;
    if (conversationId != null) {
      if (_known.contains(conversationId) ||
          await _messaging.cachedEverEncrypted(conversationId)) {
        known = conversationId;
      }
    } else if (vault != null) {
      known = await _known.conversationForPeer(vault, peer);
    }
    if (known != null) {
      return _viaSender(
        known,
        localId: localId,
        text: text,
        sharedPostId: sharedPostId,
      );
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
    if (!_session.mayStart) return _out(StartResult.plaintext);
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
        if (list.devices.isEmpty) return _out(StartResult.plaintext);
      case ListState.unreadable:
        return _lookupFailed(peer);
      case ListState.deferred:
        // The last readable list, when there is one and it is non-empty.
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

  StartOutcome _out(
    StartResult result, [
    String? conversationId,
    AppException? cause,
  ]) => (result: result, conversationId: conversationId, cause: cause);

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

/// The first message of a start: a new draft, or (a rebuild) the stage-plain
/// row [replaces] of a discarded provisional group. No `toString`.
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

  /// The key of the stage-plain row this start encrypts again (it is
  /// replaced by a row under a NEW key in the same transaction).
  final String? replaces;
  final int? createdAtMicros;
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

