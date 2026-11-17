import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../../core/router/app_router.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../shared/widgets/primitives/app_chip.dart';
import '../../../beacons/presentation/widgets/plans_activity_filter.dart'
    show PlansChipRow;
import '../bloc/trends_cubit.dart';
import '../bloc/trends_state.dart';
import 'explore_section_header.dart';
import 'explore_trends_section.dart';
import 'trends_loader.dart';
import 'trends_status_views.dart';

/// The spoken name of the hashtag chip row.
const kTrendingTagChipsLabel = 'Filter by hashtag';

/// One chip of the row.
class TrendingChipSpec {
  const TrendingChipSpec(this.tag, this.label, this.semanticsLabel);

  /// The hashtag, no `#`.
  final String tag;
  final String label;
  final String semanticsLabel;
}

/// The chips for [state]: the top [kExplorePopularRows] hashtags, then the
/// Latest one (skipped when it is already among them), and a leading chip for
/// the [selected] tag when the list no longer has it (a refresh dropped it, or
/// a link named it).
List<TrendingChipSpec> trendingChipSpecs(TrendsState state, String? selected) {
  final top = [for (final t in state.trends.take(kExplorePopularRows)) t.tag];
  final specs = [
    for (final tag in top) TrendingChipSpec(tag, '#$tag', '#$tag'),
  ];
  final latest = state.latest?.tag;
  if (latest != null && !top.contains(latest)) {
    final kicker = top.isEmpty ? 'Just posted' : 'Latest';
    specs.add(
      TrendingChipSpec(
        latest,
        '$kicker · #$latest',
        '#$latest, latest hashtag',
      ),
    );
  }
  if (selected != null && !specs.any((s) => s.tag == selected)) {
    specs.insert(0, TrendingChipSpec(selected, '#$selected', '#$selected'));
  }
  return specs;
}

/// The hashtag chip row: one row of [AppFilterPill]s that scrolls sideways.
/// Tapping a chip selects it (the page filters in place); tapping the selected
/// one clears the filter.
class TrendingTagChips extends StatelessWidget {
  const TrendingTagChips({
    super.key,
    required this.specs,
    required this.selected,
    required this.onSelected,
  });

  final List<TrendingChipSpec> specs;
  final String? selected;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) => PlansChipRow(
    label: kTrendingTagChipsLabel,
    chips: [
      for (final spec in specs)
        AppFilterPill(
          key: ValueKey('trending-chip-${spec.tag}'),
          label: spec.label,
          semanticsLabel: spec.semanticsLabel,
          selected: spec.tag == selected,
          onPressed: () => onSelected(spec.tag),
        ),
    ],
  );
}

/// Four static pills while the first list is on its way.
class _ChipsPlaceholder extends StatelessWidget {
  const _ChipsPlaceholder();

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.surfaceContainerHigh;
    return Semantics(
      label: 'Loading hashtags',
      child: ExcludeSemantics(
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: (AppSpacing.minTapTarget - AppFilterPill.minHeight) / 2,
          ),
          child: Row(
            children: [
              for (var i = 0; i < 4; i++) ...[
                if (i > 0) const SizedBox(width: AppSpacing.sm),
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                  ),
                  child: const SizedBox(
                    width: 72,
                    height: AppFilterPill.minHeight,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// The "Popular" header of the Trending tab as a sliver: the heading with
/// "See all", the hashtag chips, and the stale or failed note. Draws nothing
/// when the list is empty or `trends` is off for the caller. Mount it only
/// with `trends` on; needs [TrendsCubit] in scope.
class TrendingTagHeader extends StatelessWidget {
  const TrendingTagHeader({
    super.key,
    required this.selected,
    required this.onSelected,
  });

  final String? selected;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    return TrendsLoader(
      child: BlocBuilder<TrendsCubit, TrendsState>(
        builder: (context, state) {
          if (state.status == TrendsStatus.unavailable) {
            return const SliverToBoxAdapter(child: SizedBox.shrink());
          }
          final hasList = state.trends.isNotEmpty || state.latest != null;
          final loading =
              !hasList &&
              (state.status == TrendsStatus.initial ||
                  state.status == TrendsStatus.loading);
          if (!hasList && state.status == TrendsStatus.failed) {
            return SliverToBoxAdapter(
              child: TrendsErrorNotice(
                error: state.error,
                onRetry: () =>
                    context.read<TrendsCubit>().ensureLoaded(force: true),
              ),
            );
          }
          if (!hasList && !loading && selected == null) {
            return const SliverToBoxAdapter(child: SizedBox.shrink());
          }
          return SliverMainAxisGroup(
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.only(
                    top: AppExplorePeopleLayout.sectionGap,
                  ),
                  child: ExploreSectionHeader(
                    title: 'Popular',
                    onSeeAll: () => context.push(AppRouter.exploreTrendingPath),
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: loading
                    ? const _ChipsPlaceholder()
                    : TrendingTagChips(
                        specs: trendingChipSpecs(state, selected),
                        selected: selected,
                        onSelected: onSelected,
                      ),
              ),
              SliverToBoxAdapter(child: ExploreTrendsNote(state: state)),
            ],
          );
        },
      ),
    );
  }
}
