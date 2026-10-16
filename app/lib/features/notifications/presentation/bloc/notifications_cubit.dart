import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:uuid/uuid.dart';

import '../../../../core/network/app_exception.dart';
import '../../data/notifications_repository.dart';
import '../../data/notifications_store.dart';
import 'unread_badge_cubit.dart';

/// Automatic refreshes happen at most this often (ADR-0004 section 7).
const kNotificationsRefreshInterval = Duration(seconds: 60);

enum NotificationsStatus {
  /// Nothing cached yet and the first fetch is running.
  loading,

  /// [NotificationsState.entries] may be shown (possibly empty).
  ready,

  /// Nothing cached and the fetch failed: [NotificationsState.error] blocks.
  error,
}

/// What the notifications screen renders. Plain immutable class.
@immutable
class NotificationsState {
  const NotificationsState({
    this.status = NotificationsStatus.loading,
    this.entries = const [],
    this.hasMore = false,
    this.refreshing = false,
    this.loadingMore = false,
    this.loadMoreFailed = false,
    this.loadingGapKey,
    this.highlightSince,
    this.error,
    this.notice,
  });

  final NotificationsStatus status;

  /// Newest first: notifications and gap markers.
  final List<NotificationEntry> entries;
  final bool hasMore;
  final bool refreshing;
  final bool loadingMore;
  final bool loadMoreFailed;
  final String? loadingGapKey;

  /// Rows with `created_at` after this are drawn as unread. It is the
  /// `seen_at` from before this visit marked everything seen, so the user
  /// still sees what was new. Null = never marked seen (everything is new).
  final DateTime? highlightSince;

  /// Blocking error (nothing cached).
  final AppException? error;

  /// Non-blocking error over cached rows (refresh or page failed).
  final AppException? notice;

  bool get hasNotifications => entries.any((e) => !e.isGap);

  NotificationsState copyWith({
    NotificationsStatus? status,
    List<NotificationEntry>? entries,
    bool? hasMore,
    bool? refreshing,
    bool? loadingMore,
    bool? loadMoreFailed,
    Object? loadingGapKey = _keep,
    Object? highlightSince = _keep,
    Object? error = _keep,
    Object? notice = _keep,
  }) {
    return NotificationsState(
      status: status ?? this.status,
      entries: entries ?? this.entries,
      hasMore: hasMore ?? this.hasMore,
      refreshing: refreshing ?? this.refreshing,
      loadingMore: loadingMore ?? this.loadingMore,
      loadMoreFailed: loadMoreFailed ?? this.loadMoreFailed,
      loadingGapKey: identical(loadingGapKey, _keep)
          ? this.loadingGapKey
          : loadingGapKey as String?,
      highlightSince: identical(highlightSince, _keep)
          ? this.highlightSince
          : highlightSince as DateTime?,
      error: identical(error, _keep) ? this.error : error as AppException?,
      notice: identical(notice, _keep) ? this.notice : notice as AppException?,
    );
  }
}

const Object _keep = Object();

/// Drives the notifications list over [NotificationsRepository] (P6, ADR-0017).
///
/// - [load] renders the cache at once, then refreshes unless the list was
///   refreshed less than [kNotificationsRefreshInterval] ago.
/// - After a refresh shows rows newer than the server's `seen_at` (or the
///   badge is non-zero), mark-seen runs **once per refresh** with one
///   idempotency key per call; the badge is cleared locally, and the rows
///   stay highlighted for this visit ([NotificationsState.highlightSince]).
///   A mark-seen failure is silent: the list is the product, the mark is
///   bookkeeping, and its own daily cap must never become an error banner.
/// - Errors with nothing cached are blocking; otherwise a notice. A held
///   RATE_LIMITED answer skips automatic refreshes (no retry storm).
class NotificationsCubit extends Cubit<NotificationsState> {
  NotificationsCubit({
    required NotificationsRepository repository,
    required UnreadBadgeCubit badge,
    this.onUnexpectedError,
    Uuid? uuid,
  }) : _repository = repository,
       _badge = badge,
       _uuid = uuid ?? const Uuid(),
       super(const NotificationsState());

  final NotificationsRepository _repository;
  final UnreadBadgeCubit _badge;
  final Uuid _uuid;
  final void Function(Object error, StackTrace stack)? onUnexpectedError;

  DateTime? _serverSeenAt;
  bool _highlightSet = false;
  bool _marking = false;
  Timer? _pendingRefresh;

  /// Opens the screen: cache first, then (throttled) one refresh.
  Future<void> load() async {
    final cached = await _repository.cached();
    if (isClosed) return;
    _serverSeenAt = cached.seenAt;
    if (!_highlightSet && cached.seenAt != null) {
      _highlightSet = true;
      emit(state.copyWith(highlightSince: cached.seenAt));
    }
    emit(
      state.copyWith(
        status: cached.hasNotifications
            ? NotificationsStatus.ready
            : NotificationsStatus.loading,
        entries: cached.entries,
        hasMore: cached.hasMore,
      ),
    );
    final since = _repository.sinceRefresh;
    if (since != null && since < kNotificationsRefreshInterval) {
      if (state.status == NotificationsStatus.loading) {
        emit(state.copyWith(status: NotificationsStatus.ready));
      }
      unawaited(_markSeenIfNeeded());
      return;
    }
    await _refresh();
  }

  /// Pull-to-refresh and retry.
  Future<void> refresh() => _refresh();

  /// Resume or an FCM nudge: throttled, quiet.
  ///
  /// A nudge inside the throttle window is not dropped: one refresh is
  /// scheduled for when the window ends, so a push received right after a
  /// refresh still shows up without a pull.
  Future<void> refreshIfStale() async {
    if (isClosed || state.refreshing || state.loadingMore) return;
    if (_repository.rateLimitedFor() != null) return;
    final since = _repository.sinceRefreshAttempt;
    if (since != null && since < kNotificationsRefreshInterval) {
      _pendingRefresh ??= Timer(kNotificationsRefreshInterval - since, () {
        _pendingRefresh = null;
        unawaited(refreshIfStale());
      });
      return;
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
    emit(state.copyWith(refreshing: true));
    try {
      final snapshot = await _repository.refresh();
      if (isClosed) return;
      _apply(snapshot);
      emit(
        state.copyWith(
          status: NotificationsStatus.ready,
          refreshing: false,
          error: null,
          notice: null,
        ),
      );
      unawaited(_markSeenIfNeeded());
    } on AppException catch (error, stack) {
      if (isClosed) return;
      if (error is UnknownApiException) onUnexpectedError?.call(error, stack);
      emit(state.copyWith(refreshing: false));
      _failed(error);
    }
  }

  void _failed(AppException error) {
    if (state.hasNotifications) {
      emit(state.copyWith(notice: error));
    } else if (state.status == NotificationsStatus.loading ||
        state.status == NotificationsStatus.error) {
      emit(state.copyWith(status: NotificationsStatus.error, error: error));
    } else {
      emit(state.copyWith(notice: error));
    }
  }

  void _apply(NotificationsSnapshot snapshot) {
    // The highlight is the `seen_at` from before this visit marks anything
    // seen: fixed by the first answer (cache or network) that has one.
    if (!_highlightSet) {
      _highlightSet = true;
      emit(state.copyWith(highlightSince: snapshot.seenAt));
    }
    _serverSeenAt = snapshot.seenAt ?? _serverSeenAt;
    emit(state.copyWith(entries: snapshot.entries, hasMore: snapshot.hasMore));
  }

  /// Infinite scroll (the screen calls it near the end).
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
      final snapshot = await _repository.loadOlder();
      if (isClosed) return;
      _apply(snapshot);
      emit(state.copyWith(loadingMore: false));
    } on AppException catch (error, stack) {
      if (isClosed) return;
      if (error is UnknownApiException) onUnexpectedError?.call(error, stack);
      emit(state.copyWith(loadingMore: false, loadMoreFailed: true));
    }
  }

  /// Fills a refresh-gap row ("Show more").
  Future<void> fillGap(String gapItemKey) async {
    if (isClosed || state.loadingGapKey != null) return;
    emit(state.copyWith(loadingGapKey: gapItemKey, notice: null));
    try {
      final snapshot = await _repository.fillGap(gapItemKey);
      if (isClosed) return;
      _apply(snapshot);
      emit(state.copyWith(loadingGapKey: null));
    } on AppException catch (error, stack) {
      if (isClosed) return;
      if (error is UnknownApiException) onUnexpectedError?.call(error, stack);
      emit(state.copyWith(loadingGapKey: null, notice: error));
    }
  }

  /// Whether the newest cached row is newer than the server's `seen_at`.
  bool get _hasUnreadRows {
    final seen = _serverSeenAt;
    for (final entry in state.entries) {
      final n = entry.value;
      if (n == null || !n.hasCreatedAt()) continue;
      return seen == null || n.createdAt.toDateTime().isAfter(seen);
    }
    return false;
  }

  Future<void> _markSeenIfNeeded() async {
    if (isClosed || _marking) return;
    if (!_hasUnreadRows && _badge.state == 0) return;
    _marking = true;
    try {
      final seenAt = await _repository.markSeen(_uuid.v4());
      if (isClosed) return;
      if (seenAt != null) _serverSeenAt = seenAt;
      _badge.clear();
    } on UnknownApiException catch (error, stack) {
      onUnexpectedError?.call(error, stack);
    } on AppException {
      // Silent: see the class comment.
    } finally {
      _marking = false;
    }
  }

  @override
  Future<void> close() {
    _pendingRefresh?.cancel();
    return super.close();
  }
}
