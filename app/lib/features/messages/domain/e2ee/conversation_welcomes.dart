part of 'conversation_crypto.dart';

/// The welcome poll (R5, R8): `ListWelcomes` pages, each welcome handled
/// under its conversation's lock (taken here, or already held by catch-up's
/// generation switch), what follows a join or a permanent answer, and the
/// acknowledgements with their clock-skew counters. Joining from one
/// welcome is [_WelcomeJoin]'s.
extension _WelcomePoll on ConversationCrypto {
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
}

/// L6: a stored non-provisional group of a generation up to [generation]
/// whose (generation, epoch) is not recorded as walked to its end.
Future<bool> _unwalked(SecureVault vault, String id, int generation) async {
  final groups = await vault.groups(id);
  if (groups.isEmpty) return false;
  final done =
      (await vault.conversation(id))?.sync.completedEpochs ?? const <MlsPair>[];
  return groups.any(
    (g) =>
        !g.provisional &&
        g.generation <= generation &&
        !done.contains(MlsPair(g.generation, g.epoch)),
  );
}

Future<Map<String, int>> _readSkew(SecureVault v) async {
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

Uint8List _encodeSkew(Map<String, int> counts) =>
    Uint8List.fromList(utf8.encode(jsonEncode({'v': 1, 'n': counts})));

String _hexOf(Uint8List b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

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
