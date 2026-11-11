import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../gen/dzeroth/beacons/v1/beacons.pb.dart' as pb;
import '../../../../shared/widgets/primitives/app_chip.dart';
import '../../domain/beacon_labels.dart';

/// The key of the Plans list's activity chip row.
const kPlansActivityFilterKey = ValueKey('plans-activity-filter');

/// The spoken name of the chip row.
const kPlansActivityFilterLabel = 'Filter plans by activity';

/// The chips of the row, in the designs' order: "All" (UNSPECIFIED: no
/// filter), then each activity a plan can have but "Other".
const kPlanActivityFilters = <pb.BeaconActivity>[
  pb.BeaconActivity.BEACON_ACTIVITY_UNSPECIFIED,
  pb.BeaconActivity.BEACON_ACTIVITY_COFFEE,
  pb.BeaconActivity.BEACON_ACTIVITY_MEAL,
  pb.BeaconActivity.BEACON_ACTIVITY_STUDY,
  pb.BeaconActivity.BEACON_ACTIVITY_SPORTS,
  pb.BeaconActivity.BEACON_ACTIVITY_WALK,
  pb.BeaconActivity.BEACON_ACTIVITY_SHOPPING,
];

/// A chip's label: "All", or the activity's own label.
String planActivityFilterLabel(pb.BeaconActivity a) =>
    a == pb.BeaconActivity.BEACON_ACTIVITY_UNSPECIFIED
    ? 'All'
    : activityLabel(a);

/// F29: the Plans list's activity chips (dz.css `.seg` of `.pill`s), one
/// row that scrolls sideways when it does not fit (a phone, large text),
/// so a label is never cut. Each chip is an [AppFilterPill]: 48 dp target,
/// a check and w700 when selected, announced as a selected button. The row
/// is a named group; it mirrors in RTL.
class PlansActivityFilter extends StatelessWidget {
  const PlansActivityFilter({
    super.key,
    required this.selected,
    required this.onSelected,
  });

  final pb.BeaconActivity selected;
  final ValueChanged<pb.BeaconActivity> onSelected;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      key: kPlansActivityFilterKey,
      container: true,
      explicitChildNodes: true,
      label: kPlansActivityFilterLabel,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
        child: Row(
          children: [
            for (final (i, a) in kPlanActivityFilters.indexed) ...[
              if (i > 0) const SizedBox(width: AppSpacing.sm),
              AppFilterPill(
                label: planActivityFilterLabel(a),
                selected: a == selected,
                onPressed: () => onSelected(a),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
