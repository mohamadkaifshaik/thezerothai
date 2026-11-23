part of 'e2ee_pipeline.dart';

/// The pipeline's parts for ONE vault: one of each per session (gate items
/// 1-14), built in the order each needs the others, with every seam a gate
/// names wired here (15-20, 44, 45, 48, 67). See [E2eePipeline].
class _Parts {
  _Parts(this._p, this.vault) {
    final session = _p._session;
    final CryptoEngine Function() engine = _p._engine;
    final now = _p._now;
    final report = _p._onUnexpectedError;
    final onChanged = _p._onPartChanged;
    final keys = _p._keys;
    final messaging = _p._messaging;
    final deviceKeys = _p._deviceKeys;
    // Gate item 15: every pipeline `removedElsewhere` seam gets the same
    // fact, which fails closed while it is not known.
    bool stops() => deviceKeys.stopsPipeline;
    int ownDevices() => directory.ownDeviceCount;

    // Gate item 7: the budgets are divided by the own-device count (two own
    // devices halve the calls per minute); the receiver's probes have their
    // own read budget.
    final scale = _p._budgetScale;
    directoryBudget = SyncBudget(
      perMinute: kDirectoryCallsPerMinute * scale,
      ownDeviceCount: ownDevices,
      now: now,
    );
    syncBudget = SyncBudget(
      perMinute: kSyncCallsPerMinute * scale,
      ownDeviceCount: ownDevices,
      now: now,
    );
    readBudget = SyncBudget(
      perMinute: kMlsReadCallsPerMinute * scale,
      ownDeviceCount: ownDevices,
      now: now,
    );
    directory = DeviceDirectory(keys: keys, budget: directoryBudget, now: now);
    known = KnownConversations(session: session);
    // Gate item 10: the ledger's (and the starter's) clock is the device
    // clock, never one adjusted to the server.
    ledger = DailyLedger(session: session, now: now, onUnexpectedError: report);
    crypto = ConversationCrypto(
      session: session,
      engine: engine,
      messaging: messaging,
      directory: directory,
      syncBudget: syncBudget,
      locks: locks,
      contexts: contexts,
      known: known,
      ledger: ledger,
      now: now,
      onChanged: onChanged,
      removedElsewhere: stops,
      onUnexpectedError: report,
    );
    receiver = MessageReceiver(
      crypto: crypto,
      session: session,
      engine: engine,
      messaging: messaging,
      syncBudget: syncBudget,
      readBudget: readBudget,
      locks: locks,
      contexts: contexts,
      now: now,
      onChanged: onChanged,
      ledger: ledger,
      onUnexpectedError: report,
    );
    // Gate item 2: one receiver per session, the crypto's sink.
    crypto.sink = receiver;
    // Gate items 17-19: late-bound, built before the runner.
    final wasRemovedByUser = wasRemovedByUserOf(() => _runner);
    sender = EncryptedSender(
      crypto: crypto,
      receiver: receiver,
      session: session,
      engine: engine,
      messaging: messaging,
      locks: locks,
      contexts: contexts,
      now: now,
      onChanged: onChanged,
      // Gate item 48.
      acceptForReplyLocked: (id, {required priority}) =>
          upkeep.acceptForReplyLocked(id, priority: priority),
      removedElsewhere: stops,
      schedule: _p._scheduleFire,
      onUnexpectedError: report,
    );
    commits = CommitRunner(
      crypto: crypto,
      receiver: receiver,
      session: session,
      engine: engine,
      messaging: messaging,
      ledger: ledger,
      locks: locks,
      contexts: contexts,
      now: now,
      onChanged: onChanged,
      removedElsewhere: stops,
      schedule: _p._scheduleCancellable,
      onUnexpectedError: report,
    );
    upkeep = MembershipUpkeep(
      commits: commits,
      receiver: receiver,
      ledger: ledger,
      crypto: crypto,
      session: session,
      engine: engine,
      messaging: messaging,
      keys: keys,
      directory: directory,
      known: known,
      locks: locks,
      contexts: contexts,
      now: now,
      onChanged: onChanged,
      ownUserId: _p._ownUserId,
      removedElsewhere: stops,
      wasRemovedByUser: wasRemovedByUser,
      schedule: _p._scheduleCancellable,
      onUnexpectedError: report,
    );
    // Gate item 5: built after the upkeep; its constructor sets the
    // upkeep's queuedRemovals, removedKeyOf and removedByUser.
    runner = _runner = RemovalQueueRunner(
      keys: keys,
      directory: directory,
      commits: commits,
      upkeep: upkeep,
      receiver: receiver,
      crypto: crypto,
      session: session,
      engine: engine,
      locks: locks,
      contexts: contexts,
      now: now,
      removedElsewhere: stops,
      // Gate item 16: only a DEVICE_REMOVED answer stops a user removal,
      // never an unreadable marker (SA L8).
      removedDefinitely: () => deviceKeys.removedElsewhere,
      schedule: _p._scheduleCancellable,
      onUnexpectedError: report,
    );
    // Gate item 3: one starter per session (its constructor sets the
    // crypto's single callbacks).
    starter = GroupStarter(
      crypto: crypto,
      sender: sender,
      receiver: receiver,
      session: session,
      engine: engine,
      messaging: messaging,
      keys: keys,
      directory: directory,
      ledger: ledger,
      known: known,
      syncBudget: syncBudget,
      locks: locks,
      contexts: contexts,
      now: now,
      onChanged: onChanged,
      removedElsewhere: stops,
      ownUserId: _p._ownUserId,
      publicIdsOff: _p._publicIdsOff,
      wasRemovedByUser: wasRemovedByUser,
      schedule: _p._scheduleFire,
      onUnexpectedError: report,
    );
    // Gate item 20 (SA L6): a reset's settle, here or by the join path,
    // starts a removal pass (a removal queued mid-reset waited for it).
    starter.onResetSettled = _resetEnded;
    final forget = crypto.onOwnResetEnded;
    crypto.onOwnResetEnded = (id) {
      forget?.call(id);
      _resetEnded(id);
    };
    // Gate item 44.
    contexts
      ..onAcceptedSeen = upkeep.noteAcceptedSeen
      // Gate items 45 and 67.
      ..onRowNoted = _rowNoted;
    // Gate item 11: the pipeline's ONE known set and key history.
    reset = DeviceReset(
      session: session,
      deviceKeys: deviceKeys,
      contexts: contexts,
      keyHistory: crypto.keyHistory,
      known: known,
    );
    sync = SyncCoordinator(
      work: _Work(this),
      now: now,
      schedule: _p._scheduleCancellable,
      onUnexpectedError: report,
    );
  }

  final E2eePipeline _p;
  final SecureVault vault;

  final ConversationLocks locks = ConversationLocks();
  final ConversationContexts contexts = ConversationContexts();
  late final SyncBudget directoryBudget;
  late final SyncBudget syncBudget;
  late final SyncBudget readBudget;
  late final DeviceDirectory directory;
  late final KnownConversations known;
  late final DailyLedger ledger;
  late final ConversationCrypto crypto;
  late final MessageReceiver receiver;
  late final EncryptedSender sender;
  late final CommitRunner commits;
  late final MembershipUpkeep upkeep;
  late final RemovalQueueRunner runner;
  RemovalQueueRunner? _runner;
  late final GroupStarter starter;
  late final DeviceReset reset;
  late final SyncCoordinator sync;

  bool _disposed = false;

  /// [vault] is still the open one and these parts still the pipeline's.
  bool get live =>
      !_disposed &&
      identical(_p._parts, this) &&
      identical(_p._session.vault, vault);

  void _resetEnded(String conversationId) {
    if (!live) return;
    Zone.root.run(() => unawaited(runner.runPass()));
  }

  /// A `ListMessages` header or an inbox row read from the server in this
  /// run (`ConversationContexts.onRowNoted`; never inside a `runWrite`
  /// body). Called synchronously, maybe under the conversation lock: it
  /// waits for nothing.
  void _rowNoted(pb.Conversation row) {
    if (!live) return;
    final peer = row.hasPeer() ? row.peer.userId : '';
    if (row.canReply && peer.isNotEmpty) directory.markUsable(peer);
    Zone.root.run(() => unawaited(runner.noteConversation(row.id)));
    sync.onInboxRow(row);
  }

  /// `conversationsChanged`: the cached inbox rows are read again (no
  /// network). A cached row is no sight (review m5, audit L6): only its
  /// peer reference is taken; its `can_reply` true un-parks the peer's
  /// lookups and asks the removal queue to un-park (which reads the
  /// server-read `canReply` itself), and an encrypted row with no group
  /// here may poll welcomes. Watched threads are refreshed.
  Future<void> rereadInbox() async {
    if (!live) return;
    final rows = (await _p._messaging.cachedConversations(Folder.FOLDER_INBOX))
        .conversations;
    if (!live) return;
    for (final row in rows) {
      if (row.id.isEmpty) continue;
      contexts.note(row, peerOnly: true);
      final peer = row.hasPeer() ? row.peer.userId : '';
      if (row.canReply && peer.isNotEmpty) {
        directory.markUsable(peer);
        await runner.noteConversation(row.id);
        if (!live) return;
      }
      sync.onInboxRow(row);
    }
    sync.refreshWatched();
  }

  /// Gate item 43: the upkeep's acceptance steps, then the runner's.
  Future<void> accepted(String conversationId) async {
    if (!live) return;
    await upkeep.onAccepted(conversationId);
    if (!live) return;
    await runner.onAccepted(conversationId);
  }

  /// Gate item 47: under the conversation lock, ONE `runWrite` body and
  /// ONE transaction: every stored message and outbox row of
  /// [conversationId] goes, `cleared_at` becomes [atMicros] (never moved
  /// back), and the receiver's deferred items up to it are purged in the
  /// same transaction (a durable mark stays: a deleted message is never
  /// decrypted later). The group, the marks, the rest of the sync record and
  /// the known set stay.
  Future<void> deleteLocal(String conversationId, int atMicros) async {
    // Review I2: not made is never "done" (the caller keeps it remembered).
    if (!live) throw StateError('The vault changed.');
    final id = conversationId;
    await locks.run(id, () async {
      await _p._session.runWrite((v) async {
        if (!identical(v, vault)) throw StateError('The vault changed.');
        final rows = (await v.outbox(conversationId: id)).items;
        final record = await v.conversation(id);
        final sync = record?.sync ?? const ConversationSync();
        final before = sync.clearedAtMicros;
        final cleared = before != null && before > atMicros ? before : atMicros;
        await v.transaction((tx) async {
          await tx.deleteConversation(id);
          for (final r in rows) {
            await tx.deleteOutbox(r.idempotencyKey);
          }
          await tx.putConversationSync(
            id,
            sync.copyWith(clearedAtMicros: cleared),
          );
          await receiver.purgeDeferredIn(v, tx, id, cleared);
        });
      });
    });
    _p._onPartChanged(id);
  }

  /// Sign-out, a user change or a new vault (gate item 41): every part's
  /// memory of this run goes and the coordinator stops.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    sync.stop();
    starter.reset();
    commits.reset();
    upkeep.reset();
    runner.reset();
    sender.reset();
    contexts.clear();
    directory.clear();
    known.clear();
    syncBudget.reset();
    readBudget.reset();
    directoryBudget.reset();
  }
}
