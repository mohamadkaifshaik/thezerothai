import 'package:flutter/foundation.dart';

import '../../../../core/network/app_exception.dart';
import '../../data/timeline_store.dart';

enum TimelineStatus {
  /// Nothing cached yet and the first fetch is running.
  loading,

  /// [TimelineState.entries] may be shown (it can be empty: empty state).
  ready,

  /// Nothing cached and the fetch failed: [TimelineState.error] is blocking.
  error,
}

/// What a feed screen renders. Plain immutable class (no codegen).
@immutable
class TimelineState {
  const TimelineState({
    this.status = TimelineStatus.loading,
    this.entries = const [],
    this.hasMore = false,
    this.refreshing = false,
    this.loadingMore = false,
    this.loadMoreFailed = false,
    this.loadingGapKey,
    this.newPosts = 0,
    this.error,
    this.notice,
  });

  final TimelineStatus status;

  /// Visible rows, newest first: posts and gap markers. Posts held back for
  /// the "N new posts" pill, removed, or by a hidden author are not here.
  final List<TimelineEntry> entries;
  final bool hasMore;
  final bool refreshing;
  final bool loadingMore;

  /// The last older-page load failed; no automatic retry (no retry storm),
  /// the user taps Retry.
  final bool loadMoreFailed;

  /// The gap row ([TimelineEntry.itemKey]) being filled, if any.
  final String? loadingGapKey;

  /// Posts a refresh found that are not inserted yet (the pill).
  final int newPosts;

  /// Blocking error: only with [TimelineStatus.error] (nothing to show).
  final AppException? error;

  /// Non-blocking problem shown as a banner over the cached rows.
  final AppException? notice;

  bool get hasPosts => entries.any((e) => !e.isGap);

  TimelineState copyWith({
    TimelineStatus? status,
    List<TimelineEntry>? entries,
    bool? hasMore,
    bool? refreshing,
    bool? loadingMore,
    bool? loadMoreFailed,
    String? loadingGapKey,
    bool clearLoadingGap = false,
    int? newPosts,
    AppException? error,
    bool clearError = false,
    AppException? notice,
    bool clearNotice = false,
  }) => TimelineState(
    status: status ?? this.status,
    entries: entries ?? this.entries,
    hasMore: hasMore ?? this.hasMore,
    refreshing: refreshing ?? this.refreshing,
    loadingMore: loadingMore ?? this.loadingMore,
    loadMoreFailed: loadMoreFailed ?? this.loadMoreFailed,
    loadingGapKey: clearLoadingGap
        ? null
        : (loadingGapKey ?? this.loadingGapKey),
    newPosts: newPosts ?? this.newPosts,
    error: clearError ? null : (error ?? this.error),
    notice: clearNotice ? null : (notice ?? this.notice),
  );
}
