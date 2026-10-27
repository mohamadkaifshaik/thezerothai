import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import '../../../../shared/widgets/app_avatar.dart';
import '../../../../shared/widgets/follow_button.dart';
import '../../data/graph_repository.dart';
import '../bloc/relationship_cubit.dart';
import '../bloc/relationship_state.dart';

/// One row in any graph user list (followers, following, blocked, muted) and
/// in the "Who to follow" card.
///
/// The [FollowButton] (when [trailing] is not supplied) is seeded directly
/// from `item.relationship` — the server fills it from the caller's own
/// graph at 0 extra reads (ADR-0008 D4) — so a page of rows never triggers a
/// `GetRelationships` call.
class UserListRow extends StatelessWidget {
  const UserListRow({
    super.key,
    required this.item,
    this.trailing,
    this.onFollowed,
    this.onGone,
    this.onDismiss,
    this.showDivider = true,
  });

  final graph.UserListItem item;

  /// Overrides the default [FollowButton] trailing widget (e.g. an
  /// Unblock/Unmute action button in Settings' managed-accounts screens).
  final Widget? trailing;

  /// Called once the server confirmed a follow made from the default
  /// [FollowButton] (the state is FOLLOWING or REQUESTED, not updating, no
  /// error). Not called for the optimistic step, so a rejected follow rolls
  /// back and shows its message in the row; a caller that removes the row on
  /// this call never loses the rollback. Ignored with a [trailing].
  final VoidCallback? onFollowed;

  /// Called, once and with no message, when the follow is refused with
  /// NOT_FOUND: the account is blocked, suspended or deleted (the server
  /// answers the same for all three, W3-22 L-1). A caller that offers
  /// accounts, like the "Who to follow" card, removes the row on this call.
  /// Ignored with a [trailing].
  final VoidCallback? onGone;

  /// Shows a 48dp "x" after the control and calls this when it is tapped
  /// (the "Who to follow" card's local dismiss).
  final VoidCallback? onDismiss;

  /// The hairline under the row; a card turns it off for its last row.
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    final user = item.user;
    final theme = Theme.of(context);
    final onFollowed = this.onFollowed;
    final onGone = this.onGone;
    final onDismiss = this.onDismiss;
    final control =
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
          child: onFollowed == null
              ? FollowButton(onGone: onGone)
              : BlocListener<RelationshipCubit, RelationshipState>(
                  listenWhen: (before, after) =>
                      _isConfirmedFollow(after) && !_isConfirmedFollow(before),
                  listener: (context, state) => onFollowed(),
                  child: FollowButton(onGone: onGone),
                ),
        );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: EdgeInsets.only(
            left: AppSpacing.md,
            right: onDismiss == null ? AppSpacing.md : AppSpacing.xs,
            top: AppSpacing.sm,
            bottom: AppSpacing.sm,
          ),
          child: Row(
            children: [
              ExcludeSemantics(child: AppAvatar(url: user.avatarUrl)),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      user.displayName.isEmpty
                          ? '@${user.handle}'
                          : user.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall,
                    ),
                    Text(
                      '@${user.handle}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              control,
              if (onDismiss != null)
                IconButton(
                  tooltip: 'Dismiss @${user.handle}',
                  constraints: const BoxConstraints.tightFor(
                    width: AppSpacing.minTapTarget,
                    height: AppSpacing.minTapTarget,
                  ),
                  icon: Icon(
                    Icons.close,
                    size: AppIconSize.md,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  onPressed: onDismiss,
                ),
            ],
          ),
        ),
        if (showDivider) const Divider(height: 1),
      ],
    );
  }
}

bool _isConfirmedFollow(RelationshipState state) =>
    !state.isUpdating &&
    state.error == null &&
    (state.relationship.followState ==
            graph.FollowState.FOLLOW_STATE_FOLLOWING ||
        state.relationship.followState ==
            graph.FollowState.FOLLOW_STATE_REQUESTED);
