import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../shared/widgets/primitives/app_section_header.dart';
import '../../../../shared/widgets/user/user_list_skeleton.dart';
import '../beacons_error_messages.dart';
import '../bloc/beacons_state.dart' show BeaconsLoad;
import '../bloc/my_beacons_cubit.dart';
import '../bloc/my_beacons_state.dart';
import '../bloc/plans_session.dart';
import 'beacon_row.dart';

/// "Your plans" at the top of `/plans` on the tablet layout (tablet plan
/// section 4.1, Home = Plans list): the caller's next 2 plans (every role,
/// upcoming) and See all (My plans). Inline in band A; on top of the list
/// pane in band B. One widget, two placements, one hoisted cubit
/// ([PlansSession.yourPlans]).
///
/// - Loading: the title and 2 skeleton rows.
/// - Empty: nothing at all (no title, no gap).
/// - Failed: the title, the error copy and Try again. A FEATURE_DISABLED
///   answer draws nothing (the list below shows the paused page).
class YourPlansSection extends StatefulWidget {
  const YourPlansSection({
    super.key,
    required this.session,
    required this.onOpenPlan,
    required this.onSeeAll,
    this.selectedId,
  });

  final PlansSession session;
  final ValueChanged<String> onOpenPlan;
  final VoidCallback onSeeAll;

  /// The plan open beside the list pane (band B), highlighted.
  final String? selectedId;

  @override
  State<YourPlansSection> createState() => _YourPlansSectionState();
}

class _YourPlansSectionState extends State<YourPlansSection> {
  @override
  void initState() {
    super.initState();
    // Usually loaded already by the route's open; this covers a window that
    // grew into the tablet layout with the page open.
    unawaited(widget.session.yourPlans.ensureLoaded());
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.session.changes,
      builder: (context, _) {
        final cubit = widget.session.yourPlans;
        return BlocBuilder<MyBeaconsCubit, MyBeaconsState>(
          bloc: cubit,
          builder: (context, state) => _section(context, cubit, state),
        );
      },
    );
  }

  Widget _section(
    BuildContext context,
    MyBeaconsCubit cubit,
    MyBeaconsState state,
  ) {
    final title = AppSectionHeader(
      title: kYourPlansTitle,
      actionLabel: 'See all',
      onAction: widget.onSeeAll,
    );
    final Widget body;
    switch (state.status) {
      case BeaconsLoad.loading:
        body = const UserListSkeleton(
          rows: PlansSession.yourPlansLimit,
          semanticsLabel: 'Loading your plans',
        );
      case BeaconsLoad.error:
        final error = state.error!;
        if (error is FeatureDisabledException) return const SizedBox.shrink();
        final theme = Theme.of(context);
        body = Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  beaconsErrorMessage(error),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              TextButton(onPressed: cubit.load, child: const Text('Try again')),
            ],
          ),
        );
      case BeaconsLoad.ready:
        if (state.views.isEmpty) return const SizedBox.shrink();
        body = Column(
          children: [
            for (final view in state.views.take(PlansSession.yourPlansLimit))
              BeaconRow(
                view: view,
                dense: true,
                selected: view.beacon.beaconId == widget.selectedId,
                onTap: () => widget.onOpenPlan(view.beacon.beaconId),
              ),
          ],
        );
    }
    return Column(
      key: const ValueKey('your-plans'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        title,
        body,
        const SizedBox(height: AppSpacing.sm),
        const Divider(height: 1),
      ],
    );
  }
}

/// The section's title.
const kYourPlansTitle = 'Your plans';
