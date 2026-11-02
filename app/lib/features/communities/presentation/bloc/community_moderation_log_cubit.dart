import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../gen/dzeroth/communities/v1/communities.pb.dart' as pb;
import '../../../../gen/dzeroth/communities/v1/communities.pbenum.dart'
    show ModerationLogAction;
import '../../data/communities_repository.dart';
import 'community_moderation_cubit.dart';

enum ModerationLogStatus { loading, ready, loadingMore, error }

@immutable
class ModerationLogState {
  const ModerationLogState({
    this.status = ModerationLogStatus.loading,
    this.entries = const <pb.ModerationLogEntry>[],
    this.nextPageToken = '',
    this.error,
    this.loadMoreFailed = false,
    this.restored = const <String>{},
  });

  final ModerationLogStatus status;
  final List<pb.ModerationLogEntry> entries;
  final String nextPageToken;

  /// The failure of the first page (shown with Retry).
  final AppException? error;

  /// A later page failed: the entries stay, the footer offers Retry.
  final bool loadMoreFailed;

  /// Posts restored from this screen this visit (shows "Restored").
  final Set<String> restored;

  bool get hasMore => nextPageToken.isNotEmpty;

  /// Whether [entry] is a HIDE this screen already restored.
  bool isRestored(pb.ModerationLogEntry entry) =>
      entry.action == ModerationLogAction.MODERATION_LOG_ACTION_HIDE &&
      entry.postId.isNotEmpty &&
      restored.contains(entry.postId);

  /// Whether [entry] offers Restore: a HIDE that this log has not seen undone
  /// by a later RESTORE of the same post, and not restored here.
  bool canRestore(pb.ModerationLogEntry entry) {
    if (entry.action != ModerationLogAction.MODERATION_LOG_ACTION_HIDE ||
        entry.postId.isEmpty ||
        restored.contains(entry.postId)) {
      return false;
    }
    return !entries.any(
      (e) =>
          e.action == ModerationLogAction.MODERATION_LOG_ACTION_RESTORE &&
          e.postId == entry.postId &&
          e.seq > entry.seq,
    );
  }

  ModerationLogState copyWith({
    ModerationLogStatus? status,
    List<pb.ModerationLogEntry>? entries,
    String? nextPageToken,
    AppException? error,
    bool? loadMoreFailed,
    Set<String>? restored,
  }) => ModerationLogState(
    status: status ?? this.status,
    entries: entries ?? this.entries,
    nextPageToken: nextPageToken ?? this.nextPageToken,
    error: error ?? this.error,
    loadMoreFailed: loadMoreFailed ?? this.loadMoreFailed,
    restored: restored ?? this.restored,
  );
}

/// The moderation log of one community (W5-35): 1 `ListModerationLog` per
/// page, opened only by a moderator. Newest first, cursor in the cubit, one
/// load at a time. Restore on a HIDE entry goes through
/// [CommunityModerationCubit] (one key per post, reused on retry).
class CommunityModerationLogCubit extends Cubit<ModerationLogState> {
  CommunityModerationLogCubit({
    required this.communityId,
    required CommunitiesRepository communities,
    required CommunityModerationCubit moderation,
    this.pageSize = 25,
  }) : _communities = communities,
       _moderation = moderation,
       super(const ModerationLogState());

  final String communityId;
  final int pageSize;
  final CommunitiesRepository _communities;
  final CommunityModerationCubit _moderation;
  bool _loading = false;

  /// The first page (also pull to refresh).
  Future<void> load() async {
    if (_loading) return;
    _loading = true;
    if (state.entries.isEmpty) {
      emit(state.copyWith(status: ModerationLogStatus.loading));
    }
    try {
      final page = await _communities.listModerationLog(
        communityId: communityId,
        pageSize: pageSize,
      );
      if (isClosed) return;
      emit(
        ModerationLogState(
          status: ModerationLogStatus.ready,
          entries: page.entries,
          nextPageToken: page.nextPageToken,
          restored: state.restored,
        ),
      );
    } on AppException catch (error) {
      if (isClosed) return;
      // A refresh that fails keeps the entries it has.
      if (state.entries.isEmpty) {
        emit(state.copyWith(status: ModerationLogStatus.error, error: error));
      }
    } finally {
      _loading = false;
    }
  }

  Future<void> loadMore() async {
    if (_loading || !state.hasMore) return;
    _loading = true;
    emit(
      state.copyWith(
        status: ModerationLogStatus.loadingMore,
        loadMoreFailed: false,
      ),
    );
    try {
      final page = await _communities.listModerationLog(
        communityId: communityId,
        pageSize: pageSize,
        pageToken: state.nextPageToken,
      );
      if (isClosed) return;
      emit(
        state.copyWith(
          status: ModerationLogStatus.ready,
          entries: [...state.entries, ...page.entries],
          nextPageToken: page.nextPageToken,
        ),
      );
    } on AppException {
      if (isClosed) return;
      emit(
        state.copyWith(status: ModerationLogStatus.ready, loadMoreFailed: true),
      );
    } finally {
      _loading = false;
    }
  }

  /// Restores the post of a HIDE entry; returns the failure or null.
  Future<AppException?> restore(String postId) async {
    final error = await _moderation.restorePost(postId);
    if (error == null && !isClosed) {
      emit(state.copyWith(restored: {...state.restored, postId}));
    }
    return error;
  }
}
