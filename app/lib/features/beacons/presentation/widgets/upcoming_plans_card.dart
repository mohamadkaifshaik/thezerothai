import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/feature_flags/feature_flags.dart';
import '../../../../core/router/app_router.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/context_pane.dart';
import '../../domain/beacons_feature_flag.dart';
import '../../../../gen/dzeroth/beacons/v1/beacons.pb.dart' as pb;
import '../bloc/beacons_cubit.dart';
import '../bloc/beacons_state.dart';
import '../bloc/plans_session.dart';
import 'beacon_row.dart';

/// How many plans the card shows.
const kUpcomingPlansRows = 3;

/// The card's title (the desktop mocks' "Plans near you" / "More plans
/// nearby": the list is the public plans, soonest first, not sorted by
/// distance, so the title does not say "near").
const kUpcomingPlansTitle = 'Upcoming plans';

/// The desktop side column's "Upcoming plans" card (the Explore, Post detail
/// and My plans mocks): the first public plans of the app's hoisted `/plans`
/// list ([PlansSession.list]) as dense [BeaconRow]s and "See all plans" to
/// `/plans`. It sends at most the one `ListBeacons` the Plans page sends too
/// (`ensureLoaded`: nothing when the list was loaded already).
///
/// Draws nothing without `beacons`, while loading, empty or failed (a
/// secondary box has no error state), or when the list was switched to a
/// Community audience or an activity (the card is the public list).
class UpcomingPlansCard extends StatefulWidget {
  const UpcomingPlansCard({
    super.key,
    required this.session,
    this.margin = const EdgeInsets.only(bottom: AppSpacing.md),
  });

  final PlansSession session;
  final EdgeInsetsGeometry margin;

  @override
  State<UpcomingPlansCard> createState() => _UpcomingPlansCardState();
}

class _UpcomingPlansCardState extends State<UpcomingPlansCard> {
  @override
  void initState() {
    super.initState();
    if (!featureEnabledSnapshot(context, kFeatureBeacons)) return;
    unawaited(widget.session.list.ensureLoaded());
  }

  @override
  Widget build(BuildContext context) {
    if (!isFeatureEnabled(context, kFeatureBeacons)) {
      return const SizedBox.shrink();
    }
    return ListenableBuilder(
      listenable: widget.session.changes,
      builder: (context, _) {
        final cubit = widget.session.list;
        return BlocBuilder<BeaconsCubit, BeaconsState>(
          bloc: cubit,
          builder: (context, state) {
            if (state.status != BeaconsLoad.ready ||
                state.views.isEmpty ||
                !state.selected.isPublic ||
                state.activity !=
                    pb.BeaconActivity.BEACON_ACTIVITY_UNSPECIFIED) {
              return const SizedBox.shrink();
            }
            return ContextPaneCard(
              key: const ValueKey('upcoming-plans'),
              title: kUpcomingPlansTitle,
              margin: widget.margin,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final view in state.views.take(kUpcomingPlansRows))
                    BeaconRow(
                      key: ValueKey(view.beacon.beaconId),
                      view: view,
                      dense: true,
                      onTap: () => context.push(
                        AppRouter.planPath(view.beacon.beaconId),
                      ),
                    ),
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: TextButton(
                      style: TextButton.styleFrom(
                        minimumSize: const Size(0, AppSpacing.minTapTarget),
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.md,
                        ),
                        textStyle: Theme.of(context).textTheme.bodyMedium,
                      ),
                      onPressed: () => context.go(AppRouter.plansPath),
                      child: const Text('See all plans'),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}
