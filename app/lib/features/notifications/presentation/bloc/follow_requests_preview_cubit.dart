import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:uuid/uuid.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import '../../../graph/data/graph_repository.dart';

/// How many requests the card shows (one `ListFollowRequests` page).
const kFollowRequestsPreviewLimit = 3;

enum FollowRequestsPreviewStatus {
  /// Not asked yet: the card is only asked for where it shows.
  idle,

  /// The one `ListFollowRequests` is in flight.
  loading,

  /// [FollowRequestsPreviewState.items] is the first page (may be empty).
  ready,

  /// The call failed (offline, a rate limit): offer Retry.
  failed,

  /// FEATURE_DISABLED or UNIMPLEMENTED: show nothing (the repository then
  /// sends no request for a while).
  unavailable,
}

@immutable
class FollowRequestsPreviewState {
  const FollowRequestsPreviewState({
    this.status = FollowRequestsPreviewStatus.idle,
    this.items = const [],
    this.hasMore = false,
  });

  final FollowRequestsPreviewStatus status;
  final List<graph.UserListItem> items;

  /// The server has requests after [items].
  final bool hasMore;

  FollowRequestsPreviewState copyWith({
    FollowRequestsPreviewStatus? status,
    List<graph.UserListItem>? items,
    bool? hasMore,
  }) => FollowRequestsPreviewState(
    status: status ?? this.status,
    items: items ?? this.items,
    hasMore: hasMore ?? this.hasMore,
  );

  @override
  bool operator ==(Object other) =>
      other is FollowRequestsPreviewState &&
      other.status == status &&
      other.hasMore == hasMore &&
      listEquals(other.items, items);

  @override
  int get hashCode => Object.hash(status, hasMore, Object.hashAll(items));
}

/// The outcome of [FollowRequestsPreviewCubit.accept], for the caller's
/// message.
sealed class FollowRequestAcceptResult {
  const FollowRequestAcceptResult();
}

/// The server took the Accept; [relationship] is the viewer's own
/// relationship to the requester (so the caller can offer "Follow back").
final class FollowRequestAccepted extends FollowRequestAcceptResult {
  const FollowRequestAccepted(this.relationship);

  final graph.Relationship relationship;
}

/// The Accept failed; the row is back where it was.
final class FollowRequestAcceptFailed extends FollowRequestAcceptResult {
  const FollowRequestAcceptFailed(this.error);

  final AppException error;
}

/// The Notifications follow-requests card (F16): the first
/// [kFollowRequestsPreviewLimit] incoming requests, each with Accept.
///
/// Nothing is asked until [loadOnce]: the Notifications page calls it only
/// while the card shows beside it (tablet band B's context pane, the desktop
/// side column) and the caller has pending requests, so phones and band A
/// make no extra call. Then one `ListFollowRequests(page_size: 3)`.
///
/// [accept] mirrors the Follow requests page: the row leaves at the tap and
/// comes back if the call fails; one idempotency key per requester, reused
/// on a retry and dropped once the server took it. When the last row shown
/// is answered and the server has more, the card asks again once.
class FollowRequestsPreviewCubit extends Cubit<FollowRequestsPreviewState> {
  FollowRequestsPreviewCubit({required GraphRepository graph, Uuid? uuid})
    : _graph = graph,
      _uuid = uuid ?? const Uuid(),
      super(const FollowRequestsPreviewState());

  final GraphRepository _graph;
  final Uuid _uuid;
  final Map<String, String> _keys = {};

  /// Asks for the card the first time; later calls do nothing.
  Future<void> loadOnce() async {
    if (state.status != FollowRequestsPreviewStatus.idle) return;
    await _load();
  }

  /// Asks again after a failure (Retry), or when the card ran out of rows.
  Future<void> reload() async {
    if (state.status == FollowRequestsPreviewStatus.idle ||
        state.status == FollowRequestsPreviewStatus.loading ||
        state.status == FollowRequestsPreviewStatus.unavailable) {
      return;
    }
    await _load();
  }

  Future<void> _load() async {
    emit(state.copyWith(status: FollowRequestsPreviewStatus.loading));
    try {
      final page = await _graph.listFollowRequests(
        pageSize: kFollowRequestsPreviewLimit,
        pageToken: '',
      );
      if (isClosed) return;
      emit(
        FollowRequestsPreviewState(
          status: FollowRequestsPreviewStatus.ready,
          items: page.items.take(kFollowRequestsPreviewLimit).toList(),
          hasMore:
              page.hasMore || page.items.length > kFollowRequestsPreviewLimit,
        ),
      );
    } on FeatureDisabledException {
      if (isClosed) return;
      emit(
        const FollowRequestsPreviewState(
          status: FollowRequestsPreviewStatus.unavailable,
        ),
      );
    } on AppException {
      if (isClosed) return;
      emit(state.copyWith(status: FollowRequestsPreviewStatus.failed));
    }
  }

  /// Accepts the request of [item]; null when the row is not shown (a
  /// second tap while the first is in flight).
  Future<FollowRequestAcceptResult?> accept(graph.UserListItem item) async {
    final userId = item.user.userId;
    final index = state.items.indexWhere((i) => i.user.userId == userId);
    if (index < 0) return null;
    emit(state.copyWith(items: [...state.items]..removeAt(index)));
    final key = _keys[userId] ??= _uuid.v4();
    try {
      final relationship = await _graph.respondToFollowRequest(
        requesterUserId: userId,
        accept: true,
        idempotencyKey: key,
      );
      _keys.remove(userId);
      if (!isClosed && state.items.isEmpty && state.hasMore) {
        unawaited(reload());
      }
      return FollowRequestAccepted(relationship);
    } on AppException catch (e) {
      if (!isClosed) {
        final items = [...state.items];
        items.insert(index.clamp(0, items.length), item);
        emit(state.copyWith(items: items));
      }
      return FollowRequestAcceptFailed(e);
    }
  }
}
