import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../gen/dzeroth/beacons/v1/beacons.pb.dart' as pb;
import '../../../../shared/format/scheduled_time.dart';

/// Shows the date picker; null when dismissed. A seam so tests need not drive
/// the platform dial.
typedef BeaconPickDate = Future<DateTime?> Function(
  BuildContext context, {
  required DateTime initial,
  required DateTime first,
  required DateTime last,
});

/// Shows the time picker; null when dismissed.
typedef BeaconPickTime = Future<TimeOfDay?> Function(
  BuildContext context, {
  required TimeOfDay initial,
});

/// The helper under Date and Time on the edit form (F28; the designs'
/// PlanEdit): a new date or time tells everyone who joined (owner ruling,
/// third round: `NOTIFICATION_TYPE_BEACON_UPDATED`).
const kPlanEditNotifyHelper = 'People who joined will be notified.';

/// The title of the edit form's read-only box (the designs' PlanEdit): what
/// `UpdateBeacon` does not change.
const kPlanSetAtCreation = 'Set when the plan was created';

/// The read-only box's title once the plan has started: the start and the
/// cost join what can't change.
const kPlanFixedNow = "Can't change now";

/// The costs a plan form offers, in the designs' order.
const kPlanCosts = <pb.BeaconCost>[
  pb.BeaconCost.BEACON_COST_FREE,
  pb.BeaconCost.BEACON_COST_EVERYONE_PAYS_OWN,
  pb.BeaconCost.BEACON_COST_SPLIT_EVENLY,
];

/// Why a started plan's edit form has no date, time, duration or cost: the
/// server refuses them once the plan has started (F28, reason "started").
const kPlanStartedNote =
    "This plan has started, so its time and cost can't change.";

/// One group of a plan form: its label (a heading for screen readers, as
/// before) over [child].
class PlanFormSection extends StatelessWidget {
  const PlanFormSection({super.key, required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.md, bottom: AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            header: true,
            child: Text(title, style: theme.textTheme.titleMedium),
          ),
          const SizedBox(height: AppSpacing.sm),
          child,
        ],
      ),
    );
  }
}

/// A wrapping row of choice pills (the themed [ChoiceChip]: a check and the
/// indicator colour when selected).
class PlanChoiceChips<T> extends StatelessWidget {
  const PlanChoiceChips({
    super.key,
    required this.values,
    required this.selected,
    required this.label,
    required this.enabled,
    required this.onSelected,
  });

  final List<T> values;
  final T selected;
  final String Function(T) label;
  final bool enabled;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: AppSpacing.sm,
    runSpacing: AppSpacing.xs,
    children: [
      for (final v in values)
        ChoiceChip(
          label: Text(label(v)),
          selected: v == selected,
          onSelected: enabled ? (_) => onSelected(v) : null,
        ),
    ],
  );
}

/// A plan's start as two fields, Date and Time (the designs' PlanCreate and
/// PlanEdit): each a label over a field-shaped button with its value and a
/// calendar or clock glyph, opening the picker. Side by side when both
/// values fit whole; one over the other otherwise (a phone, large text), so
/// a value is never cut. [helper] (muted) and [error] sit under them.
class PlanWhenFields extends StatelessWidget {
  const PlanWhenFields({
    super.key,
    required this.start,
    required this.onPickDate,
    required this.onPickTime,
    this.enabled = true,
    this.helper,
    this.error,
  });

  final DateTime start;
  final VoidCallback onPickDate;
  final VoidCallback onPickTime;
  final bool enabled;
  final String? helper;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final date = formatScheduledDate(start);
    final time = formatScheduledClock(start);
    final dateField = _PickerField(
      label: 'Date',
      value: date,
      tooltip: 'Pick a date',
      icon: Icons.calendar_today_outlined,
      onTap: enabled ? onPickDate : null,
    );
    final timeField = _PickerField(
      label: 'Time',
      value: time,
      tooltip: 'Pick a time',
      icon: Icons.schedule_outlined,
      onTap: enabled ? onPickTime : null,
    );
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.md, bottom: AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final need = [
                date,
                time,
              ].map((v) => _PickerField.widthFor(context, v)).reduce(_max);
              final beside = 2 * need + AppSpacing.smd <= constraints.maxWidth;
              if (beside) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: dateField),
                    const SizedBox(width: AppSpacing.smd),
                    Expanded(child: timeField),
                  ],
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  dateField,
                  const SizedBox(height: AppSpacing.smd),
                  timeField,
                ],
              );
            },
          ),
          if (helper != null)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.xs),
              child: Text(
                helper!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.xs),
              child: Text(
                error!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
        ],
      ),
    );
  }

  static double _max(double a, double b) => a > b ? a : b;
}

/// One picker field: [label] above a field-shaped button that shows [value]
/// and [icon]. One button node, "Date, Tue, Nov 17, 2026", with [tooltip].
class _PickerField extends StatelessWidget {
  const _PickerField({
    required this.label,
    required this.value,
    required this.tooltip,
    required this.icon,
    required this.onTap,
  });

  final String label;
  final String value;
  final String tooltip;
  final IconData icon;
  final VoidCallback? onTap;

  static const _padding = EdgeInsets.symmetric(
    horizontal: AppSpacing.md,
    vertical: AppSpacing.fieldVertical,
  );
  static const _iconGap = AppSpacing.sm;

  static TextStyle? _valueStyle(ThemeData theme) =>
      theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600);

  /// The width [value] needs in a field, whole, at the current text scale.
  static double widthFor(BuildContext context, String value) {
    final painter = TextPainter(
      text: TextSpan(text: value, style: _valueStyle(Theme.of(context))),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width + _padding.horizontal + _iconGap + AppIconSize.action + 2;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.appColors;
    final enabled = onTap != null;
    final radius = BorderRadius.circular(AppRadius.field);
    final fill =
        theme.inputDecorationTheme.fillColor ??
        theme.colorScheme.surfaceContainer;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ExcludeSemantics(
          child: Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(color: colors.text2),
          ),
        ),
        const SizedBox(height: 6),
        Tooltip(
          message: tooltip,
          excludeFromSemantics: true,
          child: Semantics(
            button: true,
            enabled: enabled,
            label: '$label, $value',
            onTap: onTap,
            excludeSemantics: true,
            child: Material(
              color: fill,
              shape: RoundedRectangleBorder(
                borderRadius: radius,
                side: BorderSide(color: theme.colorScheme.outline),
              ),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: onTap,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    minHeight: AppSpacing.minTapTarget,
                  ),
                  child: Padding(
                    padding: _padding,
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            value,
                            style: _valueStyle(theme)?.copyWith(
                              color: enabled
                                  ? theme.colorScheme.onSurface
                                  : theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                        const SizedBox(width: _iconGap),
                        Icon(
                          icon,
                          size: AppIconSize.action,
                          color: colors.accentText,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// The edit form's read-only box (the designs' PlanEdit, "Set when the plan
/// was created"): what `UpdateBeacon` does not change, one line each.
class PlanReadOnlyBox extends StatelessWidget {
  const PlanReadOnlyBox({
    super.key,
    required this.title,
    required this.lines,
    this.note,
  });

  final String title;
  final List<String> lines;

  /// A muted line under them (why they can't change).
  final String? note;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.appColors;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.onSurface.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(AppRadius.field),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: AppSpacing.smd,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: theme.textTheme.labelMedium?.copyWith(color: colors.text2),
            ),
            const SizedBox(height: AppSpacing.xs),
            for (final line in lines)
              Text(
                line,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            if (note != null) ...[
              const SizedBox(height: AppSpacing.xs),
              Text(
                note!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
