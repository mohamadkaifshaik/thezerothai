import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import '../../../../shared/widgets/app_avatar.dart';
import '../../../../shared/widgets/follow_button.dart';
import '../../data/graph_repository.dart';
import '../bloc/relationship_cubit.dart';

/// One row in any graph user list (followers, following, blocked, muted).
///
/// The [FollowButton] (when [trailing] is not supplied) is seeded directly
/// from `item.relationship` — the server fills it from the caller's own
/// graph at 0 extra reads (ADR-0008 D4) — so a page of rows never triggers a
/// `GetRelationships` call.
class UserListRow extends StatelessWidget {
  const UserListRow({super.key, required this.item, this.trailing});

  final graph.UserListItem item;

  /// Overrides the default [FollowButton] trailing widget (e.g. an
  /// Unblock/Unmute action button in Settings' managed-accounts screens).
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final user = item.user;
    return ListTile(
      minVerticalPadding: AppSpacing.sm,
      leading: AppAvatar(url: user.avatarUrl),
      title: Text(
        user.displayName.isEmpty ? '@${user.handle}' : user.displayName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        '@${user.handle}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing:
          trailing ??
          BlocProvider(
            create: (context) => RelationshipCubit(
              graphRepository: context.read<GraphRepository>(),
              userId: user.userId,
              initial: graph.Relationship(
                userId: user.userId,
                followState: item.relationship.followState,
                blocking: item.relationship.blocking,
                muting: item.relationship.muting,
              ),
            ),
            child: const FollowButton(),
          ),
    );
  }
}
