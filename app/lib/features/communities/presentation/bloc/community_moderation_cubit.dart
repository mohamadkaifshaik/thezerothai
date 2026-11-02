import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:uuid/uuid.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../gen/dzeroth/communities/v1/communities.pb.dart' as pb;
import '../../data/communities_repository.dart';
import '../../domain/community_role.dart';

@immutable
class CommunityModerationState {
  const CommunityModerationState({this.busy = const <String>{}});

  /// Ids (post or user) with a moderation call in flight.
  final Set<String> busy;

  bool isBusy(String id) => busy.contains(id);
}

/// The answer of a role change: the target's new role, from the server.
@immutable
class RoleChange {
  const RoleChange({required this.role, required this.community});

  /// `SetMemberRoleResponse.role`, never inferred from the action.
  final CommunityRole role;

  /// The community header after the change (member and moderator counts).
  final pb.Community community;
}

/// Hide, restore, ban, unban, make and remove moderator for one community
/// (W5-35). Every method returns the failure (or null) for the screen's
/// snackbar and keeps the state honest: nothing here decides who may act (the
/// server does, FORBIDDEN `not_moderator` / `not_owner`).
///
/// One idempotency key per (action, target) until that action succeeds, so a
/// retry after a failure is the same intent (rule 4).
class CommunityModerationCubit extends Cubit<CommunityModerationState> {
  CommunityModerationCubit({
    required this.communityId,
    required CommunitiesRepository communities,
  }) : _communities = communities,
       super(const CommunityModerationState());

  static const _uuid = Uuid();

  final String communityId;
  final CommunitiesRepository _communities;
  final Map<String, String> _keys = {};

  String _key(String action, String target) =>
      _keys.putIfAbsent('$action:$target', _uuid.v4);

  void _setBusy(String id, bool on) {
    if (isClosed) return;
    final next = {...state.busy};
    on ? next.add(id) : next.remove(id);
    emit(CommunityModerationState(busy: next));
  }

  Future<AppException?> hidePost(String postId) => _run(
    'hide',
    postId,
    () => _communities.hidePost(
      idempotencyKey: _key('hide', postId),
      communityId: communityId,
      postId: postId,
    ),
  );

  Future<AppException?> restorePost(String postId) => _run(
    'restore',
    postId,
    () => _communities.restorePost(
      idempotencyKey: _key('restore', postId),
      communityId: communityId,
      postId: postId,
    ),
  );

  /// Runs one [pb.MemberRoleAction]; returns the new role or the failure.
  Future<({RoleChange? change, AppException? error})> setRole(
    String userId,
    pb.MemberRoleAction action,
  ) async {
    final name = action.name;
    _setBusy(userId, true);
    try {
      final r = await _communities.setMemberRole(
        idempotencyKey: _key(name, userId),
        communityId: communityId,
        userId: userId,
        action: action,
      );
      _keys.remove('$name:$userId');
      return (
        change: RoleChange(
          role: CommunityRole.fromWire(r.role),
          community: r.community,
        ),
        error: null,
      );
    } on AppException catch (error) {
      return (change: null, error: error);
    } finally {
      _setBusy(userId, false);
    }
  }

  Future<AppException?> _run(
    String action,
    String id,
    Future<void> Function() call,
  ) async {
    _setBusy(id, true);
    try {
      await call();
      _keys.remove('$action:$id');
      return null;
    } on AppException catch (error) {
      return error;
    } finally {
      _setBusy(id, false);
    }
  }
}
