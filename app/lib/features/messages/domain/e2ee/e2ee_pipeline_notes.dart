part of 'e2ee_pipeline.dart';

/// The pipeline's remembered hints (gate item 42; reviews I2, I3, I5,
/// r1-I1, r1-I2): the account tag, the remembered deletes and the owed
/// init discards, and the replay at start. Moved out of `e2ee_pipeline.dart`
/// unchanged (re-review r2-n2); the state stays in [E2eePipeline] (an
/// extension holds no fields).
extension _PipelineNotes on E2eePipeline {
  /// Whether a note may be remembered now: there is an authenticated
  /// account, and another account's notes are dropped first.
  bool _claimNotes() {
    final uid = _currentUid();
    if (uid == null || uid.isEmpty) return false;
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
      _remember(_owedDiscards, conversationId);
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
    if (!decided) _remember(_owedDiscards, conversationId);
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
  Future<void> _applyOwedDiscards(_Parts parts) async {
    _dropOtherAccountsNotes(parts.vault);
    final owed = [..._owedDiscards];
    _owedDiscards.clear();
    for (final id in owed) {
      if (!parts.live || _deviceKeys.stopsPipeline) {
        _remember(_owedDiscards, id);
        continue;
      }
      await _discardOne(parts, id);
    }
  }

  void _rememberDelete(String id, int at) {
    if (!_claimNotes()) return;
    final before = _notedDeleted.remove(id);
    _notedDeleted[id] = before != null && before > at ? before : at;
    while (_notedDeleted.length > kPipelineNotesMax) {
      _notedDeleted.remove(_notedDeleted.keys.first);
    }
  }

  /// One delete; on any failure it is remembered again (a [StateError] is
  /// quiet, anything else reported). Never throws.
  Future<bool> _deleteNow(_Parts parts, String id, int at) async {
    try {
      await parts.deleteLocal(id, at);
      return true;
    } on Object catch (e, s) {
      if (e is! StateError) _report('pipeline.delete', s);
      _rememberDelete(id, at);
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
      await _deleteNow(parts, e.key, e.value);
    }
  }

  void _remember(LinkedHashSet<String> set, String id) {
    if (!_claimNotes()) return;
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
    pushes.forEach(parts.sync.onPush);
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
