import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../gen/dzeroth/beacons/v1/beacons.pb.dart' as pb;
import '../../../../shared/widgets/primitives/app_card.dart';
import '../../../../shared/widgets/primitives/app_status_pill.dart';
import '../../../../shared/widgets/primitives/app_tile_icon.dart';
import '../../domain/beacon_labels.dart';
import '../beacon_icons.dart';
import 'beacon_status_pill.dart';

/// The viewer's part in a plan, as a list card says it: "Organising",
/// "Requested" or "You're going" (the designs' Plans list); null when none.
String? planViewerBadge(pb.ViewerState v) {
  if (v.canManage || v.role == pb.ViewerRole.VIEWER_ROLE_ORGANISER) {
    return 'Organising';
  }
  return switch (v.participantState) {
    pb.ParticipantState.PARTICIPANT_STATE_REQUESTED => 'Requested',
    pb.ParticipantState.PARTICIPANT_STATE_ACCEPTED => "You're going",
    _ => null,
  };
}

/// One plan in a list (R12, the designs' Plans list and My plans): a raised
/// card with the activity eyebrow ("PLAN · COFFEE") and the status when the
/// plan is not OPEN, the title, when and where, and how many are going with
/// the viewer's part at the end.
///
/// [dense] is the compact row of "Your plans" (the designs' side box rows):
/// the activity tile, title, when, and the viewer's part. [compact] is the
/// row of My plans: the tile, the viewer's part in the eyebrow ("ORGANISING ·
/// COFFEE"), title and when, and the going count (or "Waiting") at the end.
///
/// The whole card is the tap target (>= 48 dp) and speaks title, when,
/// venue, seats, status and the viewer's part as one label. [selected]
/// marks the open plan in the band B list pane (tablet layout): a 2 dp
/// indicator outline and `selected` in semantics.
class BeaconRow extends StatelessWidget {
  const BeaconRow({
    super.key,
    required this.view,
    this.onTap,
    this.selected = false,
    this.dense = false,
    this.compact = false,
  });

  final pb.BeaconView view;
  final VoidCallback? onTap;
  final bool selected;
  final bool dense;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final b = view.beacon;
    final when = beaconWhenText(b);
    final status = b.status == pb.BeaconStatus.BEACON_STATUS_OPEN
        ? null
        : statusLabel(b.status);
    final badge = planViewerBadge(view.viewer);
    final spoken = [
      activityLabel(b.activity),
      b.title,
      when,
      b.venue,
      beaconSeatsText(b),
      ?status,
      ?badge,
    ].join(', ');
    return Semantics(
      button: onTap != null,
      selected: selected ? true : null,
      label: spoken,
      excludeSemantics: true,
      onTap: onTap,
      child: dense ? _dense(context, badge, when) : _card(context, badge, when),
    );
  }

  Widget _dense(BuildContext context, String? badge, String when) {
    final theme = Theme.of(context);
    final b = view.beacon;
    final row = InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: AppSpacing.minTapTarget),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.smd,
          ),
          child: Row(
            children: [
              AppTileIcon(icon: activityIcon(b.activity)),
              const SizedBox(width: AppSpacing.smd),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      b.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall,
                    ),
                    Text(
                      when,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              if (badge != null) ...[
                const SizedBox(width: AppSpacing.sm),
                AppStatusPill(label: badge, tone: AppStatusTone.info),
              ],
            ],
          ),
        ),
      ),
    );
    return selected
        ? Material(color: context.appColors.selectedRow, child: row)
        : row;
  }

  Widget _card(BuildContext context, String? badge, String when) {
    final radius = BorderRadius.circular(AppRadius.card);
    final gutter = MediaQuery.sizeOf(context).width < AppBreakpoints.mobile
        ? AppPlansLayout.phoneGutter
        : AppPlansLayout.wideGutter;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: gutter, vertical: 6),
      child: DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          borderRadius: radius,
          border: selected
              ? Border.all(color: context.appColors.selectedIndicator, width: 2)
              : null,
        ),
        child: AppCard(
          padding: EdgeInsets.zero,
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              onTap: onTap,
              borderRadius: radius,
              child: Padding(
                padding: EdgeInsets.all(compact ? AppSpacing.md : 20),
                child: compact
                    ? _compactBody(context, badge, when)
                    : _cardBody(context, badge, when),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The eyebrow: "PLAN · COFFEE", or with [compact] the viewer's part,
  /// "ORGANISING · COFFEE" (the pill says "You're going"; the eyebrow,
  /// "Going").
  Widget _eyebrow(BuildContext context, String? badge) {
    final activity = activityLabel(view.beacon.activity);
    final part = badge == "You're going" ? 'Going' : badge;
    final text = compact && part != null
        ? '$part · $activity'
        : 'Plan · $activity';
    return Text(
      text.toUpperCase(),
      style: AppTextStyles.eyebrow(Theme.of(context))
          .copyWith(color: context.appColors.accentText),
    );
  }

  Widget _cardBody(BuildContext context, String? badge, String when) {
    final theme = Theme.of(context);
    final b = view.beacon;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: _eyebrow(context, badge)),
            const SizedBox(width: AppSpacing.sm),
            BeaconStatusPill(status: b.status),
          ],
        ),
        const SizedBox(height: AppSpacing.smd),
        Text(
          b.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.headlineLarge,
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(
          '$when · ${b.venue}',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: AppSpacing.smd),
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.xs,
          crossAxisAlignment: WrapCrossAlignment.center,
          alignment: WrapAlignment.spaceBetween,
          children: [
            Text(
              '${b.acceptedCount} going',
              style: theme.textTheme.labelMedium?.copyWith(
                color: context.appColors.text2,
              ),
            ),
            if (badge != null)
              AppStatusPill(label: badge, tone: AppStatusTone.info),
          ],
        ),
      ],
    );
  }

  /// My plans' row: the tile, the eyebrow, title and when, and the count at
  /// the end.
  Widget _compactBody(BuildContext context, String? badge, String when) {
    final theme = Theme.of(context);
    final b = view.beacon;
    final waiting =
        view.viewer.participantState ==
        pb.ParticipantState.PARTICIPANT_STATE_REQUESTED;
    final end = waiting
        ? 'Waiting'
        : b.status == pb.BeaconStatus.BEACON_STATUS_OPEN
        ? '${b.acceptedCount} going'
        : statusLabel(b.status);
    return Row(
      children: [
        AppTileIcon(
          icon: activityIcon(b.activity),
          size: AppPlansLayout.tileSize,
        ),
        const SizedBox(width: AppSpacing.smd),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _eyebrow(context, badge),
              Text(
                b.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium,
              ),
              Text(
                when,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        AppStatusPill(label: end, tone: AppStatusTone.info),
      ],
    );
  }
}
