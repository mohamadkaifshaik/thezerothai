part of 'group_starter.dart';

/// The `limit_name` of the server's two caps a reset can meet: the reset
/// cap and the per-conversation commit cap (a reset is a commit call).
const String kLimitResetsDaily = 'messages_resets_daily';
const String kLimitCommitsPerConversationDaily =
    'messages_commits_per_conversation_daily';

/// The most `ListConversationCommits` pages read to find a reset's record:
/// the commits of generation g from the stored after-pair, then (g + 1, 0).
///
/// Audit L2: 20 pages of 50 is 1,000 commits. Why that is enough for one
/// generation: the server stores at most 20 commit calls a user a
/// conversation a day (`messages_commits_per_conversation_daily`), so the
/// two users of a 1:1 add at most 40 a day, and 1,000 cover 25 days of
/// both at their cap since this device's last applied commit. It is also
/// catch-up's one-pass bound (`_kCommitPagesMax`). A listing that ends at
/// the cap answers `unknown` (nothing decided). Each page is one sync unit,
/// so a server that pages forever costs at most 20 units a listing (was
/// 200).
const int _kResetPagesMax = 20;

/// The reset's own fresh lists, for the settle's `attributeAfterReset`,
/// kept with the bytes they were checked for. Memory only; no `toString`.
class _ResetLists {
  const _ResetLists(this.commit, this.own, this.theirs);

  final Uint8List commit;
  final DeviceList own;
  final DeviceList theirs;
}

/// What the server holds at a reset's record pair (g + 1, 0). `unknown`:
/// the server was asked and its answer does not say (a failed call, an
/// answer the client cannot read). `notAsked` (audit M1): the local sync
/// budget refused the listing, so nothing was asked; it decides nothing
/// and never leads to a call.
enum _Record { ours, other, notStored, unknown, notAsked }

/// Task 10 (R6 step 5, R7, R12, the recovery table): a reset of an
/// encrypted conversation into generation g + 1, its answers, its resume
/// and expiry, and the stuck member's automatic repair.
///
/// Amendment 1, recorded: the reset's `CommitConversation` calls follow the
/// commit runner's call rules through the SAME helpers
/// (`commit_call_tracker.dart`): the per-conversation call count stored
/// before each call ([countCommitCall]; the first call's count is in the
/// transaction that stores the provisional group), the in-flight margin
/// measured at the listing's start, the abandoned-call tracking, the
/// spaced resends after an unknown outcome and the [kCommitRetryWaitMax]
/// ceiling on a server retry time ([CommitCallTracker]). Not through
/// `CommitRunner` itself: its pending record lives on the conversation's
/// current, non-provisional group, its success is a confirm in that group,
/// and its own entries refuse a provisional group; the reset's record lives
/// on the provisional group of g + 1 and ends with the settle.
extension _Reset on GroupStarter {
  /// The body of [GroupStarter.resetConversation] (its contract is written
  /// there). [automatic]: [GroupStarter.repairIfStuck]'s reset (audit L4).
  Future<void> _resetConversation(
    String id,
    BudgetPriority priority, {
    bool automatic = false,
  }) async {
    if (!isConversationId(id)) throw ArgumentError('Invalid conversation id.');
    if (!_session.mayStart) {
      throw const FeatureDisabledException(
        'Encryption is not on for this device.',
        feature: 'e2ee_dm',
      );
    }
    final op = await _op();
    if (op == null || _removedElsewhere() || _engineDown()) {
      throw const E2eeActionException(E2eeRefusal.unavailable);
    }
    final vault = op.vault;
    // A reset (or a start) in progress: it is resumed, never doubled.
    if ((await vault.groups(id)).any((g) => g.provisional)) {
      await _resume(id, priority);
      return;
    }
    final sync =
        (await vault.conversation(id))?.sync ?? const ConversationSync();
    // R10: never in an unaccepted conversation, received or sent.
    if (!sync.requestAccepted) {
      throw const E2eeActionException(E2eeRefusal.notAccepted);
    }
    // Decision: a reset the state does not offer (`canReset`: stuck,
    // waiting past 24 h, the M5 pause) is `unavailable`. Why: the port has
    // no type for it, the UI offers the action only with `canReset`, and a
    // reset of a healthy conversation spends a reset and a claim for
    // nothing.
    if (!(await _crypto.describeState(id)).canReset) {
      throw const E2eeActionException(E2eeRefusal.unavailable);
    }
    // The client stops one call short of the server's per-conversation cap.
    if (commitCallsToday(sync, _now()) >= kCommitCallsPerConversationPerDay) {
      throw const RateLimitedException(
        'The daily commit limit of this conversation is reached.',
        limitName: kLimitCommitsPerConversationDaily,
      );
    }
    final peer = _known.peerOf(id) ?? _contexts.of(id).peerUserId;
    if (peer == null || peer.isEmpty) {
      throw const E2eeActionException(E2eeRefusal.unavailable);
    }

    // 1. The server's current generation g (authoritative).
    if (!await _takeSyncUnit(priority)) {
      throw const E2eeActionException(E2eeRefusal.unavailable);
    }
    final pb.ListConversationCommitsResponse page;
    try {
      page = await _messaging.listConversationCommits(
        conversationId: id,
        after: (await vault.conversation(id))?.afterPair,
        pageSize: kCommitPageSize,
      );
    } on AppException catch (e) {
      throw E2eeActionException(E2eeRefusal.unavailable, cause: e);
    }
    final g = pairComponentFromInt64(page.mlsGeneration);
    if (g == null || g < 1 || g + 1 >= kMaxPairComponent) {
      throw const E2eeActionException(E2eeRefusal.unavailable);
    }
    if ((await vault.groups(id)).any((x) => x.generation > g)) {
      throw const E2eeActionException(E2eeRefusal.unavailable);
    }

    // 2. Both lists fresh (H1, as the start reads them).
    final own = _lastReadable(
      await _directory.own(fresh: true, priority: priority),
    );
    final theirs = _lastReadable(
      await _directory.peer(peer, fresh: true, priority: priority),
    );
    if (own == null || theirs == null) {
      throw const E2eeActionException(E2eeRefusal.unavailable);
    }
    final active = [
      for (final d in theirs.devices)
        if (!d.inactive) d,
    ];
    // The contract: a reset addresses at least one of the peer's devices.
    if (active.isEmpty || !await _anyUnclaimed(active)) {
      throw const E2eeActionException(E2eeRefusal.peerHasNoDevice);
    }

    // 3. The claims: the peer's (its caps are the caller's error), then
    // this user's other devices (never failing the reset: fewer readers,
    // Task 9 adds the rest).
    final kpb.ClaimKeyPackagesResponse claimed = await _claim(peer, '');
    if (claimed.conversationId != id) {
      throw const E2eeActionException(E2eeRefusal.unavailable);
    }
    final me = _ownUserId();
    var mine = const <kpb.ClaimedKeyPackage>[];
    final others = [
      for (final d in own.devices)
        if (!d.inactive && !_same(d.deviceId, op.deviceId)) d,
    ];
    if (me != null &&
        me.isNotEmpty &&
        others.isNotEmpty &&
        await _anyUnclaimed(others)) {
      try {
        mine = (await _claim(me, utf8.decode(op.deviceId))).keyPackages;
      } on AppException {
        // Decision, as at the start: the reset goes on without them.
      }
    }
    final inspectedTheirs = await _inspect(claimed.keyPackages);
    final inspectedMine = await _inspect(mine);

    // 4. The provisional group of g + 1, under the lock.
    final created = await _locks.run(id, () async {
      final made = await _createReset(
        op,
        id,
        g,
        own: own,
        theirs: theirs,
        claimedTheirs: claimed.keyPackages,
        inspectedTheirs: inspectedTheirs,
        claimedMine: mine,
        inspectedMine: inspectedMine,
        automatic: automatic,
      );
      if (made.kind == _CreatedKind.created) {
        // Review m-1: what this run remembered for an earlier reset of
        // this conversation (its wait after an unknown outcome, its
        // margin, a refusal, "the server holds it") is not this reset's:
        // an earlier one ended on the crypto side (a join) leaves it
        // behind, and its wait would hold this reset's first call although
        // its count is spent. The new reset's own lists stay.
        //
        // Review N-2: forgotten here, before the lock is released. Why: a
        // resume queued on the lock may send this reset as soon as it is
        // released; forgotten later, its call memory (its wait, a call
        // still out, "the server holds it") would be wiped, and step 5
        // would send the bytes again as a first call.
        _resetCalls.forget(id);
        _resetRefused.remove(id);
        _resetHeld.remove(id);
      }
      return made;
    });
    final omitted = [
      for (final d in active)
        if (!claimed.keyPackages.any(
          (c) => _same(utf8.encode(c.deviceId), d.deviceId),
        ))
          d.deviceId,
    ];
    for (final deviceId in [...created.emptyFor, ...omitted]) {
      try {
        await _ledger.markEmptyClaim(deviceId);
      } on Object catch (e, s) {
        _reportIfBug(e, s, 'reset.emptyClaim');
      }
    }
    switch (created.kind) {
      case _CreatedKind.created:
        // Its memory was cleared under the lock (review m-1, N-2).
        break;
      case _CreatedKind.noDevice:
        throw const E2eeActionException(E2eeRefusal.peerHasNoDevice);
      case _CreatedKind.existing:
      case _CreatedKind.unavailable:
        throw const E2eeActionException(E2eeRefusal.unavailable);
    }
    _onChanged(id);

    // 5. The call, single flight with the resumes of this conversation.
    //
    // Review m-2. A resume of this conversation may be running: one that
    // took the new group first (it sends), or one still in the steps after
    // its lock (a join, a catch-up, a drain) that never looked at the new
    // group. Each is waited for; then, under the lock, the reset makes its
    // first call unless a resume already made a call of its bytes
    // ([CommitCallTracker.called]). Why: else the second kind returned here
    // with the reset's count spent and no call made. Review N-3: a resume
    // that only SAW the bytes (not asked, or a failed listing inside the
    // margin its sight opened) made no call, so the first call is still
    // made here. A reset kept across a removal of this device is never
    // sent: `_resetSendLocked` hands it to its record (review N-1).
    while (true) {
      final running = _running[id];
      if (running == null) break;
      await running;
    }
    _Next? first;
    late final Future<void> run;
    run =
        (() async {
          final next = await _locks.run(id, () async {
            final group = await _provisionalReset(op.vault, id);
            final pending = group?.pending;
            if (pending == null || _resetCalls.called(id, pending.commit)) {
              return const _Next(_NextKind.none);
            }
            return _resetSendLocked(op, id, priority, first: true);
          });
          first = next;
          await _afterNext(id, next, priority);
        })().whenComplete(() {
          if (identical(_running[id], run)) _running.remove(id);
        });
    _running[id] = run;
    await run;
    final refusal = first?.refusal;
    if (refusal != null) throw refusal;
  }

  /// Step 4, with [id]'s lock held: ONE `runWrite` body (fresh reads, R3's
  /// checks against the pins and the key history, the engine calls) and
  /// ONE transaction: the provisional group of g + 1 with its pending
  /// reset, and the commit-call count one higher (counted before the call).
  /// The pins and generation g's group are not touched.
  ///
  /// Audit L4 (controller ruling): an [automatic] reset adds no device this
  /// device removed from [id] today (the M5 ledger's own changes, read in
  /// this body through `isUndoOfOwnChange`, which counts every device while
  /// the ledger is exhausted). Why: an automatic reset runs on lists the
  /// server supplies, and must not undo this device's own removal of the
  /// day. A manual reset is the user's choice, and its `deviceAdded` rows
  /// show what it added.
  Future<_Created> _createReset(
    _Op op,
    String id,
    int g, {
    required DeviceList own,
    required DeviceList theirs,
    required List<kpb.ClaimedKeyPackage> claimedTheirs,
    required List<KeyPackageInfo?> inspectedTheirs,
    required List<kpb.ClaimedKeyPackage> claimedMine,
    required List<KeyPackageInfo?> inspectedMine,
    bool automatic = false,
  }) async {
    const unavailable = _Created(_CreatedKind.unavailable);
    final next = g + 1;
    try {
      final made = await _session.runWrite((v) async {
        op.check(v);
        final groups = await v.groups(id);
        if (groups.any((x) => x.provisional || x.generation > g)) {
          return unavailable;
        }
        final sync =
            (await v.conversation(id))?.sync ?? const ConversationSync();
        final calls = commitCallsToday(sync, _now());
        if (!sync.requestAccepted ||
            calls >= kCommitCallsPerConversationPerDay) {
          return unavailable;
        }
        final deviceState = await v.deviceState();
        if (deviceState == null) return unavailable;
        final pins = await v.members(id);
        final former = await GroupStarter._former.of(v, id);
        final history = await _crypto.keyHistory.of(
          v,
          id,
          currentPins: pins,
          formerPins: former,
        );
        if (history.unreadable) return unavailable;
        // The pins of g (and the former pins): a known id never changes key.
        final pinned = [...pins, ...former];
        final checkedTheirs = checkClaims(
          side: ClaimSide.theirs,
          claimed: claimedTheirs,
          inspected: inspectedTheirs,
          directory: theirs,
          ownList: own,
          members: pinned,
          thisDeviceId: op.deviceId,
          forNewGroup: true,
          admissible: history.admissible,
        );
        final checkedMine = checkClaims(
          side: ClaimSide.mine,
          claimed: claimedMine,
          inspected: inspectedMine,
          directory: own,
          ownList: own,
          members: pinned,
          thisDeviceId: op.deviceId,
          forNewGroup: true,
          admissible: history.admissible,
        );
        final emptyFor = [...checkedTheirs.emptyFor, ...checkedMine.emptyFor];
        // PR 1 carryover: keys (and ids) are deduplicated ACROSS both
        // sides: one claimed on both sides is on neither.
        bool onBoth(UsableClaim a, List<UsableClaim> other) => other.any(
          (b) =>
              _same(a.signatureKey, b.signatureKey) ||
              _same(a.deviceId, b.deviceId),
        );
        // Audit L4: removed by this device here today (automatic only).
        final daily = automatic ? await _ledger.readLocked(v) : null;
        bool removedToday(UsableClaim c) =>
            daily != null &&
            daily.isUndoOfOwnChange(id, c.deviceId, removing: false);
        final usableTheirs = [
          for (final c in checkedTheirs.usable)
            if (!onBoth(c, checkedMine.usable) && !removedToday(c)) c,
        ];
        final usableMine = [
          for (final c in checkedMine.usable)
            if (!onBoth(c, checkedTheirs.usable) && !removedToday(c)) c,
        ];
        if (usableTheirs.isEmpty) {
          return _Created(_CreatedKind.noDevice, emptyFor: emptyFor);
        }
        const room = kMaxGroupMembers - 1;
        final added = <UsableClaim>[...usableTheirs.take(room)];
        added.addAll(usableMine.take(room - added.length));

        final CommitResult commit;
        final Uint8List confirmed;
        final GroupDescription description;
        try {
          final engine = _engine();
          final empty = await engine.createGroup(
            deviceState,
            mlsGroupId(id, next),
          );
          commit = await engine.commitChange(
            deviceState,
            empty,
            addKeyPackages: [for (final c in added) c.keyPackage],
          );
          confirmed = await engine.confirmCommit(
            deviceState,
            commit.groupState,
          );
          description = await engine.describe(confirmed);
        } on MlsException {
          return _Created(_CreatedKind.unavailable, emptyFor: emptyFor);
        }
        final welcome = commit.welcome;
        final inGroup = {
          for (final m in description.members)
            vaultDeviceIdHex(m.deviceId): m.signaturePublicKey,
        };
        // Not the group that was asked for: nothing of it is stored.
        if (welcome == null ||
            welcome.isEmpty ||
            commit.commit.isEmpty ||
            commit.epoch != 0 ||
            description.epoch != 1 ||
            description.hasPendingCommit ||
            !_same(description.groupId, mlsGroupId(id, next)) ||
            inGroup[vaultDeviceIdHex(op.deviceId)] == null ||
            description.members.length != added.length + 1 ||
            inGroup.length != added.length + 1 ||
            added.any((c) {
              final k = inGroup[vaultDeviceIdHex(c.deviceId)];
              return k == null || !_same(k, c.signatureKey);
            })) {
          _reportOnce('reset.group');
          return _Created(_CreatedKind.unavailable, emptyFor: emptyFor);
        }
        final pending = PendingCommit(
          kind: PendingKind.reset,
          builtOn: MlsPair(next, 0),
          commit: commit.commit,
          welcome: welcome,
          welcomeDeviceIds: [for (final c in added) utf8.decode(c.deviceId)],
        );
        await v.transaction((tx) async {
          await tx.putGroup(
            GroupRecord(
              conversationId: id,
              generation: next,
              epoch: 1,
              state: confirmed,
              provisional: true,
              provisionalCreatedAtMicros: _now().microsecondsSinceEpoch,
              pending: pending,
            ),
          );
          // Counted before the call, so a crash never undercounts.
          await tx.putConversationSync(
            id,
            sync.copyWith(
              commitCallsDay: istDay(_now()),
              commitCallsToday: calls + 1,
            ),
          );
          // Every transaction writing a group writes the history at most
          // once (nothing is admitted yet: the settle admits g + 1).
          await _crypto.keyHistory.writeIn(tx, id, history);
        });
        _resetLists[id] = _ResetLists(commit.commit, own, theirs);
        return _Created(_CreatedKind.created, emptyFor: emptyFor);
      });
      return made;
    } on _Stopped {
      return unavailable;
    } on Object catch (e, s) {
      _reportIfBug(e, s, 'reset.create');
      return unavailable;
    }
  }

  /// The provisional reset of [id], or null.
  Future<GroupRecord?> _provisionalReset(SecureVault vault, String id) async {
    for (final g in await vault.groups(id)) {
      if (g.provisional && g.pending?.kind == PendingKind.reset) return g;
    }
    return null;
  }

  /// The reset's `CommitConversation` call(s), with [id]'s lock held: the
  /// identical bytes, a new key per call, each call counted before it.
  /// [first]: the call follows the build in this same run (its count was
  /// stored with the group, and no earlier call of these bytes exists);
  /// then one identical resend is made at once after an unknown outcome.
  Future<_Next> _resetSendLocked(
    _Op op,
    String id,
    BudgetPriority priority, {
    required bool first,
  }) async {
    const none = _Next(_NextKind.none);
    final group = await _provisionalReset(op.vault, id);
    final pending = group?.pending;
    if (group == null || pending == null) return none;
    // Audit M1: the server holds these bytes; another call would only draw
    // its caps again. The settle is all that is left.
    if (_serverHolds(id, pending.commit)) {
      return _resetSettleLocked(id, group, priority);
    }
    // Review N-1: kept across a removal of this device: never sent again,
    // whoever asks (a resume, review m-2's first call); the record decides.
    if (pending.keptAfterSelfRemoval) {
      return _resetKeptLocked(op, id, group, pending, priority);
    }
    // A device whose flag is off or that was removed elsewhere sends
    // nothing (it may not reset).
    if (!_session.mayStart || _removedElsewhere()) return none;
    if (_resetCalls.heldBack(id)) return none;
    final g = pending.builtOn.generation - 1;
    var isFirst = first;
    var tries = first ? 2 : 1;
    var counted = first;
    try {
      while (true) {
        if (!op.live) return none;
        // As the init (audit M3): inside the margin before expiry nothing
        // is sent, so the expiry decides with nothing in flight.
        if (_sendsNoMore(group)) return none;
        if (!counted) {
          final count = await countCommitCall(
            session: _session,
            op: op,
            conversationId: id,
            cap: kCommitCallsPerConversationPerDay,
            now: _now,
          );
          // At the cap the record waits: the expiry decides.
          if (count == CommitCallCount.atCap) return none;
        }
        counted = false;
        final key = _hexOf(await _random(16));
        _resetCalls.noteCall(id, pending.commit);
        final MlsPair answer;
        try {
          answer = await _messaging.commitConversation(
            idempotencyKey: key,
            conversationId: id,
            // The server ignores the epoch of a reset.
            builtOn: MlsPair(g, 0),
            commit: pending.commit,
            welcome: pending.welcome,
            welcomeDeviceIds: pending.welcomeDeviceIds,
            reset: true,
          );
        } on StaleEpochException {
          return await _resetDecideLocked(op, id, group, pending, priority);
        } on AppException catch (e) {
          if (sendOutcomeUnknown(e)) {
            if (!op.live) return none;
            // Audit M2: a call the client stopped waiting for may still
            // leave it; nothing is decided while it runs, and its end
            // schedules the resume that decides.
            _resetCalls.trackAbandoned(id, pending.commit, key, () {
              Zone.root.run(
                () => _schedule(
                  kRequestInFlightMargin,
                  () => unawaited(_resume(id, BudgetPriority.background)),
                ),
              );
            });
            isFirst = false;
            tries--;
            final named = retryAfterOf(e);
            final wait = _resetCalls.noteUnknown(id, named);
            if (named != null) {
              return _Next(
                _NextKind.none,
                resendAfter: tries > 0 ? wait : null,
              );
            }
            if (tries > 0) continue;
            // Still unknown after the one resend: the record decides.
            return await _resetDecideLocked(op, id, group, pending, priority);
          }
          if (e is CannotMessageException) _contexts.of(id).canReply = false;
          // A refusal of the FIRST call: nothing of it can be stored.
          if (isFirst && e is! IdempotencyKeyReusedException) {
            return await _resetDropLocked(id, group, refusal: e);
          }
          // An earlier call's outcome is unknown: the record decides, and a
          // "not stored" read discards only after the margin.
          _resetRefused[id] = pending.commit;
          return await _resetDecideLocked(
            op,
            id,
            group,
            pending,
            priority,
            refusal: e,
          );
        }
        // Audit M1: (g + 1, e >= 1) is the server's answer for a stored
        // reset of these bytes (a first store answers (g + 1, 1), a
        // recognised retry the current pair; another device's record is
        // STALE_EPOCH). The server holds them: remembered, then settled.
        if (answer.generation == g + 1 && answer.epoch >= 1) {
          _resetHeld[id] = pending.commit;
          return await _resetSettleLocked(id, group, priority);
        }
        // A later pair (or any other answer): as STALE_EPOCH.
        return await _resetDecideLocked(op, id, group, pending, priority);
      }
    } on _BadRandom {
      _reportOnce('start.random');
      return none;
    } on Object catch (e, s) {
      _reportIfBug(e, s, 'reset.send');
      return none;
    }
  }
}
