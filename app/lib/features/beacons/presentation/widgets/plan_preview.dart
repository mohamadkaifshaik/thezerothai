import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/context_pane.dart';
import '../../../../gen/dzeroth/beacons/v1/beacons.pb.dart' as pb;
import '../../../../shared/widgets/user/user_list_skeleton.dart';
import 'plan_summary.dart';

/// The title of the preview: the band A header action, its dialog and band
/// B's pane card (one label for one thing).
const kPlanPreviewTitle = 'Preview';

/// The stand-in for a plan with no title yet.
const kPlanPreviewUntitled = 'Your plan';

/// The stand-in for a plan with no meeting point yet.
const kPlanPreviewNoVenue = 'Add a meeting point';

/// How a plan being created or edited will read on its page (tablet plan
/// section 4.1, PlanCreate / PlanEdit "Live preview"): the page's own
/// [PlanSummary] of [beacon], with stand-ins for an empty title or meeting
/// point. Built from the form only; no call.
class PlanPreview extends StatelessWidget {
  const PlanPreview({
    super.key,
    required this.beacon,
    this.showOrganiser = true,
    this.inset = AppSpacing.md,
  });

  final pb.Beacon beacon;

  /// False when the organiser is not known (no loaded profile).
  final bool showOrganiser;

  /// The start and end padding: the card's own (the pane), or 0 where the
  /// container pads already (the dialog), so the preview lines up with the
  /// title above it.
  final double inset;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsetsDirectional.fromSTEB(
      inset,
      AppSpacing.sm,
      inset,
      AppSpacing.sm,
    ),
    child: PlanSummary(
      beacon: beacon,
      showOrganiser: showOrganiser,
      titlePlaceholder: kPlanPreviewUntitled,
      venuePlaceholder: kPlanPreviewNoVenue,
    ),
  );
}

/// Band B's "Preview" card: [PlanPreview] of [beacon] in a context-pane
/// card, or the card over a skeleton while there is nothing to show yet (the
/// edit form loading its plan, a page not yet lent to the pane).
class PlanPreviewCard extends StatelessWidget {
  const PlanPreviewCard({super.key, this.beacon, this.showOrganiser = true});

  /// Null: the loading look.
  final pb.Beacon? beacon;
  final bool showOrganiser;

  @override
  Widget build(BuildContext context) {
    final b = beacon;
    return ContextPaneCard(
      title: kPlanPreviewTitle,
      child: b == null
          ? const Padding(
              padding: EdgeInsets.only(bottom: AppSpacing.sm),
              child: UserListSkeleton(
                rows: 2,
                semanticsLabel: 'Loading preview',
              ),
            )
          : PlanPreview(beacon: b, showOrganiser: showOrganiser),
    );
  }
}
