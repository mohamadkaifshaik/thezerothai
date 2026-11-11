import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../gen/dzeroth/beacons/v1/beacons.pb.dart' as pb;
import '../../../../shared/widgets/primitives/app_avatar.dart';
import '../../../../shared/widgets/primitives/app_status_pill.dart';
import '../../../../shared/widgets/primitives/app_tile_icon.dart';
import '../../domain/beacon_labels.dart';
import '../beacon_icons.dart';
import 'beacon_status_pill.dart';

/// What a plan says about itself, as the plan page (`/plans/:id`) draws it:
/// the activity tile, the title (a heading) with the status and viewer
/// pills, then the start, the meeting point with its privacy note
/// ([kMeetingPointNote]), the seats, the cost and the chat preference, the
/// organiser, and the details when there are any.
///
/// One widget for the plan page and for the create and edit forms' preview
/// (tablet plan section 4.1, PlanCreate / PlanEdit), so the preview has the
/// page's hierarchy and weights by construction. The page's banner and
/// buttons are its own.
class PlanSummary extends StatelessWidget {
  const PlanSummary({
    super.key,
    required this.beacon,
    this.viewerPill,
    this.showOrganiser = true,
    this.titlePlaceholder,
    this.venuePlaceholder,
  });

  final pb.Beacon beacon;

  /// "Requested" / "You're going", beside the status pill.
  final String? viewerPill;

  /// Whether the organiser row is drawn (a preview without a loaded
  /// profile has no organiser to show).
  final bool showOrganiser;

  /// Muted stand-ins for an empty title or meeting point (a form being
  /// filled in). Null: the text as it is.
  final String? titlePlaceholder;
  final String? venuePlaceholder;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final b = beacon;
    final untitled = b.title.isEmpty && titlePlaceholder != null;
    final noVenue = b.venue.isEmpty && venuePlaceholder != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AppTileIcon(icon: activityIcon(b.activity)),
            const SizedBox(width: AppSpacing.smd),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Semantics(
                    header: true,
                    child: Text(
                      untitled ? titlePlaceholder! : b.title,
                      style: untitled
                          ? theme.textTheme.titleLarge?.copyWith(color: muted)
                          : theme.textTheme.titleLarge,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Wrap(
                    spacing: AppSpacing.sm,
                    runSpacing: AppSpacing.xs,
                    children: [
                      BeaconStatusPill(status: b.status),
                      if (viewerPill != null)
                        AppStatusPill(
                          label: viewerPill!,
                          tone: AppStatusTone.info,
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        PlanFactLine(icon: Icons.schedule_outlined, text: beaconWhenText(b)),
        PlanFactLine(
          icon: Icons.place_outlined,
          text: noVenue ? venuePlaceholder! : b.venue,
          placeholder: noVenue,
          note: kMeetingPointNote,
        ),
        PlanFactLine(icon: Icons.people_outline, text: beaconSeatsText(b)),
        PlanFactLine(
          icon: Icons.payments_outlined,
          text: 'Cost: ${costLabel(b.cost)}',
        ),
        PlanFactLine(
          icon: Icons.chat_bubble_outline,
          text: 'Chat: ${chatPreferenceLabel(b.chatPreference)}',
        ),
        if (showOrganiser) ...[
          const SizedBox(height: AppSpacing.md),
          // The role label keeps its natural width while it fits, and gives
          // way (ellipsis) past 40 % of the row: large text in a narrow
          // column, such as the 320 dp context pane at 2.0.
          LayoutBuilder(
            builder: (context, constraints) => Row(
              children: [
                AppAvatar(url: b.organiser.avatarUrl, radius: 20),
                const SizedBox(width: AppSpacing.smd),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        b.organiser.displayName.isEmpty
                            ? b.organiser.handle
                            : b.organiser.displayName,
                        style: theme.textTheme.titleSmall,
                      ),
                      Text(
                        '@${b.organiser.handle}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: muted,
                        ),
                      ),
                    ],
                  ),
                ),
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: constraints.maxWidth * 0.4,
                  ),
                  child: Text(
                    'Organiser',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(color: muted),
                  ),
                ),
              ],
            ),
          ),
        ],
        if (b.details.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.md),
          Text(b.details, style: theme.textTheme.bodyMedium),
        ],
      ],
    );
  }
}

/// One fact of a plan: a muted icon and its text, with an optional muted
/// [note] under it (the meeting point's privacy note). [placeholder] draws
/// the text muted (a stand-in for an empty field).
class PlanFactLine extends StatelessWidget {
  const PlanFactLine({
    super.key,
    required this.icon,
    required this.text,
    this.note,
    this.placeholder = false,
  });

  final IconData icon;
  final String text;

  /// A muted line under [text] (the meeting point's privacy note).
  final String? note;

  final bool placeholder;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final style = placeholder
        ? theme.textTheme.bodyMedium?.copyWith(color: muted)
        : theme.textTheme.bodyMedium;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: AppIconSize.md, color: muted),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: note == null
                ? Text(text, style: style)
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(text, style: style),
                      Text(
                        note!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: muted,
                        ),
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}
