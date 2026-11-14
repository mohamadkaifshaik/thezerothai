import 'package:flutter/foundation.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../gen/dzeroth/lists/v1/lists.pb.dart' as pb;

/// [loading] the first page, [ready] rows (possibly none), [error] the first
/// page failed.
enum ListFeedStatus { loading, ready, error }

/// A paged feed of Lists: "Lists you follow" and Discover.
@immutable
class ListFeedState {
  const ListFeedState({
    this.status = ListFeedStatus.loading,
    this.lists = const [],
    this.nextPageToken = '',
    this.loadingMore = false,
    this.loadMoreFailed = false,
    this.error,
    this.busyIds = const {},
  });

  final ListFeedStatus status;
  final List<pb.ListInfo> lists;
  final String nextPageToken;
  final bool loadingMore;
  final bool loadMoreFailed;
  final AppException? error;

  /// Lists with a follow or unfollow in flight.
  final Set<String> busyIds;

  bool get hasMore => nextPageToken.isNotEmpty;

  ListFeedState copyWith({
    ListFeedStatus? status,
    List<pb.ListInfo>? lists,
    String? nextPageToken,
    bool? loadingMore,
    bool? loadMoreFailed,
    AppException? error,
    bool clearError = false,
    Set<String>? busyIds,
  }) => ListFeedState(
    status: status ?? this.status,
    lists: lists ?? this.lists,
    nextPageToken: nextPageToken ?? this.nextPageToken,
    loadingMore: loadingMore ?? this.loadingMore,
    loadMoreFailed: loadMoreFailed ?? this.loadMoreFailed,
    error: clearError ? null : (error ?? this.error),
    busyIds: busyIds ?? this.busyIds,
  );
}
