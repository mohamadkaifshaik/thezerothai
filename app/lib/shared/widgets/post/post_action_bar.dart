import 'package:material_ui/material_ui.dart';
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

/// How a [PostActionBar] looks. [feed] is the list card's compact row;
/// [photoViewer] is X's phone photo viewer: reply, repost, like, views,
/// bookmark, share spread evenly across the width, outline glyphs in grey
/// with 13 sp counts, and X's pink / green / blue when liked / reposted /
/// bookmarked ([AppPhotoPanel]). The actions and their semantics are the same.
enum PostActionBarStyle { feed, photoViewer }

/// Reply / Repost / Like / Share / Bookmark (the owner's order, 2026-11-15),
/// compact and left-aligned, Substack style: [iconSize] outline glyphs (18 dp,
/// dz.css `.acts`) with compact 13 sp counts, packed from the start with
/// [AppSpacing.actionItemGap] between items (the same on phone, tablet and
/// desktop; never spread across the width). Each item's tap target is at
/// least 48 dp: the target extends invisibly (an icon-only item is 48 dp wide,
/// so its visual gap to the next is a little larger), and the first glyph
/// lines up with the text above. A row too narrow for its items squeezes
/// them (a count fades) rather than overflowing. A hidden action (a flag off,
/// no callback) leaves the others packed. Bookmark is filled and
/// accent-coloured when bookmarked. The liked / reposted state uses the like /
/// repost colours and is announced as `selected`. A last, read-only slot
/// (views, F1) is added when [viewCount] is given (hidden by [kShowPostViews]
/// for now). Rendered by `PostCard` only when it is given [PostActions] (the
/// engagement bar).
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
    this.iconSize = AppIconSize.action,
    this.style = PostActionBarStyle.feed,
  });

  /// The look; see [PostActionBarStyle].
  final PostActionBarStyle style;

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

  /// Glyph size; the 48dp tap box stays.
  final double iconSize;

  bool _shows(VoidCallback? callback) => showDisabled || callback != null;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final viewer = style == PostActionBarStyle.photoViewer;
    final idle = viewer ? AppPhotoPanel.muted : null;
    final counted = <Widget>[
      if (_shows(actions.onReply) || replyDisabledHint != null)
        _ActionButton(
          icon: Icons.chat_bubble_outline,
          iconSize: iconSize,
          idleColor: idle,
          compactEnd: viewer,
          countWeight: viewer ? FontWeight.w400 : FontWeight.w600,
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
            idleColor: idle,
            compactEnd: viewer,
            countWeight: viewer ? FontWeight.w400 : FontWeight.w600,
            label: reposted ? 'Undo repost' : 'Repost',
            count: repostCount,
            active: reposted,
            activeColor: viewer ? AppPhotoPanel.reposted : colors.repost,
            onPressed: actions.onRepostFrom != null
                ? () => actions.onRepostFrom!(buttonContext)
                : actions.onRepost,
          ),
        ),
      if (_shows(actions.onLike))
        _ActionButton(
          icon: liked ? Icons.favorite : Icons.favorite_border,
          iconSize: iconSize,
          idleColor: idle,
          compactEnd: viewer,
          countWeight: viewer ? FontWeight.w400 : FontWeight.w600,
          label: liked ? 'Unlike' : 'Like',
          count: likeCount,
          active: liked,
          activeColor: viewer ? AppPhotoPanel.liked : colors.like,
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
              idleColor: idle,
              compactEnd: viewer,
              countWeight: viewer ? FontWeight.w400 : FontWeight.w600,
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
            idleColor: idle,
            compactEnd: viewer,
            countWeight: viewer ? FontWeight.w400 : FontWeight.w600,
            label: bookmarked ? 'Bookmarked' : 'Bookmark',
            active: bookmarked,
            activeColor: viewer ? AppPhotoPanel.bookmarked : null,
            onPressed: actions.onBookmark,
          );
    final views = viewCount == null
        ? null
        : Padding(
            padding: const EdgeInsetsDirectional.only(
              end: AppSpacing.actionItemGap,
            ),
            child: PostViewsStat(
              count: viewCount!,
              iconSize: iconSize,
              icon: viewsIcon,
              color: idle,
            ),
          );
    if (viewer) {
      // X's order, spread evenly: each item takes an equal share and sits at
      // the start of it, so the first glyph lines up with the text above.
      final row = <Widget>[...counted, ?views, ?saved, ?share];
      return Row(
        children: [
          for (final item in row)
            Expanded(
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: item,
              ),
            ),
        ],
      );
    }
    final items = <Widget>[...counted, ?share, ?saved, ?views];
    // Packed from the start; loose flex so a row too narrow for its items
    // squeezes them (a count fades) instead of overflowing.
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [for (final item in items) Flexible(child: item)],
      ),
    );
  }
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
    this.idleColor,
    this.compactEnd = false,
    this.countWeight = FontWeight.w600,
  });

  /// The count's weight: 600 in the feed (dz.css `.acts span`), 400 in the
  /// photo viewer.
  final FontWeight countWeight;

  /// The colour when not active (the photo viewer's grey); null is the
  /// theme's muted text colour.
  final Color? idleColor;

  /// No trailing gap after the item (the photo viewer spreads items evenly).
  final bool compactEnd;

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
        : idleColor ?? theme.colorScheme.onSurfaceVariant;
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
            // The 48 dp target; the trailing gap below is part of it.
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
                      fontWeight: countWeight,
                    ),
                  ),
                ),
              ],
              if (!compactEnd) const SizedBox(width: AppSpacing.actionItemGap),
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
