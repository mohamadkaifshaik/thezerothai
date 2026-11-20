part of 'conversation_crypto.dart';

/// Joining one conversation from one welcome (the conversation lock is
/// held): the label and replay checks, the server-pair check, settling a
/// provisional group of the welcome's generation, then the engine's join,
/// the welcome check and the join's ONE transaction (device state, group,
/// pins of the joined members, marks, baseline, known set, key history) in
/// ONE `runWrite` body; and the clock-skew rule for a `bad_input` answer.
extension _WelcomeJoin on ConversationCrypto {
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
}

/// `replay`: this device's own init was stored and the marks are already at
/// or above it.
enum _Settled { ownStored, discarded, unknown, replay }

class _Join {
  const _Join(this.kind, {this.label});

  final _Outcome kind;

  /// The welcome's label, with [_Outcome.walkFirst].
  final MlsPair? label;
}
