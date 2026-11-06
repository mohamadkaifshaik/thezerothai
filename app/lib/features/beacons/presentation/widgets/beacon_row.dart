import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../gen/dzeroth/beacons/v1/beacons.pb.dart' as pb;
import '../../../../shared/widgets/primitives/app_tile_icon.dart';
import '../../domain/beacon_labels.dart';
import 'beacon_status_pill.dart';

/// One plan in a list: activity icon, title, when, meeting point, seats and
/// the status pill when the plan is not OPEN. The whole row is the tap
/// target (>= 48dp) and speaks title, when, venue, seats and status as one
/// label.
class BeaconRow extends StatelessWidget {
  const BeaconRow({super.key, required this.view, this.onTap});

  final pb.BeaconView view;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final b = view.beacon;
    final when = beaconWhenText(b);
    final seats = beaconSeatsText(b);
    final status = b.status == pb.BeaconStatus.BEACON_STATUS_OPEN
        ? null
        : statusLabel(b.status);
    final spoken = [
      activityLabel(b.activity),
      b.title,
      when,
      b.venue,
      seats,
      ?status,
    ].join(', ');
    return Semantics(
      button: onTap != null,
      label: spoken,
      excludeSemantics: true,
      onTap: onTap,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: AppSpacing.minTapTarget),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.smd,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AppTileIcon(icon: activityIcon(b.activity)),
                const SizedBox(width: AppSpacing.smd),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        b.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium,
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      Text(
                        when,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: muted,
                        ),
                      ),
                      Text(
                        b.venue,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: muted,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      Wrap(
                        spacing: AppSpacing.sm,
                        runSpacing: AppSpacing.xs,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            seats,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: muted,
                            ),
                          ),
                          BeaconStatusPill(status: b.status),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
