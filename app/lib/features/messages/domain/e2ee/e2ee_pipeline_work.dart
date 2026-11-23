part of 'e2ee_pipeline.dart';

/// [SyncWork] over one vault's [_Parts]: what each coordinator step calls.
/// Reads go to the parts' vault and the cache only; nothing here decides
/// when to run.
class _Work implements SyncWork {
  _Work(this._parts);

  final _Parts _parts;

  SecureVault get _vault => _parts.vault;

  @override
  bool get stopped => !_parts.live || _parts._p._deviceKeys.stopsPipeline;

  @override
  Future<void> resumeProvisional({required BudgetPriority priority}) =>
      _parts.starter.resumeProvisional(priority: priority);

  @override
  Future<List<String>> encryptedOutboxConversations() async {
    final read = await _vault.outbox();
    final ids = <String>{};
    for (final item in read.items) {
      final id = item.conversationId;
      // An init row is the starter's (`resumeProvisional` resends it).
      if (id == null || item.init != null) continue;
      if (item.stage == OutboxStage.encrypted) ids.add(id);
    }
    return ids.toList();
  }

  @override
  Future<void> drain(String id, {required BudgetPriority priority}) =>
      _parts.sender.drain(id, priority: priority);

  @override
  Future<List<String>> processWelcomes({required BudgetPriority priority}) =>
      _parts.crypto.processWelcomes(priority: priority);

  /// From the cached inbox rows (encrypted, ACCEPTED, by `updated_at`);
  /// when the cache has none, the vault's group conversations whose sync
  /// record says accepted, by their newest stored message.
  @override
  Future<List<String>> recentAccepted(int limit) async {
    final rows = (await _parts._p._messaging.cachedConversations(
      Folder.FOLDER_INBOX,
    )).conversations;
    for (final row in rows) {
      // The peer reference only (a cached row is no sight).
      _parts.contexts.note(row, peerOnly: true);
    }
    final fromCache = passConversationsFrom(rows, limit);
    if (fromCache.isNotEmpty) return fromCache;
    final newest = <String, int>{};
    for (final id in await _vault.groupConversationIds()) {
      final record = await _vault.conversation(id);
      if (!(record?.sync.requestAccepted ?? false)) continue;
      final last = await _vault.messages(id, limit: 1);
      newest[id] = last.isEmpty ? 0 : last.first.createdAtMicros;
    }
    final ids = newest.keys.toList()
      ..sort((a, b) => newest[b]!.compareTo(newest[a]!));
    return ids.take(limit).toList();
  }

  /// ONE `GetKeyDevices` call (the directory batches up to
  /// `kDirectoryBatchUsers`, 10, per call) for the peers this run knows.
  @override
  Future<void> lookUpPeers(List<String> conversationIds) async {
    final refs = <String>{};
    for (final id in conversationIds) {
      final ref = _parts.contexts.of(id).peerUserId ?? _parts.known.peerOf(id);
      if (ref != null && ref.isNotEmpty) refs.add(ref);
    }
    if (refs.isEmpty) return;
    await _parts.directory.peers(refs.toList());
  }

  @override
  Future<CatchUpResult> catchUp(
    String id, {
    required BudgetPriority priority,
  }) => _parts.crypto.catchUp(id, priority: priority);

  @override
  Future<ReceiveOutcome> pullLive(
    String id, {
    required BudgetPriority priority,
  }) => _parts.receiver.pullLive(id, priority: priority);

  @override
  Future<void> reconcile(String id, {required BudgetPriority priority}) =>
      _parts.upkeep.reconcile(id, priority: priority, renewLeaf: false);

  @override
  Future<void> selfUpdateIfDue(String id, {required BudgetPriority priority}) =>
      _parts.upkeep.selfUpdateIfDue(id, priority: priority);

  @override
  Future<void> repairIfStuck(String id) => _parts.starter.repairIfStuck(id);

  @override
  Future<void> applyClearedAtOnce(
    String id, {
    required BudgetPriority priority,
  }) => _parts.receiver.applyClearedAtOnce(id, priority: priority);

  @override
  Future<void> resumePending(String id, {required BudgetPriority priority}) =>
      _parts.commits.resumePending(id, priority: priority);

  @override
  Future<List<String>> pendingCommitConversations() async {
    final out = <String>[];
    for (final id in await _vault.groupConversationIds()) {
      final groups = await _vault.groups(id);
      if (groups.any((g) => !g.provisional && g.pending != null)) out.add(id);
    }
    return out;
  }

  @override
  Future<void> removalPass(RemovalTrigger trigger) => switch (trigger) {
    RemovalTrigger.vaultReady => _parts.runner.onVaultReady(),
    RemovalTrigger.resume => _parts.runner.onAppResumed(),
  };

  /// Gate item 25: one `pendingWork` read per known conversation; those
  /// with work left come first, each group in the known set's order.
  @override
  Future<List<String>> sweepOrder() async {
    final known = _parts.known;
    if (!known.isLoadedFor(_vault)) await known.load(_vault);
    final first = <String>[];
    final rest = <String>[];
    for (final id in known.ids) {
      final pending = await _parts.receiver.pendingWork(id);
      (pending.any ? first : rest).add(id);
    }
    return [...first, ...rest];
  }

  @override
  Future<bool> hasGroup(String id) async =>
      (await _vault.groups(id)).any((g) => !g.provisional);

  @override
  Future<bool> catchUpOwed(String id) async {
    final c = _parts.contexts.of(id);
    if (c.catchUpDueAt != null || c.laterPairSeen != null) return true;
    final server = c.serverPair;
    if (server == null) return false;
    MlsPair? current;
    for (final g in await _vault.groups(id)) {
      if (!g.provisional) current = MlsPair(g.generation, g.epoch);
    }
    return current == null || current.compareTo(server) < 0;
  }
}
