part of 'e2ee_pipeline.dart';

/// A remembered delete (fix wave ruling 6): its time, and the newest stored
/// message's time when the user deleted (null: read at the delete).
typedef _NotedDelete = ({int at, int? upTo});

/// The pipeline's remembered hints (gate item 42; reviews I2, I3, I5,
/// r1-I1, r1-I2): the account tag, the remembered deletes and the owed
/// init discards, and the replay at start. Moved out of `e2ee_pipeline.dart`
/// unchanged (re-review r2-n2); the state stays in [E2eePipeline] (an
/// extension holds no fields).
extension _PipelineNotes on E2eePipeline {
  /// Whether a note may be remembered now: there is an authenticated
  /// account, and another account's notes are dropped first.
  ///
  /// Fix wave ruling 4 (security audit L2): a note made for an open vault
  /// ([account], its `uid`) is remembered only while that is still the
  /// authenticated account. Why: in a direct A→B switch the auth state is
  /// B while A's parts are live; A's failed delete would otherwise be
  /// claimed by B and applied to B's vault.
  bool _claimNotes([String? account]) {
    final uid = _currentUid();
    if (uid == null || uid.isEmpty) return false;
    if (account != null && account != uid) return false;
    if (_notesUser != uid) {
      _dropAllNotes();
      _notesUser = uid;
    }
    return true;
  }

  /// Before any apply to [vault]: notes of an account other than the
  /// vault's are dropped, never applied (review I5, r1-I2).
  void _dropOtherAccountsNotes(SecureVault vault) {
    if (_notesUser != null && _notesUser != vault.uid) _dropAllNotes();
  }

  void _dropAllNotes() {
    _notedEncrypted.clear();
    _notedAccepted.clear();
    _notedDeleted.clear();
    _notedPushes.clear();
    _owedDiscards.clear();
    _notesUser = null;
  }

  /// [conversationId]'s pending init is discarded now when the pipeline is
  /// started and not stopped; otherwise (or when the discard could not
  /// decide) it is owed. Never throws.
  Future<void> _discardOrOwe(_Parts parts, String conversationId) async {
    if (!started || _deviceKeys.stopsPipeline) {
      _remember(_owedDiscards, conversationId, account: parts.vault.uid);
      return;
    }
    await _discardOne(parts, conversationId);
  }

  /// One discard; owed again unless decided. The caller checked that the
  /// device may make MLS calls. Never throws.
  Future<void> _discardOne(_Parts parts, String conversationId) async {
    var decided = false;
    try {
      decided = await parts.discardPendingInit(conversationId);
    } on Object catch (e, s) {
      if (e is! StateError) _report('pipeline.discardInit', s);
    }
    if (!decided) {
      _remember(_owedDiscards, conversationId, account: parts.vault.uid);
    }
  }

  /// Inside the start window (device usable, not stopped), BEFORE the
  /// coordinator's sequence: its `resumeProvisional` would otherwise resend
  /// the init of a conversation the user deleted. Also at resume (r2-m1).
  ///
  /// Re-review r2-n1, why these run at USER budget priority (inside
  /// `GroupStarter.discardInit`, which takes no priority) although they are
  /// automatic work (gate item 49 says background): each comes from the
  /// user's own delete, runs at most once per owed conversation, and must
  /// win the race against the coordinator's `resumeProvisional`, which would
  /// otherwise resend a first message the user deleted. A priority parameter
  /// on `discardInit` is a starter API change, left for later.
  /// Returns the ids it tried.
  Future<Set<String>> _applyOwedDiscards(_Parts parts) async {
    _dropOtherAccountsNotes(parts.vault);
    final owed = {..._owedDiscards};
    _owedDiscards.clear();
    for (final id in owed) {
      if (!parts.live || _deviceKeys.stopsPipeline) {
        _remember(_owedDiscards, id, account: parts.vault.uid);
        continue;
      }
      await _discardOne(parts, id);
    }
    return owed;
  }

  /// The start window's last look before the coordinator's sequence (re-
  /// review r2-m1; fix wave ruling 5, code review M2): waits for the deletes
  /// in flight and runs the owed discards, again while a pass leaves a
  /// delete in flight or a NEW owed id (one it did not try), at most
  /// [kOwedDiscardPasses] times. An id that could not decide is owed again
  /// but is not new, so it never loops. Never throws.
  Future<void> _settleOwedDiscards(_Parts parts) async {
    for (var pass = 0; pass < kOwedDiscardPasses; pass++) {
      while (_deletesInFlight.isNotEmpty) {
        await Future.wait([..._deletesInFlight]);
      }
      final tried = await _applyOwedDiscards(parts);
      if (_deletesInFlight.isEmpty && _owedDiscards.every(tried.contains)) {
        return;
      }
    }
  }

  /// Two deletes of one conversation merge: the later time, and the wider
  /// bound (an unknown bound, read at the delete, wins).
  void _rememberDelete(String id, int at, {int? upTo, String? account}) {
    if (!_claimNotes(account)) return;
    final before = _notedDeleted.remove(id);
    final b = before?.upTo;
    _notedDeleted[id] = (
      at: before != null && before.at > at ? before.at : at,
      upTo: before == null
          ? upTo
          : (b == null || upTo == null)
          ? null
          : (b > upTo ? b : upTo),
    );
    while (_notedDeleted.length > kPipelineNotesMax) {
      _notedDeleted.remove(_notedDeleted.keys.first);
    }
  }

  /// One delete, of the messages stored up to [upTo] (null: up to the
  /// newest stored when it runs); on any failure it is remembered again
  /// with the same bound (a [StateError] is quiet, anything else reported).
  /// Never throws.
  Future<bool> _deleteNow(_Parts parts, String id, int at, {int? upTo}) async {
    try {
      await parts.deleteLocal(id, at, upTo: upTo);
      return true;
    } on Object catch (e, s) {
      if (e is! StateError) _report('pipeline.delete', s);
      _rememberDelete(id, at, upTo: upTo, account: parts.vault.uid);
      return false;
    }
  }

  /// Makes every remembered delete (one pass at a time). Never throws.
  Future<void> _applyDeletes(_Parts parts) {
    final running = _deleting;
    if (running != null) return running;
    final pass = _applyDeletesOnce(parts);
    _deleting = pass;
    return pass.whenComplete(() {
      if (identical(_deleting, pass)) _deleting = null;
    });
  }

  Future<void> _applyDeletesOnce(_Parts parts) async {
    _dropOtherAccountsNotes(parts.vault);
    for (final e in [..._notedDeleted.entries]) {
      if (!parts.live) return;
      _notedDeleted.remove(e.key);
      await _deleteNow(parts, e.key, e.value.at, upTo: e.value.upTo);
    }
  }

  void _remember(LinkedHashSet<String> set, String id, {String? account}) {
    if (!_claimNotes(account)) return;
    set
      ..remove(id)
      ..add(id);
    while (set.length > kPipelineNotesMax) {
      set.remove(set.first);
    }
  }

  /// At start, before the coordinator's sequence: the remembered ids join
  /// the known set (gate item 24). The remembered deletes were made at
  /// vault ready ([_applyDeletes]).
  Future<void> _applyNotes(_Parts parts) async {
    _dropOtherAccountsNotes(parts.vault);
    final encrypted = [..._notedEncrypted];
    for (final id in encrypted) {
      await _addKnown(parts, id);
    }
  }

  /// Once the coordinator runs: the remembered encrypted hints (those that
  /// arrived in the start window join the known set first), accepts,
  /// pushes, and a list change of the window.
  void _afterStartNotes(_Parts parts) {
    if (!started || !identical(_parts, parts)) return;
    _dropOtherAccountsNotes(parts.vault);
    final encrypted = [..._notedEncrypted];
    final accepted = [..._notedAccepted];
    final pushes = [..._notedPushes];
    _notedEncrypted.clear();
    _notedAccepted.clear();
    _notedPushes.clear();
    for (final id in encrypted) {
      _inRoot(() async {
        await _addKnown(parts, id);
        parts.sync.onEncrypted(id);
      });
    }
    for (final id in accepted) {
      _inRoot(() => parts.accepted(id));
    }
    for (final id in pushes) {
      _inRoot(() => _pushed(parts, id));
    }
    if (_inboxOwed) {
      _inboxOwed = false;
      _inRoot(parts.rereadInbox);
    }
  }

  Future<void> _addKnown(_Parts parts, String id) async {
    if (!parts.known.isLoadedFor(parts.vault) || parts.known.contains(id)) {
      return;
    }
    try {
      await parts.known.add(id);
    } on Object catch (e, s) {
      if (e is! StateError) _report('pipeline.known.add', s);
    }
  }
}
