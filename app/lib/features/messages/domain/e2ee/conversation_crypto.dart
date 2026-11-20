import 'dart:convert';
import 'dart:typed_data';

import '../../../../core/crypto/crypto_engine.dart';
import '../../../../core/crypto/crypto_types.dart';
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
       _formerPins = FormerPins(session: session),
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
  final FormerPins _formerPins;
  final DateTime Function() _now;
  final void Function(String conversationId) _onChanged;
  final void Function(Object error, StackTrace stack)? _onUnexpectedError;

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
  }) async {
    final poll = await _startPoll(priority);
    if (poll == null) return const [];
    final joined = <String>[];
    final listed = <String>{};
    // A welcome is handled once per poll: one left unacknowledged (transient)
    // comes back on the next page and waits for the next poll.
    final handled = <String>{};
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
      if (ackIds.isEmpty) break;
    }
    if (complete && poll.live) await _dropSkew(poll, listed);
    return joined;
  }

  Future<_Poll?> _startPoll(BudgetPriority priority) async {
    final vault = _session.vault;
    if (vault == null) return null;
    try {
      final uid = vault.uid;
      final id = await vault.deviceId();
      if (id == null) return null;
      final idString = utf8.decode(id);
      if (!_known.loaded) await _known.load(vault);
      return _Poll(
        session: _session,
        vault: vault,
        uid: uid,
        deviceId: id,
        deviceIdString: idString,
        cacheSession: _messaging.cacheSession,
        priority: priority,
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
      result = await _welcomeSteps(poll, w);
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
        await _afterJoinLocked(poll, id, baselineSince: result.baselineSince);
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
        return result.kind;
    }
  }

  Future<_Join> _welcomeSteps(_Poll poll, pb.Welcome w) async {
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

    // 2a. A provisional group of the labelled generation (security read M8).
    final provisional = await poll.vault.group(id, g);
    if (provisional != null && provisional.provisional) {
      switch (await _settleProvisional(poll, id, provisional)) {
        case _Settled.ownStored:
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
        // 4. Only bad_input can be permanent; every other code is transient.
        if (err.code != MlsErrorCode.badInput) {
          return const _Join(_Outcome.transient);
        }
        return _skewOrPermanent(v, w);
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
      final former = await _formerPins.of(id);
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
          );
          await _formerPins.deleteIn(tx, id);
          await _known.addIn(tx, id);
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
        });
      } on Object {
        _known.discardStaged();
        rethrow;
      }
      _known.commitStaged();
      return _Join(
        _Outcome.joined,
        baselineSince: firstJoin ? label.next : null,
      );
    });
  }

  /// The pins of a joined group: this device `mine`; a member pinned now
  /// with the same key and a side keeps its pin; a member held in the
  /// current or former pins with the same key and a side gets that side
  /// (`attributeAfterReset`'s first branch, no list); every other member is
  /// `unattributed` since `label.next`. Pins absent from the group go.
  Future<void> _pinJoined(
    VaultTx tx,
    String id,
    MlsPair label,
    List<GroupMember> members, {
    required Uint8List thisDevice,
    required List<MemberRecord> current,
    required List<MemberRecord> former,
  }) async {
    final pinned = [...current, ...former];
    final inGroup = <String>{};
    for (final m in members) {
      final hex = vaultDeviceIdHex(m.deviceId);
      inGroup.add(hex);
      final isThis = vaultDeviceIdHex(thisDevice) == hex;
      final kept = current.where(
        (p) =>
            vaultDeviceIdHex(p.deviceId) == hex &&
            _sameBytes(p.signatureKey, m.signaturePublicKey) &&
            p.side != MemberSide.unattributed &&
            (!isThis || p.side == MemberSide.mine),
      );
      if (kept.isNotEmpty) continue;
      final side = isThis
          ? MemberSide.mine
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
    MlsPair? after;
    for (var page = 0; page < _kSettlePagesMax; page++) {
      if (!await _takeSyncUnit(poll.priority)) return _Settled.unknown;
      final response = await _messaging.listConversationCommits(
        conversationId: id,
        after: after,
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
          return _Settled.unknown;
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
  Future<void> _afterJoinLocked(
    _Poll poll,
    String id, {
    required MlsPair? baselineSince,
  }) async {
    try {
      await _messaging.noteEverEncrypted(id, session: poll.cacheSession);
    } on Object catch (e, s) {
      _reportIfBug(e, s, 'noteEverEncrypted');
    }
    _onChanged(id);
    final context = _contexts.of(id)
      ..attributionPending = true
      ..syncedSinceStart = false
      ..livePulledAt = null
      // A later join is never a baseline: it replaces an earlier first one.
      ..baselineSince = baselineSince;
    // Stage 3 seam: the brief's step 6 runs `catchUp` here (as
    // `_catchUpLocked`, which attributes once the pair is current). Until
    // then the join's own members are attributed directly.
    try {
      await _attributeMembersLocked(id, priority: poll.priority);
    } on Object catch (e, s) {
      _reportIfBug(e, s, 'attributeAfterJoin');
      context.attributionPending = true;
    }
  }

  // ---------------------------------------------------------------------
  // Attribution (M2, H2, R10)

  /// M2 attribution only: fetches both lists fresh and pins each
  /// unattributed member to the side a list shows.
  Future<void> attributeMembers(
    String conversationId, {
    BudgetPriority priority = BudgetPriority.background,
  }) => _locks.run(conversationId, () async {
    try {
      await _attributeMembersLocked(conversationId, priority: priority);
    } on Object catch (e, s) {
      _reportIfBug(e, s, 'attribute');
    }
  });

  /// A member pinned by this run's FIRST join of the conversation
  /// ([ConversationContext.baselineSince]) is a baseline member: no
  /// peer-side row, and the own-device alert only per security read H2.
  /// Every other member (a later join, a member added by a commit, anything
  /// after a restart) gets its `deviceAdded` row once attributed.
  Future<void> _attributeMembersLocked(
    String id, {
    required BudgetPriority priority,
  }) async {
    final vault = _session.vault;
    if (vault == null) return;
    final uid = vault.uid;
    final context = _contexts.of(id);
    if (!(await vault.members(id))
        .any((m) => m.side == MemberSide.unattributed)) {
      context.attributionPending = false;
      return;
    }
    final ref = await _peerRef(id, priority);
    final own = await _directory.own(fresh: true, priority: priority);
    final peer = ref == null
        ? const DeviceList.unreadable()
        : await _directory.peer(ref, fresh: true, priority: priority);
    final baselineSince = context.baselineSince;
    final outcome = await _session.runWrite((v) async {
      if (!identical(v, vault) || v.uid != uid) {
        throw StateError('The vault changed.');
      }
      final current = await v.members(id);
      final accepted =
          (await v.conversation(id))?.sync.requestAccepted ?? false;
      final everMine = accepted
          ? await _formerPins.everPinnedMine(excluding: id)
          : const <({String deviceIdHex, String keyB64})>{};
      final brandNew = accepted && baselineSince != null
          ? await _formerPins.brandNewVault(excluding: id)
          : false;
      final nowMicros = _now().microsecondsSinceEpoch;
      final pins = <MemberRecord>[];
      final rows = <StoredMessage>[];
      var stillUnattributed = false;
      var theirsFromPeer = false;
      for (final m in current) {
        if (m.side != MemberSide.unattributed) continue;
        final side = attribute(
          deviceId: m.deviceId,
          signatureKey: m.signatureKey,
          ownList: own,
          peerList: peer,
        );
        if (side == MemberSide.unattributed) {
          // Stage 3 seam: the unknownDevice row (both lists readable and the
          // peer fetch counting), the re-attribution at acceptedSeenAt +
          // kConversationCopyStale, listUnverifiable on an unreadable list
          // and the M4 deferral bound.
          stillUnattributed = true;
          continue;
        }
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
      if (pins.isEmpty) return (wrote: false, pending: stillUnattributed);
      try {
        await v.transaction((tx) async {
          for (final p in pins) {
            await tx.putMember(p);
          }
          for (final r in rows) {
            await tx.putMessage(r);
          }
          // C1 / N3: the ref whose list the theirs-side pins came from.
          if (theirsFromPeer && ref != null) {
            await _known.addIn(tx, id, peerUserId: ref);
          }
        });
      } on Object {
        _known.discardStaged();
        rethrow;
      }
      _known.commitStaged();
      return (wrote: true, pending: stillUnattributed);
    });
    context.attributionPending = outcome.pending;
    if (outcome.wrote) _onChanged(id);
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

enum _Outcome { joined, permanent, transient, stop }

enum _Settled { ownStored, discarded, unknown }

class _Join {
  const _Join(this.kind, {this.baselineSince});

  final _Outcome kind;

  /// A first join: the `since` of the members it pinned (the baseline).
  final MlsPair? baselineSince;
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
  });

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
