import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/network/app_exception.dart';
import '../../../communities/data/communities_repository.dart';
import '../../../communities/domain/community_role.dart';
import '../../../communities/presentation/bloc/community_moderation_cubit.dart';

@immutable
class ThreadModerationState {
  const ThreadModerationState({this.communityId = '', this.role});

  /// The community whose role [role] is; empty until one is resolved.
  final String communityId;

  /// The server's `viewer_role` for [communityId]; null while unknown or when
  /// the caller is not in it (fails closed: no role, no menu row).
  final CommunityRole? role;

  bool get canModerate => role?.canModerate ?? false;
}

/// The caller's moderation rights in the community of an open thread (W5-51c,
/// ADR-0031 D4a and R3). The role is the server's `viewer_role` from the
/// session-cached ListMyCommunities, never inferred; a null repository (the
/// `communities` flag is off) resolves nothing. Hide and restore go through
/// [CommunityModerationCubit] (one idempotency key per reply until it
/// succeeds), and return the failure instead of throwing.
class ThreadModerationCubit extends Cubit<ThreadModerationState> {
  ThreadModerationCubit({CommunitiesRepository? communities})
    : _communities = communities,
      super(const ThreadModerationState());

  final CommunitiesRepository? _communities;
  CommunityModerationCubit? _moderation;
  String _resolving = '';

  /// Looks the caller up in [communityId] (0 RPCs on a warm session, one
  /// ListMyCommunities on a cold one). A failure leaves no role.
  Future<void> resolve(String communityId) async {
    final repository = _communities;
    if (repository == null || communityId.isEmpty) return;
    if (communityId == state.communityId || communityId == _resolving) return;
    _resolving = communityId;
    CommunityRole? role;
    try {
      final mine = await repository.myCommunities();
      for (final c in mine.communities) {
        if (c.communityId == communityId) role = c.role;
      }
    } on AppException {
      role = null;
    }
    if (isClosed || _resolving != communityId) return;
    _moderation?.close();
    _moderation = CommunityModerationCubit(
      communityId: communityId,
      communities: repository,
    );
    emit(ThreadModerationState(communityId: communityId, role: role));
  }

  Future<AppException?> hide(String replyId) =>
      _moderation?.hidePost(replyId) ??
      Future.value(const NotFoundException('post not found'));

  Future<AppException?> restore(String replyId) =>
      _moderation?.restorePost(replyId) ??
      Future.value(const NotFoundException('post not found'));

  @override
  Future<void> close() async {
    await _moderation?.close();
    return super.close();
  }
}
