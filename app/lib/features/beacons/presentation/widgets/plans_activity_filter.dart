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
/// filter), then each activity a plan can have, "Others" last. "Others"
/// asks the server for `other` only: a plan with no activity (an older one)
/// is not in it.
const kPlanActivityFilters = <pb.BeaconActivity>[
  pb.BeaconActivity.BEACON_ACTIVITY_UNSPECIFIED,
  pb.BeaconActivity.BEACON_ACTIVITY_COFFEE,
  pb.BeaconActivity.BEACON_ACTIVITY_MEAL,
  pb.BeaconActivity.BEACON_ACTIVITY_STUDY,
  pb.BeaconActivity.BEACON_ACTIVITY_SPORTS,
  pb.BeaconActivity.BEACON_ACTIVITY_WALK,
  pb.BeaconActivity.BEACON_ACTIVITY_SHOPPING,
  pb.BeaconActivity.BEACON_ACTIVITY_OTHER,
];

/// A chip's label: "All", "Others" (the plans of no listed activity), or the
/// activity's own label.
String planActivityFilterLabel(pb.BeaconActivity a) => switch (a) {
  pb.BeaconActivity.BEACON_ACTIVITY_UNSPECIFIED => 'All',
  pb.BeaconActivity.BEACON_ACTIVITY_OTHER => 'Others',
  _ => activityLabel(a),
};

/// One row of filter chips for the Plans list (the activities, the
/// communities): it scrolls sideways when it does not fit (a phone, large
/// text), never wraps, so a label is never cut. The chips are separated by
/// [AppSpacing.sm] and the row is padded by [AppSpacing.md]; it is a named
/// group and mirrors in RTL.
class PlansChipRow extends StatelessWidget {
  const PlansChipRow({
    super.key,
    required this.label,
    required this.chips,
    this.groupKey,
  });

  final String label;
  final List<Widget> chips;
  final Key? groupKey;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      key: groupKey,
      container: true,
      explicitChildNodes: true,
      label: label,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
        child: Row(
          children: [
            for (final (i, chip) in chips.indexed) ...[
              if (i > 0) const SizedBox(width: AppSpacing.sm),
              chip,
            ],
          ],
        ),
      ),
    );
  }
}

/// F29: the Plans list's activity chips (the designs' `.pill` chips). Each
/// chip is an [AppFilterPill]: 48 dp target, a check and w700 when selected,
/// announced as a selected button.
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
    return PlansChipRow(
      groupKey: kPlansActivityFilterKey,
      label: kPlansActivityFilterLabel,
      chips: [
        for (final a in kPlanActivityFilters)
          AppFilterPill(
            label: planActivityFilterLabel(a),
            selected: a == selected,
            onPressed: () => onSelected(a),
          ),
      ],
    );
  }
}
