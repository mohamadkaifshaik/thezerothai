import 'dart:math' as math;

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

/// Selects the action colours used on cards and on the dark media panel.
enum PostActionBarStyle { feed, photoViewer }

/// Responsive post actions. Pills size to their contents and share the
/// available space between them. Large text can flow onto another line.
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

  /// The views drawn as a read-only stat after the actions; null draws none. The
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
            countWeight: viewer ? FontWeight.w400 : FontWeight.w600,
            label: bookmarked ? 'Bookmarked' : 'Bookmark',
            active: bookmarked,
            activeColor: viewer ? AppPhotoPanel.bookmarked : null,
            onPressed: actions.onBookmark,
          );
    final items = <Widget>[
      ...counted,
      ?share,
      ?saved,
      if (viewCount != null)
        Center(
          child: PostViewsStat(
            count: viewCount!,
            iconSize: iconSize,
            icon: viewsIcon,
            color: idle,
          ),
        ),
    ];
    if (items.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) {
        const gap = 4.0;
        final largeText = MediaQuery.textScalerOf(context).scale(13) > 18;
        if (!constraints.hasBoundedWidth ||
            largeText ||
            constraints.maxWidth < items.length * (48 + gap) - gap) {
          return Wrap(
            alignment: WrapAlignment.spaceBetween,
            spacing: gap,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: items,
          );
        }
        // Intrinsic widths reserve space for each formatted count. The table
        // shares spare width evenly and keeps the gutters constant.
        return Table(
          defaultColumnWidth: const _ActionColumnWidth(),
          defaultVerticalAlignment: TableCellVerticalAlignment.middle,
          columnWidths: {
            if (counted.isNotEmpty &&
                (likeCount > 0 || replyCount > 0 || repostCount > 0)) ...{
              if (share != null && shareCount <= 0)
                2 * items.indexOf(share): const FixedColumnWidth(
                  AppSpacing.minTapTarget,
                ),
              if (saved != null)
                2 * items.indexOf(saved): const FixedColumnWidth(
                  AppSpacing.minTapTarget,
                ),
            },
            for (int i = 1; i < items.length; i++)
              2 * i - 1: const FixedColumnWidth(gap),
          },
          children: [
            TableRow(
              children: [
                for (var i = 0; i < items.length; i++) ...[
                  if (i > 0) const SizedBox.shrink(),
                  items[i],
                ],
              ],
            ),
          ],
        );
      },
    );
  }
}

/// Let a crowded row shrink a counted capsule down to its tap target.
class _ActionColumnWidth extends IntrinsicColumnWidth {
  const _ActionColumnWidth() : super(flex: 1);

  @override
  double maxIntrinsicWidth(Iterable<RenderBox> cells, double containerWidth) =>
      math.max(
        AppSpacing.minTapTarget,
        super.maxIntrinsicWidth(cells, containerWidth),
      );

  @override
  double minIntrinsicWidth(Iterable<RenderBox> cells, double containerWidth) =>
      AppSpacing.minTapTarget;
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
    this.countWeight = FontWeight.w600,
  });

  /// The count's weight: 600 in the feed (dz.css `.acts span`), 400 in the
  /// photo viewer.
  final FontWeight countWeight;

  /// The colour when not active (the photo viewer's grey); null is the
  /// theme's muted text colour.
  final Color? idleColor;

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
      enabled: onPressed != null,
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
            // The hit area extends beyond the visible capsule.
            minWidth: AppSpacing.minTapTarget,
            minHeight: AppSpacing.minTapTarget,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: DecoratedBox(
              decoration: ShapeDecoration(
                color: active
                    ? color.withValues(alpha: .14)
                    : theme.colorScheme.onSurface.withValues(alpha: .09),
                shape: const StadiumBorder(),
              ),
              child: Container(
                constraints: const BoxConstraints(minWidth: 38, minHeight: 36),
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 5),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, size: iconSize, color: color),
                    if (shown > 0) ...[
                      const SizedBox(width: AppSpacing.actionGap),
                      Flexible(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
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
                      ),
                    ],
                  ],
                ),
              ),
            ),
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
