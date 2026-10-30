import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../../core/theme/app_theme.dart';
import '../../data/search_repository.dart' show Trend;

/// One trending hashtag (W4-17/18, X's trend row): a grey "N - Trending" meta
/// line (the rank), the bold `#tag`, and a grey "N posts" line. The whole row is
/// one button (>= 48dp) that calls [onTap] (it opens the tag's results). Grows
/// with the text scale; the tag wraps to two lines before it is cut.
class TrendRow extends StatelessWidget {
  const TrendRow({super.key, required this.trend, required this.onTap});

  final Trend trend;
  final VoidCallback onTap;

  /// "1.2K posts", "1 post".
  static String postsLabel(int count) =>
      count == 1 ? '1 post' : '${NumberFormat.compact().format(count)} posts';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final count = trend.postCount.toInt();
    return Semantics(
      button: true,
      label:
          'Trending number ${trend.rank}, #${trend.tag}, ${postsLabel(count)}',
      excludeSemantics: true,
      onTap: onTap,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minHeight: AppSpacing.minTapTarget,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.md,
                vertical: AppSpacing.sm,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${trend.rank} · Trending',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(color: muted),
                  ),
                  Text(
                    '#${trend.tag}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    postsLabel(count),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(color: muted),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
