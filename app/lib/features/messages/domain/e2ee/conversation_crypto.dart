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

/// R12, MP "Catch-up": a conversation waiting for a welcome may be reset this
/// long after its first-saw time.
const Duration kResetWaitWithoutWelcome = Duration(hours: 24);

/// The contract's page size for `ListConversationCommits` (at most 50).
const int kCommitPageSize = 50;

/// Generation switches one catch-up pass follows before it stops (each needs
/// a stored welcome; the next pass goes on).
const int _kSwitchesPerPass = 4;

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
  static const FormerPins _formerPins = FormerPins();
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

  /// Catch-up with [id]'s lock held. Never throws: an unexpected failure is
  /// `interrupted` (nothing was written by a failed body).
  ///
  /// [parent]: the welcome poll this catch-up runs inside (its welcomes are
  /// acknowledged by it, never again by a nested poll).
  Future<CatchUpResult> _catchUpLocked(
    String id, {
    required BudgetPriority priority,
    _Poll? parent,
  }) async {
    final context = _contexts.of(id);
    // Set again only by a pass that ends at the server pair (step 8).
    context.syncedSinceStart = false;
    try {
      final pass = await _startPoll(priority, parent: parent);
      if (pass == null) return CatchUpResult.interrupted;
      for (var i = 0; i < _kSwitchesPerPass; i++) {
        final step = await _passLocked(pass, id);
        if (step == null) continue; // a newer generation was joined
        switch (step) {
          case CatchUpResult.stuck:
            context.stuck = true;
          case CatchUpResult.current:
          case CatchUpResult.waitingForWelcome:
          case CatchUpResult.notEncrypted:
            context.stuck = false;
          case CatchUpResult.interrupted:
            break;
        }
        return step;
      }
      return CatchUpResult.interrupted;
    } on Object catch (e, s) {
      _reportIfBug(e, s, 'catchUp');
      return CatchUpResult.interrupted;
    }
  }

  /// One pass over the current group's generation. Null: a newer generation
  /// was joined, start again with it.
  Future<CatchUpResult?> _passLocked(_Poll pass, String id) async {
    if (!pass.live) return CatchUpResult.interrupted;
    final context = _contexts.of(id);
    final vault = pass.vault;
    final groups = await vault.groups(id);
    GroupRecord? current;
    for (final group in groups) {
      if (!group.provisional) current = group; // ascending generation
    }
    final record = await vault.conversation(id);
    final accepted = record?.sync.requestAccepted ?? false;
    if (accepted) context.acceptedSeenAt ??= _now();

    // 1. No group: learn the current pair once.
    if (current == null) {
      // A provisional group only: Task 8 settles it; nothing to apply.
      if (groups.isNotEmpty) return CatchUpResult.interrupted;
      final page = await _listCommits(pass, id, null);
      final server = page == null ? null : _serverPairOf(page);
      if (server == null) return CatchUpResult.interrupted;
      if (server == const MlsPair(0, 0)) {
        context.serverPair = null;
        return CatchUpResult.notEncrypted;
      }
      context.serverPair = server;
      await _noteWaiting(pass, id, server.generation);
      return CatchUpResult.waitingForWelcome;
    }

    final g = current.generation;
    var e = current.epoch;
    // The pair of the last commit applied to this group.
    var after = e >= 1 ? MlsPair(g, e - 1) : record?.afterPair;
    MlsPair? server;
    var switching = false;
    var gStuck = false;
    pages:
    while (true) {
      final page = await _listCommits(pass, id, after);
      server = page == null ? null : _serverPairOf(page);
      if (page == null || server == null) return CatchUpResult.interrupted;
      context.serverPair = server;
      final serverAhead = server.generation > g;
      for (final c in page.commits) {
        final cg = pairComponentFromInt64(c.mlsGeneration);
        final ce = pairComponentFromInt64(c.mlsEpoch);
        if (cg != null && cg > g) {
          // 6. A later generation: g is done; its epoch-0 record is never
          // applied.
          switching = true;
          break pages;
        }
        if (cg != g || ce != e) {
          // 5. A gap (or a pair the client cannot hold).
          if (serverAhead) {
            gStuck = true;
            switching = true;
            break pages;
          }
          return CatchUpResult.stuck;
        }
        switch (await _applyLocked(pass, id, MlsPair(g, e), c)) {
          case _Applied.ok:
            after = MlsPair(g, e);
            e++;
          case _Applied.selfRemoved:
            return CatchUpResult.waitingForWelcome;
          case _Applied.interrupted:
            return CatchUpResult.interrupted;
          case _Applied.stuck:
            if (serverAhead) {
              gStuck = true;
              switching = true;
              break pages;
            }
            return CatchUpResult.stuck;
        }
      }
      if (!page.more || page.commits.isEmpty) break;
    }

    if (!switching) {
      final here = MlsPair(g, e);
      if (server.generation > g) {
        switching = true;
      } else if (server == here) {
        return _atServerPair(pass, id, server);
      } else if (server.compareTo(here) > 0) {
        // 5. No commit returned while the server pair is ahead.
        return CatchUpResult.stuck;
      } else {
        // The server is behind this device: nothing to apply; look again.
        return CatchUpResult.interrupted;
      }
    }

    // 6. Generation switch: g's last epoch is walked to its end first (L6).
    final last = MlsPair(g, e);
    // A LOWER stored generation catch-up never walks (it walks the highest
    // only), not recorded as walked: its last epoch is marked undecryptable
    // and recorded with g's, so the join deletes it too.
    final done =
        (await vault.conversation(id))?.sync.completedEpochs ??
        const <MlsPair>[];
    final orphans = [
      for (final old in await vault.groups(id))
        if (!old.provisional &&
            old.generation < g &&
            !done.contains(MlsPair(old.generation, old.epoch)))
          MlsPair(old.generation, old.epoch),
    ];
    final sink = this.sink;
    try {
      for (final o in orphans) {
        await sink?.markEpochUndecryptable(id, o, priority: pass.priority);
      }
      if (gStuck) {
        await sink?.markEpochUndecryptable(id, last, priority: pass.priority);
      } else {
        await sink?.completeEpoch(id, last, priority: pass.priority);
      }
    } on Object catch (err, s) {
      _reportIfBug(err, s, 'completeEpoch');
      return CatchUpResult.interrupted;
    }
    await _noteWalked(pass, id, [...orphans, last]);
    await _pollWelcomes(
      priority: pass.priority,
      held: id,
      serverPairs: {id: server},
      parent: pass,
      fromSwitch: true,
    );
    if (!pass.live) return CatchUpResult.interrupted;
    final after2 = await vault.groups(id);
    if (after2.any((x) => !x.provisional && x.generation > g)) return null;
    await _noteWaiting(pass, id, server.generation);
    return CatchUpResult.waitingForWelcome;
  }

  /// Step 8: the pair is current. Attribution when a member is unattributed
  /// and not concluded this run; then R7 / M10's `syncedSinceStart`.
  Future<CatchUpResult> _atServerPair(
    _Poll pass,
    String id,
    MlsPair server,
  ) async {
    final context = _contexts.of(id);
    if (!pass.live) return CatchUpResult.interrupted;
    final unattributed = (await pass.vault.members(id))
        .any((m) => m.side == MemberSide.unattributed);
    if (!unattributed) {
      context
        ..attributionPending = false
        ..attributionConcluded = true
        ..deferredSince = null;
    } else if (!context.attributionConcluded) {
      try {
        await _attributeMembersLocked(pass, id);
      } on Object catch (e, s) {
        _reportIfBug(e, s, 'attribute');
        context.attributionPending = true;
      }
    }
    context.syncedSinceStart =
        !context.attributionPending && context.livePulledAt == server;
    return CatchUpResult.current;
  }

  /// One `ListConversationCommits` call (one sync-budget unit); null when it
  /// could not be made or failed.
  Future<pb.ListConversationCommitsResponse?> _listCommits(
    _Poll pass,
    String id,
    MlsPair? after,
  ) async {
    if (!await _takeSyncUnit(pass.priority)) return null;
    try {
      return await _messaging.listConversationCommits(
        conversationId: id,
        after: after,
        pageSize: kCommitPageSize,
      );
    } on Object catch (e, s) {
      _reportIfBug(e, s, 'listConversationCommits');
      return null;
    }
  }

  static MlsPair? _serverPairOf(pb.ListConversationCommitsResponse page) {
    final g = pairComponentFromInt64(page.mlsGeneration);
    final e = pairComponentFromInt64(page.mlsEpoch);
    return g == null || e == null ? null : MlsPair(g, e);
  }

  /// Step 4 for the commit at [at]: confirm (own, by bytes) or process, then
  /// ONE transaction with the result, in one runWrite body.
  Future<_Applied> _applyLocked(
    _Poll pass,
    String id,
    MlsPair at,
    pb.ConversationCommit commit,
  ) async {
    try {
      await sink?.completeEpoch(id, at, priority: pass.priority);
    } on Object catch (e, s) {
      _reportIfBug(e, s, 'completeEpoch');
      return _Applied.interrupted;
    }
    final _Applied applied;
    // The known set grew in the applied commit's transaction (a migrated v1
    // group that was never in it).
    var knownGrew = false;
    try {
      applied = await _session.runWrite((v) async {
        pass.check(v);
        final group = await v.group(id, at.generation);
        if (group == null || group.provisional || group.epoch != at.epoch) {
          return _Applied.interrupted;
        }
        final deviceState = await v.deviceState();
        if (deviceState == null) return _Applied.interrupted;
        final record = await v.conversation(id);
        final pins = await v.members(id);
        final engine = _engine();
        final bytes = Uint8List.fromList(commit.commit);
        final pending = group.pending;
        final Uint8List next;
        MlsCommitEvent? event;
        GroupDescription? described;
        try {
          if (pending != null && _sameBytes(bytes, pending.commit)) {
            // This device's own accepted commit: merged, never processed.
            next = await engine.confirmCommit(deviceState, group.state);
          } else {
            var state = group.state;
            // A migrated v1 group with a pending commit and no record.
            if (pending == null &&
                (await engine.describe(state)).hasPendingCommit) {
              state = await engine.discardCommit(deviceState, state);
            }
            final result = await engine.process(deviceState, state, bytes);
            final ev = result.event;
            // An application message in the commit list is unprocessable.
            if (ev is! MlsCommitEvent) return _Applied.stuck;
            event = ev;
            next = result.groupState;
          }
          if (event == null || !event.selfRemoved) {
            described = await engine.describe(next);
          }
        } on MlsException catch (err) {
          return _transient(err.code) ? _Applied.interrupted : _Applied.stuck;
        }
        final written = await _writeApplied(
          v,
          id,
          at,
          next: next,
          event: event,
          described: described,
          record: record,
          pins: pins,
          thisDevice: pass.deviceId,
        );
        knownGrew = written.knownGrew;
        if (written.newMember) {
          _contexts.of(id)
            ..attributionConcluded = false
            ..attributionPending = true;
        }
        return event?.selfRemoved ?? false ? _Applied.selfRemoved : _Applied.ok;
      });
    } on _Stopped {
      return _Applied.interrupted;
    } on Object catch (e, s) {
      _reportIfBug(e, s, 'applyCommit');
      return _Applied.interrupted;
    }
    if (applied == _Applied.ok || applied == _Applied.selfRemoved) {
      _onChanged(id);
    }
    if (knownGrew) {
      try {
        await _messaging.noteEverEncrypted(id, session: pass.cacheSession);
      } on Object catch (e, s) {
        _reportIfBug(e, s, 'noteEverEncrypted');
      }
    }
    return applied;
  }

  /// The one transaction of an applied commit (inside the runWrite body that
  /// computed [next]). `newMember`: a member was pinned unattributed (added,
  /// or a changed key); `knownGrew`: the id was added to the known set.
  Future<({bool newMember, bool knownGrew})> _writeApplied(
    SecureVault v,
    String id,
    MlsPair at, {
    required Uint8List next,
    required MlsCommitEvent? event,
    required GroupDescription? described,
    required ConversationRecord? record,
    required List<MemberRecord> pins,
    required Uint8List thisDevice,
  }) async {
    final nextPair = at.next;
    final sync = record?.sync ?? const ConversationSync();
    final accepted = sync.requestAccepted;
    final nowMicros = _now().microsecondsSinceEpoch;
    // L6's checks (the join's delete, `_unwalked`) only ever look for a
    // stored group's CURRENT (generation, epoch). After this commit the
    // group of `at.generation` is at `at.next`, so no entry of that
    // generation (`at` included) can match again: only the walked last
    // epochs of the other stored generations are kept (at most one each).
    final completed = [
      for (final p in sync.completedEpochs)
        if (p.generation != at.generation) p,
    ];
    final needKnown = !_known.contains(id);
    final groups = await v.groups(id);
    // Read fresh in this body: the key history, cross-checked against the
    // pins and the former pins ([DeviceKeyHistory]).
    final former = await _formerPins.of(v, id);
    final history = await _keyHistory.of(
      v,
      id,
      currentPins: pins,
      formerPins: former,
    );
    var newMember = false;
    try {
      await v.transaction((tx) async {
        if (event != null && event.selfRemoved) {
          // This device was removed: groups and pins go; the pins are kept
          // as former pins (H2) and the rejoin is compared with them.
          for (final group in groups) {
            await tx.deleteGroup(id, group.generation);
          }
          for (final p in pins) {
            await tx.deleteMember(id, p.deviceId);
          }
          await _formerPins.putIn(tx, v, id, pins);
          // The rejoin is never a first join: no baseline is kept.
          await _baselines.deleteIn(tx, v, id);
          // The key history is untouched (nothing ever shrinks it): it
          // already holds every pin kept here, and a rejoin is admitted
          // against it.
          if (MlsPair.above(at, record?.afterPair)) {
            await tx.setAfterPair(id, at);
          }
          await tx.clearSentBefore(id, nextPair);
          await tx.putConversationSync(
            id,
            sync.copyWith(
              // Every group was deleted: nothing is left for L6 to check.
              completedEpochs: const [],
              epochMustAdvance: false,
              firstSawGeneration: at.generation,
              firstSawGenerationAtMicros: nowMicros,
            ),
          );
          if (needKnown) await _known.addIn(tx, v, id);
          return;
        }
        final byHex = {for (final p in pins) vaultDeviceIdHex(p.deviceId): p};
        final thisHex = vaultDeviceIdHex(thisDevice);
        final members = described?.members ?? const <GroupMember>[];
        final inGroup = {for (final m in members) vaultDeviceIdHex(m.deviceId)};
        // Removed: from the event, or (an own commit, no event) the pins the
        // group no longer has.
        final removed = event != null
            ? [for (final r in event.removed) vaultDeviceIdHex(r)]
            : [
                for (final hex in byHex.keys)
                  if (hex != thisHex && !inGroup.contains(hex)) hex,
              ];
        for (final hex in removed) {
          final pinned = byHex.remove(hex);
          if (pinned == null) continue;
          await tx.deleteMember(id, pinned.deviceId);
          // R10: no system row of any kind while unaccepted.
          if (!accepted) continue;
          await tx.putMessage(
            _systemRow(
              id,
              nextPair,
              SystemLine.deviceRemoved,
              nowMicros,
              deviceId: pinned.deviceId,
              side: pinned.side,
            ),
          );
        }
        // Added, and the (id, key) comparison after every commit: a member
        // not pinned, or pinned with another key, is pinned unattributed
        // with the key the group holds (never kept on its old side). Each is
        // admitted to the key history first, in this same transaction and
        // whatever the acceptance state: the history decides, not the pins
        // (a removed device's pin is gone, its recorded key is not). A pair
        // the history refuses (an id seen with another key, a new id while
        // the history is closed) is never attributed; its unknownDevice
        // row, display only, is written here in accepted conversations and
        // by attribution once one is accepted.
        final added = <String, Uint8List>{};
        if (event != null) {
          for (var i = 0; i < event.added.length; i++) {
            if (i < event.addedSignatureKeys.length) {
              added[vaultDeviceIdHex(event.added[i])] =
                  event.addedSignatureKeys[i];
            }
          }
        }
        for (final m in members) {
          final hex = vaultDeviceIdHex(m.deviceId);
          added[hex] = m.signaturePublicKey;
        }
        for (final entry in added.entries) {
          if (entry.key == thisHex) continue;
          final pinned = byHex[entry.key];
          if (pinned != null && _sameBytes(pinned.signatureKey, entry.value)) {
            continue;
          }
          final deviceId = _deviceIdOf(entry.key, event, members);
          if (deviceId == null) continue;
          newMember = true;
          final refusal = history.admit(entry.key, entry.value);
          await tx.putMember(
            MemberRecord(
              conversationId: id,
              deviceId: deviceId,
              signatureKey: entry.value,
              side: MemberSide.unattributed,
              since: nextPair,
            ),
          );
          // No row from an unreadable history.
          if (accepted &&
              refusal != KeyRefusal.none &&
              refusal != KeyRefusal.unreadable) {
            final row = _systemRow(
              id,
              nextPair,
              SystemLine.unknownDevice,
              nowMicros,
              deviceId: deviceId,
            );
            if (!await v.hasMessage(id, row.messageId)) {
              await tx.putMessage(row);
            }
          }
        }
        await tx.putGroup(
          GroupRecord(
            conversationId: id,
            generation: at.generation,
            epoch: nextPair.epoch,
            state: next,
          ),
        );
        if (MlsPair.above(at, record?.afterPair)) {
          await tx.setAfterPair(id, at);
        }
        await tx.clearSentBefore(id, nextPair);
        await tx.putConversationSync(
          id,
          sync.copyWith(completedEpochs: completed, epochMustAdvance: false),
        );
        if (needKnown) await _known.addIn(tx, v, id);
        // The one history write of this transaction: only when a new id or
        // a taint was recorded (a removal never writes it).
        await _keyHistory.writeIn(tx, id, history);
      });
    } on Object {
      _known.discardStaged();
      rethrow;
    }
    _known.commitStaged();
    return (newMember: newMember, knownGrew: needKnown);
  }

  static Uint8List? _deviceIdOf(
    String hex,
    MlsCommitEvent? event,
    List<GroupMember> members,
  ) {
    for (final m in members) {
      if (vaultDeviceIdHex(m.deviceId) == hex) return m.deviceId;
    }
    for (final a in event?.added ?? const <Uint8List>[]) {
      if (vaultDeviceIdHex(a) == hex) return a;
    }
    return null;
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

  /// `internal`, `deadline` and `unavailable` are transient: the pass stops
  /// and changes nothing; the commit is never skipped.
  static bool _transient(MlsErrorCode code) =>
      code == MlsErrorCode.internal ||
      code == MlsErrorCode.deadline ||
      code == MlsErrorCode.unavailable;

  /// Steps 1 and 6: the device waits for a welcome of [generation]. The
  /// first-saw record is written when that generation is not recorded yet
  /// (never moved earlier), with the known set (C1) in the same transaction.
  Future<void> _noteWaiting(_Poll pass, String id, int generation) async {
    final wrote = await _session.runWrite((v) async {
      pass.check(v);
      final record = await v.conversation(id);
      final sync = record?.sync ?? const ConversationSync();
      final seen = sync.firstSawGeneration;
      final record0 =
          seen == null ||
          seen < generation ||
          sync.firstSawGenerationAtMicros == null;
      final needKnown = !_known.contains(id);
      if (!record0 && !needKnown) return false;
      try {
        await v.transaction((tx) async {
          if (record0) {
            await tx.putConversationSync(
              id,
              sync.copyWith(
                firstSawGeneration: generation,
                firstSawGenerationAtMicros: _now().microsecondsSinceEpoch,
              ),
            );
          }
          if (needKnown) await _known.addIn(tx, v, id);
        });
      } on Object {
        _known.discardStaged();
        rethrow;
      }
      _known.commitStaged();
      return needKnown;
    });
    if (wrote) {
      try {
        await _messaging.noteEverEncrypted(id, session: pass.cacheSession);
      } on Object catch (e, s) {
        _reportIfBug(e, s, 'noteEverEncrypted');
      }
    }
  }

  /// L6: [walked], generation g's last epoch (and those of lower stored
  /// generations left behind), was walked to its end after the server
  /// reported a later generation (completed or marked undecryptable):
  /// recorded in `completedEpochs`, which the next join reads to delete
  /// those generations.
  Future<void> _noteWalked(_Poll pass, String id, List<MlsPair> walked) =>
      _session.runWrite((v) async {
        pass.check(v);
        final sync =
            (await v.conversation(id))?.sync ?? const ConversationSync();
        final add = [
          for (final p in walked)
            if (!sync.completedEpochs.contains(p)) p,
        ];
        if (add.isEmpty) return;
        await v.transaction(
          (tx) => tx.putConversationSync(
            id,
            sync.copyWith(completedEpochs: [...sync.completedEpochs, ...add]),
          ),
        );
      });

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
    // be read: the allowance is no exit from an unreadable history).
    var keyHistoryClosed = false;
    var mayAllowMoreDevices = false;
    try {
      final history = await _keyHistory.of(
        vault,
        id,
        currentPins: pins,
        formerPins: await _formerPins.of(vault, id),
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

  /// One welcome poll. With [held] (the caller holds that conversation's
  /// lock, stage 3's catch-up), only [held]'s welcome is handled, in place;
  /// the others are left for the next poll.
  Future<List<String>> _pollWelcomes({
    required BudgetPriority priority,
    String? held,
    Map<String, MlsPair>? serverPairs,
    _Poll? parent,
    bool fromSwitch = false,
  }) async {
    final poll = await _startPoll(
      priority,
      held: held,
      serverPairs: serverPairs,
      parent: parent,
      fromSwitch: fromSwitch,
    );
    if (poll == null) return const [];
    final joined = <String>[];
    final listed = <String>{};
    // A welcome is handled (and acknowledged) once per OUTER poll: one left
    // unacknowledged (transient) comes back on the next page and waits for
    // the next poll, and a nested poll (catch-up's generation switch after a
    // join) skips one its outer poll has not acknowledged yet. The set is
    // shared with the nested polls.
    final handled = poll.handled;
    var complete = false;
    while (poll.live) {
      if (!await _takeSyncUnit(priority)) break;
      final pb.ListWelcomesResponse page;
      try {
        page = await _messaging.listWelcomes(deviceId: poll.deviceIdString);
      } on Object catch (e, s) {
        _reportIfBug(e, s, 'listWelcomes');
        break;
      }
      final ackIds = <String>[];
      // A welcome joined (and acknowledged) by a nested poll of the
      // catch-up it started: the next page no longer lists it.
      var joinedInPlace = false;
      for (final w in page.welcomes) {
        if (w.id.isEmpty) continue;
        listed.add(w.id);
        final id = w.conversationId;
        if (held != null && id != held) continue;
        if (!handled.add(w.id)) continue;
        final outcome = id.isEmpty
            ? _Outcome.permanent
            : held != null
            ? await _welcomeLocked(poll, w)
            : await _locks.run(id, () => _welcomeLocked(poll, w));
        if (outcome == _Outcome.stop || !poll.live) break;
        if (outcome == _Outcome.joinedInPlace ||
            outcome == _Outcome.handledInPlace) {
          if (outcome == _Outcome.joinedInPlace) joined.add(id);
          joinedInPlace = true;
          continue;
        }
        if (outcome == _Outcome.joined) joined.add(id);
        if (outcome != _Outcome.transient) ackIds.add(w.id);
      }
      // A changed vault acknowledges nothing more.
      if (!poll.live) break;
      if (!await _ack(poll, ackIds)) break;
      if (!page.more) {
        complete = held == null;
        break;
      }
      // The same page would come back.
      if (ackIds.isEmpty && !joinedInPlace) break;
    }
    if (complete && poll.live) await _dropSkew(poll, listed);
    return joined;
  }

  /// [parent]: the poll (or pass) this one runs inside; its handled set is
  /// shared.
  Future<_Poll?> _startPoll(
    BudgetPriority priority, {
    String? held,
    Map<String, MlsPair>? serverPairs,
    _Poll? parent,
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
      return _Poll(
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

  /// One welcome under its conversation's lock (held by the caller).
  Future<_Outcome> _welcomeLocked(_Poll poll, pb.Welcome w) async {
    final id = w.conversationId;
    _Join result;
    try {
      result = await _welcomeSteps(poll, w, mayWalk: !poll.fromSwitch);
      final label = result.label;
      if (result.kind == _Outcome.walkFirst && label != null) {
        // Step 6 / L6: a stored generation not walked to its end goes first.
        // Catch-up applies its remaining commits, completes (or marks) its
        // last epoch, then joins this welcome in place through its own held
        // poll, which acknowledges it.
        // The nested poll may handle this welcome once (it is released from
        // this poll's handled set for that).
        poll.handled.remove(w.id);
        await _catchUpLocked(id, priority: poll.priority, parent: poll);
        if (!poll.live) return _Outcome.stop;
        if (!poll.handled.add(w.id)) {
          // Handled there (joined, refused or left for the next poll), and
          // acknowledged there when it was to be.
          final after = await poll.vault.conversation(id);
          return after?.joinHighWater == label
              ? _Outcome.joinedInPlace
              : _Outcome.handledInPlace;
        }
        // The walk did not finish (a transient failure): the next poll.
        if (await _unwalked(poll.vault, id, label.generation)) {
          return _Outcome.transient;
        }
        // Walked (or the old group went with selfRemoved) but not joined
        // there: join here, with the marks read again.
        result = await _welcomeSteps(poll, w, mayWalk: false);
      }
    } on _Stopped {
      return _Outcome.stop;
    } on Object catch (e, s) {
      // Transient: a vault error, a closed vault, a budget pause, the network,
      // an engine deadline. Never acknowledged; the next poll retries.
      _reportIfBug(e, s, 'welcome');
      return poll.live ? _Outcome.transient : _Outcome.stop;
    }
    switch (result.kind) {
      case _Outcome.joined:
        await _afterJoinLocked(poll, id);
        return _Outcome.joined;
      case _Outcome.permanent:
        try {
          await _notePermanent(poll, id);
        } on Object catch (e, s) {
          _reportIfBug(e, s, 'welcomeKnown');
          return poll.live ? _Outcome.transient : _Outcome.stop;
        }
        return _Outcome.permanent;
      case _Outcome.transient:
      case _Outcome.stop:
      case _Outcome.joinedInPlace:
      case _Outcome.handledInPlace:
        return result.kind;
      case _Outcome.walkFirst:
        // Only once per welcome (mayWalk false the second time).
        return _Outcome.transient;
    }
  }

  /// L6: a stored non-provisional group of a generation up to [generation]
  /// whose (generation, epoch) is not recorded as walked to its end.
  static Future<bool> _unwalked(
    SecureVault vault,
    String id,
    int generation,
  ) async {
    final groups = await vault.groups(id);
    if (groups.isEmpty) return false;
    final done =
        (await vault.conversation(id))?.sync.completedEpochs ??
        const <MlsPair>[];
    return groups.any(
      (g) =>
          !g.provisional &&
          g.generation <= generation &&
          !done.contains(MlsPair(g.generation, g.epoch)),
    );
  }

  /// [mayWalk]: a stored generation not walked to its end yields
  /// [_Outcome.walkFirst] (the caller catches up first) instead of a join.
  Future<_Join> _welcomeSteps(
    _Poll poll,
    pb.Welcome w, {
    required bool mayWalk,
  }) async {
    final id = w.conversationId;
    // 1. The label; a component the client cannot hold is permanent.
    final g = pairComponentFromInt64(w.mlsGeneration);
    final e = pairComponentFromInt64(w.mlsEpoch);
    if (g == null || e == null || e >= kMaxPairComponent) {
      return const _Join(_Outcome.permanent);
    }
    final label = MlsPair(g, e);

    // 2. A label not above both marks is a replay: no engine call.
    final record = await poll.vault.conversation(id);
    if (!MlsPair.above(label, record?.afterPair) ||
        !MlsPair.above(label, record?.joinHighWater)) {
      return const _Join(_Outcome.permanent);
    }

    // A welcome of a generation below the server's current one is useless
    // (MP "Catch-up"): acknowledged, no engine call. One call per
    // conversation per poll (catch-up hands over the pair it read).
    var server = poll.serverPairs[id];
    if (server == null) {
      final page = await _listCommits(poll, id, null);
      server = page == null ? null : _serverPairOf(page);
      if (server == null) return const _Join(_Outcome.transient);
      poll.serverPairs[id] = server;
    }
    if (g < server.generation) return const _Join(_Outcome.permanent);

    // L6 / step 6: an older (or the same) generation still to be walked is
    // walked by catch-up first; a join now would leave its last epochs
    // unread (or overwrite a same-generation group).
    if (mayWalk && await _unwalked(poll.vault, id, g)) {
      return _Join(_Outcome.walkFirst, label: label);
    }

    // 2a. A provisional group of the labelled generation (security read M8).
    final provisional = await poll.vault.group(id, g);
    if (provisional != null && provisional.provisional) {
      switch (await _settleProvisional(poll, id, provisional)) {
        case _Settled.ownStored:
        case _Settled.replay:
          return const _Join(_Outcome.permanent);
        case _Settled.unknown:
          return const _Join(_Outcome.transient);
        case _Settled.discarded:
          break;
      }
    }

    // The own list for the welcome check: the last readable one (it may be
    // read from the server, so before the body), this device always in.
    final own = await _directory.own(priority: poll.priority);
    final ownHex = <String>{
      deviceIdHex(poll.deviceId),
      if (own.state != ListState.unreadable)
        for (final d in own.devices) deviceIdHex(d.deviceId),
    };

    // 3. Join, check and store in ONE runWrite body.
    return _session.runWrite((v) async {
      poll.check(v);
      final state = await v.deviceState();
      if (state == null) throw StateError('No device state.');
      final stored = await v.conversation(id);
      final JoinResult joined;
      final GroupDescription description;
      try {
        joined = await _engine().joinFromWelcome(
          state,
          Uint8List.fromList(w.welcome),
        );
        description = await _engine().describe(joined.groupState);
      } on MlsException catch (err) {
        // 4. As catch-up: internal, deadline and unavailable are transient;
        // bad_input goes through the skew rule (L1); every other code
        // (evicted, duplicate, a corrupt state...) is permanent.
        if (_transient(err.code)) return const _Join(_Outcome.transient);
        if (err.code == MlsErrorCode.badInput) return _skewOrPermanent(v, w);
        return const _Join(_Outcome.permanent);
      }
      final verdict = checkWelcome(
        conversationId: id,
        label: label,
        joinedGroupId: joined.groupId,
        joinedEpoch: joined.epoch,
        members: description.members,
        afterPair: stored?.afterPair,
        joinHighWater: stored?.joinHighWater,
        ownDeviceIdsHex: ownHex,
      );
      if (verdict == WelcomeVerdict.permanent) {
        return const _Join(_Outcome.permanent);
      }
      // Read fresh in this body: the pins, the former pins, the groups.
      final groups = await v.groups(id);
      final current = await v.members(id);
      final former = await _formerPins.of(v, id);
      // The key history as it was BEFORE this join stores anything (a
      // missing one is fresh only while the conversation has no state).
      final history = await _keyHistory.of(
        v,
        id,
        currentPins: current,
        formerPins: former,
      );
      final firstJoin =
          stored?.afterPair == null &&
          stored?.joinHighWater == null &&
          former.isEmpty &&
          groups.isEmpty;
      try {
        await v.transaction((tx) async {
          await tx.putDeviceState(joined.deviceState);
          await tx.putGroup(
            GroupRecord(
              conversationId: id,
              generation: g,
              epoch: label.epoch + 1,
              state: joined.groupState,
            ),
          );
          // L6: a lower generation goes only once its last epoch was walked
          // to the end (completed or marked undecryptable, stage 3).
          final done = stored?.sync.completedEpochs ?? const <MlsPair>[];
          for (final old in groups) {
            if (old.generation < g &&
                !old.provisional &&
                done.contains(MlsPair(old.generation, old.epoch))) {
              await tx.deleteGroup(id, old.generation);
            }
          }
          await _pinJoined(
            tx,
            id,
            label,
            description.members,
            thisDevice: poll.deviceId,
            current: current,
            former: former,
            history: history,
          );
          // Step 7: a join of a later generation where pins of an earlier
          // one existed is a reset: one row per join (the same id when a
          // join is processed again), never while unaccepted (R10).
          // "Pins of an earlier generation": pins are stored and the
          // after-pair is of a lower generation (a kept pin keeps its old
          // `since`, so `since` alone would call a same-generation re-add a
          // reset).
          final afterPair = stored?.afterPair;
          if ((stored?.sync.requestAccepted ?? false) &&
              current.isNotEmpty &&
              afterPair != null &&
              afterPair.generation < g) {
            await tx.putMessage(
              _systemRow(
                id,
                label.next,
                SystemLine.encryptionReset,
                _now().microsecondsSinceEpoch,
              ),
            );
          }
          await _formerPins.deleteIn(tx, v, id);
          // I-2: a first join records its baseline in the vault; any later
          // join replaces it with none.
          if (firstJoin) {
            await _baselines.putIn(tx, v, id, label.next);
          } else {
            await _baselines.deleteIn(tx, v, id);
          }
          await _known.addIn(tx, v, id);
          if (MlsPair.above(label, stored?.afterPair)) {
            await tx.setAfterPair(id, label);
          }
          if (MlsPair.above(label, stored?.joinHighWater)) {
            await tx.setJoinHighWater(id, label);
          }
          await tx.putConversationSync(
            id,
            (stored?.sync ?? const ConversationSync()).copyWith(
              firstSawGeneration: null,
              firstSawGenerationAtMicros: null,
              completedEpochs: const [],
              epochMustAdvance: false,
              lastSelfUpdateAtMicros: _now().microsecondsSinceEpoch,
            ),
          );
          // The one history write of this transaction (a first join writes
          // it even when nothing was admitted).
          await _keyHistory.writeIn(tx, id, history);
        });
      } on Object {
        _known.discardStaged();
        rethrow;
      }
      _known.commitStaged();
      return const _Join(_Outcome.joined);
    });
  }

  /// The pins of a joined group: this device `mine`; a member pinned now
  /// with the same key and a side keeps its pin; a member held in the
  /// current or former pins with the same key and a side gets that side
  /// (`attributeAfterReset`'s first branch, no list); every other member is
  /// `unattributed` since `label.next`. Pins absent from the group go.
  ///
  /// Every other member is admitted to [history] (the body's fresh read)
  /// first, and only a pair it does not refuse may keep or get a side: a
  /// refused one (an id seen with another key, a new id while the history
  /// is closed) is pinned unattributed, which beats a kept pin and the
  /// former side. One exception: while the history is unreadable a current
  /// pin with a side and the same key is kept (every other member is
  /// unattributed). The caller writes [history] once, at the end of this
  /// transaction; pins absent from the group go, their history stays.
  Future<void> _pinJoined(
    VaultTx tx,
    String id,
    MlsPair label,
    List<GroupMember> members, {
    required Uint8List thisDevice,
    required List<MemberRecord> current,
    required List<MemberRecord> former,
    required KeyHistory history,
  }) async {
    final pinned = [...current, ...former];
    final inGroup = <String>{};
    for (final m in members) {
      final hex = vaultDeviceIdHex(m.deviceId);
      inGroup.add(hex);
      final isThis = vaultDeviceIdHex(thisDevice) == hex;
      final changed =
          !isThis &&
          history.admit(hex, m.signaturePublicKey) != KeyRefusal.none;
      final kept = current.where(
        (p) =>
            vaultDeviceIdHex(p.deviceId) == hex &&
            _sameBytes(p.signatureKey, m.signaturePublicKey) &&
            p.side != MemberSide.unattributed &&
            (!isThis || p.side == MemberSide.mine),
      );
      // An unreadable history never demotes a pin that already has a side
      // and the same key (it was attributable when it got the side, and a
      // taint always replaces the pin with an unattributed one).
      if (kept.isNotEmpty && (!changed || history.unreadable)) continue;
      final side = isThis
          ? MemberSide.mine
          : changed
          ? MemberSide.unattributed
          : attributeAfterReset(
              deviceId: m.deviceId,
              signatureKey: m.signaturePublicKey,
              pinnedAtEndOfPrevious: pinned,
              ownList: const DeviceList.unreadable(),
              peerList: const DeviceList.unreadable(),
            );
      await tx.putMember(
        MemberRecord(
          conversationId: id,
          deviceId: m.deviceId,
          signatureKey: m.signaturePublicKey,
          side: side,
          since: label.next,
        ),
      );
    }
    for (final p in current) {
      if (!inGroup.contains(vaultDeviceIdHex(p.deviceId))) {
        await tx.deleteMember(id, p.deviceId);
      }
    }
  }

  /// Step 4: `bad_input` while the device clock is behind the welcome's
  /// `created_at` is transient at most [kWelcomeSkewRetries] times per
  /// welcome id (counted in the vault, inside this body); otherwise
  /// permanent.
  Future<_Join> _skewOrPermanent(SecureVault v, pb.Welcome w) async {
    if (!w.hasCreatedAt()) return const _Join(_Outcome.permanent);
    final created = w.createdAt.toDateTime();
    if (!_now().isBefore(created)) return const _Join(_Outcome.permanent);
    final counts = await _readSkew(v);
    final n = counts[w.id] ?? 0;
    if (n >= kWelcomeSkewRetries) return const _Join(_Outcome.permanent);
    counts[w.id] = n + 1;
    await v.transaction(
      (tx) => tx.putSetting(kVaultSettingWelcomeSkew, _encodeSkew(counts)),
    );
    return const _Join(_Outcome.transient);
  }

  /// Step 2a: settles a provisional group of the welcome's generation from
  /// the server's first stored commit of that generation.
  Future<_Settled> _settleProvisional(
    _Poll poll,
    String id,
    GroupRecord provisional,
  ) async {
    final g = provisional.generation;
    pb.ConversationCommit? first;
    var passed = false;
    // From the stored after-pair: every commit up to it was applied here and
    // is below generation g's first one. An after-pair already in g (or
    // above) would skip that first commit: read from the start then.
    final stored = (await poll.vault.conversation(id))?.afterPair;
    MlsPair? after = stored != null && stored.generation < g ? stored : null;
    for (var page = 0; page < _kSettlePagesMax; page++) {
      if (!await _takeSyncUnit(poll.priority)) return _Settled.unknown;
      final response = await _messaging.listConversationCommits(
        conversationId: id,
        after: after,
        pageSize: kCommitPageSize,
      );
      for (final c in response.commits) {
        final cg = pairComponentFromInt64(c.mlsGeneration);
        final ce = pairComponentFromInt64(c.mlsEpoch);
        if (cg == null || ce == null) return _Settled.unknown;
        if (cg == g) {
          first = c;
          break;
        }
        if (cg > g) {
          passed = true;
          break;
        }
        after = MlsPair(cg, ce);
      }
      if (first != null || passed) break;
      if (!response.more || response.commits.isEmpty) break;
    }
    // Nothing stored for that generation yet: the outcome is not known.
    if (first == null && !passed) return _Settled.unknown;
    final pending = provisional.pending;
    final own =
        first != null &&
        pending != null &&
        MlsPair(
              pairComponentFromInt64(first.mlsGeneration)!,
              pairComponentFromInt64(first.mlsEpoch)!,
            ) ==
            pending.builtOn &&
        _sameBytes(first.commit, pending.commit);
    return _session.runWrite((v) async {
      poll.check(v);
      final group = await v.group(id, g);
      if (group == null || !group.provisional) {
        // Settled meanwhile (it cannot be, under the lock): look again later.
        return _Settled.unknown;
      }
      if (own) {
        final stored = await v.conversation(id);
        if (!MlsPair.above(pending.builtOn, stored?.afterPair)) {
          // The marks are already at or past this init (the marks cannot be
          // written again): the welcome is a replay, for good. Clearing the
          // provisional group is Task 8's.
          return _Settled.replay;
        }
        await v.transaction((tx) async {
          await tx.clearProvisional(id, g, afterPair: pending.builtOn);
          // The init is accepted: nothing of it is pending any more.
          await tx.putGroup(
            GroupRecord(
              conversationId: id,
              generation: g,
              epoch: group.epoch,
              state: group.state,
            ),
          );
        });
        return _Settled.ownStored;
      }
      final members = await v.members(id);
      final outbox = await v.outbox();
      final peerRef = _known.peerOf(id);
      await v.transaction((tx) async {
        await tx.deleteGroup(id, g);
        for (final m in members) {
          if (m.since.generation >= g) await tx.deleteMember(id, m.deviceId);
        }
        for (final item in outbox.items) {
          final mine =
              item.conversationId == id ||
              (item.conversationId == null &&
                  peerRef != null &&
                  item.recipientUserId == peerRef);
          if (!mine ||
              item.stage != OutboxStage.encrypted ||
              item.generation != g) {
            continue;
          }
          await tx.putOutbox(
            OutboxItem(
              idempotencyKey: item.idempotencyKey,
              localId: item.localId,
              expectedMessageId: item.expectedMessageId,
              conversationId: item.conversationId,
              recipientUserId: item.recipientUserId,
              generation: 0,
              epoch: 0,
              ciphertext: Uint8List(0),
              reportCommitment: Uint8List(0),
              content: item.content,
              createdAtMicros: item.createdAtMicros,
              stage: OutboxStage.plain,
              attempts: item.attempts,
              lastError: item.lastError,
            ),
          );
        }
      });
      return _Settled.discarded;
    });
  }

  /// Step 5: a permanent welcome extends the known set only for a cached
  /// conversation of this user (C1, re-read N5).
  Future<void> _notePermanent(_Poll poll, String id) async {
    if (await _messaging.cachedConversation(id) == null) return;
    if (!poll.live) throw const _Stopped();
    if (!_known.contains(id)) await _known.add(id);
    await _messaging.noteEverEncrypted(id, session: poll.cacheSession);
  }

  /// Step 6, under the conversation's lock after a stored join. A failure
  /// here never changes the acknowledgement: the join is stored.
  Future<void> _afterJoinLocked(_Poll poll, String id) async {
    try {
      await _messaging.noteEverEncrypted(id, session: poll.cacheSession);
    } on Object catch (e, s) {
      _reportIfBug(e, s, 'noteEverEncrypted');
    }
    _onChanged(id);
    _contexts.of(id)
      ..attributionPending = true
      ..syncedSinceStart = false
      ..livePulledAt = null
      ..attributionConcluded = false;
    // Joined in place by catch-up's generation switch: that pass goes on
    // (and attributes once current); a nested catch-up would poll again.
    if (poll.held == id) return;
    // Step 6: catch-up, through the locked variant (this lock is held). It
    // never throws, and never changes the acknowledgement.
    await _catchUpLocked(id, priority: poll.priority, parent: poll);
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

  /// The attribution entry points' body (the lock is held): the known set is
  /// loaded for the current vault like every other entry point. Never throws.
  Future<void> _attributeEntry(String id, BudgetPriority priority) async {
    try {
      final pass = await _startPoll(priority);
      if (pass == null) return;
      await _attributeMembersLocked(pass, id);
    } on _Stopped {
      // The vault changed: nothing was written.
    } on Object catch (e, s) {
      _reportIfBug(e, s, 'attribute');
    }
  }

  /// A member pinned by the FIRST join of the conversation (the sealed
  /// baseline record, [JoinBaselines], read fresh in the write body) is a
  /// baseline member: no peer-side row, and the own-device alert only per
  /// security read H2. Every other member (a later join, a member added by a
  /// commit) gets its `deviceAdded` row once attributed. A member whose
  /// (device id, key) the conversation's key history refuses is never
  /// attributed: it stays an unknown device. An ordinary unknown device
  /// (recorded with that one key; its row written by an earlier unknown
  /// verdict) is attributed once a list shows it.
  Future<void> _attributeMembersLocked(_Poll pass, String id) async {
    final priority = pass.priority;
    final vault = pass.vault;
    if (!pass.live) return;
    final context = _contexts.of(id);
    if (!(await vault.members(id))
        .any((m) => m.side == MemberSide.unattributed)) {
      context
        ..attributionPending = false
        ..attributionConcluded = true
        ..deferredSince = null;
      return;
    }
    final ref = await _peerRef(id, priority);
    final own = await _directory.own(fresh: true, priority: priority);
    final peer = ref == null
        ? const DeviceList.unreadable()
        : await _directory.peer(ref, fresh: true, priority: priority);
    final unreadable =
        own.state == ListState.unreadable || peer.state == ListState.unreadable;
    final deferred =
        !unreadable &&
        (own.state == ListState.deferred || peer.state == ListState.deferred);
    final outcome = await _session.runWrite((v) async {
      pass.check(v);
      final baselineSince = await _baselines.of(v, id);
      final current = await v.members(id);
      // Fresh and cross-checked; attribution never writes the history.
      final history = await _keyHistory.of(
        v,
        id,
        currentPins: current,
        formerPins: await _formerPins.of(v, id),
      );
      final accepted =
          (await v.conversation(id))?.sync.requestAccepted ?? false;
      final now = _now();
      final acceptedSeenAt = accepted ? (context.acceptedSeenAt ??= now) : null;
      // The peer fetch is the full registered list only from
      // kConversationCopyStale after this run knew the conversation accepted.
      final peerFetched = peer.fetchedAt;
      final counts =
          !unreadable &&
          !deferred &&
          peerFetched != null &&
          fetchCounts(fetchedAt: peerFetched, acceptedSeenAt: acceptedSeenAt);
      var waiting = false;
      final everMine = accepted
          ? await _formerPins.everPinnedMine(v, excluding: id)
          : const <({String deviceIdHex, String keyB64})>{};
      final brandNew = accepted && baselineSince != null
          ? await _formerPins.brandNewVault(v, excluding: id)
          : false;
      final nowMicros = _now().microsecondsSinceEpoch;
      final pins = <MemberRecord>[];
      final rows = <StoredMessage>[];
      var stillUnattributed = false;
      var theirsFromPeer = false;
      var baselineLeft = false;
      for (final m in current) {
        if (m.side != MemberSide.unattributed) continue;
        final hex = vaultDeviceIdHex(m.deviceId);
        // A pair the key history refuses ([DeviceKeyHistory]: a tainted id,
        // an id it does not hold, every member while it is unreadable)
        // stays an unknown device whatever the lists now say. Checked
        // before the lists decide anything. Its row is display only:
        // written once the conversation is accepted (R10), never from an
        // unreadable history.
        final refusal = history.refusal(hex, m.signatureKey);
        if (refusal != KeyRefusal.none) {
          stillUnattributed = true;
          if (m.since == baselineSince) baselineLeft = true;
          context.firstSeenUnattributed[hex] ??= now;
          context.unknownDevices.add(hex);
          if (accepted && refusal != KeyRefusal.unreadable) {
            final row = _systemRow(
              id,
              m.since,
              SystemLine.unknownDevice,
              nowMicros,
              deviceId: m.deviceId,
            );
            if (!await v.hasMessage(id, row.messageId)) rows.add(row);
          }
          continue;
        }
        final side = attribute(
          deviceId: m.deviceId,
          signatureKey: m.signatureKey,
          ownList: own,
          peerList: peer,
        );
        if (side == MemberSide.unattributed) {
          if (m.since == baselineSince) baselineLeft = true;
          stillUnattributed = true;
          // R10: unaccepted, an unmatched member just stays unattributed.
          // An unreadable or deferred list decides nothing (handled below).
          if (!accepted || unreadable || deferred) continue;
          if (!counts) {
            // The server may still answer with active devices only: no row,
            // no flag; one re-attribution at the time the fetch counts.
            waiting = true;
            context.reattributeAt = acceptedSeenAt!.add(kConversationCopyStale);
            continue;
          }
          // M2: unknown with both lists readable and a counting fetch. One
          // row per device and pair (the stored row is the record of it).
          context.firstSeenUnattributed[hex] ??= now;
          context.unknownDevices.add(hex);
          final row = _systemRow(
            id,
            m.since,
            SystemLine.unknownDevice,
            nowMicros,
            deviceId: m.deviceId,
          );
          if (!await v.hasMessage(id, row.messageId)) rows.add(row);
          continue;
        }
        context.unknownDevices.remove(hex);
        context.firstSeenUnattributed.remove(hex);
        if (side == MemberSide.theirs) theirsFromPeer = true;
        pins.add(
          MemberRecord(
            conversationId: id,
            deviceId: m.deviceId,
            signatureKey: m.signatureKey,
            side: side,
            since: m.since,
          ),
        );
        // R10: no system row of any kind while unaccepted.
        if (!accepted) continue;
        final baseline = baselineSince != null && m.since == baselineSince;
        final bool row;
        if (side == MemberSide.mine) {
          // H2: at a first join only an own-side pair this vault never
          // pinned mine in another accepted conversation alerts, and not on
          // a brand-new vault; after any other join every new key does.
          row =
              !baseline ||
              (!brandNew &&
                  !everMine.contains((
                    deviceIdHex: vaultDeviceIdHex(m.deviceId),
                    keyB64: base64Encode(m.signatureKey),
                  )));
        } else {
          row = !baseline;
        }
        if (row) {
          rows.add(
            StoredMessage(
              conversationId: id,
              messageId: systemLineId(
                id,
                m.since,
                SystemLine.deviceAdded,
                deviceId: m.deviceId,
              ),
              createdAtMicros: nowMicros,
              mine: false,
              state: StoredMessageState.visible,
              generation: m.since.generation,
              epoch: m.since.epoch,
              content: SystemLineContent(
                line: SystemLine.deviceAdded,
                deviceId: m.deviceId,
                side: side,
              ).encode(),
              kind: StoredMessageKind.system,
            ),
          );
        }
      }
      // Pending: a member is unattributed for a reason a later attribution
      // may settle (a list not readable or deferred, a fetch not counting
      // yet). An unreadable or deferred list is retried in an unaccepted
      // conversation too (it writes no row there); an unmatched member of an
      // unaccepted one is not (the lookup there means nothing).
      final pending =
          stillUnattributed &&
          (unreadable || deferred || (accepted && waiting));
      // I-2: the baseline goes once no member at its `since` is unattributed.
      final dropBaseline = baselineSince != null && !baselineLeft;
      if (pins.isEmpty && rows.isEmpty && !dropBaseline) {
        return (wrote: false, pending: pending, knownGrew: false);
      }
      var knownGrew = false;
      try {
        await v.transaction((tx) async {
          for (final p in pins) {
            await tx.putMember(p);
          }
          for (final r in rows) {
            await tx.putMessage(r);
          }
          if (dropBaseline) await _baselines.deleteIn(tx, v, id);
          // C1 / N3: the ref whose list the theirs-side pins came from.
          if (theirsFromPeer && ref != null) {
            knownGrew = await _known.addIn(tx, v, id, peerUserId: ref);
          }
        });
      } on Object {
        _known.discardStaged();
        rethrow;
      }
      _known.commitStaged();
      return (
        wrote: pins.isNotEmpty || rows.isNotEmpty,
        pending: pending,
        knownGrew: knownGrew,
      );
    });
    // As an applied commit (I-4): the known set grew in that transaction.
    if (outcome.knownGrew) {
      try {
        await _messaging.noteEverEncrypted(id, session: pass.cacheSession);
      } on Object catch (e, s) {
        _reportIfBug(e, s, 'noteEverEncrypted');
      }
    }
    final now = _now();
    final unattributedLeft = (await vault.members(id))
        .any((m) => m.side == MemberSide.unattributed);
    if (unreadable) {
      context.listUnverifiable = true;
    } else if (deferred) {
      // M4: silent while deferred, up to kDeferredWithUnattributedLimit with
      // an unattributed member; then it reads as unreadable.
      if (unattributedLeft) context.deferredSince ??= now;
      if (deferralOutlasted(
        deferredSince: context.deferredSince,
        unattributedPresent: unattributedLeft,
        now: now,
      )) {
        context.listUnverifiable = true;
      }
    } else {
      context
        ..deferredSince = null
        ..listUnverifiable = false;
    }
    context
      ..attributionPending = outcome.pending
      ..attributionConcluded = !outcome.pending;
    if (!outcome.pending) context.reattributeAt = null;
    if (outcome.wrote) _onChanged(id);
  }

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
  Future<bool> allowNewDevices(String conversationId) =>
      _locks.run(conversationId, () => _allowNewDevicesLocked(conversationId));

  Future<bool> _allowNewDevicesLocked(String id) async {
    try {
      final pass = await _startPoll(BudgetPriority.user);
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

  /// The peer's user reference: this run's context, else the cached header,
  /// else the first `ListMessages` page. Null when none is known.
  Future<String?> _peerRef(String id, BudgetPriority priority) async {
    final context = _contexts.of(id);
    String? known() {
      final ref = context.peerUserId;
      return ref == null || ref.isEmpty ? null : ref;
    }

    if (known() != null) return known();
    final row = await _messaging.cachedConversation(id);
    if (row != null) _contexts.note(row);
    if (known() != null) return known();
    if (!await _takeSyncUnit(priority)) return null;
    final page = await _messaging.listMlsMessages(conversationId: id);
    if (page.hasConversation()) _contexts.note(page.conversation);
    return known();
  }

  // ---------------------------------------------------------------------
  // Acknowledgements and the skew counters

  /// Acknowledges [ids] in calls of at most [kAckWelcomesMaxIds]; false when
  /// a call could not be made or failed (the rest come back next poll).
  Future<bool> _ack(_Poll poll, List<String> ids) async {
    for (var i = 0; i < ids.length; i += kAckWelcomesMaxIds) {
      final end = i + kAckWelcomesMaxIds > ids.length
          ? ids.length
          : i + kAckWelcomesMaxIds;
      final chunk = ids.sublist(i, end);
      if (!poll.live) return false;
      if (!await _takeSyncUnit(poll.priority)) return false;
      try {
        final key = _hexOf(await _engine().randomBytes(16));
        await _messaging.ackWelcomes(
          idempotencyKey: key,
          deviceId: poll.deviceIdString,
          ids: chunk,
        );
      } on Object catch (e, s) {
        _reportIfBug(e, s, 'ackWelcomes');
        return false;
      }
      await _editSkew(poll, (n) {
        var changed = false;
        for (final id in chunk) {
          changed = n.remove(id) != null || changed;
        }
        return changed;
      });
    }
    return true;
  }

  /// After a complete poll: the counters of welcome ids it did not list go.
  Future<void> _dropSkew(_Poll poll, Set<String> listed) =>
      _editSkew(poll, (n) {
        final before = n.length;
        n.removeWhere((id, _) => !listed.contains(id));
        return n.length != before;
      });

  /// Reads the counters fresh in a runWrite body and writes them only when
  /// [edit] changed them. A failure is quiet: the counters are only ever
  /// conservative (a stale entry is dropped at the next complete poll).
  Future<void> _editSkew(
    _Poll poll,
    bool Function(Map<String, int> counts) edit,
  ) async {
    try {
      await _session.runWrite((v) async {
        poll.check(v);
        final counts = await _readSkew(v);
        if (!edit(counts)) return;
        await v.transaction(
          (tx) => tx.putSetting(kVaultSettingWelcomeSkew, _encodeSkew(counts)),
        );
      });
    } on Object catch (e, s) {
      _reportIfBug(e, s, 'welcomeSkew');
    }
  }

  static Future<Map<String, int>> _readSkew(SecureVault v) async {
    final bytes = await v.setting(kVaultSettingWelcomeSkew);
    if (bytes == null) return {};
    try {
      final m = jsonDecode(utf8.decode(bytes));
      if (m is! Map<String, Object?> || m['v'] != 1) {
        throw const FormatException('shape');
      }
      final n = m['n'];
      if (n is! Map<String, Object?>) throw const FormatException('shape');
      return {
        for (final e in n.entries)
          e.key: e.value is int && (e.value! as int) >= 0
              ? e.value! as int
              : throw const FormatException('count'),
      };
    } on FormatException {
      throw const VaultCorruptException('vault_settings');
    }
  }

  static Uint8List _encodeSkew(Map<String, int> counts) =>
      Uint8List.fromList(utf8.encode(jsonEncode({'v': 1, 'n': counts})));

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

  static bool _sameBytes(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  static String _hexOf(Uint8List b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
}

/// `joinedInPlace`: joined and acknowledged by the nested poll of the
/// catch-up a `walkFirst` started (nothing more to acknowledge);
/// `handledInPlace`: handled there without a join (acknowledged there when
/// it was to be). `walkFirst`: a stored generation must be walked to its end
/// before this join.
enum _Outcome {
  joined,
  permanent,
  transient,
  stop,
  joinedInPlace,
  handledInPlace,
  walkFirst,
}

/// `replay`: this device's own init was stored and the marks are already at
/// or above it.
enum _Settled { ownStored, discarded, unknown, replay }

enum _Applied { ok, selfRemoved, stuck, interrupted }

class _Join {
  const _Join(this.kind, {this.label});

  final _Outcome kind;

  /// The welcome's label, with [_Outcome.walkFirst].
  final MlsPair? label;
}

/// The vault the poll started with is no longer the session's.
class _Stopped implements Exception {
  const _Stopped();
}

/// One welcome poll's fixed facts, captured when it started. No `toString`.
class _Poll {
  _Poll({
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

  /// The first thing every runWrite body of the poll does.
  void check(SecureVault v) {
    if (!identical(v, vault) || v.uid != uid || !live) throw const _Stopped();
  }
}
