import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:uuid/uuid.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;
import '../../../../gen/dzeroth/messaging/v1/messaging.pbenum.dart';
import '../../data/messaging_repository.dart';
import '../../data/messaging_store.dart';
import '../../domain/conversation_id.dart';
import '../../domain/e2ee/encrypted_messaging.dart';
import '../../domain/thread_poller.dart';
import '../widgets/request_banner.dart' show isSentRequest;

export '../../domain/conversation_id.dart' show isConversationId;

enum ThreadStatus {
  /// Nothing cached yet and the first fetch is running.
  loading,

  /// [ThreadState.messages] may be shown (possibly empty).
  ready,

  /// Nothing cached and the fetch failed: [ThreadState.error] blocks.
  error,

  /// Malformed id, or NOT_FOUND (not a participant, unknown, deleted): one
  /// message for all of them, so none can be told apart.
  unavailable,
}

/// What the conversation screen renders. Plain immutable class.
@immutable
class ThreadState {
  const ThreadState({
    this.status = ThreadStatus.loading,
    this.messages = const [],
    this.conversation,
    this.hasMore = false,
    this.refreshing = false,
    this.loadingMore = false,
    this.loadMoreFailed = false,
    this.pendingNew = 0,
    this.peerBlocked = false,
    this.deleting = false,
    this.accepting = false,
    this.cannotMessage = false,
    this.error,
    this.notice,
    this.encrypted = false,
    this.entries = const [],
    this.security,
    this.encryptedHasMore = false,
    this.resetting = false,
    this.resetError,
    this.mls = false,
    this.knownPlain = false,
    this.vaultBlocked = false,
  });

  final ThreadStatus status;

  /// This thread is rendered from [entries] (the port's stream). Never goes
  /// back to false for the cubit's lifetime.
  final bool encrypted;

  /// The decrypted rows, newest first; empty unless [encrypted]. Readable
  /// text: this class defines no `toString`.
  final List<ThreadEntry> entries;

  /// Null until the first `EncryptedThread`.
  final ConversationSecurity? security;
  final bool encryptedHasMore;

  /// `resetConversation` is in flight.
  final bool resetting;

  /// Why the last reset failed: a typed [AppException] or a
  /// [ResetRefusedException], never text. The screen shows it once.
  final Object? resetError;

  /// The conversation is known to be encrypted (the `isMls` latch).
  final bool mls;

  /// A header said NONE and nothing ever said MLS: known to be plaintext.
  /// UNSPECIFIED is unknown, never "not encrypted".
  final bool knownPlain;

  /// There is no port, or the vault on this device is not usable.
  final bool vaultBlocked;

  /// The header says MLS but there is no port or no usable vault (R11).
  bool get encryptedNoVault => mls && vaultBlocked;

  /// The messages on screen, newest first. While the reader is scrolled up
  /// this is held back from the latest (see [pendingNew]).
  final List<pb.Message> messages;

  /// The header (peer, `can_reply`, state) once ListMessages answered it.
  final pb.Conversation? conversation;
  final bool hasMore;
  final bool refreshing;
  final bool loadingMore;
  final bool loadMoreFailed;

  /// Messages that arrived while the reader was scrolled up and are not in
  /// [messages] yet: the "New messages" pill.
  final int pendingNew;

  /// The caller blocked the peer from this screen: read-only from now on.
  final bool peerBlocked;
  final bool deleting;

  /// AcceptMessageRequest is in flight: the request banner is busy.
  final bool accepting;

  /// A send was refused with CANNOT_MESSAGE: read-only from now on,
  /// without waiting for a header refresh.
  final bool cannotMessage;

  /// Blocking error (nothing cached).
  final AppException? error;

  /// Non-blocking error over the cached messages (a refresh or poll failed).
  final AppException? notice;

  bool get hasMessages => messages.isNotEmpty;

  /// True when the server said so (`can_reply` false: either side blocks the
  /// other, or the peer's account is gone) or the caller just blocked. With
  /// no header yet it is false: nothing is announced before it is known.
  bool get readOnly =>
      peerBlocked ||
      cannotMessage ||
      (conversation != null && !conversation!.canReply);

  ThreadState copyWith({
    ThreadStatus? status,
    List<pb.Message>? messages,
    pb.Conversation? conversation,
    bool? hasMore,
    bool? refreshing,
    bool? loadingMore,
    bool? loadMoreFailed,
    int? pendingNew,
    bool? peerBlocked,
    bool? deleting,
    bool? accepting,
    bool? cannotMessage,
    Object? error = _keep,
    Object? notice = _keep,
    bool? encrypted,
    List<ThreadEntry>? entries,
    ConversationSecurity? security,
    bool? encryptedHasMore,
    bool? resetting,
    Object? resetError = _keep,
    bool? mls,
    bool? knownPlain,
    bool? vaultBlocked,
  }) {
    return ThreadState(
      status: status ?? this.status,
      messages: messages ?? this.messages,
      conversation: conversation ?? this.conversation,
      hasMore: hasMore ?? this.hasMore,
      refreshing: refreshing ?? this.refreshing,
      loadingMore: loadingMore ?? this.loadingMore,
      loadMoreFailed: loadMoreFailed ?? this.loadMoreFailed,
      pendingNew: pendingNew ?? this.pendingNew,
      peerBlocked: peerBlocked ?? this.peerBlocked,
      deleting: deleting ?? this.deleting,
      accepting: accepting ?? this.accepting,
      cannotMessage: cannotMessage ?? this.cannotMessage,
      error: identical(error, _keep) ? this.error : error as AppException?,
      notice: identical(notice, _keep) ? this.notice : notice as AppException?,
      encrypted: encrypted ?? this.encrypted,
      entries: entries ?? this.entries,
      security: security ?? this.security,
      encryptedHasMore: encryptedHasMore ?? this.encryptedHasMore,
      resetting: resetting ?? this.resetting,
      resetError: identical(resetError, _keep) ? this.resetError : resetError,
      mls: mls ?? this.mls,
      knownPlain: knownPlain ?? this.knownPlain,
      vaultBlocked: vaultBlocked ?? this.vaultBlocked,
    );
  }
}

const Object _keep = Object();

/// Drives one conversation over [MessagingRepository] and a [ThreadPoller]
///Those two are its only dependencies.
///
/// - [load] renders the cache at once, starts the poller (which does not pull
///   by itself) and refreshes once.
/// - [pull] is what the poller calls (`pull: cubit.pull`): the repository's
///   `since` poll, then the cache re-read. A RATE_LIMITED answer is rethrown
///   so the poller records the hold and stops pulling.
/// - Reader at the bottom: new messages join [ThreadState.messages] at once.
///   Scrolled up ([setAtBottom] false): they are held back and counted in
///   [ThreadState.pendingNew] until [showNew], so nothing jumps.
/// - Mark read: on open and when messages from the peer arrive while
///   [setVisible] is true, and only when the unread count is above 0. One
///   idempotency key per attempt, reused if it failed.
/// - [setVisible], [noteInput] and [onPush] are forwarded to the poller.
class ThreadCubit extends Cubit<ThreadState> {
  ThreadCubit({
    required MessagingRepository repository,
    required ThreadPoller poller,
    required this.conversationId,
    this.onUnexpectedError,
    this.onOpenedUnread,
    Uuid? uuid,
    EncryptedMessaging? encrypted,
    bool Function()? vaultUsable,
  }) : _repository = repository,
       _poller = poller,
       _port = encrypted,
       _vaultUsable = vaultUsable,
       _uuid = uuid ?? const Uuid(),
       super(
         isConversationId(conversationId)
             ? const ThreadState()
             : const ThreadState(status: ThreadStatus.unavailable),
       );

  final MessagingRepository _repository;
  final ThreadPoller _poller;
  final Uuid _uuid;
  final String conversationId;
  final void Function(Object error, StackTrace stack)? onUnexpectedError;

  /// Called once, when the conversation is first seen with unread messages on
  /// open (the Messages badge drops it). Not for messages that arrive
  /// while the thread is open.
  final void Function(String conversationId)? onOpenedUnread;
  bool _reportedUnread = false;

  /// The newest messages the repository holds (held back or not).
  List<pb.Message> _latest = const [];

  /// Sort key of the newest message seen so far; later ones are "new".
  String? _newestKey;
  bool _atBottom = true;
  bool _visible = true;
  int _unread = 0;
  bool _marking = false;
  String? _markKey;
  String? _deleteKey;
  String? _acceptKey;
  StreamSubscription<void>? _changes;

  final EncryptedMessaging? _port;
  final bool Function()? _vaultUsable;
  StreamSubscription<EncryptedThread>? _watch;

  /// The `isMls` latch: once true it stays true for the cubit's lifetime.
  bool _mls = false;

  /// A header said NONE at least once.
  bool _sawNone = false;

  /// The cached inbox row was ever seen marked encrypted (5a keeps the marker
  /// sticky; a later server answer never clears it).
  bool _rowMarked = false;

  /// Whether the conversation is end-to-end encrypted: true as soon as any
  /// sign says so, then for good. False means unknown or plaintext, see
  /// [ThreadState.knownPlain]. Never read from the port's stream.
  bool get isMls => _mls;

  /// Encrypted messaging is present for this thread (a port was given).
  bool get hasPort => _port != null;

  /// The vault became (un)usable: re-evaluates the rules. The screen calls it
  /// when the vault status changes.
  void refreshVault() => _reevaluate();

  static bool _rowEncrypted(pb.Conversation? c) =>
      c != null && c.hasLastMessage() && c.lastMessage.encrypted;

  /// Latches `isMls` from every sign this cubit holds, then subscribes to the
  /// port when the thread is to be rendered from it. Evaluated on every data
  /// path (cache, refresh, poll, row follow, vault change). `hasLocal` is read
  /// each time until it answers true, because it is false before the vault is
  /// ready.
  void _reevaluate() {
    if (isClosed) return;
    final port = _port;
    final header = state.conversation;
    if (header != null &&
        header.encryption ==
            ConversationEncryption.CONVERSATION_ENCRYPTION_NONE) {
      _sawNone = true;
    }
    if (!_mls) {
      _mls =
          _rowMarked ||
          (header != null &&
              header.encryption ==
                  ConversationEncryption.CONVERSATION_ENCRYPTION_MLS) ||
          _rowEncrypted(header) ||
          _latest.any((m) => m.mlsGeneration.toInt() > 0) ||
          (port != null && port.hasLocal(conversationId));
    }
    final usable = port != null && (_vaultUsable?.call() ?? true);
    final encrypted = state.encrypted || (_mls && usable);
    final knownPlain = _sawNone && !_mls;
    if (_mls != state.mls ||
        knownPlain != state.knownPlain ||
        !usable != state.vaultBlocked ||
        encrypted != state.encrypted) {
      emit(
        state.copyWith(
          mls: _mls,
          knownPlain: knownPlain,
          vaultBlocked: !usable,
          encrypted: encrypted,
        ),
      );
    }
    if (encrypted && port != null && _watch == null) {
      _watch = port
          .watchThread(ThreadRef.conversation(conversationId))
          .listen(
            _onEncryptedThread,
            onError: (Object _, StackTrace stack) =>
                onUnexpectedError?.call(StateError('watchThread'), stack),
          );
    }
  }

  void _onEncryptedThread(EncryptedThread thread) {
    if (isClosed) return;
    emit(
      state.copyWith(
        entries: thread.entries,
        security: thread.security,
        encryptedHasMore: thread.hasMore,
      ),
    );
  }

  /// Opens the screen: cache first, then one refresh.
  Future<void> load() async {
    if (!isConversationId(conversationId)) return;
    // The header follows the cached row, so a sent request's waiting
    // note goes when an Inbox refresh brings the accept. Local re-read only.
    _changes ??= _repository.conversationsChanged.listen(
      (_) => unawaited(_followRow()),
    );
    final ThreadSnapshot cached;
    try {
      cached = await _repository.cachedThread(conversationId);
    } on Object catch (error, stack) {
      // A broken disk must not block the network path.
      onUnexpectedError?.call(error, stack);
      if (isClosed) return;
      _poller.start();
      await _refresh(open: true);
      return;
    }
    if (isClosed) return;
    if (cached.messages.isNotEmpty || cached.conversation != null) {
      _apply(cached, open: true);
      emit(state.copyWith(status: ThreadStatus.ready));
    }
    // Also with nothing cached: the vault may know the conversation.
    _reevaluate();
    _poller.start();
    await _refresh(open: true);
  }

  /// Takes `state`, `folder` and `can_reply` from the cached list row into the
  /// header when they differ. The row is what ListConversations wrote,
  /// so it carries REQUEST for a sent request and ACCEPTED after the accept.
  /// Nothing else on the header moves, and nothing is fetched.
  Future<void> _followRow() async {
    if (isClosed || state.conversation == null || state.deleting) return;
    final pb.Conversation? row;
    try {
      row = await _repository.cachedConversation(conversationId);
    } on Object catch (error, stack) {
      onUnexpectedError?.call(error, stack);
      return;
    }
    final header = state.conversation;
    if (isClosed || row == null || header == null) return;
    if (_rowEncrypted(row) && !_rowMarked) {
      _rowMarked = true;
      _reevaluate();
    }
    if (row.state == ConversationState.CONVERSATION_STATE_UNSPECIFIED ||
        row.folder == Folder.FOLDER_UNSPECIFIED) {
      return;
    }
    if (row.state == header.state &&
        row.folder == header.folder &&
        row.canReply == header.canReply) {
      return;
    }
    emit(
      state.copyWith(
        conversation: header.deepCopy()
          ..state = row.state
          ..folder = row.folder
          ..canReply = row.canReply,
      ),
    );
  }

  /// Retry after a blocking error.
  Future<void> refresh() => _refresh(open: true);

  Future<void> _refresh({required bool open}) async {
    if (isClosed || state.refreshing) return;
    final limited = _repository.rateLimitedFor();
    if (limited != null) {
      _failed(limited);
      return;
    }
    emit(state.copyWith(refreshing: true));
    try {
      final snapshot = await _repository.refreshThread(conversationId);
      if (isClosed) return;
      _apply(snapshot, open: open);
      emit(
        state.copyWith(
          status: ThreadStatus.ready,
          refreshing: false,
          error: null,
          notice: null,
        ),
      );
      unawaited(_markReadIfNeeded());
    } on AppException catch (error, stack) {
      if (isClosed) return;
      if (error is UnknownApiException) onUnexpectedError?.call(error, stack);
      emit(state.copyWith(refreshing: false));
      _failed(error);
    }
  }

  /// One poll for [ThreadPoller] (`pull: cubit.pull`).
  ///
  /// Not-found ends the screen's polling ("isn't available"); a RATE_LIMITED
  /// answer is rethrown so the poller records the hold; any other failure is
  /// a notice over the cached messages, never an error page.
  Future<PollResult> pull() async {
    if (isClosed) return const PollResult(newMessages: false);
    try {
      final result = await _repository.pollThread(conversationId);
      if (isClosed) return result;
      if (result.newMessages || state.status != ThreadStatus.ready) {
        final snapshot = await _repository.cachedThread(conversationId);
        if (isClosed) return result;
        _apply(snapshot, open: state.status != ThreadStatus.ready);
        emit(state.copyWith(status: ThreadStatus.ready, error: null));
      }
      if (state.notice != null) emit(state.copyWith(notice: null));
      unawaited(_markReadIfNeeded());
      return result;
    } on NotFoundException {
      if (!isClosed) _becameUnavailable();
      return const PollResult(newMessages: false);
    } on RateLimitedException catch (error) {
      if (!isClosed) emit(state.copyWith(notice: error));
      rethrow;
    } on AppException catch (error, stack) {
      if (error is UnknownApiException) onUnexpectedError?.call(error, stack);
      if (!isClosed) emit(state.copyWith(notice: error));
      return const PollResult(newMessages: false);
    }
  }

  void _failed(AppException error) {
    if (error is NotFoundException) {
      _becameUnavailable();
    } else if (state.hasMessages || state.conversation != null) {
      emit(state.copyWith(notice: error));
    } else {
      emit(state.copyWith(status: ThreadStatus.error, error: error));
    }
  }

  void _becameUnavailable() {
    _poller.stop();
    emit(state.copyWith(status: ThreadStatus.unavailable));
  }

  /// Merges [snapshot] into the state. [open] is a load or retry: the header's
  /// unread count counts then; a poll counts only the peer's new messages.
  void _apply(ThreadSnapshot snapshot, {required bool open}) {
    final messages = snapshot.messages;
    final newestKey = _newestKey;
    var arrivedFromPeer = 0;
    if (newestKey != null) {
      for (final m in messages) {
        if (messageSortKey(m).compareTo(newestKey) <= 0) break;
        if (!m.fromSelf) arrivedFromPeer++;
      }
    }
    if (messages.isNotEmpty) {
      final top = messageSortKey(messages.first);
      if (newestKey == null || top.compareTo(newestKey) > 0) _newestKey = top;
    }
    _unread += arrivedFromPeer;
    final conversation = snapshot.conversation;
    if (open && conversation != null) {
      // A first page's count is the server's, 0 included (read on another
      // device): it replaces what the cached row said, so a stale cached
      // unread row sends no needless mark-read. Any other snapshot keeps the
      // larger of the two.
      _unread = snapshot.firstPageHeader
          ? conversation.unreadCount.toInt()
          : math.max(_unread, conversation.unreadCount.toInt());
      // A request never counts toward the badge.
      if (conversation.unreadCount.toInt() > 0 &&
          conversation.folder != Folder.FOLDER_REQUESTS &&
          !_reportedUnread) {
        _reportedUnread = true;
        onOpenedUnread?.call(conversationId);
      }
    }
    _latest = messages;

    // A peer message that arrives in a request the caller sent can
    // only be the recipient's reply, and that reply accepts the request
    //So the request is answered: ACCEPTED here and in
    // the cached row. A cold open never counts (arrivedFromPeer is 0 then).
    var shownConversation = conversation;
    if (arrivedFromPeer > 0) {
      final current = conversation ?? state.conversation;
      if (current != null && isSentRequest(current)) {
        shownConversation = current.deepCopy()
          ..state = ConversationState.CONVERSATION_STATE_ACCEPTED;
        unawaited(_noteAnswered());
      }
    }

    // `peer_read_at` comes with a first page only: a poll or a send that
    // rewrote the cached header must not take "Seen" away. A first page is
    // the server's word, so it replaces what was shown.
    final before = state.conversation;
    if (!snapshot.firstPageHeader &&
        shownConversation != null &&
        !shownConversation.hasPeerReadAt() &&
        before != null &&
        before.hasPeerReadAt()) {
      shownConversation = shownConversation.deepCopy()
        ..peerReadAt = before.peerReadAt;
    }

    // Held back while the reader is scrolled up, so the list does not move.
    var shown = messages;
    var pending = 0;
    if (!_atBottom && state.messages.isNotEmpty) {
      final topId = state.messages.first.id;
      final index = messages.indexWhere((m) => m.id == topId);
      if (index > 0) {
        shown = messages.sublist(index);
        pending = index;
      }
    }
    emit(
      state.copyWith(
        messages: shown,
        pendingNew: pending,
        conversation: shownConversation,
        hasMore: snapshot.hasMore,
      ),
    );
    _reevaluate();
  }

  Future<void> _noteAnswered() async {
    try {
      await _repository.noteSentRequestAnswered(conversationId);
    } on Object catch (error, stack) {
      onUnexpectedError?.call(error, stack);
    }
  }

  /// The reader reached (or left) the newest message. Reaching it shows the
  /// held-back ones.
  void setAtBottom(bool atBottom) {
    if (_atBottom == atBottom) return;
    _atBottom = atBottom;
    if (atBottom) showNew();
  }

  /// The "New messages" pill: shows what was held back.
  void showNew() {
    if (isClosed || state.pendingNew == 0) return;
    emit(state.copyWith(messages: _latest, pendingNew: 0));
  }

  /// The screen is visible (app resumed and this route on top). Hidden stops
  /// all polling; visible again pulls at once (the poller's resume).
  void setVisible(bool visible) {
    if (_visible == visible) return;
    _visible = visible;
    _poller.setVisible(visible);
    if (visible) unawaited(_markReadIfNeeded());
  }

  /// A tap or scroll: keeps the thread "hot" (15 s polls).
  void noteInput() => _poller.noteInput();

  /// A push arrived for this conversation: pull at once (when visible).
  void onPush() => _poller.onPush();

  /// Scroll older: the page below the oldest cached message.
  Future<void> loadMore() async {
    if (state.encrypted) {
      if (isClosed ||
          state.loadingMore ||
          !state.encryptedHasMore ||
          state.loadMoreFailed) {
        return;
      }
      await _loadOlderEncrypted();
      return;
    }
    if (isClosed ||
        state.loadingMore ||
        state.refreshing ||
        !state.hasMore ||
        state.loadMoreFailed) {
      return;
    }
    await _loadMore();
  }

  /// The footer's inline retry.
  Future<void> retryLoadMore() async {
    if (isClosed || state.loadingMore) return;
    if (state.encrypted) {
      await _loadOlderEncrypted();
      return;
    }
    await _loadMore();
  }

  /// One more page from the vault; the stream re-emits the wider window.
  Future<void> _loadOlderEncrypted() async {
    final port = _port;
    if (port == null) return;
    emit(state.copyWith(loadingMore: true, loadMoreFailed: false));
    try {
      await port.loadOlder(ThreadRef.conversation(conversationId));
      if (!isClosed) emit(state.copyWith(loadingMore: false));
    } on Object catch (_, stack) {
      onUnexpectedError?.call(StateError('loadOlder'), stack);
      if (!isClosed) {
        emit(state.copyWith(loadingMore: false, loadMoreFailed: true));
      }
    }
  }

  /// Reset encryption for this conversation (R6 step 5, M5, stuck member):
  /// asks the port once. A failure is kept as [ThreadState.resetError], typed,
  /// never as text. Refused here for a sent request or when the pipeline does
  /// not offer it, so a stale tap does nothing.
  Future<void> resetEncryption() async {
    final port = _port;
    final security = state.security;
    if (isClosed ||
        port == null ||
        security == null ||
        !security.canReset ||
        security.sentRequest ||
        state.resetting) {
      return;
    }
    emit(state.copyWith(resetting: true, resetError: null));
    try {
      await port.resetConversation(conversationId);
      if (!isClosed) emit(state.copyWith(resetting: false));
    } on Object catch (error, stack) {
      final typed = error is AppException || error is ResetRefusedException;
      if (!typed) {
        onUnexpectedError?.call(StateError('resetConversation'), stack);
      }
      if (!isClosed) {
        emit(
          state.copyWith(
            resetting: false,
            resetError: typed ? error : StateError('resetConversation'),
          ),
        );
      }
    }
  }

  Future<void> _loadMore() async {
    final limited = _repository.rateLimitedFor();
    if (limited != null) {
      emit(state.copyWith(loadMoreFailed: true));
      return;
    }
    emit(state.copyWith(loadingMore: true, loadMoreFailed: false));
    try {
      final snapshot = await _repository.loadOlderMessages(conversationId);
      if (isClosed) return;
      _apply(snapshot, open: false);
      emit(state.copyWith(loadingMore: false));
    } on AppException catch (error, stack) {
      if (isClosed) return;
      if (error is NotFoundException) {
        emit(state.copyWith(loadingMore: false));
        _becameUnavailable();
        return;
      }
      if (error is UnknownApiException) onUnexpectedError?.call(error, stack);
      emit(state.copyWith(loadingMore: false, loadMoreFailed: true));
    }
  }

  Future<void> _markReadIfNeeded() async {
    if (isClosed || !_visible || _marking || _unread <= 0) return;
    if (state.status != ThreadStatus.ready) return;
    _marking = true;
    final marked = _unread;
    try {
      await _repository.markConversationRead(
        idempotencyKey: _markKey ??= _uuid.v4(),
        conversationId: conversationId,
      );
      _markKey = null;
      _unread = math.max(0, _unread - marked);
    } on AppException catch (error, stack) {
      // Not worth a banner: the count stays and the next arrival or resume
      // tries again with the same key.
      if (error is UnknownApiException) onUnexpectedError?.call(error, stack);
      _marking = false;
      return;
    }
    _marking = false;
    // More arrived while the call was in flight.
    if (!isClosed && _unread > 0) unawaited(_markReadIfNeeded());
  }

  /// The caller blocked the peer from this screen (the graph flow ran): the
  /// thread is read-only now, without waiting for a header refresh. A blocked
  /// requester's row leaves the cached Requests list at once (no RPC;
  /// the repository ignores a conversation that is not a cached request).
  void markPeerBlocked() {
    if (isClosed || state.peerBlocked) return;
    emit(state.copyWith(peerBlocked: true));
    unawaited(_dropBlockedRequest());
  }

  Future<void> _dropBlockedRequest() async {
    try {
      await _repository.dropBlockedRequest(conversationId);
    } on Object catch (error, stack) {
      onUnexpectedError?.call(error, stack);
    }
  }

  /// A send was refused with CANNOT_MESSAGE: the thread
  /// is read-only from now on (one answer for every cause, so none shows).
  void markCannotMessage() {
    if (isClosed || state.cannotMessage) return;
    emit(state.copyWith(cannotMessage: true));
  }

  /// A send succeeded: the repository cached the message, so read it
  /// back and show it at once, deduped by id with what is on screen. The
  /// screen scrolls to the newest on send, so nothing is held back.
  Future<void> noteSent() async {
    if (isClosed) return;
    try {
      final snapshot = await _repository.cachedThread(conversationId);
      if (isClosed) return;
      setAtBottom(true);
      _apply(snapshot, open: false);
    } on Object catch (error, stack) {
      onUnexpectedError?.call(error, stack);
    }
  }

  /// Deletes the conversation for the caller (also "delete request"). Returns
  /// null on success, else the failure to tell the user about; the same
  /// idempotency key is reused if the user retries after a failure. A success
  /// clears the key: the server replays a repeated key as a no-op, so a later
  /// real delete (the conversation came back with a new message) needs its
  /// own. NOT_FOUND counts as done (the repository cleans the cache).
  Future<AppException?> deleteConversation() async {
    if (isClosed || state.deleting || state.accepting) return null;
    emit(state.copyWith(deleting: true));
    try {
      await _repository.deleteConversation(
        idempotencyKey: _deleteKey ??= _uuid.v4(),
        conversationId: conversationId,
      );
      _deleteKey = null;
      _poller.stop();
      if (!isClosed) emit(state.copyWith(deleting: false));
      return null;
    } on AppException catch (error, stack) {
      if (error is UnknownApiException) onUnexpectedError?.call(error, stack);
      if (!isClosed) emit(state.copyWith(deleting: false));
      return error;
    }
  }

  /// Accepts the request this conversation is. Returns null on
  /// success, else the failure to tell the user about; the same idempotency
  /// key is reused if the user retries. On success the header becomes an
  /// ACCEPTED inbox conversation at once (what the repository just wrote to the
  /// cache), so the banner goes and the composer appears with no refetch.
  Future<AppException?> acceptRequest() async {
    if (isClosed || state.accepting || state.deleting) return null;
    emit(state.copyWith(accepting: true));
    try {
      await _repository.acceptMessageRequest(
        idempotencyKey: _acceptKey ??= _uuid.v4(),
        conversationId: conversationId,
      );
      _acceptKey = null;
      if (isClosed) return null;
      final header = state.conversation;
      emit(
        state.copyWith(
          accepting: false,
          conversation: header == null
              ? null
              : (header.deepCopy()
                  ..state = ConversationState.CONVERSATION_STATE_ACCEPTED
                  ..folder = Folder.FOLDER_INBOX),
        ),
      );
      return null;
    } on AppException catch (error, stack) {
      if (error is UnknownApiException) onUnexpectedError?.call(error, stack);
      if (isClosed) return error;
      emit(state.copyWith(accepting: false));
      // The rule: NOT_FOUND means the conversation is not available.
      if (error is NotFoundException) _becameUnavailable();
      return error;
    }
  }

  @override
  Future<void> close() {
    unawaited(_changes?.cancel());
    unawaited(_watch?.cancel());
    _watch = null;
    _poller.dispose();
    return super.close();
  }
}
