import 'package:material_ui/material_ui.dart';
import 'package:intl/intl.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../gen/dzeroth/beacons/v1/beacons.pb.dart' as pb;
import '../../../../shared/widgets/primitives/app_card.dart';
import '../../../../shared/widgets/primitives/app_status_pill.dart';
import '../../../../shared/widgets/primitives/app_tile_icon.dart';
import '../../domain/beacon_labels.dart';
import '../beacon_icons.dart';
import 'area_label.dart';
import 'beacon_status_pill.dart';
import 'quick_join.dart';

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
    this.proximity,
  });

  final pb.BeaconView view;
  final VoidCallback? onTap;
  final bool selected;
  final bool dense;
  final bool compact;

  /// Where the plan's area sits relative to the area asked for (Explore
  /// Nearby rows): the area line reads "In your area", "Nearby: AREA" or
  /// "In CITY" instead of the area name.
  final pb.AreaProximity? proximity;

  @override
  Widget build(BuildContext context) {
    final b = view.beacon;
    final when = beaconWhenText(b);
    final status = b.status == pb.BeaconStatus.BEACON_STATUS_OPEN
        ? null
        : statusLabel(b.status);
    final badge = planViewerBadge(view.viewer);
    final area = b.hasArea() && showsAreaLabel(context, b.area)
        ? areaLabelText(b.area, proximity)
        : null;
    final spoken = [
      activityLabel(b.activity),
      b.title,
      if (!dense &&
          !compact &&
          MediaQuery.sizeOf(context).width < AppBreakpoints.mobile)
        b.communityId.isEmpty ? 'Public' : 'Community',
      when,
      b.venue,
      ?area,
      beaconSeatsText(b),
      ?status,
      ?badge,
    ].join(', ');
    Widget spokenAs(Widget child) => Semantics(
      button: onTap != null,
      selected: selected ? true : null,
      label: spoken,
      excludeSemantics: true,
      onTap: onTap,
      child: child,
    );
    if (dense) return spokenAs(_dense(context, badge, when));
    // "I'm in" (`beacon_quick_join` on, the server allows it) sits under the
    // card's text, outside its one spoken label so it stays its own button.
    final quickJoin = !compact && showsQuickJoin(context, view.viewer);
    return _card(
      context,
      badge,
      when,
      spokenAs: spokenAs,
      quickJoin: quickJoin,
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

  Widget _card(
    BuildContext context,
    String? badge,
    String when, {
    required Widget Function(Widget child) spokenAs,
    required bool quickJoin,
  }) {
    final radius = BorderRadius.circular(AppRadius.card);
    final phone = MediaQuery.sizeOf(context).width < AppBreakpoints.mobile;
    final gutter = phone
        ? AppPlansLayout.phoneGutter
        : AppPlansLayout.wideGutter;
    final cardPad = phone
        ? AppPlansLayout.phoneCardPad
        : AppPlansLayout.cardPad;
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        spokenAs(
          Material(
            type: MaterialType.transparency,
            child: InkWell(
              onTap: onTap,
              borderRadius: radius,
              child: Padding(
                padding: EdgeInsets.all(compact ? AppSpacing.md : cardPad),
                child: compact
                    ? _compactBody(context, badge, when)
                    : phone
                    ? _phoneBody(context, badge)
                    : _cardBody(context, badge, when),
              ),
            ),
          ),
        ),
        if (quickJoin)
          Padding(
            padding: EdgeInsets.fromLTRB(cardPad, 0, cardPad, AppSpacing.smd),
            child: Align(
              alignment: phone
                  ? AlignmentDirectional.centerEnd
                  : AlignmentDirectional.centerStart,
              child: PlanQuickJoinPill(
                key: ValueKey('quick-join-${view.beacon.beaconId}'),
                view: view,
              ),
            ),
          ),
      ],
    );
    final colors = Theme.of(context).colorScheme;
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
        child: phone && !compact
            ? Material(
                color: colors.surfaceContainer,
                shape: RoundedRectangleBorder(
                  borderRadius: radius,
                  side: BorderSide(color: colors.outlineVariant),
                ),
                child: body,
              )
            : AppCard(padding: EdgeInsets.zero, child: body),
      ),
    );
  }

  Widget _phoneBody(BuildContext context, String? badge) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final b = view.beacon;
    final start = b.startAt.toDateTime().toLocal();
    final locale = Localizations.localeOf(context).toString();
    final scope = b.communityId.isEmpty ? 'Public' : 'Community';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              constraints: const BoxConstraints(
                minWidth: AppPlansLayout.dateTileWidth,
                minHeight: AppPlansLayout.dateTileHeight,
              ),
              padding: const EdgeInsets.all(AppSpacing.xs),
              decoration: BoxDecoration(
                color: theme.brightness == Brightness.dark
                    ? AppPalette.drawerTileTealDark
                    : AppPalette.drawerTileTeal,
                borderRadius: BorderRadius.circular(AppRadius.card),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    DateFormat.MMM(locale).format(start),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: context.appColors.accentText,
                    ),
                  ),
                  Text(
                    DateFormat.d(locale).format(start),
                    style: theme.textTheme.titleLarge?.copyWith(
                      color: context.appColors.accentText,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.smd),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: AppSpacing.xs,
                    runSpacing: AppSpacing.xs,
                    children: [
                      AppStatusPill(
                        label: '${activityLabel(b.activity)} · $scope',
                      ),
                      if (b.status != pb.BeaconStatus.BEACON_STATUS_OPEN)
                        BeaconStatusPill(status: b.status),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(b.title, style: theme.textTheme.titleMedium),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    '${MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(start), alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context))} · ${b.venue}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                  if (b.hasArea() && showsAreaLabel(context, b.area))
                    AreaLabel(area: b.area, proximity: proximity),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        const Divider(height: 1),
        const SizedBox(height: AppSpacing.sm),
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.xs,
          children: [
            Text(
              '${b.acceptedCount}/${b.openSpots} going',
              style: theme.textTheme.labelMedium,
            ),
            if (badge != null)
              AppStatusPill(label: badge, tone: AppStatusTone.info),
          ],
        ),
      ],
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
        if (b.hasArea() && showsAreaLabel(context, b.area)) ...[
          const SizedBox(height: AppSpacing.xs),
          AreaLabel(area: b.area, proximity: proximity),
        ],
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
        AppStatusPill(
          label: end,
          tone: b.status == pb.BeaconStatus.BEACON_STATUS_ENDED
              ? AppStatusTone.danger
              : AppStatusTone.info,
        ),
      ],
    );
  }
}
