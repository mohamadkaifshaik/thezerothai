import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_shell_scope.dart';
import '../../../core/widgets/app_top_bar.dart';
import '../../../shared/widgets/app_tab_bar.dart';
import '../../../core/feature_flags/feature_flags.dart';
import '../../graph/presentation/widgets/who_to_follow_card.dart';
import '../domain/search_feature_flags.dart';
import 'widgets/explore_trends_section.dart';
import 'widgets/app_search_field.dart';

/// `/explore` (W4-17, ADR-0028, F7): a root destination of the new shell. A
/// two-row sticky header (the search field, then a one-tab "Trending" bar), the
/// trends list, and the "Who to follow" card (W3's, which draws nothing unless
/// its own flags are on). No news, sports or entertainment tabs, no promoted
/// hero, no "Posts for you" (F7). The route needs `search` and `ui_shell`.
/// The height reserved for the search field in Explore's header at text scale
/// [scaler]: the 48dp target, or the text line plus the field's padding when the
/// text is scaled up. A pinned sliver header needs its extent up front.
double searchFieldHeightFor(TextScaler scaler) {
  final padded =
      scaler.scale(AppSpacing.lg + AppSpacing.xs) + 2 * AppSpacing.smd;
  return padded < AppSpacing.minTapTarget ? AppSpacing.minTapTarget : padded;
}

class ExploreScreen extends StatelessWidget {
  const ExploreScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    final rowHeight = searchFieldHeightFor(scaler) + AppSpacing.sm;
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverPersistentHeader(
            pinned: true,
            delegate: _ExploreHeader(
              extent: rowHeight + AppSize.headerRow,
              rowHeight: rowHeight,
            ),
          ),
          if (isFeatureEnabled(context, kFeatureTrends))
            const ExploreTrendsSection(),
          const SliverToBoxAdapter(
            child: WhoToFollowCard(margin: EdgeInsets.all(AppSpacing.md)),
          ),
        ],
      ),
    );
  }
}

class _ExploreHeader extends SliverPersistentHeaderDelegate {
  const _ExploreHeader({required this.extent, required this.rowHeight});

  final double extent;
  final double rowHeight;

  @override
  double get minExtent => extent;

  @override
  double get maxExtent => extent;

  @override
  bool shouldRebuild(_ExploreHeader old) =>
      old.extent != extent || old.rowHeight != rowHeight;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    final colors = Theme.of(context).colorScheme;
    // The drawer's avatar button leads the row on phones only, as on the other
    // top bars.
    final showAvatar =
        MediaQuery.sizeOf(context).width < AppBreakpoints.mobile &&
        AppShellScope.maybeOf(context) != null;
    return ColoredBox(
      color: colors.surface.withValues(alpha: 0.92),
      child: Column(
        children: [
          SizedBox(
            height: rowHeight,
            child: Row(
              children: [
                if (showAvatar)
                  const Padding(
                    padding: EdgeInsets.only(left: AppSpacing.sm),
                    child: AppAvatarButton(),
                  )
                else
                  const SizedBox(width: AppSpacing.md),
                if (showAvatar) const SizedBox(width: AppSpacing.sm),
                Expanded(child: const Center(child: AppSearchField())),
                const SizedBox(width: AppSpacing.md),
              ],
            ),
          ),
          AppTabBar(
            semanticLabel: 'Explore sections',
            selectedIndex: 0,
            onChanged: (_) {},
            tabs: const [AppTab(label: 'Trending')],
          ),
        ],
      ),
    );
  }
}
