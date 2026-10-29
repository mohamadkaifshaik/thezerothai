import 'dart:math' as math;

import 'package:drift/drift.dart';
import 'package:fixnum/fixnum.dart' show Int64;

import '../../../core/storage/app_database.dart';
import '../../../gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;
import '../../../gen/dzeroth/messaging/v1/messaging.pbenum.dart';

/// Messages kept per conversation (ADR-0027 D14: "the last 200 messages per
/// conversation in drift per uid").
const kMessagesPerConversation = 200;

/// The cached conversations of one folder, newest activity first.
class ConversationsSnapshot {
  const ConversationsSnapshot({
    this.conversations = const [],
    this.sinceToken = '',
    this.olderPageToken = '',
    this.requestCount,
  });

  final List<pb.Conversation> conversations;
  final String sinceToken;
  final String olderPageToken;

  /// Last known pending message-request count (INBOX only; null = unknown).
  final int? requestCount;

  bool get hasMore => olderPageToken.isNotEmpty;
}

/// The cached thread of one conversation: messages newest first, and the
/// conversation header when one was cached.
class ThreadSnapshot {
  const ThreadSnapshot({
    this.messages = const [],
    this.conversation,
    this.sinceToken = '',
    this.olderPageToken = '',
    this.firstPageHeader = false,
  });

  final List<pb.Message> messages;
  final pb.Conversation? conversation;
  final String sinceToken;
  final String olderPageToken;

  /// True only for the snapshot a refresh returns after it APPLIED a first
  /// ListMessages page (a cold open): the header's `unread_count` and `silent`
  /// are then the server's (W7-27), 0 included. False for a cache read, a
  /// `since` refresh and an older page, whose cached count may be stale.
  final bool firstPageHeader;

  bool get hasMore => olderPageToken.isNotEmpty;

  /// This snapshot, marked as the result of an applied first page.
  ThreadSnapshot asFirstPage() => ThreadSnapshot(
    messages: messages,
    conversation: conversation,
    sinceToken: sinceToken,
    olderPageToken: olderPageToken,
    firstPageHeader: true,
  );
}

/// Sort key of a conversation: zero-padded `updated_at` microseconds, then
/// the id (a total order, newest first when sorted descending).
String conversationSortKey(pb.Conversation c) {
  final micros = c.hasUpdatedAt()
      ? c.updatedAt.toDateTime().microsecondsSinceEpoch
      : 0;
  return '${micros.toString().padLeft(20, '0')}|${c.id}';
}

/// The conversation a thread cold open stores: the ListMessages header
/// [fresh] merged into the cached row [cached] instead of overwriting it
/// (W7-19, ADR-0027 D14).
///
/// ListMessages carries identity, peer, state, folder and `can_reply`; it does
/// not carry the caller's `last_message` or `updated_at`, which
/// ListConversations owns. So the header wins for what it carries, and the
/// cached entry is kept for what it omits. The sort key follows `updated_at`,
/// so keeping it keeps the row where the Inbox put it.
///
/// `unread_count` and `silent` depend on the page kind (W7-27, ADR-0027). The
/// FIRST page ([firstPage] true) carries the caller's entry, so both are taken
/// as they are, including 0 and false: a 0 means the thread was read on
/// another device. A `since` or older page leaves them unset, and a proto3
/// scalar cannot say "omitted" apart from zero, so with [firstPage] false the
/// cached values stay exactly as before (a header count above 0 or `silent`
/// true still wins). The caller says which page it applied; it is never guessed
/// from the value.
pb.Conversation mergeThreadHeader(
  pb.Conversation? cached,
  pb.Conversation fresh, {
  required bool firstPage,
}) {
  final merged = fresh.deepCopy();
  if (cached == null) return merged;
  if (merged.kind == ConversationKind.CONVERSATION_KIND_UNSPECIFIED) {
    merged.kind = cached.kind;
  }
  if (merged.state == ConversationState.CONVERSATION_STATE_UNSPECIFIED) {
    merged.state = cached.state;
  }
  if (merged.folder == Folder.FOLDER_UNSPECIFIED) merged.folder = cached.folder;
  if (!merged.hasLastMessage() && cached.hasLastMessage()) {
    merged.lastMessage = cached.lastMessage;
  }
  // Known window (#459 review): a first-page 0 is authoritative EXCEPT within
  // 60 s of an Accept on another server instance. There the instance's cached
  // conversation copy can still point at the requests folder, the entry read
  // misses and the server answers 0. Effect: the Messages badge can drop for
  // one conversation that is still unread and the mark-read is skipped. It
  // self-corrects at the next GetMe or Inbox first page. No client heuristic
  // on purpose: 0 is taken as it is.
  if (!firstPage) {
    if (merged.unreadCount == Int64.ZERO) {
      merged.unreadCount = cached.unreadCount;
    }
    if (!merged.silent && cached.silent) merged.silent = true;
  }
  if (!merged.hasUpdatedAt() && cached.hasUpdatedAt()) {
    merged.updatedAt = cached.updatedAt;
  }
  return merged;
}

/// Sort key of a message: zero-padded `created_at` microseconds, then the id.
String messageSortKey(pb.Message m) {
  final micros = m.hasCreatedAt()
      ? m.createdAt.toDateTime().microsecondsSinceEpoch
      : 0;
  return '${micros.toString().padLeft(20, '0')}|${m.id}';
}

String _folderStateKey(Folder folder) =>
    folder == Folder.FOLDER_REQUESTS ? 'requests' : 'inbox';

String _threadStateKey(String conversationId) => 'thread:$conversationId';

/// Persists the direct-message inbox, requests and threads in drift and
/// implements every merge rule in one place (one transaction per method).
/// Mirrors `NotificationsStore`: every write takes the session it started
/// under and is dropped when the epoch ended since, so an in-flight response
/// of a signed-out user never lands in the next user's cache (CLAUDE.md
/// privacy rule 10). Nothing here logs; message text never leaves the
/// database.
class MessagingStore {
  MessagingStore(this._db);

  final AppDatabase _db;

  int get session => _db.sessionEpoch.value;

  Future<T?> _tx<T>(int session, Future<T> Function() body) {
    return _db.transaction<T?>(() async {
      if (!_db.sessionEpoch.allows(session)) return null;
      return body();
    });
  }

  // --- conversations -------------------------------------------------------

  Future<ConversationsSnapshot> readConversations(Folder folder) async {
    final rows =
        await (_db.select(_db.conversationEntries)
              ..where((t) => t.folder.equals(folder.value))
              ..orderBy([(t) => OrderingTerm.desc(t.sortKey)]))
            .get();
    final items = <pb.Conversation>[];
    final undecodable = <String>[];
    for (final row in rows) {
      try {
        items.add(pb.Conversation.fromBuffer(row.payload));
      } catch (_) {
        undecodable.add(row.conversationId);
      }
    }
    if (undecodable.isNotEmpty) {
      await (_db.delete(
        _db.conversationEntries,
      )..where((t) => t.conversationId.isIn(undecodable))).go();
    }
    final state = await _state(_folderStateKey(folder));
    return ConversationsSnapshot(
      conversations: items,
      sinceToken: state?.sinceToken ?? '',
      olderPageToken: state?.olderPageToken ?? '',
      requestCount: folder == Folder.FOLDER_INBOX ? state?.requestCount : null,
    );
  }

  /// The cached conversation [id], whichever folder it is in.
  Future<pb.Conversation?> conversation(String id) async {
    final row = await (_db.select(
      _db.conversationEntries,
    )..where((t) => t.conversationId.equals(id))).getSingleOrNull();
    if (row == null) return null;
    try {
      return pb.Conversation.fromBuffer(row.payload);
    } catch (_) {
      return null;
    }
  }

  /// Replaces [folder] with a first page (no tokens sent).
  /// The cached conversation with [peerUserId], whichever folder it is in
  /// (W7-17: "open the existing one, never a duplicate"). The cache is the
  /// inbox and requests pages only, so this is a scan of at most a few dozen
  /// rows; the newest activity wins if two entries ever named the same peer.
  Future<pb.Conversation?> conversationWithPeer(String peerUserId) async {
    if (peerUserId.isEmpty) return null;
    final rows = await (_db.select(
      _db.conversationEntries,
    )..orderBy([(t) => OrderingTerm.desc(t.sortKey)])).get();
    for (final row in rows) {
      try {
        final c = pb.Conversation.fromBuffer(row.payload);
        if (c.peer.userId == peerUserId) return c;
      } catch (_) {
        // An undecodable row is dropped by the next read of its folder.
      }
    }
    return null;
  }

  Future<void> applyConversationsColdOpen(
    Folder folder, {
    required List<pb.Conversation> items,
    required String sinceToken,
    required String nextPageToken,
    required int session,
    int? requestCount,
  }) {
    return _tx(session, () async {
      await (_db.delete(
        _db.conversationEntries,
      )..where((t) => t.folder.equals(folder.value))).go();
      await _upsertConversations(_validConversations(items), folder);
      await _saveState(
        _folderStateKey(folder),
        sinceToken: sinceToken,
        olderPageToken: nextPageToken,
        replaceOlder: true,
        requestCount: requestCount,
      );
    });
  }

  /// Merges a `since_token` refresh by conversation id (a conversation that
  /// moved folder is rewritten in place).
  Future<void> applyConversationsRefresh(
    Folder folder, {
    required List<pb.Conversation> items,
    required String sinceToken,
    required int session,
  }) {
    return _tx(session, () async {
      await _upsertConversations(_validConversations(items), folder);
      await _saveState(_folderStateKey(folder), sinceToken: sinceToken);
    });
  }

  /// Merges a scroll-down page into the tail of [folder].
  Future<void> applyConversationsOlder(
    Folder folder, {
    required List<pb.Conversation> items,
    required String nextPageToken,
    required int session,
  }) {
    return _tx(session, () async {
      await _upsertConversations(_validConversations(items), folder);
      await _saveState(
        _folderStateKey(folder),
        olderPageToken: nextPageToken,
        replaceOlder: true,
      );
    });
  }

  /// Drops the stored `since_token` of [folder] (the server rejected it).
  Future<void> clearConversationsSince(Folder folder, {required int session}) =>
      _tx(
        session,
        () => _saveState(
          _folderStateKey(folder),
          sinceToken: '',
          replaceSince: true,
        ),
      );

  /// Adds [delta] to the stored request count, floor 0 (an accepted or
  /// deleted request). No-op while the count is unknown (null).
  Future<void> adjustRequestCount(int delta, {required int session}) {
    return _tx(session, () async {
      final old = (await _state('inbox'))?.requestCount;
      if (old == null) return;
      await _saveState('inbox', requestCount: math.max(0, old + delta));
    });
  }

  /// Sets the caller's unread count of [id] to 0 (after MarkConversationRead).
  Future<void> markConversationRead(String id, {required int session}) {
    return _tx(session, () async {
      final c = await conversation(id);
      if (c == null || c.unreadCount == 0) return;
      await _putConversation(c.deepCopy()..unreadCount = Int64.ZERO);
    });
  }

  /// Moves [id] to the inbox as ACCEPTED (after AcceptMessageRequest).
  Future<void> markConversationAccepted(String id, {required int session}) {
    return _tx(session, () async {
      final c = await conversation(id);
      if (c == null) return;
      await _putConversation(
        c.deepCopy()
          ..state = ConversationState.CONVERSATION_STATE_ACCEPTED
          ..folder = Folder.FOLDER_INBOX,
      );
    });
  }

  /// Removes only [id]'s row from the cached lists; its messages and thread
  /// state stay (W7-18: a blocked requester's open thread keeps working).
  /// Unguarded on purpose: removing rows can never leak data.
  Future<void> removeConversationEntry(String id) {
    return (_db.delete(
      _db.conversationEntries,
    )..where((t) => t.conversationId.equals(id))).go();
  }

  /// Removes [id] and everything cached for it (after DeleteConversation).
  /// Unguarded on purpose: removing rows can never leak data.
  Future<void> removeConversation(String id) {
    return _db.transaction(() async {
      await (_db.delete(
        _db.conversationEntries,
      )..where((t) => t.conversationId.equals(id))).go();
      await (_db.delete(
        _db.messageEntries,
      )..where((t) => t.conversationId.equals(id))).go();
      await (_db.delete(
        _db.messagingStateEntries,
      )..where((t) => t.stateKey.equals(_threadStateKey(id)))).go();
    });
  }

  // --- threads -------------------------------------------------------------

  Future<ThreadSnapshot> readThread(String conversationId) async {
    final rows =
        await (_db.select(_db.messageEntries)
              ..where((t) => t.conversationId.equals(conversationId))
              ..orderBy([(t) => OrderingTerm.desc(t.sortKey)]))
            .get();
    final messages = <pb.Message>[];
    final undecodable = <String>[];
    for (final row in rows) {
      try {
        messages.add(pb.Message.fromBuffer(row.payload));
      } catch (_) {
        undecodable.add(row.messageId);
      }
    }
    if (undecodable.isNotEmpty) {
      await (_db.delete(_db.messageEntries)..where(
            (t) =>
                t.conversationId.equals(conversationId) &
                t.messageId.isIn(undecodable),
          ))
          .go();
    }
    final state = await _state(_threadStateKey(conversationId));
    return ThreadSnapshot(
      messages: messages,
      conversation: await conversation(conversationId),
      sinceToken: state?.sinceToken ?? '',
      olderPageToken: state?.olderPageToken ?? '',
    );
  }

  /// Replaces the thread with a first page. Returns how many of [items] were
  /// not cached before; null when the write was dropped (session ended).
  Future<int?> applyThreadColdOpen(
    String conversationId, {
    required List<pb.Message> items,
    required pb.Conversation? conversation,
    required String sinceToken,
    required String nextPageToken,
    required int session,
  }) {
    return _tx(session, () async {
      final valid = _validMessages(items);
      final known = await _knownIds(conversationId);
      await (_db.delete(
        _db.messageEntries,
      )..where((t) => t.conversationId.equals(conversationId))).go();
      await _upsertMessages(conversationId, valid);
      if (valid.isNotEmpty && nextPageToken.isNotEmpty) {
        await _setPageToken(conversationId, valid.last.id, nextPageToken);
      }
      if (conversation != null && conversation.id.isNotEmpty) {
        // Merged, not overwritten: the header omits the preview and sort key,
        // which the cached Inbox row holds. This is always a first page, so
        // its unread_count and silent are the server's (W7-27), 0 included.
        await _putConversation(
          mergeThreadHeader(
            await this.conversation(conversation.id),
            conversation,
            firstPage: true,
          ),
        );
      }
      await _saveState(
        _threadStateKey(conversationId),
        sinceToken: sinceToken,
        olderPageToken: nextPageToken,
        replaceOlder: true,
      );
      await _trim(conversationId);
      return valid.where((m) => !known.contains(m.id)).length;
    });
  }

  /// Merges a `since_token` refresh (and the pages that filled its gap) by
  /// message id: a duplicate id replaces the old row, never adds a second.
  /// Returns how many ids were not cached before; null when dropped.
  Future<int?> applyThreadRefresh(
    String conversationId, {
    required List<pb.Message> items,
    required String sinceToken,
    required int session,
  }) {
    return _tx(session, () async {
      final valid = _validMessages(items);
      final known = await _knownIds(conversationId);
      await _upsertMessages(conversationId, valid);
      await _saveState(_threadStateKey(conversationId), sinceToken: sinceToken);
      await _trim(conversationId);
      return valid.where((m) => !known.contains(m.id)).length;
    });
  }

  /// Merges a scroll-down page into the tail of the thread.
  Future<void> applyThreadOlder(
    String conversationId, {
    required List<pb.Message> items,
    required String nextPageToken,
    required int session,
  }) {
    return _tx(session, () async {
      final valid = _validMessages(items);
      await _upsertMessages(conversationId, valid);
      if (valid.isNotEmpty && nextPageToken.isNotEmpty) {
        await _setPageToken(conversationId, valid.last.id, nextPageToken);
      }
      await _saveState(
        _threadStateKey(conversationId),
        olderPageToken: nextPageToken,
        replaceOlder: true,
      );
      await _trim(conversationId);
    });
  }

  /// Drops the stored `since_token` of a thread (the server rejected it).
  Future<void> clearThreadSince(String conversationId, {required int session}) {
    return _tx(
      session,
      () => _saveState(
        _threadStateKey(conversationId),
        sinceToken: '',
        replaceSince: true,
      ),
    );
  }

  /// Stores a message the caller just sent, and the conversation it landed in.
  Future<void> applySent(
    pb.Message message,
    pb.Conversation? conversation, {
    required int session,
  }) {
    return _tx(session, () async {
      final conversationId = message.conversationId.isNotEmpty
          ? message.conversationId
          : conversation?.id ?? '';
      if (conversationId.isEmpty || message.id.isEmpty) return;
      await _upsertMessages(conversationId, [message]);
      if (conversation != null && conversation.id.isNotEmpty) {
        await _putConversation(conversation);
      }
      await _trim(conversationId);
    });
  }

  // --- internals -----------------------------------------------------------

  List<pb.Conversation> _validConversations(List<pb.Conversation> items) {
    final byId = <String, pb.Conversation>{};
    for (final c in items) {
      if (c.id.isNotEmpty) byId[c.id] = c;
    }
    return byId.values.toList();
  }

  /// One entry per id (a later one wins), in the order first seen.
  List<pb.Message> _validMessages(List<pb.Message> items) {
    final byId = <String, pb.Message>{};
    for (final m in items) {
      if (m.id.isNotEmpty) byId[m.id] = m;
    }
    return byId.values.toList();
  }

  Future<Set<String>> _knownIds(String conversationId) async {
    final rows = await (_db.select(
      _db.messageEntries,
    )..where((t) => t.conversationId.equals(conversationId))).get();
    return {for (final r in rows) r.messageId};
  }

  Future<CachedMessagingState?> _state(String key) {
    return (_db.select(
      _db.messagingStateEntries,
    )..where((t) => t.stateKey.equals(key))).getSingleOrNull();
  }

  /// A null/empty token leaves the stored one alone unless the matching
  /// `replace*` flag is set (a response without a `since_token` must not
  /// erase the old one).
  Future<void> _saveState(
    String key, {
    String? sinceToken,
    String? olderPageToken,
    bool replaceSince = false,
    bool replaceOlder = false,
    int? requestCount,
  }) async {
    final old = await _state(key);
    final since =
        (sinceToken != null && (sinceToken.isNotEmpty || replaceSince))
        ? sinceToken
        : old?.sinceToken ?? '';
    final older =
        (olderPageToken != null && (olderPageToken.isNotEmpty || replaceOlder))
        ? olderPageToken
        : old?.olderPageToken ?? '';
    await _db
        .into(_db.messagingStateEntries)
        .insertOnConflictUpdate(
          MessagingStateEntriesCompanion.insert(
            stateKey: key,
            sinceToken: Value(since),
            olderPageToken: Value(older),
            requestCount: Value(requestCount ?? old?.requestCount),
            updatedAt: DateTime.now(),
          ),
        );
  }

  Future<void> _upsertConversations(
    List<pb.Conversation> items,
    Folder folder,
  ) async {
    for (final c in items) {
      // The folder of the list asked for decides; an unspecified folder on
      // the wire never moves a row.
      final fixed = c.folder == Folder.FOLDER_UNSPECIFIED
          ? (c.deepCopy()..folder = folder)
          : c;
      await _putConversation(fixed);
    }
  }

  Future<void> _putConversation(pb.Conversation c) {
    return _db
        .into(_db.conversationEntries)
        .insertOnConflictUpdate(
          ConversationEntriesCompanion.insert(
            conversationId: c.id,
            folder: c.folder == Folder.FOLDER_UNSPECIFIED
                ? Folder.FOLDER_INBOX.value
                : c.folder.value,
            sortKey: conversationSortKey(c),
            payload: c.writeToBuffer(),
          ),
        );
  }

  Future<void> _upsertMessages(
    String conversationId,
    List<pb.Message> items,
  ) async {
    for (final m in items) {
      await _db
          .into(_db.messageEntries)
          .insertOnConflictUpdate(
            MessageEntriesCompanion.insert(
              conversationId: conversationId,
              messageId: m.id,
              sortKey: messageSortKey(m),
              payload: m.writeToBuffer(),
            ),
          );
    }
  }

  Future<void> _setPageToken(String conversationId, String id, String token) {
    return (_db.update(_db.messageEntries)..where(
          (t) =>
              t.conversationId.equals(conversationId) & t.messageId.equals(id),
        ))
        .write(MessageEntriesCompanion(pageToken: Value(token)));
  }

  /// Keeps at most [kMessagesPerConversation] newest messages. The cut is
  /// moved up to the deepest row of the kept window that ended a fetched
  /// page, so the stored scroll token still continues exactly below the
  /// oldest kept row; without such a row the newest 200 are kept and the
  /// scroll token is dropped (older history is then reached by reopening the
  /// thread).
  Future<void> _trim(String conversationId) async {
    final rows =
        await (_db.select(_db.messageEntries)
              ..where((t) => t.conversationId.equals(conversationId))
              ..orderBy([(t) => OrderingTerm.desc(t.sortKey)]))
            .get();
    if (rows.length <= kMessagesPerConversation) return;
    var keep = kMessagesPerConversation;
    var token = '';
    for (var i = kMessagesPerConversation - 1; i >= 0; i--) {
      final t = rows[i].pageToken;
      if (t != null && t.isNotEmpty) {
        keep = i + 1;
        token = t;
        break;
      }
    }
    final drop = [for (final r in rows.skip(keep)) r.messageId];
    await (_db.delete(_db.messageEntries)..where(
          (t) =>
              t.conversationId.equals(conversationId) & t.messageId.isIn(drop),
        ))
        .go();
    await _saveState(
      _threadStateKey(conversationId),
      olderPageToken: token,
      replaceOlder: true,
    );
  }
}
