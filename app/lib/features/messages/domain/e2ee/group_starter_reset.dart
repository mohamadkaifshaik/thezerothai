part of 'group_starter.dart';

/// The `limit_name` of the server's two caps a reset can meet: the reset
/// cap and the per-conversation commit cap (a reset is a commit call).
const String kLimitResetsDaily = 'messages_resets_daily';
const String kLimitCommitsPerConversationDaily =
    'messages_commits_per_conversation_daily';

/// The most `ListConversationCommits` pages read to find a reset's record
/// (50 commits a page; a generation never comes near it).
const int _kResetPagesMax = 200;

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
  /// there).
  Future<void> _resetConversation(String id, BudgetPriority priority) async {
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
    final created = await _locks.run(
      id,
      () => _createReset(
        op,
        id,
        g,
        own: own,
        theirs: theirs,
        claimedTheirs: claimed.keyPackages,
        inspectedTheirs: inspectedTheirs,
        claimedMine: mine,
        inspectedMine: inspectedMine,
      ),
    );
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
        // Review m-1: what this run remembered for an earlier reset of this
        // conversation (its wait after an unknown outcome, its margin, a
        // refusal, "the server holds it") is not this reset's: an earlier
        // one ended on the crypto side (a join) leaves it behind, and its
        // wait would hold this reset's first call although its count is
        // spent. The new reset's own lists stay.
        _resetCalls.forget(id);
        _resetRefused.remove(id);
        _resetHeld.remove(id);
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
    // first call unless a resume met its bytes (the tracker knows them:
    // that resume sent them, or decided they wait). Why: else the second
    // kind returned here with the reset's count spent and no call made.
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
            if (pending == null || _resetCalls.knows(id, pending.commit)) {
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
        final usableTheirs = [
          for (final c in checkedTheirs.usable)
            if (!onBoth(c, checkedMine.usable)) c,
        ];
        final usableMine = [
          for (final c in checkedMine.usable)
            if (!onBoth(c, checkedTheirs.usable)) c,
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

  /// What the server holds at the reset's record pair (g + 1, 0), read from
  /// the stored after-pair on, and decided under the lock held:
  ///
  /// - this device's bytes: accepted, settled ([_resetSettleLocked]);
  /// - another record (another reset or commit won), or the server already
  ///   past g + 1 without it: the provisional group goes and this device
  ///   joins from the winner's welcome. Amendment 1: only while no call of
  ///   the reset's bytes that outlived the client's wait still runs (a
  ///   reset can then no longer reach the server; one that reached it names
  ///   generation g, which is no longer current, so it cannot be stored);
  /// - nothing at the pair while the server is still at g: NOT stored now.
  ///   The group is dropped only after a refusal ([refusal]) or at the
  ///   expiry ([expire]), and only when the margin had passed when the
  ///   listing STARTED and no such call runs (Task 8 B / Task 9 N); else
  ///   nothing is decided (one resume is scheduled for the margin's end);
  /// - an answer that does not say: nothing is decided.
  Future<_Next> _resetDecideLocked(
    _Op op,
    String id,
    GroupRecord group,
    PendingCommit pending,
    BudgetPriority priority, {
    AppException? refusal,
    bool expire = false,
  }) async {
    final provedAt = _now();
    final record = await _resetRecord(op.vault, id, pending, priority);
    return _resetDecideOnLocked(
      id,
      group,
      pending,
      priority,
      record,
      provedAt,
      refusal: refusal,
      expire: expire,
    );
  }

  /// [_resetDecideLocked]'s decision on a [record] whose listing started at
  /// [provedAt].
  Future<_Next> _resetDecideOnLocked(
    String id,
    GroupRecord group,
    PendingCommit pending,
    BudgetPriority priority,
    _Record record,
    DateTime provedAt, {
    AppException? refusal,
    bool expire = false,
  }) async {
    const none = _Next(_NextKind.none);
    switch (record) {
      case _Record.ours:
        // Audit M1: from now on no call of these bytes is made again.
        _resetHeld[id] = pending.commit;
        return _resetSettleLocked(id, group, priority);
      case _Record.other:
        if (_resetCalls.callStillOut(id, pending.commit)) return none;
        return _resetDropLocked(id, group, join: true);
      case _Record.notStored:
        if (refusal == null && !expire) return none;
        if (_resetCalls.callStillOut(id, pending.commit)) return none;
        final left = _resetCalls.marginLeft(id, pending.commit, provedAt);
        if (left != null) {
          // The resume at the margin's end lists again and decides.
          return _Next(_NextKind.none, resendAfter: left);
        }
        return _resetDropLocked(id, group, refusal: refusal);
      case _Record.unknown:
      case _Record.notAsked:
        return none;
    }
  }

  /// The listing behind [_resetDecideLocked]: pages from the stored
  /// after-pair (when it is below g + 1), each one sync-budget unit. A unit
  /// the budget refuses is `notAsked` (audit M1), never `unknown`.
  Future<_Record> _resetRecord(
    SecureVault vault,
    String id,
    PendingCommit pending,
    BudgetPriority priority,
  ) async {
    final at = pending.builtOn;
    final stored = (await vault.conversation(id))?.afterPair;
    MlsPair? after = stored != null && stored.generation < at.generation
        ? stored
        : null;
    try {
      for (var i = 0; i < _kResetPagesMax; i++) {
        if (!await _takeSyncUnit(priority)) return _Record.notAsked;
        final page = await _messaging.listConversationCommits(
          conversationId: id,
          after: after,
          pageSize: kCommitPageSize,
        );
        for (final c in page.commits) {
          final cg = pairComponentFromInt64(c.mlsGeneration);
          final ce = pairComponentFromInt64(c.mlsEpoch);
          if (cg == null || ce == null) return _Record.unknown;
          if (cg == at.generation) {
            if (ce != 0) return _Record.unknown;
            return _same(c.commit, pending.commit)
                ? _Record.ours
                : _Record.other;
          }
          if (cg > at.generation) return _Record.other;
          after = MlsPair(cg, ce);
        }
        if (!page.more || page.commits.isEmpty) {
          final sg = pairComponentFromInt64(page.mlsGeneration);
          if (sg == null) return _Record.unknown;
          if (sg < at.generation) return _Record.notStored;
          // The server is past g without a record this listing showed.
          return sg > at.generation ? _Record.other : _Record.unknown;
        }
      }
    } on NotFoundException {
      return _Record.unknown;
    } on Object catch (e, s) {
      _reportIfBug(e, s, 'reset.listConversationCommits');
      return _Record.unknown;
    }
    return _Record.unknown;
  }

  /// The server stored this device's reset: the one success function
  /// (`ConversationCrypto.settleOwnInitLocked`, which walks g to its end
  /// first), with the reset's own lists when this run made it.
  Future<_Next> _resetSettleLocked(
    String id,
    GroupRecord group,
    BudgetPriority priority,
  ) async {
    final pending = group.pending!;
    final lists = _resetLists[id];
    final mine = lists != null && _same(lists.commit, pending.commit);
    final settled = await _crypto.settleOwnInitLocked(
      id,
      group.generation,
      priority: priority,
      ownList: mine ? lists.own : null,
      peerList: mine ? lists.theirs : null,
    );
    switch (settled) {
      case InitSettle.settled:
      case InitSettle.notProvisional:
        _forgetReset(id);
        _onChanged(id);
        return const _Next(_NextKind.settledReset);
      case InitSettle.replay:
        // Amendment 6: the marks are already at or past this reset (this
        // device joined a later generation meanwhile): it can never be
        // settled, and its commit, stored or not, is in the past. It is
        // ended here, never left provisional for good.
        return _resetDropLocked(id, group);
      case InitSettle.waiting:
        return const _Next(_NextKind.none);
    }
  }

  /// The provisional group of the reset goes (the shared discard: no mark,
  /// no pin of g, the key history untouched). [join]: another reset or
  /// commit won, so this device then catches up and joins from its welcome.
  /// [refusal]: the server's answer, handed back to the user's reset.
  Future<_Next> _resetDropLocked(
    String id,
    GroupRecord group, {
    bool join = false,
    AppException? refusal,
  }) async {
    if (!await _crypto.discardProvisionalLocked(id, group.generation)) {
      return const _Next(_NextKind.none);
    }
    _forgetReset(id);
    _onChanged(id);
    return _Next(join ? _NextKind.join : _NextKind.none, refusal: refusal);
  }

  /// Audit M1: whether this run knows the server holds [commit] as [id]'s
  /// reset ([GroupStarter._resetHeld]).
  bool _serverHolds(String id, Uint8List commit) {
    final held = _resetHeld[id];
    return held != null && _same(held, commit);
  }

  /// Amendment 4: [resumeProvisional] for a provisional RESET, with the
  /// lock held. Its record at (g + 1, 0) decides first (a restart finds a
  /// stored reset and settles it; another winner is joined).
  /// [kProvisionalExpiry] old and not stored: the group goes, only on a
  /// listing that started after the margin with no call still out.
  ///
  /// Audit M1, first, at any age: when this run knows the server holds
  /// these bytes ([GroupStarter._resetHeld]: a call answered (g + 1,
  /// e >= 1), or a listing showed them), nothing is listed or sent; only
  /// the settle is retried.
  ///
  /// Young (review I1: the server draws both of its caps BEFORE it
  /// recognises a retry, `service_mls.go` `commitCaps`, so every needless
  /// resend spends one of this conversation's 20 calls and one of the
  /// user's 10 resets a day, shared by every conversation):
  /// - held back after an unknown outcome ([CommitCallTracker.heldBack]):
  ///   nothing, not even the listing (one sync unit spared per trigger);
  /// - the record is OURS: never a call. The server holds the reset; the
  ///   settle (which may wait, for example while g's walk is interrupted)
  ///   is retried at the next trigger;
  /// - another record, or the server past g + 1: decided as before;
  /// - NOT stored: the identical bytes are sent once more (spaced, counted,
  ///   never inside the margin before the expiry, never again after a
  ///   refusal of them);
  /// - the server failed the listing (or answered what the client cannot
  ///   read): sent once more only when no call of these bytes was made (nor
  ///   the record first seen) in this run within [kRequestInFlightMargin]
  ///   ([CommitCallTracker.marginLeft] at now), so at most one resend per
  ///   margin however many triggers come;
  /// - the local sync budget refused the listing (audit M1, `notAsked`):
  ///   nothing was asked, so nothing is decided and nothing is sent.
  Future<_Next> _resetResumeLocked(
    _Op op,
    String id,
    GroupRecord group,
    PendingCommit pending,
    BudgetPriority priority,
  ) async {
    const none = _Next(_NextKind.none);
    // The first sight of a record an earlier run left starts its margin.
    _resetCalls.noteSeen(id, pending.commit);
    // Audit M1: the server holds these bytes. No listing and no call: the
    // settle is retried (at any age; a stored reset is never expired).
    if (_serverHolds(id, pending.commit)) {
      return _resetSettleLocked(id, group, priority);
    }
    if (_resetCalls.callStillOut(id, pending.commit)) return none;
    final refused = _resetRefused[id];
    final wasRefused = refused != null && _same(refused, pending.commit);
    final expired = _ageOf(group) >= kProvisionalExpiry;
    if (expired || wasRefused) {
      return _resetDecideLocked(op, id, group, pending, priority, expire: true);
    }
    if (_resetCalls.heldBack(id)) return none;
    final provedAt = _now();
    final record = await _resetRecord(op.vault, id, pending, priority);
    final decided = await _resetDecideOnLocked(
      id,
      group,
      pending,
      priority,
      record,
      provedAt,
    );
    switch (record) {
      case _Record.ours:
      case _Record.other:
      // Audit M1: nothing was asked (the local budget refused): no
      // decision and no call.
      case _Record.notAsked:
        return decided;
      case _Record.notStored:
        break;
      // A listing the server failed: resent at most once per margin.
      case _Record.unknown:
        if (_resetCalls.marginLeft(id, pending.commit, _now()) != null) {
          return decided;
        }
    }
    if (decided.kind != _NextKind.none || decided.resendAfter != null) {
      return decided;
    }
    if (await _provisionalReset(op.vault, id) == null) return decided;
    return _resetSendLocked(op, id, priority, first: false);
  }

  /// The body of [GroupStarter.repairIfStuck] (its contract is written
  /// there). Never throws.
  Future<void> _repairIfStuck(String id) async {
    if (!_repairing.add(id)) return;
    try {
      // A flag-off device never resets: the conversation stays stuck, and
      // `describeState` says so (`canReset` false).
      if (!_session.mayStart) return;
      final state = await _crypto.describeState(id);
      if (state.phase != ConversationPhase.stuck || !state.canReset) return;
      // Security read M9: at most kAutoResetsPerDay automatic resets per
      // conversation per IST day, read and counted BEFORE the first claim
      // (so a crash or a failed reset never undercounts, and the bound
      // never rests on the server). At the limit the conversation stays
      // stuck with the manual offer.
      if (await _ledger.autoResets(id) >= kAutoResetsPerDay) return;
      await _ledger.addAutoReset(id);
      // Decision: at `live` priority. Why: the repair is no user intent
      // (amendment 2) but follows the conversation's own catch-up, and a
      // deferred list would spend the day's automatic reset for nothing.
      await _resetConversation(id, BudgetPriority.live);
    } on E2eeActionException {
      // Counted: the conversation stays stuck with the manual offer.
    } on AppException {
      // The same: a refusal or a cap of the server.
    } on Object catch (e, s) {
      _reportIfBug(e, s, 'reset.repair');
    } finally {
      _repairing.remove(id);
    }
  }
}
