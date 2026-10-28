import 'dart:async';
import 'dart:math' as math;

import '../../../core/network/api_client.dart';
import '../../../core/network/app_exception.dart';
import '../../../core/network/rate_limit_hold.dart';
import '../../../gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;
import '../../../gen/dzeroth/messaging/v1/messaging.pbenum.dart';
import '../domain/messaging_feature_gate.dart';
import '../domain/thread_poller.dart';
import 'messaging_store.dart';

/// Pages fetched in a row when the server answers a short or empty page while
/// more rows exist (requests of blocked or muted peers are dropped after the
/// query; the proto says to keep paging, never infer the end from a short
/// page).
const kMessagingEmptyPageRetries = 3;

/// Pages followed to fill the gap of a `since` poll before the thread is
/// reloaded from its first page instead (4 x 50 covers the 200 cached).
const kMaxGapPages = 4;

/// A ListConversations answer: the cache after merging it, plus the pending
/// request count the server sends on a first INBOX page only.
class ConversationsResult {
  const ConversationsResult(this.snapshot, {this.requestCount});

  final ConversationsSnapshot snapshot;

  /// `request_count` of a first INBOX page ("Message requests (N)"); null for
  /// every other answer (the server sends 0 there, which means "unknown").
  final int? requestCount;
}

/// Talks to `MessagingService` and keeps the inbox, requests and the newest
/// 200 messages per conversation in drift (ADR-0027 D5, D7, D14). It is the
/// only caller of the messaging RPCs.
///
/// - `cached*` render from disk with no network call.
/// - [refreshThread] and [refreshConversations] send the stored
///   `since_token` and merge by id; the 5 s settle window means a refresh may
///   return items already held, which replace the old row (one row per id).
///   A token the server rejects (`since_token` / `page_token`) is dropped and
///   exactly one first-page open is sent.
/// - Sends and Accept go through [MessagingFeatureGate.run] (per caller); the
///   other four RPCs through [MessagingFeatureGate.runRead] (not globally
///   off), so a user dropped from the allowlist can still read and clean up.
/// - ListConversations and ListMessages share the read [RateLimitHold]
///   (ADR-0010 D5: one daily read budget per uid); a RATE_LIMITED answer is
///   recorded there, which also holds [TimerThreadPoller]. Mutations never
///   use it.
/// - Messages carry no sender uid, only `from_self` (D5). Nothing here logs
///   or reports message text.
///
/// Calls are serialized and an identical call already in flight is shared.
class MessagingRepository {
  MessagingRepository({
    required ApiClient apiClient,
    required MessagingStore store,
    required MessagingFeatureGate gate,
    int pageSize = 0,
    RateLimitHold? rateLimitHold,
  }) : _apiClient = apiClient,
       _store = store,
       _gate = gate,
       _pageSize = pageSize,
       _hold = rateLimitHold ?? RateLimitHold();

  final ApiClient _apiClient;
  final MessagingStore _store;
  final MessagingFeatureGate _gate;
  final int _pageSize;
  final RateLimitHold _hold;

  Future<void> _tail = Future<void>.value();
  final Map<String, Future<Object?>> _inflight = {};
  final StreamController<void> _conversationsChanged =
      StreamController<void>.broadcast();

  /// The gate, so UI can follow the flag turning off mid-session.
  MessagingFeatureGate get gate => _gate;

  /// Whether the caller may send (the per-caller flag).
  bool get enabled => _gate.canSend;

  /// Fires after the cached conversation lists changed by a local action (an
  /// accepted or deleted request, W7-18), so an open inbox or requests list
  /// re-reads the cache (no network) instead of showing a stale row or count.
  /// Not a poll and not a server push: nothing here is live.
  Stream<void> get conversationsChanged => _conversationsChanged.stream;

  void _notifyConversationsChanged() {
    if (!_conversationsChanged.isClosed) _conversationsChanged.add(null);
  }

  /// Sign-out: forget in-flight work (the shared session epoch is ended by
  /// `wipeSessionData`, which drops their writes).
  void clearSession() {
    _inflight.clear();
    _tail = Future<void>.value();
  }

  /// The RATE_LIMITED answer list calls are held back for, with the time
  /// left; null when nothing is held.
  RateLimitedException? rateLimitedFor() => _hold.check();

  /// The shared read hold, for building a [ThreadPoller] that pauses on it
  /// (`TimerThreadPoller(pull: ..., rateLimitHold: repo.rateLimitHold)`).
  RateLimitHold get rateLimitHold => _hold;

  // --- conversations -------------------------------------------------------

  /// What is on disk for [folder]. Never touches the network.
  Future<ConversationsSnapshot> cachedConversations(Folder folder) =>
      _store.readConversations(folder);

  /// First open / resume / push received / pull-to-refresh of [folder].
  ///
  /// Decision: ListConversations has no `gap_page_token`. A `since` answer
  /// that fills a whole page may hide more, so the first page is reloaded
  /// (a cold open) instead of guessing.
  Future<ConversationsResult> refreshConversations(Folder folder) {
    final session = _store.session;
    return _single(
      'conversations:${folder.value}',
      () => _refreshConversations(folder, session),
    );
  }

  Future<ConversationsResult> _refreshConversations(
    Folder folder,
    int session,
  ) async {
    final state = await _store.readConversations(folder);
    if (state.sinceToken.isEmpty) {
      return _conversationsColdOpen(folder, session);
    }
    final page = await _listConversationsUnlessRejected(
      folder,
      'since_token',
      sinceToken: state.sinceToken,
    );
    if (page == null) {
      await _store.clearConversationsSince(folder, session: session);
      return _conversationsColdOpen(folder, session);
    }
    if (page.conversations.length >= _effectivePageSize) {
      return _conversationsColdOpen(folder, session);
    }
    await _store.applyConversationsRefresh(
      folder,
      items: page.conversations,
      sinceToken: page.sinceToken,
      session: session,
    );
    return ConversationsResult(await _store.readConversations(folder));
  }

  Future<ConversationsResult> _conversationsColdOpen(
    Folder folder,
    int session,
  ) async {
    final page = await _listConversations(folder);
    await _store.applyConversationsColdOpen(
      folder,
      items: page.conversations,
      sinceToken: page.sinceToken,
      nextPageToken: page.nextPageToken,
      session: session,
      requestCount: folder == Folder.FOLDER_INBOX
          ? page.requestCount.toInt()
          : null,
    );
    final snapshot = await _keepPagingConversations(
      folder,
      session,
      await _store.readConversations(folder),
      empty: page.conversations.isEmpty,
    );
    return ConversationsResult(
      snapshot,
      requestCount: folder == Folder.FOLDER_INBOX
          ? page.requestCount.toInt()
          : null,
    );
  }

  /// Infinite scroll: the page below the oldest cached conversation. No call
  /// when there is nothing older.
  Future<ConversationsSnapshot> loadOlderConversations(Folder folder) {
    final session = _store.session;
    return _single('conversations-older:${folder.value}', () async {
      final state = await _store.readConversations(folder);
      if (state.olderPageToken.isEmpty) return state;
      final page = await _listConversationsUnlessRejected(
        folder,
        'page_token',
        pageToken: state.olderPageToken,
      );
      if (page == null) {
        return (await _conversationsColdOpen(folder, session)).snapshot;
      }
      await _store.applyConversationsOlder(
        folder,
        items: page.conversations,
        nextPageToken: page.nextPageToken,
        session: session,
      );
      return _keepPagingConversations(
        folder,
        session,
        await _store.readConversations(folder),
        empty: page.conversations.isEmpty,
      );
    });
  }

  /// A page can be empty while more rows exist (filtered at read time): keep
  /// paging a few times so the screen is not left looking empty.
  Future<ConversationsSnapshot> _keepPagingConversations(
    Folder folder,
    int session,
    ConversationsSnapshot snapshot, {
    required bool empty,
  }) async {
    var current = snapshot;
    var wasEmpty = empty;
    for (var i = 0; i < kMessagingEmptyPageRetries; i++) {
      if (!wasEmpty || current.olderPageToken.isEmpty) break;
      final page = await _listConversationsUnlessRejected(
        folder,
        'page_token',
        pageToken: current.olderPageToken,
      );
      if (page == null) break;
      await _store.applyConversationsOlder(
        folder,
        items: page.conversations,
        nextPageToken: page.nextPageToken,
        session: session,
      );
      current = await _store.readConversations(folder);
      wasEmpty = page.conversations.isEmpty;
    }
    return current;
  }

  /// The cached conversation with [peerUserId] (W7-17), or null. Never
  /// touches the network: a conversation that was never loaded here is not
  /// found, and the first send then names the recipient, which the server
  /// resolves to the same deterministic conversation (no duplicate).
  Future<pb.Conversation?> cachedConversationWith(String peerUserId) =>
      _store.conversationWithPeer(peerUserId);

  // --- threads -------------------------------------------------------------

  /// What is on disk for [conversationId]. Never touches the network.
  Future<ThreadSnapshot> cachedThread(String conversationId) =>
      _store.readThread(conversationId);

  /// Opening a thread, resume, a push for it, or pull-to-refresh.
  Future<ThreadSnapshot> refreshThread(String conversationId) async {
    return (await _refreshThreadShared(conversationId)).snapshot;
  }

  /// One pull for [ThreadPoller] (`pull: () => repo.pollThread(id)`): the
  /// same refresh, answering whether it brought messages not held before.
  /// A RATE_LIMITED answer is recorded in the shared hold and rethrown, so
  /// the poller stops until the hold clears.
  Future<PollResult> pollThread(String conversationId) async {
    final refresh = await _refreshThreadShared(conversationId);
    return PollResult(newMessages: refresh.newMessages > 0);
  }

  Future<_ThreadRefresh> _refreshThreadShared(String conversationId) {
    final session = _store.session;
    return _single(
      'thread:$conversationId',
      () => _refreshThread(conversationId, session),
    );
  }

  Future<_ThreadRefresh> _refreshThread(
    String conversationId,
    int session,
  ) async {
    final state = await _store.readThread(conversationId);
    if (state.sinceToken.isEmpty) {
      return _threadColdOpen(conversationId, session);
    }
    final first = await _listMessagesUnlessRejected(
      conversationId,
      'since_token',
      sinceToken: state.sinceToken,
    );
    if (first == null) {
      await _store.clearThreadSince(conversationId, session: session);
      return _threadColdOpen(conversationId, session);
    }
    // A full since page carries gap_page_token: page it until it ends, then
    // write everything at once, so a failure part-way leaves the cache and
    // its since_token as they were and the next poll retries.
    final messages = [...first.messages];
    var gap = first.gapPageToken;
    var pages = 0;
    while (gap.isNotEmpty) {
      if (pages++ >= kMaxGapPages) {
        return _threadColdOpen(conversationId, session);
      }
      final next = await _listMessagesUnlessRejected(
        conversationId,
        'page_token',
        pageToken: gap,
      );
      if (next == null) return _threadColdOpen(conversationId, session);
      messages.addAll(next.messages);
      gap = next.nextPageToken;
    }
    final added = await _store.applyThreadRefresh(
      conversationId,
      items: messages,
      sinceToken: first.sinceToken,
      session: session,
    );
    return _ThreadRefresh(await _store.readThread(conversationId), added ?? 0);
  }

  Future<_ThreadRefresh> _threadColdOpen(
    String conversationId,
    int session,
  ) async {
    final page = await _listMessages(conversationId);
    final added = await _store.applyThreadColdOpen(
      conversationId,
      items: page.messages,
      conversation: page.hasConversation() ? page.conversation : null,
      sinceToken: page.sinceToken,
      nextPageToken: page.nextPageToken,
      session: session,
    );
    return _ThreadRefresh(await _store.readThread(conversationId), added ?? 0);
  }

  /// Scroll older: the page below the oldest cached message. No call when
  /// there is nothing older.
  Future<ThreadSnapshot> loadOlderMessages(String conversationId) {
    final session = _store.session;
    return _single('thread-older:$conversationId', () async {
      final state = await _store.readThread(conversationId);
      if (state.olderPageToken.isEmpty) return state;
      final page = await _listMessagesUnlessRejected(
        conversationId,
        'page_token',
        pageToken: state.olderPageToken,
      );
      if (page == null) {
        return (await _threadColdOpen(conversationId, session)).snapshot;
      }
      await _store.applyThreadOlder(
        conversationId,
        items: page.messages,
        nextPageToken: page.nextPageToken,
        session: session,
      );
      return _store.readThread(conversationId);
    });
  }

  // --- mutations -----------------------------------------------------------

  /// Sends [text] to an existing [conversationId] or, with
  /// [recipientUserId], opens or continues the 1:1 conversation. Exactly one
  /// target. [idempotencyKey] is generated once per user action and reused on
  /// retry (a retry returns the stored message). Per caller: with the flag
  /// off for the caller no RPC is sent. The message and conversation are
  /// cached on success.
  Future<pb.SendMessageResponse> sendMessage({
    required String idempotencyKey,
    required String text,
    String? conversationId,
    String? recipientUserId,
  }) async {
    assert(
      (conversationId == null) != (recipientUserId == null),
      'Exactly one of conversationId and recipientUserId',
    );
    final session = _store.session;
    final request = pb.SendMessageRequest(
      idempotencyKey: idempotencyKey,
      text: text,
    );
    if (conversationId != null) request.conversationId = conversationId;
    if (recipientUserId != null) request.recipientUserId = recipientUserId;
    final response = await _gate.run(
      () => _apiClient.messaging.sendMessage(request),
    );
    await _store.applySent(
      response.message,
      response.hasConversation() ? response.conversation : null,
      session: session,
    );
    return response;
  }

  /// Marks the conversation read (call only with `unread_count > 0`). Not
  /// globally off is enough. The cached unread count drops to 0.
  Future<void> markConversationRead({
    required String idempotencyKey,
    required String conversationId,
  }) async {
    final session = _store.session;
    await _gate.runRead(
      () => _apiClient.messaging.markConversationRead(
        pb.MarkConversationReadRequest(
          idempotencyKey: idempotencyKey,
          conversationId: conversationId,
        ),
      ),
    );
    await _store.markConversationRead(conversationId, session: session);
  }

  /// Accepts a message request. Per caller (and the peer: the server answers
  /// CANNOT_MESSAGE when the peer is outside the rollout). The cached
  /// conversation moves to the inbox.
  Future<void> acceptMessageRequest({
    required String idempotencyKey,
    required String conversationId,
  }) async {
    final session = _store.session;
    final wasRequest = await _isRequest(conversationId);
    await _gate.run(
      () => _apiClient.messaging.acceptMessageRequest(
        pb.AcceptMessageRequestRequest(
          idempotencyKey: idempotencyKey,
          conversationId: conversationId,
        ),
      ),
    );
    await _store.markConversationAccepted(conversationId, session: session);
    if (wasRequest) await _store.adjustRequestCount(-1, session: session);
    _notifyConversationsChanged();
  }

  /// Deletes the conversation for the caller only (also "delete request").
  /// Not globally off is enough. Everything cached for it is removed.
  Future<void> deleteConversation({
    required String idempotencyKey,
    required String conversationId,
  }) async {
    final session = _store.session;
    final wasRequest = await _isRequest(conversationId);
    await _gate.runRead(
      () => _apiClient.messaging.deleteConversation(
        pb.DeleteConversationRequest(
          idempotencyKey: idempotencyKey,
          conversationId: conversationId,
        ),
      ),
    );
    await _store.removeConversation(conversationId);
    if (wasRequest) await _store.adjustRequestCount(-1, session: session);
    _notifyConversationsChanged();
  }

  /// Whether [conversationId] is cached in the REQUESTS folder (so accepting
  /// or deleting it lowers the persisted request count).
  Future<bool> _isRequest(String conversationId) async =>
      (await _store.conversation(conversationId))?.folder ==
      Folder.FOLDER_REQUESTS;

  // --- internals -----------------------------------------------------------

  int get _effectivePageSize => _pageSize <= 0 ? 20 : math.min(_pageSize, 50);

  Future<pb.ListConversationsResponse?> _listConversationsUnlessRejected(
    Folder folder,
    String field, {
    String sinceToken = '',
    String pageToken = '',
  }) async {
    try {
      return await _listConversations(
        folder,
        sinceToken: sinceToken,
        pageToken: pageToken,
      );
    } on ValidationException catch (error) {
      if (error.field == field) return null;
      rethrow;
    }
  }

  /// One ListConversations RPC; at most one token may be set.
  Future<pb.ListConversationsResponse> _listConversations(
    Folder folder, {
    String sinceToken = '',
    String pageToken = '',
  }) {
    return _readCall(
      () => _apiClient.messaging.listConversations(
        pb.ListConversationsRequest(
          folder: folder,
          pageSize: _pageSize,
          sinceToken: sinceToken,
          pageToken: pageToken,
        ),
      ),
    );
  }

  Future<pb.ListMessagesResponse?> _listMessagesUnlessRejected(
    String conversationId,
    String field, {
    String sinceToken = '',
    String pageToken = '',
  }) async {
    try {
      return await _listMessages(
        conversationId,
        sinceToken: sinceToken,
        pageToken: pageToken,
      );
    } on ValidationException catch (error) {
      if (error.field == field) return null;
      rethrow;
    }
  }

  /// One ListMessages RPC; at most one token may be set.
  Future<pb.ListMessagesResponse> _listMessages(
    String conversationId, {
    String sinceToken = '',
    String pageToken = '',
  }) {
    return _readCall(
      () => _apiClient.messaging.listMessages(
        pb.ListMessagesRequest(
          conversationId: conversationId,
          pageSize: _pageSize,
          sinceToken: sinceToken,
          pageToken: pageToken,
        ),
      ),
    );
  }

  /// A list read: held while the shared RATE_LIMITED hold is set, and a
  /// RATE_LIMITED answer is recorded in it.
  Future<T> _readCall<T>(Future<T> Function() call) async {
    final held = _hold.check();
    if (held != null) throw held;
    try {
      return await _gate.runRead(call);
    } on RateLimitedException catch (error) {
      _hold.record(error);
      rethrow;
    }
  }

  Future<T> _single<T>(String op, Future<T> Function() body) {
    final running = _inflight[op];
    if (running != null) return running as Future<T>;
    final future = _tail.catchError((Object _) {}).then((_) => body());
    _inflight[op] = future;
    _tail = future.then<void>((_) {}, onError: (Object _) {});
    future.whenComplete(() {
      if (identical(_inflight[op], future)) _inflight.remove(op);
    }).ignore();
    return future;
  }
}

class _ThreadRefresh {
  const _ThreadRefresh(this.snapshot, this.newMessages);
  final ThreadSnapshot snapshot;
  final int newMessages;
}
