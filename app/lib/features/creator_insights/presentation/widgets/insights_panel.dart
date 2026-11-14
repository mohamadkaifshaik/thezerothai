import 'package:fixnum/fixnum.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/router/app_router.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/app_error_view.dart';
import '../../../../gen/dzeroth/identity/v1/identity.pb.dart' as pb;
import '../../../../shared/format/view_count.dart';
import '../../../../shared/widgets/primitives/app_empty_view.dart';
import '../../../../shared/widgets/primitives/app_skeleton.dart';
import '../../../../shared/widgets/primitives/settings_group.dart';
import '../../data/creator_insights_repository.dart';
import '../../domain/creator_insights_feature_flag.dart';
import '../bloc/creator_insights_cubit.dart';
import '../bloc/creator_insights_state.dart';
import 'insights_metric_tile.dart';

/// Creator Studio's Insights group with the flag on: the window selector,
/// three metric tiles and the top posts. Owns its cubit (one
/// `GetCreatorInsights` on open, again on a window switch or a retry).
///
/// The phone stacks the tiles in raised cards; the tablet and desktop put the
/// three side by side in flat boxes. Same data and actions on all three.
class InsightsPanel extends StatelessWidget {
  const InsightsPanel({super.key, required this.style});

  final SettingsGroupStyle style;

  static const title = 'Insights';
  static const emptyTitle = 'Not enough data yet';
  static const emptySubtitle =
      'Impressions, engagements and new followers show up here as they come '
      'in.';

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (context) => CreatorInsightsCubit(
        repository: context.read<CreatorInsightsRepository>(),
      )..load(),
      child: _PanelBody(style: style),
    );
  }
}

class _PanelBody extends StatelessWidget {
  const _PanelBody({required this.style});

  final SettingsGroupStyle style;

  @override
  Widget build(BuildContext context) {
    final wide = style != SettingsGroupStyle.raised;
    final cubit = context.read<CreatorInsightsCubit>();
    return BlocBuilder<CreatorInsightsCubit, CreatorInsightsState>(
      builder: (context, state) {
        final side = wide
            ? const EdgeInsets.symmetric(horizontal: AppSpacing.md)
            : EdgeInsets.zero;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: side.copyWith(
                top: wide ? AppSettingsLayout.flatLabelTop : 0,
                bottom: AppSpacing.sm,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Semantics(
                      header: true,
                      child: Text(
                        InsightsPanel.title.toUpperCase(),
                        style: AppTextStyles.eyebrow(Theme.of(context)),
                      ),
                    ),
                  ),
                  _WindowSelector(
                    selected: state.windowDays,
                    onSelected: cubit.selectWindow,
                  ),
                ],
              ),
            ),
            Padding(
              padding: side.copyWith(bottom: AppSettingsLayout.groupGap),
              child: switch (state) {
                CreatorInsightsLoading() => const _Loading(),
                CreatorInsightsEmpty() => const AppEmptyView(
                  icon: Icons.insights_outlined,
                  title: InsightsPanel.emptyTitle,
                  subtitle: InsightsPanel.emptySubtitle,
                ),
                CreatorInsightsError(:final error) => AppErrorView(
                  error: error,
                  onRetry: cubit.load,
                ),
                CreatorInsightsReady(:final data) => _Ready(
                  data: data,
                  wide: wide,
                  style: style,
                ),
              },
            ),
          ],
        );
      },
    );
  }
}

class _WindowSelector extends StatelessWidget {
  const _WindowSelector({required this.selected, required this.onSelected});

  final int selected;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<int>(
      key: const ValueKey('insights-window'),
      showSelectedIcon: false,
      style: const ButtonStyle(visualDensity: VisualDensity.compact),
      segments: [
        for (final days in kInsightsWindows)
          ButtonSegment(value: days, label: Text('$days days')),
      ],
      selected: {selected},
      onSelectionChanged: (set) => onSelected(set.first),
    );
  }
}

class _Loading extends StatelessWidget {
  const _Loading();

  @override
  Widget build(BuildContext context) {
    return const AppSkeletonScope(
      semanticsLabel: 'Loading insights',
      child: Column(
        children: [
          AppSkeletonBlock(height: 84, radius: AppRadius.card),
          SizedBox(height: AppStudioLayout.statGap),
          AppSkeletonBlock(height: 84, radius: AppRadius.card),
          SizedBox(height: AppStudioLayout.statGap),
          AppSkeletonBlock(height: 84, radius: AppRadius.card),
        ],
      ),
    );
  }
}

class _Ready extends StatelessWidget {
  const _Ready({required this.data, required this.wide, required this.style});

  final pb.GetCreatorInsightsResponse data;
  final bool wide;
  final SettingsGroupStyle style;

  static int _n(Int64 v) => v.toInt();

  @override
  Widget build(BuildContext context) {
    final days = data.days;
    final net =
        _n(data.current.followersGained) - _n(data.current.followersLost);
    final tiles = [
      InsightsMetricTile(
        key: const ValueKey('insight-impressions'),
        label: 'Impressions',
        value: formatCompactCount(_n(data.current.impressions)),
        series: [for (final d in days) _n(d.impressions)],
        changePct: data.hasImpressionsChangePct()
            ? data.impressionsChangePct
            : null,
        wide: wide,
      ),
      InsightsMetricTile(
        key: const ValueKey('insight-engagements'),
        label: 'Engagements',
        value: formatCompactCount(_n(data.current.engagements)),
        series: [for (final d in days) _n(d.engagements)],
        changePct: data.hasEngagementsChangePct()
            ? data.engagementsChangePct
            : null,
        wide: wide,
      ),
      InsightsMetricTile(
        key: const ValueKey('insight-followers'),
        label: 'Followers gained',
        value: net > 0
            ? '+${formatCompactCount(net)}'
            : formatCompactCount(net),
        series: [
          for (final d in days) _n(d.followersGained) - _n(d.followersLost),
        ],
        caption:
            '${_n(data.current.followersGained)} gained, '
            '${_n(data.current.followersLost)} lost',
        wide: wide,
      ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (wide)
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < tiles.length; i++) ...[
                  if (i > 0) const SizedBox(width: AppStudioLayout.statGap),
                  Expanded(child: tiles[i]),
                ],
              ],
            ),
          )
        else
          for (var i = 0; i < tiles.length; i++) ...[
            if (i > 0) const SizedBox(height: AppStudioLayout.statGap),
            tiles[i],
          ],
        if (data.topPosts.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.md),
          SettingsGroup(
            title: 'Top posts',
            style: style,
            rows: [for (final p in data.topPosts) _TopPostRow(post: p)],
          ),
        ],
      ],
    );
  }
}

class _TopPostRow extends StatelessWidget {
  const _TopPostRow({required this.post});

  final pb.CreatorTopPost post;

  @override
  Widget build(BuildContext context) {
    final views = post.viewCount.toInt();
    final likes = post.likeCount.toInt();
    final replies = post.replyCount.toInt();
    return SettingsRow(
      key: ValueKey('insight-top-${post.postId}'),
      icon: Icons.trending_up,
      title: post.text.isEmpty ? 'Media post' : post.text,
      subtitle:
          '${viewsSemanticsLabel(views)} · '
          '${formatCompactCount(likes)} ${likes == 1 ? 'like' : 'likes'} · '
          '${formatCompactCount(replies)} '
          '${replies == 1 ? 'reply' : 'replies'}',
      onTap: () => context.push(AppRouter.postPath(post.postId)),
    );
  }
}
