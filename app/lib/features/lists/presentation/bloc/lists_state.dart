import 'package:flutter/foundation.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../gen/dzeroth/lists/v1/lists.pb.dart' as pb;
import '../../domain/lists_feature_flag.dart';

/// [loading] the first fetch (skeleton), [ready] with rows or the empty
/// state, [error] the fetch failed and there is nothing to show.
enum ListsStatus { loading, ready, error }

/// The "Your Lists" screen state (W5-11).
@immutable
class ListsState {
  const ListsState({
    this.status = ListsStatus.loading,
    this.lists = const [],
    this.error,
  });

  final ListsStatus status;

  /// The caller's own lists, oldest first (the server's order).
  final List<pb.ListInfo> lists;
  final AppException? error;

  /// Create is disabled at the per-owner cap (the server enforces it too).
  bool get atCap => lists.length >= kMaxListsPerUser;

  ListsState copyWith({
    ListsStatus? status,
    List<pb.ListInfo>? lists,
    AppException? error,
    bool clearError = false,
  }) => ListsState(
    status: status ?? this.status,
    lists: lists ?? this.lists,
    error: clearError ? null : (error ?? this.error),
  );
}
