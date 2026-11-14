import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/feature_flags/feature_flags.dart';
import '../../../core/theme/app_theme.dart';
import '../../../features/engagement/domain/post_views_feature_flag.dart';
import '../../../gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import '../../../gen/dzeroth/posts/v1/posts.pbenum.dart' show PostKind;
import '../../format/view_count.dart';

/// The owner hid the view count everywhere, for everyone, on 2026-11-15.
/// Views are still recorded (`ImpressionTracker` / `ImpressionDetector`, behind
/// `post_views`) so real counts exist later. Set this true to show them again:
/// on list cards they are the last slot of the action bar, and on the opened
/// post they sit beside the timestamp. A test can turn them on for a subtree
/// with [PostViewsVisibility].
const bool kShowPostViews = false;

/// Overrides [kShowPostViews] for the subtree below it (tests, and any future
/// per-surface switch).
class PostViewsVisibility extends InheritedWidget {
  const PostViewsVisibility({
    super.key,
    required this.show,
    required super.child,
  });

  final bool show;

  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PostViewsVisibility>()?.show ??
      kShowPostViews;

  @override
  bool updateShouldNotify(PostViewsVisibility oldWidget) =>
      show != oldWidget.show;
}

/// The view count to draw for [post], or null to draw none: views are shown
/// at all ([kShowPostViews]), the server set `view_count` (its presence is the
/// visibility signal; never set on a REPOST row, an embed or a withheld row)
/// AND `post_views` is on for the caller. False without a session above (some
/// tests).
int? shownViewCount(BuildContext context, pb.Post post) {
  if (!PostViewsVisibility.of(context)) return null;
  if (!post.hasViewCount() || post.kind == PostKind.POST_KIND_REPOST) {
    return null;
  }
  try {
    if (!isFeatureEnabled(context, kFeaturePostViews)) return null;
  } on ProviderNotFoundException {
    return null;
  }
  return post.viewCount.toInt();
}

/// The glyph of the views stat (a bar chart, as for impressions elsewhere).
/// One line to swap; the owner's alternatives were
/// `Icons.signal_cellular_alt_rounded` and `Icons.insights_rounded`.
const IconData kPostViewsIcon = Icons.bar_chart_rounded;

/// A read-only "bars + 1.2K" stat. Not a button: no tap target, so it takes
/// only the room of its text and the action row around it keeps its layout.
class PostViewsStat extends StatelessWidget {
  const PostViewsStat({
    super.key,
    required this.count,
    this.iconSize,
    this.icon = kPostViewsIcon,
  });

  /// The glyph; [kPostViewsIcon] unless a comparison asks for another.
  final IconData icon;

  final int count;

  /// Glyph size; defaults to the action glyph size.
  final double? iconSize;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.onSurfaceVariant;
    return Semantics(
      label: viewsSemanticsLabel(count),
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: iconSize ?? AppIconSize.action, color: color),
          const SizedBox(width: AppSpacing.actionGap),
          Flexible(
            child: Text(
              formatCompactCount(count),
              maxLines: 1,
              overflow: TextOverflow.fade,
              softWrap: false,
              style: theme.textTheme.bodySmall?.copyWith(
                color: color,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
