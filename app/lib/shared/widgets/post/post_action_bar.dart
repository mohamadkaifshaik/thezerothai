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
    this.onRepostFrom,
    this.onLike,
    this.onBookmark,
    this.onShare,
    this.onShareAt,
  });

  final VoidCallback? onReply;
  final VoidCallback? onRepost;

  /// Like [onRepost], with the Repost button's context, so the tablet layout
  /// can hang its menu from the button. Takes precedence over [onRepost].
  final ValueChanged<BuildContext>? onRepostFrom;
  final VoidCallback? onLike;
  final VoidCallback? onBookmark;
  final VoidCallback? onShare;

  /// Like [onShare], with the Share button's global rect, so a menu can open
  /// at the button wherever it sits in the row. Takes precedence over
  /// [onShare].
  final ValueChanged<Rect>? onShareAt;
}

/// The widest the action row grows (dz.css `.acts` `max-width: 440px`): on
/// a wide column the actions stay together instead of drifting apart.
const kPostActionsMaxWidth = 440.0;

/// Reply / Repost / Like / Bookmark / Share (the order of every design):
/// [iconSize] outline glyphs (18 dp, dz.css `.acts`) in 48dp tap boxes with
/// compact 13 sp counts, across the row up to [kPostActionsMaxWidth] from the
/// start edge. The first glyph lines up with the text above it. With all
/// five actions the row is spread edge to edge (`justify-content:
/// space-between`); with fewer (a flag off) each gets an equal slot, its
/// button at the slot's start, so they stay together. Bookmark is
/// filled and accent-coloured when bookmarked. The liked / reposted state
/// uses the like / repost colours and is announced as `selected`. There are
/// three counts only: view counts (F1) have no backend yet, so no fourth
/// count is drawn. Rendered by `PostCard` only when it is given [PostActions]
/// (the engagement bar).
///
/// [spread] is the opened post's row: the actions spaced edge to edge
/// (`justify-content: space-between`, still within the 440 dp cap), with
/// [iconSize] glyphs.
class PostActionBar extends StatelessWidget {
  const PostActionBar({
    super.key,
    required this.actions,
    this.replyCount = 0,
    this.repostCount = 0,
    this.likeCount = 0,
    this.shareCount = 0,
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

  /// The share count drawn beside the Share glyph; 0 draws none. The caller
  /// passes it only while the `share_count` flag is on for the viewer.
  final int shareCount;
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

  /// Space every action evenly across the row (the opened post).
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
      if (_shows(actions.onRepost) || actions.onRepostFrom != null)
        Builder(
          builder: (buttonContext) => _ActionButton(
            icon: Icons.repeat,
            iconSize: iconSize,
            label: reposted ? 'Undo repost' : 'Repost',
            count: repostCount,
            active: reposted,
            activeColor: colors.repost,
            onPressed: actions.onRepostFrom != null
                ? () => actions.onRepostFrom!(buttonContext)
                : actions.onRepost,
          ),
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
        count: shareCount,
        alignEnd: alignEnd,
        onPressed: actions.onShareAt != null
            ? () => actions.onShareAt!(targetRectOf(buttonContext))
            : actions.onShare,
      ),
    );

    final saved = bookmark(alignEnd: false);
    // All five (the designs' row): spread edge to edge, `space-between`.
    final allFive = counted.length == 3 && saved != null && shareShown;
    final Widget row;
    if (spread || allFive) {
      // Loose flex: each button gets a bounded width (its count can fade at
      // large text) and the space left over spreads them out.
      row = Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          for (final button in counted) Flexible(child: button),
          if (saved != null) Flexible(child: saved),
          if (shareShown) Flexible(child: share(alignEnd: false)),
        ],
      );
    } else {
      // Fewer than five (a flag off): equal slots, so they stay together at
      // the start instead of drifting to the edges.
      row = Row(
        children: [
          for (final button in counted) _ActionSlot(child: button),
          if (saved != null) _ActionSlot(child: saved),
          if (shareShown) _ActionSlot(child: share(alignEnd: false)),
        ],
      );
    }
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: kPostActionsMaxWidth),
        child: row,
      ),
    );
  }
}

/// One equal-width slot of the bar, its button at the start.
class _ActionSlot extends StatelessWidget {
  const _ActionSlot({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Expanded(
    child: Align(alignment: AlignmentDirectional.centerStart, child: child),
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
                    // dz.css `.acts span`: 13 sp, w600.
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: color,
                      fontWeight: FontWeight.w600,
                    ),
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
