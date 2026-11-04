import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../core/theme/app_theme.dart';
import 'post_share_menu.dart';

/// Engagement callbacks for [PostActionBar]. Each one should add an event to
/// the owning bloc (e.g. `context.read<TimelineBloc>().add(...)`); the bar
/// itself holds no state. A null callback disables that action.
class PostActions {
  const PostActions({
    this.onReply,
    this.onRepost,
    this.onLike,
    this.onBookmark,
    this.onShare,
    this.onShareAt,
  });

  final VoidCallback? onReply;
  final VoidCallback? onRepost;
  final VoidCallback? onLike;
  final VoidCallback? onBookmark;
  final VoidCallback? onShare;

  /// Like [onShare], with the Share button's global rect, so a menu can open
  /// at the button wherever it sits in the row. Takes precedence over
  /// [onShare].
  final ValueChanged<Rect>? onShareAt;
}

/// Reply / repost / like / bookmark / share: 16dp outline icons (in 48dp tap
/// boxes) with compact counts. Every visible counted action (reply, repost,
/// like) gets an equal, left-aligned slot. Share and Bookmark use the final
/// slots in that order (Bookmark filled and accent when
/// bookmarked). The liked / reposted state uses the like / repost colours and
/// is announced as `selected`. Rendered by `PostCard` only when it is given
/// [PostActions] (the engagement bar).
///
/// [spread] is the opened post's row (X's post page): every action, Bookmark
/// and Share included, spaced evenly across the width, with [iconSize] glyphs.
class PostActionBar extends StatelessWidget {
  const PostActionBar({
    super.key,
    required this.actions,
    this.replyCount = 0,
    this.repostCount = 0,
    this.likeCount = 0,
    this.liked = false,
    this.reposted = false,
    this.bookmarked = false,
    this.showDisabled = true,
    this.replyDisabledHint,
    this.spread = false,
    this.iconSize = AppIconSize.action,
  });

  final PostActions actions;
  final int replyCount;
  final int repostCount;
  final int likeCount;
  final bool liked;
  final bool reposted;

  /// Bookmark is filled and accent-coloured, and announced as `selected`.
  final bool bookmarked;

  /// Show an action whose callback is null (greyed out). False hides it, so
  /// a bar can offer only what the caller's flags allow (no Share without a
  /// share link scope, no Reply while replies are off).
  final bool showDisabled;

  /// When set, Reply is shown disabled whatever [showDisabled] says, and
  /// announced and tooltipped with this text (the viewer may not reply to
  /// this post). It is advisory: it never says why.
  final String? replyDisabledHint;

  /// Space every action evenly across the width (the opened post).
  final bool spread;

  /// Glyph size; the 48dp tap box stays.
  final double iconSize;

  bool _shows(VoidCallback? callback) => showDisabled || callback != null;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final counted = <Widget>[
      if (_shows(actions.onReply) || replyDisabledHint != null)
        _ActionButton(
          icon: Icons.chat_bubble_outline,
          iconSize: iconSize,
          label: 'Reply',
          count: replyCount,
          onPressed: actions.onReply,
          disabledHint: actions.onReply == null ? replyDisabledHint : null,
        ),
      if (_shows(actions.onRepost))
        _ActionButton(
          icon: Icons.repeat,
          iconSize: iconSize,
          label: reposted ? 'Undo repost' : 'Repost',
          count: repostCount,
          active: reposted,
          activeColor: colors.repost,
          onPressed: actions.onRepost,
        ),
      if (_shows(actions.onLike))
        _ActionButton(
          icon: liked ? Icons.favorite : Icons.favorite_border,
          iconSize: iconSize,
          label: liked ? 'Unlike' : 'Like',
          count: likeCount,
          active: liked,
          activeColor: colors.like,
          onPressed: actions.onLike,
        ),
    ];
    final shareShown =
        showDisabled || actions.onShare != null || actions.onShareAt != null;
    // Offered only with a callback (never as a disabled placeholder).
    Widget? bookmark({required bool alignEnd}) => actions.onBookmark == null
        ? null
        : _ActionButton(
            icon: bookmarked ? Icons.bookmark : Icons.bookmark_border,
            iconSize: iconSize,
            label: bookmarked ? 'Bookmarked' : 'Bookmark',
            active: bookmarked,
            alignEnd: alignEnd,
            onPressed: actions.onBookmark,
          );
    Widget share({required bool alignEnd}) => Builder(
      builder: (buttonContext) => _ActionButton(
        icon: Icons.ios_share,
        iconSize: iconSize,
        label: 'Share',
        alignEnd: alignEnd,
        onPressed: actions.onShareAt != null
            ? () => actions.onShareAt!(targetRectOf(buttonContext))
            : actions.onShare,
      ),
    );

    if (spread) {
      // Loose flex: each button gets a bounded width (its count can fade at
      // large text) and the space left over still spreads them out.
      return Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          for (final button in counted) Flexible(child: button),
          if (shareShown) Flexible(child: share(alignEnd: false)),
          ?bookmark(alignEnd: false),
        ],
      );
    }
    return Row(
      children: [
        for (final button in counted) _ActionSlot(child: button),
        if (shareShown) _ActionSlot(child: share(alignEnd: false)),
        if (actions.onBookmark != null)
          _ActionSlot(child: bookmark(alignEnd: false)!),
      ],
    );
  }
}

/// One equal-width, left-aligned slot of the bar.
class _ActionSlot extends StatelessWidget {
  const _ActionSlot({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Expanded(
    child: Align(alignment: Alignment.centerLeft, child: child),
  );
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.icon,
    required this.iconSize,
    required this.label,
    required this.onPressed,
    this.count,
    this.active = false,
    this.activeColor,
    this.alignEnd = false,
    this.disabledHint,
  });

  final IconData icon;
  final double iconSize;
  final String label;
  final int? count;
  final bool active;
  final Color? activeColor;
  final VoidCallback? onPressed;

  /// A 48dp-wide box with the icon at its right edge (Share, flush with the
  /// card's right padding) instead of a left-aligned one.
  final bool alignEnd;

  /// Why-less explanation of a deliberately disabled button: a semantics
  /// hint (and `enabled: false`) plus a tooltip (long press / hover).
  final String? disabledHint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = disabledHint != null
        ? theme.disabledColor
        : active
        ? activeColor ?? theme.colorScheme.primary
        : theme.colorScheme.onSurfaceVariant;
    final shown = count ?? 0;
    final button = Semantics(
      button: true,
      selected: active,
      enabled: disabledHint == null ? null : false,
      hint: disabledHint,
      label: shown > 0 ? '$label, $shown' : label,
      excludeSemantics: true,
      onTap: onPressed,
      child: InkResponse(
        onTap: onPressed,
        radius: AppSpacing.lg,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minWidth: AppSpacing.minTapTarget,
            maxWidth: alignEnd ? AppSpacing.minTapTarget : double.infinity,
            minHeight: AppSpacing.minTapTarget,
          ),
          child: Row(
            mainAxisSize: alignEnd ? MainAxisSize.max : MainAxisSize.min,
            mainAxisAlignment: alignEnd
                ? MainAxisAlignment.end
                : MainAxisAlignment.start,
            children: [
              Icon(icon, size: iconSize, color: color),
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
    );
    final hint = disabledHint;
    return hint == null
        ? button
        : Tooltip(message: hint, excludeFromSemantics: true, child: button);
  }
}
