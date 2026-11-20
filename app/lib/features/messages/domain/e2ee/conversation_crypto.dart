import 'dart:convert';
import 'dart:typed_data';

import '../../../../core/crypto/crypto_engine.dart';
import '../../../../core/crypto/crypto_types.dart';
import '../../../../core/crypto/guarded_crypto_engine.dart';
import '../../../../core/crypto/mls_pair.dart';
import '../../../../core/vault/secure_vault.dart';
import '../../../../core/vault/vault_session.dart';
import '../../../../core/vault/vault_status.dart';
import '../../../../gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;
import '../../data/messaging_repository.dart';
import 'conversation_context.dart';
import 'conversation_locks.dart';
import 'device_directory.dart';
import 'e2ee_types.dart';
import 'former_pins.dart';
import 'join_baselines.dart';
import 'device_key_history.dart';
import 'known_conversations.dart';
import 'membership_rules.dart';
import 'sync_budget.dart';

// The service's private steps, one concern per part (private extensions on
// ConversationCrypto): catch-up passes, applying one commit, the welcome
// poll, joining from one welcome, member attribution. This file keeps the
// public entry points, the locking, describeState, allowNewDevices and the
// operation context.
part 'conversation_attribution.dart';
part 'conversation_catch_up.dart';
part 'conversation_commit_apply.dart';
part 'conversation_join.dart';
part 'conversation_welcomes.dart';

/// Vault setting: welcome clock-skew retries (security read L1). Sealed
/// `{"v":1,"n":{welcomeId:n}}`; the key holds no id.
const String kVaultSettingWelcomeSkew = 'messages.e2ee.welcomeSkew';

/// Transient treatments of a `bad_input` join answer while the device clock
/// is behind the welcome's `created_at`, per welcome id; the next one is
/// permanent (security read L1, owner-approved).
const int kWelcomeSkewRetries = 3;

/// The most ids one `AckWelcomes` call carries (the contract's 1-50).
const int kAckWelcomesMaxIds = 50;

/// The most `ListConversationCommits` pages read to settle one provisional
/// group (security read M8): 50 commits a page, so far above any real
/// generation's distance from the start.
const int _kSettlePagesMax = 200;

/// The most `ListWelcomes` pages one welcome poll reads: the sync budget is
/// a rate, not a cap, so a server that always says `more` would otherwise
/// hold the poll forever. At the cap the poll ends as if the server had no
/// more for now (incomplete: no skew counter is dropped); the next poll goes
/// on with what is still unacknowledged.
const int _kWelcomePagesMax = 20;

/// The most `ListConversationCommits` pages one catch-up pass reads while it
/// holds the conversation lock (50 commits a page). At the cap the pass ends
/// `interrupted`; every applied commit is stored, and the next pass goes on
/// from the stored after-pair.
const int _kCommitPagesMax = 20;

/// R12, MP "Catch-up": a conversation waiting for a welcome may be reset this
/// long after its first-saw time.
const Duration kResetWaitWithoutWelcome = Duration(hours: 24);

/// The contract's page size for `ListConversationCommits` (at most 50).
const int kCommitPageSize = 50;

/// Generation switches one catch-up pass follows before it stops (each needs
/// a stored welcome; the next pass goes on).
const int _kSwitchesPerPass = 4;

const FormerPins _formerPins = FormerPins();

/// What one catch-up pass ended with.
///
/// `interrupted`: a transient failure (budget pause, deadline, network, vault
/// closed): nothing was lost; try again later.
enum CatchUpResult {
  current,
  waitingForWelcome,
  stuck,
  notEncrypted,
  interrupted,
}

/// Implemented by Task 6; Task 5 tests use a recording double.
///
/// A sink is called BY catch-up, under the conversation lock: it must never
/// call catch-up (or any entry point that runs it, locked or not) itself.
abstract interface class EpochMessageSink {
  /// Called under the conversation lock with every message of one closed
  /// epoch, before its commit is applied.
  Future<void> completeEpoch(
    String conversationId,
    MlsPair pair, {
    required BudgetPriority priority,
  });

  /// Called when an epoch's messages can no longer be decrypted by this
  /// device (state lost, commit unusable).
  Future<void> markEpochUndecryptable(
    String conversationId,
    MlsPair pair, {
    required BudgetPriority priority,
  });
}

/// The encrypted conversations' crypto service: joins from welcomes and
/// attributes the members it met (Task 5).
///
/// Locking (plan "Global Constraints"): the conversation lock first, then
/// `session.runWrite` inside it; never two conversation locks at once. RPCs
/// run under the conversation lock and outside `runWrite`. Inside a
/// `runWrite` body the device state is read fresh, the engine is called and
/// its result is written in ONE transaction of that same body.
///
/// Public entry points take the conversation lock; the private `...Locked`
/// variants assume it is held (`KeyedMutex` is not re-entrant).
///
/// Never logs; an unexpected failure is reported as [E2eePipelineError] with
/// a step name only.
class ConversationCrypto {
  /// [known] is the app's one [KnownConversations] (Task 13b's `hasLocal`
  /// reads the same instance); it is loaded here when it was not loaded yet.
  ConversationCrypto({
    required VaultSession session,
    required CryptoEngine Function() engine,
    required MessagingRepository messaging,
    required DeviceDirectory directory,
    required SyncBudget syncBudget,
    required ConversationLocks locks,
    required ConversationContexts contexts,
    required KnownConversations known,
    required DateTime Function() now,
    required void Function(String conversationId) onChanged,
    void Function(Object error, StackTrace stack)? onUnexpectedError,
  }) : _session = session,
       _engine = engine,
       _messaging = messaging,
       _directory = directory,
       _syncBudget = syncBudget,
       _locks = locks,
       _contexts = contexts,
       _known = known,
       _baselines = JoinBaselines(onUnexpectedError: onUnexpectedError),
       _keyHistory = DeviceKeyHistory(onUnexpectedError: onUnexpectedError),
       _now = now,
       _onChanged = onChanged,
       _onUnexpectedError = onUnexpectedError;

  final VaultSession _session;
  final CryptoEngine Function() _engine;
  final MessagingRepository _messaging;
  final DeviceDirectory _directory;
  final SyncBudget _syncBudget;
  final ConversationLocks _locks;
  final ConversationContexts _contexts;
  final KnownConversations _known;
  final JoinBaselines _baselines;
  final DeviceKeyHistory _keyHistory;
  final DateTime Function() _now;
  final void Function(String conversationId) _onChanged;
  final void Function(Object error, StackTrace stack)? _onUnexpectedError;

  /// Set by Task 6.
  EpochMessageSink? sink;

  /// Applies commits from the after-pair to the server's current pair, then
  /// attributes new members (M2).
  Future<CatchUpResult> catchUp(
    String conversationId, {
    BudgetPriority priority = BudgetPriority.background,
  }) => _locks.run(
    conversationId,
    () => _catchUpLocked(conversationId, priority: priority),
  );

  /// [catchUp] for a caller that ALREADY HOLDS [id]'s conversation lock
  /// (Tasks 6, 7, 8 call in while holding it; [ConversationLocks] is not
  /// re-entrant). Never throws (asserts the lock is held).
  Future<CatchUpResult> catchUpLocked(
    String id, {
    BudgetPriority priority = BudgetPriority.background,
  }) {
    assert(_locks.isHeld(id), 'The caller must hold the conversation lock.');
    return _catchUpLocked(id, priority: priority);
  }

  /// Processes [id]'s welcomes, then catches up, for a caller that ALREADY
  /// HOLDS [id]'s conversation lock. Only [id]'s welcome is handled (the
  /// others wait for the next poll). Never throws (asserts the lock is held).
  Future<CatchUpResult> processWelcomesHeld(
    String id, {
    BudgetPriority priority = BudgetPriority.background,
  }) {
    assert(_locks.isHeld(id), 'The caller must hold the conversation lock.');
    return _processWelcomesHeld(id, priority);
  }

  Future<CatchUpResult> _processWelcomesHeld(
    String id,
    BudgetPriority priority,
  ) async {
    try {
      await _pollWelcomes(priority: priority, held: id);
    } on Object catch (e, s) {
      _reportIfBug(e, s, 'welcomePoll');
    }
    return _catchUpLocked(id, priority: priority);
  }

  /// [attributeMembers] for a caller that ALREADY HOLDS [id]'s conversation
  /// lock. Never throws (asserts the lock is held).
  Future<void> attributeMembersLocked(
    String id, {
    BudgetPriority priority = BudgetPriority.background,
  }) {
    assert(_locks.isHeld(id), 'The caller must hold the conversation lock.');
    return _attributeEntry(id, priority);
  }

  StoredMessage _systemRow(
    String id,
    MlsPair pair,
    String line,
    int nowMicros, {
    Uint8List? deviceId,
    String? side,
  }) => StoredMessage(
    conversationId: id,
    messageId: systemLineId(id, pair, line, deviceId: deviceId),
    createdAtMicros: nowMicros,
    mine: false,
    state: StoredMessageState.visible,
    generation: pair.generation,
    epoch: pair.epoch,
    content: SystemLineContent(
      line: line,
      deviceId: deviceId,
      side: side,
    ).encode(),
    kind: StoredMessageKind.system,
  );

  /// Builds the 5b state from the vault and the context. Takes no lock (a
  /// read only); never throws for a closed vault.
  Future<ConversationCryptoState> describeState(String conversationId) async {
    final id = conversationId;
    final context = _contexts.of(id);
    final engine = _engine();
    final engineDown =
        engine is GuardedCryptoEngine && engine.unavailable.value;
    final vault = _session.vault;
    final List<GroupRecord> groups;
    final ConversationRecord? record;
    final List<MemberRecord> pins;
    try {
      if (vault == null) throw StateError('No vault.');
      groups = await vault.groups(id);
      record = await vault.conversation(id);
      pins = await vault.members(id);
    } on Object catch (e, s) {
      _reportIfBug(e, s, 'describeState');
      return ConversationCryptoState(
        phase: ConversationPhase.notEncrypted,
        sendBlock: SendBlock.unavailable,
        requestAccepted: false,
        incomingRequest: context.incomingRequest ?? true,
        deviceListUnverifiable: false,
        unknownDevicePresent: false,
        committingPausedToday: false,
        unattributedPresent: false,
        myDeviceCount: 0,
        theirDeviceCount: 0,
        canReset: false,
      );
    }
    // The key history's state (a read only; false for both when it cannot
    // be read: the allowance is no exit from an unreadable history). No
    // lock is held here, so a first join can commit between these reads
    // and make the history look missing: this read never reports, and so
    // never spends the conversation's one `keyHistory.read` report.
    var keyHistoryClosed = false;
    var mayAllowMoreDevices = false;
    try {
      final history = await _keyHistory.of(
        vault,
        id,
        currentPins: pins,
        formerPins: await _formerPins.of(vault, id),
        report: false,
      );
      keyHistoryClosed = !history.unreadable && history.closed;
      mayAllowMoreDevices = history.mayAllowMore;
    } on Object catch (e, s) {
      _reportIfBug(e, s, 'describeState');
    }
    final sync = record?.sync ?? const ConversationSync();
    final accepted = sync.requestAccepted;
    GroupRecord? current;
    for (final group in groups) {
      if (!group.provisional) current = group;
    }
    final server = context.serverPair;
    final ConversationPhase phase;
    // The brief's order: a remembered stuck answer before a provisional
    // group.
    if (context.stuck) {
      phase = ConversationPhase.stuck;
    } else if (groups.any((x) => x.provisional)) {
      phase = ConversationPhase.provisional;
    } else if (current != null &&
        (server == null || current.generation >= server.generation) &&
        (sync.firstSawGeneration ?? 0) <= current.generation) {
      phase = ConversationPhase.ready;
    } else if (current != null || record != null || _known.contains(id)) {
      phase = ConversationPhase.waitingForWelcome;
    } else {
      phase = ConversationPhase.notEncrypted;
    }
    final unattributed = pins.any((p) => p.side == MemberSide.unattributed);
    final unknown =
        accepted &&
        pins.any(
          (p) =>
              p.side == MemberSide.unattributed &&
              context.unknownDevices.contains(vaultDeviceIdHex(p.deviceId)),
        );
    final now = _now();
    final unverifiable =
        context.listUnverifiable ||
        deferralOutlasted(
          deferredSince: context.deferredSince,
          unattributedPresent: unattributed,
          now: now,
        );
    final SendBlock block;
    if (engineDown) {
      block = SendBlock.unavailable;
    } else if (phase == ConversationPhase.stuck) {
      block = SendBlock.stuck;
    } else if (phase == ConversationPhase.waitingForWelcome) {
      block = SendBlock.waitingForWelcome;
    } else if (phase == ConversationPhase.provisional) {
      block = SendBlock.provisional;
    } else if (phase == ConversationPhase.notEncrypted) {
      block = context.canReply ? SendBlock.none : SendBlock.cannotMessage;
    } else if (unknown) {
      block = SendBlock.unknownDevice;
    } else if (sync.epochMustAdvance) {
      block = SendBlock.epochMustAdvance;
    } else if (!context.syncedSinceStart ||
        context.attributionPending ||
        unattributed) {
      block = SendBlock.notSynced;
    } else if (!context.canReply) {
      block = SendBlock.cannotMessage;
    } else {
      block = SendBlock.none;
    }
    final seenAt = sync.firstSawGenerationAtMicros;
    return ConversationCryptoState(
      phase: phase,
      sendBlock: block,
      requestAccepted: accepted,
      incomingRequest: context.incomingRequest ?? !accepted,
      deviceListUnverifiable: unverifiable,
      unknownDevicePresent: unknown,
      // Task 9 (M5) and Task 10 own these.
      committingPausedToday: false,
      unattributedPresent: unattributed,
      myDeviceCount: pins.where((p) => p.side == MemberSide.mine).length,
      theirDeviceCount: pins.where((p) => p.side == MemberSide.theirs).length,
      canReset: false,
      resetAllowedAt:
          phase == ConversationPhase.waitingForWelcome && seenAt != null
          ? DateTime.fromMicrosecondsSinceEpoch(
              seenAt,
              isUtc: true,
            ).add(kResetWaitWithoutWelcome)
          : null,
      keyHistoryClosed: keyHistoryClosed,
      mayAllowMoreDevices: mayAllowMoreDevices,
    );
  }

  // ---------------------------------------------------------------------
  // Welcomes (R5, R8)

  /// `ListWelcomes` for THIS device, join, store, then `AckWelcomes`;
  /// repeats while `more`. Returns the conversation ids joined. Takes no lock
  /// for the list call; each welcome takes its own conversation's lock.
  Future<List<String>> processWelcomes({
    BudgetPriority priority = BudgetPriority.background,
  }) => _pollWelcomes(priority: priority);

  /// [parent]: the poll (or pass) this one runs inside; its handled set is
  /// shared.
  Future<_Operation?> _startOperation(
    BudgetPriority priority, {
    String? held,
    Map<String, MlsPair>? serverPairs,
    _Operation? parent,
    bool fromSwitch = false,
  }) async {
    final vault = _session.vault;
    if (vault == null) return null;
    try {
      final uid = vault.uid;
      final id = await vault.deviceId();
      if (id == null) return null;
      final idString = utf8.decode(id);
      // Loaded for THIS vault (not only loaded): a set of another vault is
      // replaced before anything is written.
      if (!_known.isLoadedFor(vault)) await _known.load(vault);
      return _Operation(
        session: _session,
        vault: vault,
        uid: uid,
        deviceId: id,
        deviceIdString: idString,
        cacheSession: _messaging.cacheSession,
        priority: priority,
        held: held,
        serverPairs: serverPairs,
        handled: parent?.handled,
        fromSwitch: fromSwitch,
      );
    } on Object catch (e, s) {
      // A closed or changed vault: nothing to do now.
      _reportIfBug(e, s, 'welcomePoll');
      return null;
    }
  }

  // ---------------------------------------------------------------------
  // Attribution (M2, H2, R10)

  /// M2 attribution only: fetches both lists fresh and pins each
  /// unattributed member to the side a list shows.
  Future<void> attributeMembers(
    String conversationId, {
    BudgetPriority priority = BudgetPriority.background,
  }) => _locks.run(
    conversationId,
    () => _attributeEntry(conversationId, priority),
  );

  // ---------------------------------------------------------------------
  // The key history's allowance

  /// The user's confirmed "allow new devices here" for [conversationId]
  /// (the caller shows the confirmation; nothing here runs on its own).
  ///
  /// One transaction under the conversation lock: the key history, read
  /// fresh and cross-checked, has its allowance raised by one step, and the
  /// devices it only remembered because it was full are admitted, each on
  /// the key it was first seen with, while there is room (their pins stay
  /// unattributed until a list shows them; a device whose key changed
  /// meanwhile is tainted and never admitted). It reopens only when none is
  /// left held. No id and no taint is dropped.
  ///
  /// True when the allowance was raised. False, with nothing written, when
  /// the history is not closed, cannot be raised further, is unreadable, or
  /// the vault is closed or changed. Never throws.
  ///
  /// It starts no attribution: after it returns true the caller must run
  /// [catchUp] or [attributeMembers] (the admitted devices stay unattributed
  /// until then), and should read [describeState] again, because a raise can
  /// promote nothing (every held device may have changed key, or there may
  /// be none).
  Future<bool> allowNewDevices(String conversationId) =>
      _locks.run(conversationId, () => _allowNewDevicesLocked(conversationId));

  Future<bool> _allowNewDevicesLocked(String id) async {
    try {
      final pass = await _startOperation(BudgetPriority.user);
      if (pass == null) return false;
      final raised = await _session.runWrite((v) async {
        pass.check(v);
        // Read fresh in this body, with its vault.
        final current = await v.members(id);
        final former = await _formerPins.of(v, id);
        final history = await _keyHistory.of(
          v,
          id,
          currentPins: current,
          formerPins: former,
        );
        // Only a closed, readable history below the maximum gets more.
        if (!history.mayAllowMore) return false;
        // Promotion uses only the keys the history holds, never a pin's.
        history.allowNewDevices();
        await v.transaction((tx) => _keyHistory.writeIn(tx, id, history));
        return true;
      });
      if (!raised) return false;
      // The admitted devices are still unattributed: the next pass asks the
      // lists.
      _contexts.of(id)
        ..attributionConcluded = false
        ..attributionPending = true;
      _onChanged(id);
      return true;
    } on _Stopped {
      return false;
    } on Object catch (e, s) {
      _reportIfBug(e, s, 'allowNewDevices');
      return false;
    }
  }

  // ---------------------------------------------------------------------

  /// One unit of the sync budget; false (make no call) while paused, when a
  /// pause released the wait, or after a reset.
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

  /// Reports a programming error (never an expected failure) by its step
  /// name only; the error itself is never passed on.
  void _reportIfBug(Object e, StackTrace s, String step) {
    if (e is Error && e is! StateError) {
      _onUnexpectedError?.call(E2eePipelineError(step), s);
    }
  }
}

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

/// The vault the poll started with is no longer the session's.
class _Stopped implements Exception {
  const _Stopped();
}

/// One operation's fixed facts (a welcome poll, a catch-up pass, an
/// attribution or an allowance change), captured by `_startOperation` when
/// it started: the vault and its user, this device, the priority, and the
/// welcome poll's shared sets. No `toString`.
class _Operation {
  _Operation({
    required this.session,
    required this.vault,
    required this.uid,
    required this.deviceId,
    required this.deviceIdString,
    required this.cacheSession,
    required this.priority,
    this.held,
    Map<String, MlsPair>? serverPairs,
    Set<String>? handled,
    this.fromSwitch = false,
  }) : serverPairs = serverPairs ?? {},
       handled = handled ?? {};

  /// The poll of catch-up's generation switch (the held conversation was
  /// just walked): its welcome never starts another walk (I-1's gate is
  /// "not already held by a catch-up"; a lower generation catch-up does not
  /// walk would otherwise loop).
  final bool fromSwitch;

  /// Welcome ids handled in this poll and the polls nested in it (m6: each
  /// is acknowledged at most once per outer poll).
  final Set<String> handled;

  /// The conversation whose lock the caller holds (catch-up's generation
  /// switch): its welcome is joined in place and no catch-up follows the
  /// join (the caller's pass goes on).
  final String? held;

  /// The server's current pair per conversation, read once per poll.
  final Map<String, MlsPair> serverPairs;

  final VaultSession session;
  final SecureVault vault;
  final String uid;
  final Uint8List deviceId;
  final String deviceIdString;
  final int cacheSession;
  final BudgetPriority priority;

  bool get live {
    final v = session.vault;
    return identical(v, vault) && v?.uid == uid;
  }

  /// The first thing every runWrite body of the operation does.
  void check(SecureVault v) {
    if (!identical(v, vault) || v.uid != uid || !live) throw const _Stopped();
  }
}
