import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../../core/theme/app_theme.dart';
import '../../data/search_repository.dart' show Trend;

/// One trending hashtag (X's trend row): a grey "N - Trending" meta
/// line (the rank), the bold `#tag`, and a grey "N posts" line. The whole row is
/// one button (>= 48dp) that calls [onTap] (it opens the tag's results). Grows
/// with the text scale; the tag wraps to two lines before it is cut.
///
/// [ranked] is Explore's look (the Explore mocks' `.trend`): the rank as a
/// teal "01" column in front, "Trending" over the tag and a chevron at the
/// end. The default is the compact side card's row.
class TrendRow extends StatelessWidget {
  const TrendRow({
    super.key,
    required this.trend,
    required this.onTap,
    this.ranked = false,
  });

  final Trend trend;
  final VoidCallback onTap;
  final bool ranked;

  /// "1.2K posts", "1 post".
  static String postsLabel(int count) =>
      count == 1 ? '1 post' : '${NumberFormat.compact().format(count)} posts';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final count = trend.postCount.toInt();
    final texts = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          ranked ? 'Trending' : '${trend.rank} · Trending',
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
    );
    final side = MediaQuery.sizeOf(context).width < AppBreakpoints.mobile
        ? AppExplorePeopleLayout.trendPaddingPhone
        : AppExplorePeopleLayout.trendPaddingWide;
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
              padding: EdgeInsets.symmetric(
                horizontal: ranked ? side : AppSpacing.md,
                vertical: AppSpacing.sm,
              ),
              child: ranked
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ConstrainedBox(
                          constraints: const BoxConstraints(
                            minWidth: AppExplorePeopleLayout.trendRankWidth,
                          ),
                          child: Text(
                            trend.rank.toString().padLeft(2, '0'),
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w800,
                              color: context.appColors.accentText,
                            ),
                          ),
                        ),
                        const SizedBox(
                          width: AppExplorePeopleLayout.trendRankGap,
                        ),
                        Expanded(child: texts),
                        Icon(Icons.chevron_right, color: muted),
                      ],
                    )
                  : texts,
            ),
          ),
        ),
      ),
    );
  }
}
