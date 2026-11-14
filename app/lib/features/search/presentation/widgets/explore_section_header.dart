import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';

/// The heading of one Explore section ("Trending", "Media"): a bold title and
/// a "See all >" link in the accent colour (>= 48 dp tall). The link's
/// semantic label names the section ("See all trending").
class ExploreSectionHeader extends StatelessWidget {
  const ExploreSectionHeader({
    super.key,
    required this.title,
    required this.onSeeAll,
    this.padding = const EdgeInsets.only(left: AppSpacing.md),
  });

  final String title;
  final VoidCallback onSeeAll;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = context.appColors.accentText;
    return Padding(
      padding: padding,
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              header: true,
              child: Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleLarge?.copyWith(
                  fontSize: AppExplorePeopleLayout.sectionTitleSize,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
          Semantics(
            button: true,
            label: 'See all ${title.toLowerCase()}',
            excludeSemantics: true,
            onTap: onSeeAll,
            child: TextButton(
              style: TextButton.styleFrom(
                foregroundColor: accent,
                minimumSize: const Size(
                  AppSpacing.minTapTarget,
                  AppSpacing.minTapTarget,
                ),
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
              ),
              onPressed: onSeeAll,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'See all',
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: accent,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Icon(Icons.chevron_right, color: accent),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
