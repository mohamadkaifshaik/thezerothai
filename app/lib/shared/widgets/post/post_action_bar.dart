import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../core/theme/app_theme.dart';
import 'post_share_menu.dart';
import 'post_views_stat.dart';

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

/// The widest the opened post's action row grows (dz.css `.acts`
/// `max-width: 440px`). A list card's row spans the card's full width.
const kPostActionsMaxWidth = 440.0;

/// Reply / Repost / Like / Share / Bookmark (the owner's order, 2026-11-15):
/// [iconSize] outline glyphs (18 dp, dz.css `.acts`) in 48dp tap boxes with
/// compact 13 sp counts. A list card's row spans the card's full width in
/// equal slots, each button at its slot's start (so the first glyph lines up
/// with the text above it); a slot narrower than 48 dp squeezes its button
/// rather than overflowing. A hidden action (a flag off, no callback) leaves
/// the others to share the width. Bookmark is filled and accent-coloured when
/// bookmarked. The liked / reposted state uses the like / repost colours and is
/// announced as `selected`. A last, read-only slot (views, F1) is added when
/// [viewCount] is given (hidden by [kShowPostViews] for now). Rendered by
/// `PostCard` only when it is given [PostActions] (the engagement bar).
///
/// [spread] is the opened post's row: the same order spaced edge to edge
/// (`justify-content: space-between`, within the 440 dp cap), with [iconSize]
/// glyphs.
class PostActionBar extends StatelessWidget {
  const PostActionBar({
    super.key,
    required this.actions,
    this.replyCount = 0,
    this.repostCount = 0,
    this.likeCount = 0,
    this.shareCount = 0,
    this.viewCount,
    this.viewsIcon = kPostViewsIcon,
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

  /// The views drawn as a read-only stat after Like; null draws none. The
  /// caller passes it only when the server set `view_count` and `post_views`
  /// is on for the viewer.
  final int? viewCount;

  /// The views glyph; [kPostViewsIcon] unless a comparison asks for another.
  final IconData viewsIcon;
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
    final share = !shareShown
        ? null
        : Builder(
            builder: (buttonContext) => _ActionButton(
              icon: Icons.ios_share,
              iconSize: iconSize,
              label: 'Share',
              count: shareCount,
              onPressed: actions.onShareAt != null
                  ? () => actions.onShareAt!(targetRectOf(buttonContext))
                  : actions.onShare,
            ),
          );
    // Offered only with a callback (never as a disabled placeholder).
    final saved = actions.onBookmark == null
        ? null
        : _ActionButton(
            icon: bookmarked ? Icons.bookmark : Icons.bookmark_border,
            iconSize: iconSize,
            label: bookmarked ? 'Bookmarked' : 'Bookmark',
            active: bookmarked,
            onPressed: actions.onBookmark,
          );
    final views = viewCount == null
        ? null
        : Padding(
            padding: EdgeInsets.symmetric(
              horizontal: spread ? AppSpacing.xs : 0,
            ),
            child: PostViewsStat(
              count: viewCount!,
              iconSize: iconSize,
              icon: viewsIcon,
            ),
          );
    final items = <Widget>[...counted, ?share, ?saved, ?views];
    final Widget row = spread
        // The opened post: every action spaced edge to edge, `space-between`.
        // Loose flex: each button gets a bounded width (its count can fade at
        // large text) and the space left over spreads them out.
        ? Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [for (final item in items) Flexible(child: item)],
          )
        // A list card: equal slots across the full width, each button at its
        // slot's start. A count that does not fit its slot fades; it never
        // overlaps the next slot.
        : Row(children: [for (final item in items) _ActionSlot(child: item)]);
    final bar = spread
        ? ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: kPostActionsMaxWidth),
            child: row,
          )
        : row;
    return Align(alignment: AlignmentDirectional.centerStart, child: bar);
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
    this.disabledHint,
  });

  final IconData icon;
  final double iconSize;
  final String label;
  final int? count;
  final bool active;
  final Color? activeColor;
  final VoidCallback? onPressed;

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
        // No press ripple or pressed circle behind the icon (owner,
        // 2026-11-13): the button's own state (a filled heart, a count) is
        // the feedback. A faint hover stays for pointers, and the focus
        // highlight stays for the keyboard.
        splashColor: Colors.transparent,
        highlightColor: Colors.transparent,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            // In a slot narrower than 48 dp (six slots on a 320 dp card) the
            // box gives way to the slot.
            minWidth: AppSpacing.minTapTarget,
            minHeight: AppSpacing.minTapTarget,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: iconSize, color: color),
              if (shown > 0) ...[
                const SizedBox(width: AppSpacing.actionGap),
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
