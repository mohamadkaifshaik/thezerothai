part of 'group_starter.dart';

/// The start itself (R6 steps 1 to 3): the fresh lists and the claims under
/// no lock, the checks of the claim's conversation id, then, under that
/// conversation's lock, the provisional group in ONE `runWrite` body and
/// ONE transaction.
extension _Start on GroupStarter {
  /// Steps 1 to 3 for [draft] to [peer]. `started`: the provisional group
  /// and the stage-encrypted row are stored (the caller sends the init).
  /// [priority]: the budget priority of the one commit listing a
  /// [_Mode.replace] makes before it replaces (audit M3).
  Future<StartOutcome> _begin(
    String peer,
    _Draft draft, {
    _Mode mode = _Mode.fresh,
    BudgetPriority priority = BudgetPriority.user,
  }) async {
    final op = await _op();
    if (op == null) return _out(StartResult.unavailable);
    // The key the init's ciphertext goes out under: made here, never one a
    // row carried.
    final key = _hexOf(await _random(16));
    if (draft.replaces == null &&
        (await op.vault.outbox()).items.any(
          (r) => r.localId == draft.localId,
        )) {
      throw ArgumentError('An unsent row already has this local id.');
    }

    // Task 8 audit L1. Decision: what the creating body would refuse
    // without the server's help is read here, before any lookup or claim,
    // and refused as it would be there (`unavailable`). Why: a claim spends
    // the peer's one-time packages and one of the 20 claims per target a
    // day; one made for a start the local state refuses anyway is wasted,
    // and a rebuild would repeat it at every resume. The body reads it all
    // again under the lock (the state can change in between).
    if (!await _locallyStartable(op, draft, mode)) {
      return _out(StartResult.unavailable);
    }
    // Audit L1: one 24 h rebuild per conversation per [kRebuildSpacing],
    // taken (and stored) before its first lookup.
    if (mode == _Mode.replace) {
      final id = draft.expectId;
      if (id == null) return _out(StartResult.unavailable);
      bool taken;
      try {
        taken = await _ledger.takeRebuild(id, spacing: kRebuildSpacing);
      } on Object catch (e, s) {
        _reportIfBug(e, s, 'start.rebuildSlot');
        taken = false;
      }
      if (!taken) return _out(StartResult.unavailable);
    }

    // 1. Both lists fresh. A deferred answer stands for the last readable
    // list only when that list is younger than `kDeviceListReuse` (H1,
    // review 3b); with none, or an older one, it is `lookupFailed`.
    final ownAnswer = await _directory.own(
      fresh: true,
      priority: BudgetPriority.user,
    );
    final peerAnswer = await _directory.peer(
      peer,
      fresh: true,
      priority: BudgetPriority.user,
    );
    final own = _lastReadable(ownAnswer);
    final theirs = _lastReadable(peerAnswer);
    if (theirs == null) return _lookupFailed(peer);
    if (own == null) return _out(StartResult.lookupFailed);
    final active = [
      for (final d in theirs.devices)
        if (!d.inactive) d,
    ];
    if (active.isEmpty) {
      // Decision: the routing lookup listed a device and this one lists
      // none (or none active). Never plaintext on a changed answer: nothing
      // is sent, and the next attempt routes on the new list.
      return _out(
        peerAnswer.readable
            ? StartResult.peerHasNoDevice
            : StartResult.lookupFailed,
      );
    }
    // R3: a listed device whose claim came back empty today is not claimed
    // again this IST day.
    if (!await _anyUnclaimed(active)) {
      return _out(StartResult.peerHasNoDevice);
    }

    // Code review M5. Decision: with public ids KNOWN off the claim's id
    // must be checked against the two raw uids (2b below), and without the
    // own uid it cannot be: refused here, before the claim. Why: the
    // refusal was certain either way, and a claim made first spent the
    // peer's one-time packages and one of the 20 claims per target a day.
    final me = _ownUserId();
    final verified = _publicIdsOff();
    if (verified && (me == null || me.isEmpty)) {
      return _out(StartResult.unavailable);
    }

    final kpb.ClaimKeyPackagesResponse claimed;
    try {
      claimed = await _claim(peer, '');
    } on RateLimitedException catch (e) {
      final cap =
          e.limitName == kLimitClaimsPerTargetDaily ||
          e.limitName == kLimitClaimsDaily;
      return _out(
        cap ? StartResult.tryAgainTomorrow : StartResult.lookupFailed,
        null,
        e,
      );
    } on AppException catch (e) {
      // Nothing is saved or sent: the caller may try again.
      return _out(StartResult.lookupFailed, null, e);
    }

    // 2. The claim's id is not trusted blindly.
    final id = claimed.conversationId;
    if (!isConversationId(id)) return _out(StartResult.unavailable);
    final asked = draft.expectId ?? draft.conversationId;
    // Decision: a draft addressed by a conversation id whose claim names
    // another conversation is refused (the two cannot both be right).
    if (asked != null && asked != id) return _out(StartResult.unavailable);
    // (a) An id this vault knows as the conversation with someone else.
    final knownPeer = _known.peerOf(id);
    if (_known.contains(id) && knownPeer != null && knownPeer != peer) {
      return _out(StartResult.unavailable);
    }
    // (b) Raw uids on both sides: the id is computed as the server does
    // (the own uid is known here: checked before the claim).
    if (verified) {
      if (me == null || me.isEmpty || dmConversationId(me, peer) != id) {
        return _out(StartResult.unavailable);
      }
    }
    // (c) Task 8 audit M2: the cache's word against the server's.
    if (!await _cacheAgrees(id, peer)) return _out(StartResult.unavailable);
    // Review I2. Decision: the claim's id is the server's word. An id this
    // vault already knows (or holds a group for) is used only with proof
    // that it is THIS peer's conversation; without it the message could be
    // encrypted to another person's group, chosen by the server. Checked
    // again under the lock in [_create].
    if (!_proven(id, peer, draft, verified) &&
        (_known.contains(id) || (await op.vault.groups(id)).isNotEmpty)) {
      return _out(StartResult.unavailable);
    }

    // The own side: only when the own list shows other active devices.
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
        // Decision: the start goes on without the own devices (fewer
        // readers, never more); they are added by a later commit (Task 9).
      }
    }
    final inspectedTheirs = await _inspect(claimed.keyPackages);
    final inspectedMine = await _inspect(mine);

    final created = await _locks.run(
      id,
      () => _create(
        op,
        id,
        peer,
        draft,
        key,
        mode: mode,
        priority: priority,
        verified: verified,
        own: own,
        theirs: theirs,
        claimedTheirs: claimed.keyPackages,
        inspectedTheirs: inspectedTheirs,
        claimedMine: mine,
        inspectedMine: inspectedMine,
      ),
    );
    // The ledger opens its own write: after the body, never inside it.
    // Review M6. Decision: a listed, active peer device with NO entry in
    // the answer counts as an empty claim too (today's server answers an
    // entry without a package; one that left it out would otherwise be
    // claimed again on every attempt, up to the daily cap).
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
        _reportIfBug(e, s, 'start.emptyClaim');
      }
    }
    switch (created.kind) {
      case _CreatedKind.created:
        if (created.knownGrew) {
          // After the committing transaction, as every path that extends
          // the known set.
          try {
            await _messaging.noteEverEncrypted(id, session: created.session);
          } on Object catch (e, s) {
            _reportIfBug(e, s, 'start.noteEverEncrypted');
          }
        }
        return _out(StartResult.started, id);
      case _CreatedKind.existing:
        // Started meanwhile (the claimed packages are wasted, bounded by
        // the claim caps): a new draft's row goes to the sender. A draft
        // with no typed text here is a restart's stage-plain row, which
        // is the sender's already (the 24 h replace never answers
        // `existing`: its row stays the old init row).
        final text = draft.text;
        if (text == null) return _out(StartResult.joinedExisting, id);
        return _viaSender(
          id,
          localId: draft.localId,
          text: text,
          sharedPostId: draft.sharedPostId,
        );
      case _CreatedKind.noDevice:
        return _out(StartResult.peerHasNoDevice);
      case _CreatedKind.unavailable:
        return _out(StartResult.unavailable);
    }
  }

  /// Audit L1: the creating body's local refusals, read before any lookup
  /// or claim (from the vault, with no lock: [_create] reads them all
  /// again in its body). False when the device state is gone; for a start
  /// whose conversation is known before the claim (a restart, the 24 h
  /// replace) when its key history does not open; and for the replace,
  /// when the replace guard ([_replaceable]) or the old init row already
  /// refuses.
  Future<bool> _locallyStartable(_Op op, _Draft draft, _Mode mode) async {
    final vault = op.vault;
    if (await vault.deviceState() == null) return false;
    if (mode == _Mode.fresh) return true;
    final id = draft.expectId ?? draft.conversationId;
    if (id == null) return false;
    if (mode == _Mode.replace) {
      if (!_replaceable(await vault.groups(id), draft)) return false;
      OutboxItem? old;
      for (final r in (await vault.outbox()).items) {
        if (r.idempotencyKey == draft.replaces) old = r;
      }
      if (old == null ||
          old.stage != OutboxStage.encrypted ||
          old.init == null) {
        return false;
      }
    }
    final pins = await vault.members(id);
    final former = await GroupStarter._former.of(vault, id);
    final history = await _crypto.keyHistory.of(
      vault,
      id,
      currentPins: pins,
      formerPins: former,
    );
    return !history.unreadable;
  }

  /// Review I3 / N6, the replace guard: [groups] (all of the conversation's)
  /// are exactly the one provisional group of generation 1 whose pending
  /// init is still the commit [draft] replaces.
  bool _replaceable(List<GroupRecord> groups, _Draft draft) {
    final only = groups.length == 1 ? groups.single : null;
    final pending = only?.pending;
    final commit = draft.replacesCommit;
    return only != null &&
        only.provisional &&
        only.generation == 1 &&
        pending != null &&
        pending.kind == PendingKind.init &&
        commit != null &&
        _same(pending.commit, commit);
  }

  /// Task 8 audit M2. Whether the drift cache agrees that the conversation
  /// [id] a claim named is the one with [peer]: (i) the cached header of
  /// [id], when there is one, names [peer]; (ii) the cached conversation
  /// with [peer], when there is one, is [id]. Read before the lock, after
  /// the claim (the id is not known before it).
  ///
  /// Decision: either disagreement is `unavailable`; nothing is stored and
  /// the claimed packages are wasted. Why: with public ids on the client
  /// cannot compute the id, and a hostile server could answer another
  /// conversation's id (A's with Q for a start with P); the group would be
  /// made with P's devices, and every later send in thread X would then be
  /// encrypted to P. An honest server never disagrees with its own headers
  /// (the id is deterministic per pair). A header with no peer says
  /// nothing. A header of the other id kind (audit L8) disagrees too: fail
  /// closed, never plaintext.
  Future<bool> _cacheAgrees(String id, String peer) async {
    final named = (await _messaging.cachedConversation(id))?.peer.userId;
    if (named != null && named.isNotEmpty && named != peer) return false;
    final withPeer = await _messaging.cachedConversationWith(peer);
    return withPeer == null || withPeer.id.isEmpty || withPeer.id == id;
  }

  /// Proof that the conversation [id] a claim named is [peer]'s: the caller
  /// addressed the draft by that id, the id was computed from the two raw
  /// uids ([verified]), or the vault stores [peer] as that id's peer ref.
  /// Pre-flag-on audit M-A: none of it is proof when the vault stores
  /// ANOTHER peer ref for [id]; [_create] refuses that first, under the
  /// lock.
  bool _proven(String id, String peer, _Draft draft, bool verified) =>
      draft.conversationId == id ||
      draft.expectId == id ||
      verified ||
      _known.peerOf(id) == peer;

  /// A readable list as it is; a deferred one as the last readable list it
  /// carries, when that list was read within [kDeviceListReuse]; null when
  /// there is none (unreadable, never read, or too old).
  ///
  /// Review M4. Decision: R3 checks claimed packages against these lists
  /// (and the own list decides "this id is not ours"). A deferred answer
  /// of any age could add a device its owner removed days ago, so an old
  /// one is `lookupFailed`: nothing is sent, and the caller may try again.
  ///
  /// Review N8. Decision: a list dated AFTER now (the device clock moved
  /// back) has no age that can be told, so it is too old as well; a
  /// negative difference would otherwise pass as "young" for as long as
  /// the clock stays behind.
  DeviceList? _lastReadable(DeviceList list) {
    if (list.readable) return list;
    final at = list.fetchedAt;
    final now = _now();
    if (list.state == ListState.deferred &&
        at != null &&
        !at.isAfter(now) &&
        now.difference(at) < kDeviceListReuse) {
      return DeviceList(ListState.readable, list.devices, at);
    }
    return null;
  }

  /// Whether any of [devices] had no empty claim recorded today.
  Future<bool> _anyUnclaimed(List<DirectoryDevice> devices) async {
    for (final d in devices) {
      if (!await _ledger.emptyClaimTried(d.deviceId)) return true;
    }
    return false;
  }

  /// One `ClaimKeyPackages` call, under its own random key (a claim is not
  /// replayable: nothing is retried here).
  Future<kpb.ClaimKeyPackagesResponse> _claim(
    String userId,
    String excludeDeviceId,
  ) async {
    final key = _hexOf(await _random(16));
    return _keys
        .claim(
          userId: userId,
          excludeDeviceId: excludeDeviceId,
          idempotencyKey: key,
        )
        .timeout(
          kMlsRpcTimeout,
          onTimeout: () => throw const NetworkException('timed out'),
        );
  }

  /// The engine's reading of each claimed package (null: none, or one the
  /// engine refuses). An engine that cannot answer now throws.
  Future<List<KeyPackageInfo?>> _inspect(
    List<kpb.ClaimedKeyPackage> claimed,
  ) async {
    final out = <KeyPackageInfo?>[];
    for (final c in claimed) {
      if (!c.hasKeyPackage_4 || c.keyPackage.isEmpty) {
        out.add(null);
        continue;
      }
      try {
        out.add(
          await _engine().inspectKeyPackage(Uint8List.fromList(c.keyPackage)),
        );
      } on MlsException catch (e) {
        if (e.code != MlsErrorCode.badInput) rethrow;
        out.add(null);
      }
    }
    return out;
  }

  /// Step 3, with [id]'s lock held: ONE `runWrite` body (fresh reads, R3's
  /// checks against the key history, the engine calls) and ONE transaction.
  Future<_Created> _create(
    _Op op,
    String id,
    String peer,
    _Draft draft,
    String key, {
    required _Mode mode,
    required BudgetPriority priority,
    required bool verified,
    required DeviceList own,
    required DeviceList theirs,
    required List<kpb.ClaimedKeyPackage> claimedTheirs,
    required List<KeyPackageInfo?> inspectedTheirs,
    required List<kpb.ClaimedKeyPackage> claimedMine,
    required List<KeyPackageInfo?> inspectedMine,
  }) async {
    // Pre-flag-on audit M-A. Decision: under the lock, before anything is
    // answered, the stored peer ref of [id] and the cache are asked again.
    // A stored ref that is not [peer] (another person, or the other id
    // kind) is `unavailable`, and so is a cache that disagrees. Why: the
    // checks in [_begin] ran before the lock, around awaits (the own-device
    // claim, the inspection) in which another peer's routing can commit
    // [id] under its own peer ref; a hostile server answering two claims
    // with one id would then have this draft, even one addressed by [id]
    // (whose id is no proof once a stored ref names someone else), saved
    // into the other person's group and encrypted to their devices. The
    // known set only grows under this lock, so this read stands for the
    // body below. Cost: an id-kind drift of the stored ref refuses here
    // (fail closed, never plaintext; the routing's own check routes it).
    final storedPeer = _known.peerOf(id);
    if (storedPeer != null && storedPeer != peer) {
      return const _Created(_CreatedKind.unavailable);
    }
    if (!await _cacheAgrees(id, peer)) {
      return const _Created(_CreatedKind.unavailable);
    }
    // Review I2: an existing conversation takes the row only with proof
    // that it is this peer's (read again here, under the lock).
    final existing = _proven(id, peer, draft, verified)
        ? const _Created(_CreatedKind.existing)
        : const _Created(_CreatedKind.unavailable);
    final session = _messaging.cacheSession;
    try {
      if (mode == _Mode.replace) {
        // Audit M3. Decision: the stored commits are asked once more here,
        // with the lock held, right before the transaction that deletes
        // the old provisional group; it is replaced only on "not stored".
        // Why: the expiry's answer is from an earlier hold of the lock,
        // before the lookups and the claim. A request the server stored in
        // between would leave it holding a group this device deleted, and
        // the rebuilt init would be answered STALE_EPOCH with no welcome
        // to join from. An answer that does not say replaces nothing; the
        // claimed packages are wasted (bounded by the claim caps) and the
        // next resume settles or rebuilds.
        PendingCommit? pending;
        for (final g in await op.vault.groups(id)) {
          if (g.provisional) pending = g.pending;
        }
        if (pending == null ||
            await _ownInitStored(id, pending, priority) != false) {
          return const _Created(_CreatedKind.unavailable);
        }
      }
      return await _session.runWrite((v) async {
        op.check(v);
        final groups = await v.groups(id);
        var replacing = false;
        switch (mode) {
          case _Mode.fresh:
            // A conversation this vault knows of, or holds a group for,
            // takes the row (C1): no second group is started for it.
            if (groups.isNotEmpty || _known.contains(id)) return existing;
          case _Mode.restart:
            // Review F1 (c): read again in this body, from the vault. A
            // group that appeared meanwhile, or any sign that this device
            // was a member, leaves the row waiting with the sender.
            if (groups.isNotEmpty) return existing;
            if (!await _neverMember(v, id, peer)) {
              return const _Created(_CreatedKind.unavailable);
            }
          case _Mode.replace:
            // Review I3: the claim is made first; the old provisional
            // group goes only here, in the transaction that stores the new
            // one, and only while it is still the same init. A failed
            // claim never reaches this point and leaves it untouched.
            if (!_replaceable(groups, draft)) {
              return const _Created(_CreatedKind.unavailable);
            }
            replacing = true;
        }
        final deviceState = await v.deviceState();
        if (deviceState == null) {
          return const _Created(_CreatedKind.unavailable);
        }
        final outbox = (await v.outbox()).items;
        OutboxItem? old;
        final replaces = draft.replaces;
        if (replaces == null) {
          if (outbox.any((r) => r.localId == draft.localId)) {
            throw ArgumentError('An unsent row already has this local id.');
          }
        } else {
          for (final r in outbox) {
            if (r.idempotencyKey == replaces) old = r;
          }
          // Gone, or no longer the row this start is for: nothing to do.
          // A restart replaces a waiting row; a replace, the old init row.
          if (old == null ||
              (replacing
                  ? old.stage != OutboxStage.encrypted || old.init == null
                  : old.stage != OutboxStage.plain || old.init != null)) {
            return const _Created(_CreatedKind.unavailable);
          }
        }
        // Read fresh in this body: the pins, the former pins, the history.
        final pins = await v.members(id);
        final former = await GroupStarter._former.of(v, id);
        final history = await _crypto.keyHistory.of(
          v,
          id,
          currentPins: pins,
          formerPins: former,
        );
        // An unreadable history refuses everyone: nothing is started.
        if (history.unreadable) {
          return const _Created(_CreatedKind.unavailable);
        }
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
        // A key or a device id claimed on both sides is on neither.
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
        // At most 9 other devices: the own ones are dropped first.
        const room = kMaxGroupMembers - 1;
        final added = <UsableClaim>[...usableTheirs.take(room)];
        added.addAll(usableMine.take(room - added.length));

        // The engine: create, add, confirm (epoch 1), encrypt.
        final CommitResult commit;
        final GroupDescription description;
        final EncryptResult encrypted;
        try {
          final engine = _engine();
          final empty = await engine.createGroup(
            deviceState,
            mlsGroupId(id, 1),
          );
          commit = await engine.commitChange(
            deviceState,
            empty,
            addKeyPackages: [for (final c in added) c.keyPackage],
          );
          final confirmed = await engine.confirmCommit(
            deviceState,
            commit.groupState,
          );
          description = await engine.describe(confirmed);
          encrypted = await engine.encrypt(
            deviceState,
            confirmed,
            draft.content,
          );
        } on MlsException {
          // Nothing of it is stored (the claimed packages are wasted).
          return _Created(_CreatedKind.unavailable, emptyFor: emptyFor);
        }
        final welcome = commit.welcome;
        final thisHex = vaultDeviceIdHex(op.deviceId);
        final inGroup = {
          for (final m in description.members)
            vaultDeviceIdHex(m.deviceId): m.signaturePublicKey,
        };
        final thisKey = inGroup[thisHex];
        // Not the group that was asked for: nothing of it is stored.
        if (welcome == null ||
            welcome.isEmpty ||
            commit.commit.isEmpty ||
            commit.epoch != 0 ||
            description.epoch != 1 ||
            description.hasPendingCommit ||
            !_same(description.groupId, mlsGroupId(id, 1)) ||
            thisKey == null ||
            description.members.length != added.length + 1 ||
            inGroup.length != added.length + 1 ||
            added.any((c) {
              final k = inGroup[vaultDeviceIdHex(c.deviceId)];
              return k == null || !_same(k, c.signatureKey);
            }) ||
            encrypted.epoch != 1 ||
            encrypted.ciphertext.isEmpty ||
            encrypted.ciphertext.length > kMaxOutboxCiphertext) {
          _reportOnce('start.group');
          return _Created(_CreatedKind.unavailable, emptyFor: emptyFor);
        }

        const first = MlsPair(1, 1);
        final welcomeDeviceIds = [
          for (final c in added) utf8.decode(c.deviceId),
        ];
        final init = pb.MlsInit(
          commit: commit.commit,
          welcome: welcome,
          welcomeDeviceIds: welcomeDeviceIds,
        ).writeToBuffer();
        final nowMicros = _now().microsecondsSinceEpoch;
        // Strictly after every waiting row of the conversation.
        var at = draft.createdAtMicros ?? nowMicros;
        if (draft.createdAtMicros == null) {
          for (final r in outbox) {
            if (r.conversationId == id && r.createdAtMicros >= at) {
              at = r.createdAtMicros + 1;
            }
          }
        }
        final recipient = draft.recipient;
        final item = OutboxItem(
          idempotencyKey: key,
          localId: draft.localId,
          expectedMessageId: expectedMessageId(v.uid, key),
          // The recipient reference exactly as sent, else the conversation.
          conversationId: recipient == null ? id : null,
          recipientUserId: recipient,
          generation: first.generation,
          epoch: first.epoch,
          ciphertext: encrypted.ciphertext,
          reportCommitment: reportCommitment(draft.content),
          content: draft.content,
          createdAtMicros: at,
          init: init,
          // The sends made under THIS key: none yet (a rebuilt row starts
          // again at 0, so its first send is a first attempt).
        );
        var grew = false;
        try {
          await v.transaction((tx) async {
            if (replacing) {
              // The old provisional group's pins go with it (putGroup below
              // replaces its state); the key history never shrinks.
              for (final m in pins) {
                await tx.deleteMember(id, m.deviceId);
              }
            }
            await tx.putGroup(
              GroupRecord(
                conversationId: id,
                generation: 1,
                epoch: 1,
                state: encrypted.groupState,
                provisional: true,
                provisionalCreatedAtMicros: nowMicros,
                pending: PendingCommit(
                  kind: PendingKind.init,
                  builtOn: const MlsPair(1, 0),
                  commit: commit.commit,
                  welcome: welcome,
                  welcomeDeviceIds: welcomeDeviceIds,
                ),
              ),
            );
            await tx.putMember(
              MemberRecord(
                conversationId: id,
                deviceId: op.deviceId,
                signatureKey: thisKey,
                side: MemberSide.mine,
                since: first,
              ),
            );
            for (final c in added) {
              // Admitted in this transaction; a pair the history refuses
              // now (it was admissible a moment ago) ends the start.
              if (history.admit(vaultDeviceIdHex(c.deviceId), c.signatureKey) !=
                  KeyRefusal.none) {
                throw const _Stopped();
              }
              await tx.putMember(
                MemberRecord(
                  conversationId: id,
                  deviceId: c.deviceId,
                  signatureKey: c.signatureKey,
                  side: c.side == ClaimSide.mine
                      ? MemberSide.mine
                      : MemberSide.theirs,
                  since: first,
                ),
              );
            }
            // C1: a provisional group is an encryption fact; the peer ref
            // is the claim target the theirs-side pins were checked against
            // (first write wins).
            grew = await _known.addIn(tx, v, id, peerUserId: peer);
            if (old != null) await tx.deleteOutbox(old.idempotencyKey);
            await tx.putOutbox(item);
            await tx.addSent(id, first, sentDigest(encrypted.ciphertext));
            // The one history write, in the transaction that creates the
            // provisional group row (written even when empty). No mark.
            await _crypto.keyHistory.writeIn(tx, id, history);
          });
        } on Object {
          _known.discardStaged();
          rethrow;
        }
        _known.commitStaged();
        return _Created(
          _CreatedKind.created,
          emptyFor: emptyFor,
          knownGrew: grew,
          session: session,
        );
      });
    } on _Stopped {
      return const _Created(_CreatedKind.unavailable);
    } on ArgumentError {
      rethrow;
    } on Object catch (e, s) {
      // A vault error or a closed vault: the transaction stored nothing.
      _reportIfBug(e, s, 'start.create');
      return const _Created(_CreatedKind.unavailable);
    }
  }
}

enum _CreatedKind { created, existing, noDevice, unavailable }

/// What step 3 did. A class, not a record: it carries device ids. No
/// `toString`.
class _Created {
  const _Created(
    this.kind, {
    this.emptyFor = const [],
    this.knownGrew = false,
    this.session = 0,
  });

  final _CreatedKind kind;

  /// Listed devices whose claim carried no package (for the daily ledger).
  final List<Uint8List> emptyFor;
  final bool knownGrew;

  /// The cache session captured before the write.
  final int session;
}
