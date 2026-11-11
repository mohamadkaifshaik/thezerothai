import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../gen/dzeroth/beacons/v1/beacons.pb.dart' as pb;
import '../../../../shared/widgets/primitives/app_avatar.dart';
import '../../../../shared/widgets/primitives/app_chip.dart';
import '../../domain/beacon_labels.dart';
import '../beacon_icons.dart';

/// What a plan says about itself, as the plan page (`/plans/:id`) draws it
/// (R12, the designs' PlanDetail): a navy hero with the activity eyebrow and
/// the status, the title, then the start, the meeting point with its privacy
/// note ([kMeetingPointNote]), the seats, the cost and the chat preference in
/// pearl beside electric-teal glyphs; under it the organiser row ("Organiser"
/// over the name), and the details when there are any.
///
/// One widget for the plan page and for the create and edit forms' preview
/// (tablet plan section 4.1, PlanCreate / PlanEdit), so the preview has the
/// page's hierarchy and weights by construction. The page's banner, People
/// card and buttons are its own; it puts its Edit button or the viewer's
/// state ([organiserTrailing]) at the end of the organiser row.
class PlanSummary extends StatelessWidget {
  const PlanSummary({
    super.key,
    required this.beacon,
    this.organiserTrailing,
    this.showOrganiser = true,
    this.titlePlaceholder,
    this.venuePlaceholder,
  });

  final pb.Beacon beacon;

  /// At the end of the organiser row: the organiser's Edit, or the viewer's
  /// "Requested" / "You're going" (the designs' PlanDetail-Visitor).
  final Widget? organiserTrailing;

  /// Whether the organiser row is drawn (a preview without a loaded
  /// profile has no organiser to show).
  final bool showOrganiser;

  /// Muted stand-ins for an empty title or meeting point (a form being
  /// filled in). Null: the text as it is.
  final String? titlePlaceholder;
  final String? venuePlaceholder;

  /// The width (at text scale 1) the trailing pill may take beside the name.
  static const double _trailingRoom = 120;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final colors = context.appColors;
    final b = beacon;
    final untitled = b.title.isEmpty && titlePlaceholder != null;
    final noVenue = b.venue.isEmpty && venuePlaceholder != null;
    final open = b.status == pb.BeaconStatus.BEACON_STATUS_OPEN;
    final title = theme.textTheme.displaySmall?.copyWith(
      color: untitled ? AppPalette.mutedOnDark : AppPalette.pearl,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DecoratedBox(
          key: const ValueKey('plan-hero'),
          decoration: BoxDecoration(
            gradient: AppGradients.hero,
            borderRadius: BorderRadius.circular(AppRadius.card),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(
                      activityIcon(b.activity),
                      size: AppIconSize.sm,
                      color: AppPalette.tealElectric,
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Text(
                        'Plan · ${activityLabel(b.activity)}'.toUpperCase(),
                        style: AppTextStyles.eyebrow(theme)
                            .copyWith(color: AppPalette.tealElectric),
                      ),
                    ),
                    if (!open) ...[
                      const SizedBox(width: AppSpacing.sm),
                      AppChip(label: statusLabel(b.status), onDark: true),
                    ],
                  ],
                ),
                const SizedBox(height: AppSpacing.smd),
                Semantics(
                  header: true,
                  child: Text(
                    untitled ? titlePlaceholder! : b.title,
                    style: title,
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                PlanFactLine(
                  icon: Icons.schedule_outlined,
                  text: beaconWhenText(b),
                ),
                PlanFactLine(
                  icon: Icons.place_outlined,
                  text: noVenue ? venuePlaceholder! : b.venue,
                  placeholder: noVenue,
                  note: kMeetingPointNote,
                ),
                PlanFactLine(
                  icon: Icons.people_outline,
                  text: beaconSeatsText(b),
                ),
                PlanFactLine(
                  icon: Icons.payments_outlined,
                  text: 'Cost: ${costLabel(b.cost)}',
                ),
                PlanFactLine(
                  icon: Icons.chat_bubble_outline,
                  text: 'Chat: ${chatPreferenceLabel(b.chatPreference)}',
                  last: true,
                ),
              ],
            ),
          ),
        ),
        if (showOrganiser) ...[
          const SizedBox(height: AppSpacing.md),
          // The trailing Edit or viewer pill sits at the end of the row
          // while the name keeps half of it; past that (large text, a narrow
          // column) it goes under the name, whole.
          LayoutBuilder(
            builder: (context, constraints) {
              final trailing = organiserTrailing;
              final under =
                  trailing != null &&
                  MediaQuery.textScalerOf(context).scale(1) * _trailingRoom >
                      constraints.maxWidth / 2;
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AppAvatar(
                    url: b.organiser.avatarUrl,
                    name: b.organiser.displayName.isEmpty
                        ? b.organiser.handle
                        : b.organiser.displayName,
                    radius: AppSize.avatarRow / 2,
                  ),
                  const SizedBox(width: AppSpacing.smd),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Organiser',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: muted,
                          ),
                        ),
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
                        if (under) ...[
                          const SizedBox(height: AppSpacing.sm),
                          trailing,
                        ],
                      ],
                    ),
                  ),
                  if (trailing != null && !under) ...[
                    const SizedBox(width: AppSpacing.sm),
                    trailing,
                  ],
                ],
              );
            },
          ),
        ],
        if (b.details.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.smd),
          Text(
            b.details,
            style: theme.textTheme.bodyLarge?.copyWith(color: colors.text2),
          ),
        ],
      ],
    );
  }
}

/// One fact of a plan on the hero: an electric-teal glyph and its pearl text,
/// with an optional muted [note] under it (the meeting point's privacy
/// note). [placeholder] draws the text muted (a stand-in for an empty field).
class PlanFactLine extends StatelessWidget {
  const PlanFactLine({
    super.key,
    required this.icon,
    required this.text,
    this.note,
    this.placeholder = false,
    this.last = false,
  });

  final IconData icon;
  final String text;

  /// A muted line under [text] (the meeting point's privacy note).
  final String? note;

  final bool placeholder;

  /// No gap under the last line.
  final bool last;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.labelMedium?.copyWith(
      color: placeholder ? AppPalette.mutedOnDark : AppPalette.pearl,
    );
    return Padding(
      padding: EdgeInsets.only(bottom: last ? 0 : AppSpacing.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: AppIconSize.action, color: AppPalette.tealElectric),
          const SizedBox(width: 10),
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
                          color: AppPalette.mutedOnDark,
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
