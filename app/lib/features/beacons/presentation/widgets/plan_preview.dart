import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../gen/dzeroth/beacons/v1/beacons.pb.dart' as pb;
import 'plan_summary.dart';

/// The title of the preview: the header action and its dialog (one label for
/// one thing).
const kPlanPreviewTitle = 'Preview';

/// The stand-in for a plan with no title yet.
const kPlanPreviewUntitled = 'Your plan';

/// The stand-in for a plan with no meeting point yet.
const kPlanPreviewNoVenue = 'Add a meeting point';

/// How a plan being created or edited will read on its page (the forms'
/// Preview dialog): the page's own [PlanSummary] of [beacon], with stand-ins
/// for an empty title or meeting point. Built from the form only; no call.
/// The dialog pads its title and body already, so the summary lines up with
/// the title above it.
class PlanPreview extends StatelessWidget {
  const PlanPreview({
    super.key,
    required this.beacon,
    this.showOrganiser = true,
  });

  final pb.Beacon beacon;

  /// False when the organiser is not known (no loaded profile).
  final bool showOrganiser;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
    child: PlanSummary(
      beacon: beacon,
      showOrganiser: showOrganiser,
      titlePlaceholder: kPlanPreviewUntitled,
      venuePlaceholder: kPlanPreviewNoVenue,
    ),
  );
}
