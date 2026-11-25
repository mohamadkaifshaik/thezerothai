import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/icons/dz_icon.dart';
import '../../../core/icons/dz_icon_data.dart';
import '../../../core/icons/dz_icons.dart';
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

/// How the actions sit in the row.
///
/// * [compact]: DzHome and DzThread. Reply, repost and like (with counts) at
///   the leading edge in 44 dp boxes with 10 dp of side padding, then the
///   free space, then save and share at the trailing edge.
/// * [spread]: DzPost and ZPhotoViewer. Every action in a 48 dp box, spread
///   evenly across the width.
enum PostActionBarLayout { compact, spread }

/// The post actions as the Dz artboards draw them: stroke icons (reply,
/// repost, like, save, share; `DzIcons`), 13/600 tabular counts, 44 dp boxes
/// (48 dp [PostActionBarLayout.spread]), a press shrink and a short pop when
/// like, repost or save switch on (none under the platform's reduce-motion
/// setting). Large text or a narrow width flows onto another line.
///
/// One widget for the feed card, the opened post, a thread row and the photo
/// viewer's bottom bar: pick the look with [layout], [style], [iconSize] and
/// [showCounts].
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
    this.iconSize = AppIconSize.postAction,
    this.style = PostActionBarStyle.feed,
    this.layout = PostActionBarLayout.compact,
    this.showCounts = true,
  });

  /// The look; see [PostActionBarStyle].
  final PostActionBarStyle style;

  /// Where the actions sit; see [PostActionBarLayout].
  final PostActionBarLayout layout;

  /// Draw the reply, repost, like and share counts. The opened post turns
  /// this off when the screen shows its own "4 Replies 0 Reposts" line.
  final bool showCounts;

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

  /// Glyph size; the tap box stays.
  final double iconSize;

  bool _shows(VoidCallback? callback) => showDisabled || callback != null;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final viewer = style == PostActionBarStyle.photoViewer;
    final idle = viewer ? AppPhotoPanel.muted : colors.text2;
    final spread = layout == PostActionBarLayout.spread;
    final target = spread
        ? AppIconSize.actionTargetSpread
        : AppIconSize.actionTarget;
    final weight = viewer ? FontWeight.w400 : FontWeight.w600;
    int? shown(int count) => showCounts ? count : null;

    final counted = <Widget>[
      if (_shows(actions.onReply) || replyDisabledHint != null)
        _ActionButton(
          icon: DzIcons.reply,
          iconSize: iconSize,
          target: target,
          idleColor: idle,
          countWeight: weight,
          label: 'Reply',
          count: shown(replyCount),
          onPressed: actions.onReply,
          disabledHint: actions.onReply == null ? replyDisabledHint : null,
        ),
      if (_shows(actions.onRepost) || actions.onRepostFrom != null)
        Builder(
          builder: (buttonContext) => _ActionButton(
            icon: DzIcons.repost,
            // The design draws the reposted arrows heavier (2.2).
            strokeWidth: reposted ? 2.2 : null,
            iconSize: iconSize,
            target: target,
            idleColor: idle,
            countWeight: weight,
            label: reposted ? 'Undo repost' : 'Repost',
            count: shown(repostCount),
            active: reposted,
            activeColor: viewer ? AppPhotoPanel.reposted : colors.repost,
            onPressed: actions.onRepostFrom != null
                ? () => actions.onRepostFrom!(buttonContext)
                : actions.onRepost,
          ),
        ),
      if (_shows(actions.onLike))
        _ActionButton(
          icon: DzIcons.like,
          iconSize: iconSize,
          target: target,
          idleColor: idle,
          countWeight: weight,
          label: liked ? 'Unlike' : 'Like',
          count: shown(likeCount),
          active: liked,
          fillsWhenActive: true,
          activeColor: viewer ? AppPhotoPanel.liked : colors.like,
          onPressed: actions.onLike,
        ),
    ];
    // Offered only with a callback (never as a disabled placeholder).
    final saved = actions.onBookmark == null
        ? null
        : _ActionButton(
            icon: DzIcons.save,
            iconSize: iconSize,
            target: target,
            idleColor: idle,
            countWeight: weight,
            label: bookmarked ? 'Bookmarked' : 'Bookmark',
            active: bookmarked,
            fillsWhenActive: true,
            activeColor: viewer ? AppPhotoPanel.bookmarked : null,
            onPressed: actions.onBookmark,
          );
    final shareShown =
        showDisabled || actions.onShare != null || actions.onShareAt != null;
    final share = !shareShown
        ? null
        : Builder(
            builder: (buttonContext) => _ActionButton(
              icon: DzIcons.share,
              iconSize: iconSize,
              target: target,
              idleColor: idle,
              countWeight: weight,
              label: 'Share',
              count: shown(shareCount),
              onPressed: actions.onShareAt != null
                  ? () => actions.onShareAt!(targetRectOf(buttonContext))
                  : actions.onShare,
            ),
          );
    final views = viewCount == null
        ? null
        : Center(
            child: PostViewsStat(
              count: viewCount!,
              iconSize: iconSize,
              icon: viewsIcon,
              color: viewer ? idle : null,
            ),
          );
    final leading = <Widget>[...counted];
    // Views stay a read-only stat after the actions.
    final trailing = <Widget>[?saved, ?share, ?views];
    final items = [...leading, ...trailing];
    if (items.isEmpty) return const SizedBox.shrink();

    // A painted icon sits in a scrolling list: give the row its own layer so
    // a like animation repaints this row only.
    return RepaintBoundary(
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (!constraints.hasBoundedWidth) {
            return Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              children: items,
            );
          }
          if (spread) {
            // A box and, with counts, room for a few digits.
            final need = items.length * (target + (showCounts ? 24 : 0));
            if (constraints.maxWidth < need) {
              return Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: items,
              );
            }
            return Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: items,
            );
          }
          // Compact: the leading actions take what the trailing ones leave
          // and flow onto another line when the width or the text is short.
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: leading,
                ),
              ),
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                children: trailing,
              ),
            ],
          );
        },
      ),
    );
  }
}

class _ActionButton extends StatefulWidget {
  const _ActionButton({
    required this.icon,
    required this.iconSize,
    required this.target,
    required this.label,
    required this.onPressed,
    this.count,
    this.active = false,
    this.fillsWhenActive = false,
    this.strokeWidth,
    this.activeColor,
    this.disabledHint,
    this.idleColor,
    this.countWeight = FontWeight.w600,
  });

  /// The count's weight: 600 in the feed (`13/600`), 400 in the photo viewer.
  final FontWeight countWeight;

  /// The colour when not active (text2, or the photo viewer's grey).
  final Color? idleColor;

  final DzIconData icon;
  final double iconSize;

  /// Tap box height and least width (44, or 48 in the spread row).
  final double target;
  final String label;
  final int? count;
  final bool active;

  /// Like and save fill their glyph when on; repost only recolours.
  final bool fillsWhenActive;

  /// Overrides the icon's stroke width (on the 24 grid).
  final double? strokeWidth;
  final Color? activeColor;
  final VoidCallback? onPressed;

  /// Why-less explanation of a deliberately disabled button: a semantics
  /// hint (and `enabled: false`) plus a tooltip (long press / hover).
  final String? disabledHint;

  @override
  State<_ActionButton> createState() => _ActionButtonState();
}

class _ActionButtonState extends State<_ActionButton>
    with SingleTickerProviderStateMixin {
  /// Fill and pop length (design: about 150-200 ms).
  static const _duration = Duration(milliseconds: 180);
  static const _pressedScale = 0.88;

  late final AnimationController _pop = AnimationController(
    vsync: this,
    duration: _duration,
  );
  late final Animation<double> _popScale = TweenSequence<double>([
    TweenSequenceItem(
      tween: Tween(
        begin: 1.0,
        end: 1.25,
      ).chain(CurveTween(curve: Curves.easeOut)),
      weight: 40,
    ),
    TweenSequenceItem(
      tween: Tween(
        begin: 1.25,
        end: 1.0,
      ).chain(CurveTween(curve: Curves.easeIn)),
      weight: 60,
    ),
  ]).animate(_pop);
  bool _pressed = false;

  @override
  void didUpdateWidget(_ActionButton old) {
    super.didUpdateWidget(old);
    if (widget.active &&
        !old.active &&
        !MediaQuery.disableAnimationsOf(context)) {
      _pop.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _pop.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final reduce = MediaQuery.disableAnimationsOf(context);
    final active = widget.active;
    final color = widget.disabledHint != null
        ? theme.disabledColor
        : active
        ? widget.activeColor ?? theme.colorScheme.primary
        : widget.idleColor ?? context.appColors.text2;
    final shown = widget.count ?? 0;
    final button = Semantics(
      button: true,
      selected: active,
      enabled: widget.onPressed != null,
      hint: widget.disabledHint,
      label: shown > 0 ? '${widget.label}, $shown' : widget.label,
      excludeSemantics: true,
      onTap: widget.onPressed,
      child: InkResponse(
        onTap: widget.onPressed,
        onHighlightChanged: (down) {
          if (down != _pressed) setState(() => _pressed = down);
        },
        radius: AppSpacing.lg,
        // No ripple or pressed circle behind the glyph (owner, 2026-11-13).
        // The press shrinks the glyph a little, and the toggle's pop and
        // fill are the state feedback. A faint hover stays for pointers and
        // the focus highlight for the keyboard.
        splashColor: Colors.transparent,
        highlightColor: Colors.transparent,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minWidth: widget.target,
            minHeight: widget.target,
          ),
          child: Center(
            widthFactor: 1,
            heightFactor: 1,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppIconSize.actionSidePadding,
              ),
              child: AnimatedScale(
                scale: _pressed && widget.onPressed != null ? _pressedScale : 1,
                duration: reduce
                    ? Duration.zero
                    : const Duration(milliseconds: 80),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AnimatedBuilder(
                      animation: _popScale,
                      builder: (context, child) =>
                          Transform.scale(scale: _popScale.value, child: child),
                      child: DzIcon(
                        widget.icon,
                        size: widget.iconSize,
                        color: color,
                        fill: active && widget.fillsWhenActive ? 1 : 0,
                        fillDuration: reduce ? Duration.zero : _duration,
                        strokeWidth: widget.strokeWidth,
                      ),
                    ),
                    if (shown > 0) ...[
                      const SizedBox(width: AppSpacing.actionGap - 1),
                      Flexible(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            NumberFormat.compact().format(shown),
                            maxLines: 1,
                            overflow: TextOverflow.fade,
                            softWrap: false,
                            // 13/600 with tabular figures.
                            style: AppTextStyles.dzCount(theme).copyWith(
                              color: color,
                              fontWeight: widget.countWeight,
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
    final hint = widget.disabledHint;
    return hint == null
        ? button
        : Tooltip(message: hint, excludeFromSemantics: true, child: button);
  }
}
