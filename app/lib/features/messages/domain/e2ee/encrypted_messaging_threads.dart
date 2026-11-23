part of 'encrypted_messaging_impl.dart';

// Plan 5a Task 13b, step 13b-ii: the port's threads (gate items 27-30):
// one broadcast controller per ThreadRef, built from the vault only.

/// The rows a thread starts with, and what [EncryptedMessaging.loadOlder]
/// adds.
const int kThreadPage = 50;

const EncryptedThread _emptyThread = EncryptedThread(
  security: ConversationSecurity(state: ConversationEncryptionState.ready),
);

/// One watched thread (gate item 29). The window starts at [kThreadPage]
/// stored rows plus every unsent row and every deferred row in it
/// ([entryOfDeferred], gate item 27); entries newest first; nothing at or
/// before `cleared_at`. Re-emits after every pipeline change of its
/// conversation and every session or device status change ([refresh],
/// single flight). Its first listener opens the conversation with the
/// coordinator ([E2eePipeline.opened]: the foreground sync, the
/// `cleared_at` read, reconciliation, the self-update check); the last one
/// leaving closes it and cancels nothing in flight. Errors are never
/// emitted: a failed read keeps the last emission (or emits an empty
/// thread that cannot send). Defines no `toString`.
class _Thread {
  _Thread(this._impl, this.ref) {
    _controller = StreamController<EncryptedThread>.broadcast(
      onListen: _firstListener,
      onCancel: _lastListener,
    );
  }

  final EncryptedMessagingImpl _impl;
  final ThreadRef ref;
  late final StreamController<EncryptedThread> _controller;

  int window = kThreadPage;
  EncryptedThread? _latest;

  /// The conversation id of the last build (null: not known yet).
  String? _id;

  /// The id opened with the coordinator while someone listens.
  String? _opened;

  Future<void>? _building;
  bool _again = false;

  /// Each listener gets the latest thread at once, then every change.
  ///
  /// Branch review m1: a thread nobody listens to is not in the port's map
  /// and holds nothing decrypted ([_lastListener]). A stream object listened
  /// to again registers its thread again, or follows the thread another
  /// `watchThread` made for the same ref meanwhile; a thread closed by a
  /// vault change (L3) stays ended.
  Stream<EncryptedThread> get stream => Stream.multi((c) {
    _impl._checkVault();
    if (_controller.isClosed) {
      c.close();
      return;
    }
    final owner = _impl._threads.putIfAbsent(ref, () => this);
    if (!identical(owner, this)) {
      final sub = owner.stream.listen(c.add, onDone: c.close);
      c.onCancel = sub.cancel;
      return;
    }
    final latest = _latest;
    if (latest != null) c.add(latest);
    final sub = _controller.stream.listen(c.add, onDone: c.close);
    c.onCancel = sub.cancel;
  });

  /// Someone listens (branch review n2: `loadOlder` reads nothing else).
  bool get watched => _controller.hasListener;

  /// Whether a change of [conversationId] concerns this thread (a thread
  /// whose id is not known yet may be the one a send just bound).
  bool shows(String conversationId) => _id == null || _id == conversationId;

  void refreshIfWatched() {
    if (_controller.hasListener) unawaited(refresh());
  }

  /// Builds and emits; a call while a build runs makes exactly one more.
  Future<void> refresh() {
    final running = _building;
    if (running != null) {
      _again = true;
      return running;
    }
    return _building = _run();
  }

  Future<void> _run() async {
    try {
      do {
        _again = false;
        final thread = await _build();
        if (_controller.isClosed) return;
        // m1: a build that ends after the last listener left keeps nothing.
        if (!_controller.hasListener) return;
        if (thread != null) {
          _latest = thread;
          _controller.add(thread);
        }
        _open();
      } while (_again);
    } finally {
      _building = null;
    }
  }

  void _firstListener() => unawaited(refresh());

  /// Closes the conversation with the coordinator, and (branch review m1)
  /// drops the decrypted window and this thread's entry in the port's map:
  /// the next first listener builds again from the vault anyway.
  void _lastListener() {
    final id = _opened;
    _opened = null;
    if (id != null) _impl._pipeline.closed(id);
    _latest = null;
    _again = false;
    if (identical(_impl._threads[ref], this)) _impl._threads.remove(ref);
  }

  /// Opens the conversation once its id is known and someone listens.
  void _open() {
    final id = _id;
    if (id == null || _opened == id || !_controller.hasListener) return;
    final before = _opened;
    if (before != null) _impl._pipeline.closed(before);
    _opened = id;
    unawaited(_impl._pipeline.opened(id));
  }

  /// L3: the vault changed; the stream ends.
  void close() {
    _lastListener();
    unawaited(_controller.close());
  }

  /// Null: keep the last emission.
  Future<EncryptedThread?> _build() async {
    final impl = _impl;
    final parts = impl._pipeline.parts;
    if (parts == null) {
      // No ready vault: the port's empty thread (the pinned inertness
      // test), keeping the id it is addressed by.
      return EncryptedThread(
        conversationId: ref.conversationId,
        security: _emptyThread.security,
      );
    }
    try {
      final id = _id = await _idOf(parts);
      if (id == null) {
        final unsent = await impl.unsentEntries(ref) ?? _unsentOf(_latest);
        return EncryptedThread(
          entries: unsent,
          security: _emptyThread.security,
        );
      }
      return await _read(parts, id);
    } on Object catch (e, s) {
      if (EncryptedMessagingImpl._isBug(e)) {
        impl._pipeline.reportPortError('port.watchThread', s);
      }
      if (_latest != null) return null;
      return EncryptedThread(
        conversationId: _id,
        security: const ConversationSecurity(
          state: ConversationEncryptionState.ready,
          canSend: false,
        ),
      );
    }
  }

  /// K2: a recipient ref is bound once a send learned its id, or once the
  /// vault holds a pending init or a stored ref for that person.
  Future<String?> _idOf(PipelineParts parts) async {
    final c = ref.conversationId;
    if (c != null) return c;
    final recipient = ref.recipientUserId!;
    final bound = _impl._bound[recipient];
    if (bound != null) return bound;
    final init = await parts.starter.pendingInit(recipientUserId: recipient);
    final id =
        init?.conversationId ??
        await parts.known.conversationForPeer(parts.vault, recipient);
    if (id != null) _impl._bound[recipient] = id;
    return id;
  }

  Future<EncryptedThread> _read(PipelineParts parts, String id) async {
    final impl = _impl;
    final vault = parts.vault;
    final rows = await vault.messages(id, limit: window + 1);
    final hasMore = rows.length > window;
    final page = hasMore ? rows.sublist(0, window) : rows;
    final cleared = (await vault.conversation(id))?.sync.clearedAtMicros;
    final state = await parts.crypto.describeState(id);
    final security = securityOf(
      state,
      usable:
          parts.live &&
          !impl._pipeline.deviceKeys.stopsPipeline &&
          state.sendBlock != SendBlock.unavailable,
    );
    // A5 / gate 5.3: a request (received or sent) shows no system line.
    final lines =
        security.state != ConversationEncryptionState.pendingRequest &&
        !security.sentRequest;
    final entries = <ThreadEntry>[];
    final storedIds = <String>{};
    for (final r in page) {
      if (cleared != null && r.createdAtMicros <= cleared) continue;
      storedIds.add(r.messageId);
      if (r.kind == StoredMessageKind.system) {
        final line = lines ? lineOfStored(r) : null;
        if (line != null) entries.add(line);
      } else {
        entries.add(entryOfStored(r));
      }
    }
    // Gate item 27: the deferred rows inside the window (all of them when
    // the window holds every stored row).
    final oldest = page.isEmpty ? null : page.last.createdAtMicros;
    for (final d in await parts.receiver.deferredView(id)) {
      if (storedIds.contains(d.id)) continue;
      if (hasMore && oldest != null && d.atMicros < oldest) continue;
      entries.add(entryOfDeferred(d));
    }
    final unsent =
        await impl.unsentEntries(ThreadRef.conversation(id)) ??
        _unsentOf(_latest);
    // Branch review m2, decision: the port's promise "nothing at or before
    // cleared_at" holds for own unsent rows too. A row kept after a
    // delete-for-me (the init discard answered `held`) stays in the vault,
    // since it may still go out, but this thread does not show it.
    for (final e in unsent) {
      if (cleared == null || e.at.microsecondsSinceEpoch > cleared) {
        entries.add(e);
      }
    }
    return EncryptedThread(
      conversationId: id,
      entries: _newestFirst(entries),
      hasMore: hasMore,
      security: security,
    );
  }

  /// The unsent rows of the last emission (gate item 17: a failed read of
  /// the outbox is "not known now", so the bubbles stay).
  static List<DecryptedMessage> _unsentOf(EncryptedThread? t) => [
    for (final e in t?.entries ?? const <ThreadEntry>[])
      if (e is DecryptedMessage &&
          e.mine &&
          e.progress != SendProgress.delivered)
        e,
  ];

  /// Newest first, stable for equal times (the order they were added).
  static List<ThreadEntry> _newestFirst(List<ThreadEntry> entries) {
    final indexed = [for (var i = 0; i < entries.length; i++) (i, entries[i])];
    indexed.sort((a, b) {
      final c = b.$2.at.compareTo(a.$2.at);
      return c != 0 ? c : a.$1.compareTo(b.$1);
    });
    return [for (final x in indexed) x.$2];
  }
}
