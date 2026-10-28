import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;
import '../../../../gen/dzeroth/messaging/v1/messaging.pbenum.dart';
import '../../data/messaging_repository.dart';
import '../../data/messaging_store.dart';

/// Automatic refreshes (resume, a push) happen at most this often
/// (`flutter-feature` skill: auto-refresh at most every 60 s). Opening the
/// screen and a pull-to-refresh always refresh.
const kConversationsRefreshInterval = Duration(seconds: 60);

enum ConversationsStatus {
  /// Nothing cached yet and the first fetch is running.
  loading,

  /// [ConversationsState.conversations] may be shown (possibly empty).
  ready,

  /// Nothing cached and the fetch failed: [ConversationsState.error] blocks.
  error,
}

/// What the inbox renders. Plain immutable class.
@immutable
class ConversationsState {
  const ConversationsState({
    this.status = ConversationsStatus.loading,
    this.conversations = const [],
    this.hasMore = false,
    this.refreshing = false,
    this.loadingMore = false,
    this.loadMoreFailed = false,
    this.requestCount,
    this.error,
    this.notice,
  });

  final ConversationsStatus status;

  /// Most recent activity first.
  final List<pb.Conversation> conversations;
  final bool hasMore;
  final bool refreshing;
  final bool loadingMore;
  final bool loadMoreFailed;

  /// Pending message requests ("Message requests (N)"): the server sends it on
  /// a first INBOX page only; the repository persists the last one, so it is
  /// shown on a warm start and is null only before any was ever received.
  final int? requestCount;

  /// Blocking error (nothing cached).
  final AppException? error;

  /// Non-blocking error over cached rows (refresh or page failed).
  final AppException? notice;

  bool get hasConversations => conversations.isNotEmpty;

  ConversationsState copyWith({
    ConversationsStatus? status,
    List<pb.Conversation>? conversations,
    bool? hasMore,
    bool? refreshing,
    bool? loadingMore,
    bool? loadMoreFailed,
    Object? requestCount = _keep,
    Object? error = _keep,
    Object? notice = _keep,
  }) {
    return ConversationsState(
      status: status ?? this.status,
      conversations: conversations ?? this.conversations,
      hasMore: hasMore ?? this.hasMore,
      refreshing: refreshing ?? this.refreshing,
      loadingMore: loadingMore ?? this.loadingMore,
      loadMoreFailed: loadMoreFailed ?? this.loadMoreFailed,
      requestCount: identical(requestCount, _keep)
          ? this.requestCount
          : requestCount as int?,
      error: identical(error, _keep) ? this.error : error as AppException?,
      notice: identical(notice, _keep) ? this.notice : notice as AppException?,
    );
  }
}

const Object _keep = Object();

/// Drives one folder of the inbox over [MessagingRepository] (W7-14,
/// ADR-0027 D7, D14).
///
/// - [load] renders the cache at once, then refreshes (opening always does).
/// - [refreshIfStale] is for resume and a message push: throttled to one
///   attempt per [kConversationsRefreshInterval], quiet, and skipped while a
///   RATE_LIMITED hold is set. There is no timer and no periodic poll.
/// - [refresh] is pull-to-refresh, Retry and what the shell calls on a
///   message push (W7-19) when it wants an unthrottled pull.
/// - Errors with nothing cached are blocking; otherwise a notice over the
///   cached rows.
class ConversationsCubit extends Cubit<ConversationsState> {
  ConversationsCubit({
    required MessagingRepository repository,
    this.folder = Folder.FOLDER_INBOX,
    this.onUnexpectedError,
    DateTime Function()? now,
  }) : _repository = repository,
       _now = now ?? DateTime.now,
       super(const ConversationsState()) {
    // An accepted or deleted request (W7-18) changed the cache: re-read it,
    // no network.
    _changes = _repository.conversationsChanged.listen(
      (_) => unawaited(_reloadFromCache()),
    );
  }

  final MessagingRepository _repository;
  final DateTime Function() _now;

  /// The folder this cubit shows: INBOX, or REQUESTS for `/messages/requests`.
  final Folder folder;
  final void Function(Object error, StackTrace stack)? onUnexpectedError;

  DateTime? _lastAttempt;
  Timer? _pendingRefresh;
  StreamSubscription<void>? _changes;

  bool get _isInbox => folder == Folder.FOLDER_INBOX;

  /// Opens the screen: cache first, then one refresh.
  Future<void> load() async {
    final ConversationsSnapshot cached;
    try {
      cached = await _repository.cachedConversations(folder);
    } on Object catch (error, stack) {
      // A broken disk must not block the network path.
      onUnexpectedError?.call(error, stack);
      if (isClosed) return;
      await refresh();
      return;
    }
    if (isClosed) return;
    _apply(cached);
    emit(
      state.copyWith(
        status: cached.conversations.isEmpty
            ? ConversationsStatus.loading
            : ConversationsStatus.ready,
      ),
    );
    await refresh();
  }

  /// Pull-to-refresh, Retry, and a pull the shell triggers on a message push.
  Future<void> refresh() => _refresh();

  /// Resume or a message push: throttled, quiet.
  ///
  /// A call inside the throttle window is not dropped: one refresh is
  /// scheduled for when the window ends, so a push received right after a
  /// refresh still shows up without a pull. (A one-shot timer, not a poll.)
  Future<void> refreshIfStale() async {
    if (isClosed || state.refreshing || state.loadingMore) return;
    if (_repository.rateLimitedFor() != null) return;
    final last = _lastAttempt;
    if (last != null) {
      final since = _now().difference(last);
      if (since < kConversationsRefreshInterval) {
        _pendingRefresh ??= Timer(kConversationsRefreshInterval - since, () {
          _pendingRefresh = null;
          unawaited(refreshIfStale());
        });
        return;
      }
    }
    await _refresh();
  }

  Future<void> _refresh() async {
    if (isClosed || state.refreshing) return;
    final limited = _repository.rateLimitedFor();
    if (limited != null) {
      _failed(limited);
      return;
    }
    _lastAttempt = _now();
    emit(state.copyWith(refreshing: true));
    try {
      final result = await _repository.refreshConversations(folder);
      if (isClosed) return;
      _apply(result.snapshot);
      emit(
        state.copyWith(
          status: ConversationsStatus.ready,
          refreshing: false,
          // Only a first INBOX page carries the count; keep the last one
          // otherwise.
          requestCount: _isInbox && result.requestCount != null
              ? result.requestCount
              : state.requestCount,
          error: null,
          notice: null,
          loadMoreFailed: false,
        ),
      );
    } on AppException catch (error, stack) {
      if (isClosed) return;
      if (error is UnknownApiException) onUnexpectedError?.call(error, stack);
      emit(state.copyWith(refreshing: false));
      _failed(error);
    }
  }

  /// The cache changed under an open list (an accepted or deleted request):
  /// show what is on disk now, the persisted request count included. Nothing
  /// is fetched, and the status, notice and error stay as they are.
  Future<void> _reloadFromCache() async {
    if (isClosed || state.status != ConversationsStatus.ready) return;
    try {
      final cached = await _repository.cachedConversations(folder);
      if (!isClosed) _apply(cached);
    } on Object catch (error, stack) {
      onUnexpectedError?.call(error, stack);
    }
  }

  void _failed(AppException error) {
    if (state.hasConversations) {
      emit(state.copyWith(notice: error));
    } else if (state.status == ConversationsStatus.loading ||
        state.status == ConversationsStatus.error) {
      emit(state.copyWith(status: ConversationsStatus.error, error: error));
    } else {
      emit(state.copyWith(notice: error));
    }
  }

  void _apply(ConversationsSnapshot snapshot) {
    emit(
      state.copyWith(
        conversations: snapshot.conversations,
        hasMore: snapshot.hasMore,
        // The persisted last known count (INBOX only).
        requestCount: _isInbox && snapshot.requestCount != null
            ? snapshot.requestCount
            : state.requestCount,
      ),
    );
  }

  /// Prefetch paging (the screen calls it near the end).
  Future<void> loadMore() async {
    if (isClosed || state.loadingMore || state.refreshing || !state.hasMore) {
      return;
    }
    if (state.loadMoreFailed) return;
    await _loadMore();
  }

  /// The footer's inline retry.
  Future<void> retryLoadMore() async {
    if (isClosed || state.loadingMore) return;
    await _loadMore();
  }

  Future<void> _loadMore() async {
    if (_repository.rateLimitedFor() != null) {
      emit(state.copyWith(loadMoreFailed: true));
      return;
    }
    emit(state.copyWith(loadingMore: true, loadMoreFailed: false));
    try {
      final snapshot = await _repository.loadOlderConversations(folder);
      if (isClosed) return;
      _apply(snapshot);
      emit(state.copyWith(loadingMore: false));
    } on AppException catch (error, stack) {
      if (isClosed) return;
      if (error is UnknownApiException) onUnexpectedError?.call(error, stack);
      emit(state.copyWith(loadingMore: false, loadMoreFailed: true));
    }
  }

  @override
  Future<void> close() {
    _pendingRefresh?.cancel();
    unawaited(_changes?.cancel());
    return super.close();
  }
}
