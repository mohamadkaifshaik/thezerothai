import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/router/app_router.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../gen/dzeroth/beacons/v1/beacons.pb.dart' as pb;
import '../../../../shared/widgets/primitives/app_card.dart';
import '../../../../shared/widgets/primitives/app_empty_view.dart';
import '../../../beacons/presentation/beacons_error_messages.dart';
import '../../../beacons/presentation/bloc/nearby_plans_cubit.dart';
import '../../../beacons/presentation/widgets/beacon_row.dart';
import '../../../beacons/presentation/widgets/plan_form_fields.dart';
import '../../../beacons/presentation/widgets/plan_skeletons.dart';

const kNearbyPromptTitle = 'See plans near you';
const kNearbyPromptBody =
    'Choose an area to see public plans in it and around it.';
const kNearbyChooseArea = 'Choose an area';
const kNearbyChangeArea = 'Change area';
const kNearbyScopeArea = 'Your area';

/// "All of CITY".
String nearbyScopeCity(String city) => 'All of $city';

/// "No plans near AREA yet".
String nearbyEmptyTitle(String area) => 'No plans near $area yet';

/// The count line of the header: "14 plans" (exact, up to one page),
/// "About 120 plans" (an aggregate above that), "A few plans" (fewer than the
/// server's K-anonymity minimum) or null (none). The server's rule: an exact
/// count fits in the first page's probe, anything above it is an aggregate
/// capped at 1000.
String? nearbyCountText(pb.NearbyCount? count) {
  if (count == null) return null;
  if (count.few) return 'A few plans';
  final n = count.plans;
  if (n <= 0) return null;
  if (n == 1) return '1 plan';
  if (n <= NearbyPlansCubit.pageSize) return '$n plans';
  return n >= 1000 ? 'About 1000+ plans' : 'About $n plans';
}

/// The Nearby tab of Explore, as a sliver. [cubit] is made by the screen and
/// lives with it. Mount it only with `location` and `beacons` on.
class ExploreNearbySection extends StatelessWidget {
  const ExploreNearbySection({super.key, required this.cubit});

  final NearbyPlansCubit cubit;

  /// Opens Settings > Location and reloads Nearby on return.
  static Future<void> chooseArea(
    BuildContext context,
    NearbyPlansCubit cubit,
  ) async {
    await context.push(AppRouter.locationSettingsPath);
    if (!cubit.isClosed) unawaited(cubit.load());
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<NearbyPlansCubit, NearbyPlansState>(
      bloc: cubit,
      builder: (context, state) {
        switch (state.load) {
          case NearbyLoad.loading:
            return const SliverToBoxAdapter(child: PlanCardListSkeleton());
          case NearbyLoad.disabled:
            // The screen hides the tab; nothing to draw meanwhile.
            return const SliverToBoxAdapter(child: SizedBox.shrink());
          case NearbyLoad.noArea:
            return SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.xl),
                child: AppEmptyView(
                  icon: Icons.place_outlined,
                  title: kNearbyPromptTitle,
                  subtitle: kNearbyPromptBody,
                  action: FilledButton(
                    onPressed: () => unawaited(chooseArea(context, cubit)),
                    child: const Text(kNearbyChooseArea),
                  ),
                ),
              ),
            );
          case NearbyLoad.error:
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
          case NearbyLoad.ready:
            return _ready(context, state);
        }
      },
    );
  }

  Widget _ready(BuildContext context, NearbyPlansState state) {
    final area = state.area;
    final empty = state.items.isEmpty && !state.hasMore;
    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(
          child: _Header(cubit: cubit, state: state),
        ),
        if (empty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.xl),
              child: AppEmptyView(
                icon: Icons.event_outlined,
                title: nearbyEmptyTitle(area?.name ?? 'you'),
                subtitle: 'Plans anyone can join show up here.',
              ),
            ),
          )
        else
          SliverList.builder(
            itemCount: state.items.length + (state.hasMore ? 1 : 0),
            itemBuilder: (context, i) {
              if (i == state.items.length) return _LoadMore(cubit: cubit);
              final item = state.items[i];
              final id = item.view.beacon.beaconId;
              return BeaconRow(
                key: ValueKey(id),
                view: item.view,
                proximity: item.proximity,
                onTap: () => context.push(AppRouter.planPath(id)),
              );
            },
          ),
      ],
    );
  }
}

/// The "Happening nearby" card: the area, the count line, the scope switch
/// (neighbourhoods only) and "Change area".
class _Header extends StatelessWidget {
  const _Header({required this.cubit, required this.state});

  final NearbyPlansCubit cubit;
  final NearbyPlansState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final area = state.area;
    final count = nearbyCountText(state.count);
    final gutter = MediaQuery.sizeOf(context).width < AppBreakpoints.mobile
        ? AppPlansLayout.phoneGutter
        : AppPlansLayout.wideGutter;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        gutter,
        AppSpacing.sm,
        gutter,
        AppSpacing.sm,
      ),
      child: AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Semantics(
              header: true,
              child: Text(
                area == null ? 'In your area' : 'In your area · ${area.name}',
                style: theme.textTheme.titleMedium,
              ),
            ),
            if (count != null) ...[
              const SizedBox(height: AppSpacing.xs),
              Text(
                count,
                key: const ValueKey('nearby-count'),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            if (state.canSwitchScope) ...[
              const SizedBox(height: AppSpacing.smd),
              PlanChoiceChips<pb.NearbyScope>(
                values: const [
                  pb.NearbyScope.NEARBY_SCOPE_AREA,
                  pb.NearbyScope.NEARBY_SCOPE_CITY,
                ],
                selected: state.scope,
                label: (s) => s == pb.NearbyScope.NEARBY_SCOPE_CITY
                    ? nearbyScopeCity(area!.cityName)
                    : kNearbyScopeArea,
                enabled: true,
                onSelected: (s) => unawaited(cubit.setScope(s)),
              ),
            ],
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton(
                onPressed: () =>
                    unawaited(ExploreNearbySection.chooseArea(context, cubit)),
                child: const Text(kNearbyChangeArea),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LoadMore extends StatelessWidget {
  const _LoadMore({required this.cubit});

  final NearbyPlansCubit cubit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return BlocBuilder<NearbyPlansCubit, NearbyPlansState>(
      bloc: cubit,
      buildWhen: (a, b) => a.loadingMore != b.loadingMore || a.error != b.error,
      builder: (context, state) => Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          children: [
            if (state.error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                child: Text(
                  beaconsErrorMessage(state.error!),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            if (state.loadingMore)
              Semantics(
                label: 'Loading more plans',
                child: const SizedBox(
                  width: AppIconSize.lg,
                  height: AppIconSize.lg,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            else
              TextButton(
                onPressed: () => unawaited(cubit.loadMore()),
                child: const Text('Load more'),
              ),
          ],
        ),
      ),
    );
  }
}
