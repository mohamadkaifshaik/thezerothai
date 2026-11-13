import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../shared/widgets/primitives/app_back_header.dart';
import '../../../shared/widgets/primitives/app_empty_view.dart';
import '../../../shared/widgets/primitives/app_main_column.dart';
import 'bloc/trends_cubit.dart';
import 'bloc/trends_state.dart';
import 'widgets/explore_trends_section.dart';
import 'widgets/trends_loader.dart';
import 'widgets/trends_status_views.dart';

/// `/explore/trending`: Explore's "See all" for Trending, the whole list (up
/// to [kExploreTrendsMaxRows]) in the same ranked rows. Reads the shared
/// [TrendsCubit], so it costs no call of its own. Loading, failed (with Retry)
/// and empty states. The route needs `search`, `trends` and `ui_shell`.
class ExploreTrendingScreen extends StatelessWidget {
  const ExploreTrendingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: AppMainColumn(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AppBackHeader(
                title: 'Trending',
                onBack: () => context.canPop()
                    ? context.pop()
                    : context.go(AppRouter.explorePath),
              ),
              Expanded(
                child: TrendsLoader(
                  child: BlocBuilder<TrendsCubit, TrendsState>(
                    builder: (context, state) => _body(context, state),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _body(BuildContext context, TrendsState state) {
    final trends = state.trends.take(kExploreTrendsMaxRows).toList();
    if (trends.isEmpty) {
      switch (state.status) {
        case TrendsStatus.initial:
        case TrendsStatus.loading:
          return const SingleChildScrollView(
            primary: false,
            child: TrendsSkeleton(rows: 8),
          );
        case TrendsStatus.failed:
          return SingleChildScrollView(
            primary: false,
            child: TrendsErrorNotice(
              error: state.error,
              onRetry: () =>
                  context.read<TrendsCubit>().ensureLoaded(force: true),
            ),
          );
        case TrendsStatus.unavailable:
        case TrendsStatus.ready:
          return const AppEmptyView(
            icon: Icons.trending_up,
            title: 'Nothing is trending yet',
            subtitle:
                'Popular hashtags show up here once enough people use them.',
          );
      }
    }
    return ListView.builder(
      padding: EdgeInsets.only(
        bottom: MediaQuery.paddingOf(context).bottom + AppSpacing.md,
      ),
      itemCount: trends.length + 1,
      itemBuilder: (context, i) => i == 0
          ? ExploreTrendsNote(state: state)
          : exploreTrendRow(context, trends[i - 1], last: i == trends.length),
    );
  }
}
