import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../core/router/app_router.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../shared/widgets/primitives/app_empty_view.dart';
import '../../../beacons/presentation/beacons_error_messages.dart';
import '../../../beacons/presentation/beacons_screen.dart'
    show PlansLoadMore, kPlansPausedBody, kPlansPausedTitle;
import '../../../beacons/presentation/bloc/beacons_cubit.dart';
import '../../../beacons/presentation/bloc/beacons_state.dart';
import '../../../beacons/presentation/widgets/beacon_row.dart';
import '../../../beacons/presentation/widgets/plan_skeletons.dart';

/// The Plans tab of Explore, as a sliver: the public plans ([cubit] is a
/// public-only [BeaconsCubit], 20 per page, "Load more" with the cursor) as
/// [BeaconRow]s, or the loading, empty, failed and paused states. Mount it
/// only with `beacons` on.
class ExplorePlansSection extends StatelessWidget {
  const ExplorePlansSection({super.key, required this.cubit});

  final BeaconsCubit cubit;

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<BeaconsCubit, BeaconsState>(
      bloc: cubit,
      builder: (context, state) {
        if (state.error is FeatureDisabledException) {
          return const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
              child: AppEmptyView(
                icon: Icons.event_outlined,
                title: kPlansPausedTitle,
                subtitle: kPlansPausedBody,
              ),
            ),
          );
        }
        switch (state.status) {
          case BeaconsLoad.loading:
            return const SliverToBoxAdapter(child: PlanCardListSkeleton());
          case BeaconsLoad.error:
            return SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.xl),
                child: AppEmptyView(
                  icon: Icons.error_outline,
                  title: beaconsErrorMessage(state.error!),
                  action: TextButton(
                    onPressed: () => unawaited(cubit.load()),
                    child: const Text('Try again'),
                  ),
                ),
              ),
            );
          case BeaconsLoad.ready:
            if (state.views.isEmpty && !state.hasMore) {
              return const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
                  child: AppEmptyView(
                    icon: Icons.event_outlined,
                    title: 'No public plans yet',
                    subtitle: 'Plans anyone can join show up here.',
                  ),
                ),
              );
            }
            return SliverList.builder(
              itemCount: state.views.length + (state.hasMore ? 1 : 0),
              itemBuilder: (context, i) {
                if (i == state.views.length) {
                  return PlansLoadMore(
                    state: state,
                    onLoadMore: () => unawaited(cubit.loadMore()),
                  );
                }
                final view = state.views[i];
                return BeaconRow(
                  key: ValueKey(view.beacon.beaconId),
                  view: view,
                  onTap: () =>
                      context.push(AppRouter.planPath(view.beacon.beaconId)),
                );
              },
            );
        }
      },
    );
  }
}
