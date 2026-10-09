import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/theme/app_theme.dart';

/// Engagement callbacks for [PostActionBar]. Each one should add an event to
/// the owning bloc (e.g. `context.read<TimelineBloc>().add(...)`); the bar
/// itself holds no state. A null callback disables that action.
class PostActions {
  const PostActions({this.onReply, this.onRepost, this.onLike, this.onShare});

  final VoidCallback? onReply;
  final VoidCallback? onRepost;
  final VoidCallback? onLike;
  final VoidCallback? onShare;
}

/// Reply / repost / like / share: outline icons with compact counts, spread
/// evenly across the content column. Rendered by `PostCard` only when it is
/// given [PostActions] (engagement ships in P5).
class PostActionBar extends StatelessWidget {
  const PostActionBar({
    super.key,
    required this.actions,
    this.replyCount = 0,
    this.repostCount = 0,
    this.likeCount = 0,
    this.liked = false,
    this.reposted = false,
  });

  final PostActions actions;
  final int replyCount;
  final int repostCount;
  final int likeCount;
  final bool liked;
  final bool reposted;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        _ActionButton(
          icon: Icons.chat_bubble_outline,
          label: 'Reply',
          count: replyCount,
          onPressed: actions.onReply,
        ),
        _ActionButton(
          icon: Icons.repeat,
          label: reposted ? 'Undo repost' : 'Repost',
          count: repostCount,
          active: reposted,
          activeColor: colors.primary,
          onPressed: actions.onRepost,
        ),
        _ActionButton(
          icon: liked ? Icons.favorite : Icons.favorite_border,
          label: liked ? 'Unlike' : 'Like',
          count: likeCount,
          active: liked,
          activeColor: colors.error,
          onPressed: actions.onLike,
        ),
        _ActionButton(
          icon: Icons.ios_share,
          label: 'Share',
          onPressed: actions.onShare,
        ),
      ],
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.count,
    this.active = false,
    this.activeColor,
  });

  final IconData icon;
  final String label;
  final int? count;
  final bool active;
  final Color? activeColor;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = active
        ? activeColor ?? theme.colorScheme.primary
        : theme.colorScheme.onSurfaceVariant;
    final shown = count ?? 0;
    return Flexible(
      child: Semantics(
        button: true,
        label: shown > 0 ? '$label, $shown' : label,
        excludeSemantics: true,
        child: InkResponse(
          onTap: onPressed,
          radius: AppSpacing.lg,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minWidth: AppSpacing.minTapTarget,
              minHeight: AppSpacing.minTapTarget,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: AppIconSize.md, color: color),
                if (shown > 0) ...[
                  const SizedBox(width: AppSpacing.xs),
                  Flexible(
                    child: Text(
                      NumberFormat.compact().format(shown),
                      maxLines: 1,
                      overflow: TextOverflow.fade,
                      softWrap: false,
                      style: theme.textTheme.bodyMedium?.copyWith(color: color),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
