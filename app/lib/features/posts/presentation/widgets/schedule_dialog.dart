import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../shared/format/scheduled_time.dart';
import '../../../../shared/widgets/app_form_header.dart';
import '../../domain/schedule_rules.dart';
import '../bloc/schedule_dialog_cubit.dart';

/// The L-9 note (ADR-0021 security review, founder-approved): shown only when
/// photos are attached, because an uploaded image has a public URL before the
/// post goes out.
const kScheduleImagesNote =
    'Images are uploaded now and can be reached by anyone with the link '
    'before the post goes out.';

/// [kScheduleImagesNote] with its info icon: in the Schedule dialog and, so
/// that adding photos after choosing a time cannot skip it, under the
/// "Will send on" line of the composer ([compact]: smaller type, there).
class ScheduleImagesNote extends StatelessWidget {
  const ScheduleImagesNote({super.key, this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          Icons.info_outline,
          size: AppIconSize.md,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Text(
            kScheduleImagesNote,
            style:
                (compact
                        ? theme.textTheme.bodySmall
                        : theme.textTheme.bodyMedium)
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}

/// How the Schedule dialog was left (dismissing it is `null`).
sealed class ScheduleDialogResult {
  const ScheduleDialogResult();
}

/// Confirm: schedule at [publishAt] (UTC).
final class ScheduleChosen extends ScheduleDialogResult {
  const ScheduleChosen(this.publishAt);
  final DateTime publishAt;
}

/// "Remove schedule": post now again.
final class ScheduleRemoved extends ScheduleDialogResult {
  const ScheduleRemoved();
}

/// The "Scheduled posts" footer link: the caller opens the list.
final class ScheduleOpenList extends ScheduleDialogResult {
  const ScheduleOpenList();
}

/// Shows the date picker; null when dismissed. A seam so tests need not drive
/// the platform dial.
typedef SchedulePickDate = Future<DateTime?> Function(
  BuildContext context, {
  required DateTime initial,
  required DateTime first,
  required DateTime last,
});

/// Shows the time picker; null when dismissed.
typedef SchedulePickTime = Future<TimeOfDay?> Function(
  BuildContext context, {
  required TimeOfDay initial,
});

Future<DateTime?> _platformPickDate(
  BuildContext context, {
  required DateTime initial,
  required DateTime first,
  required DateTime last,
}) => showDatePicker(
  context: context,
  initialDate: initial,
  firstDate: first,
  lastDate: last,
  helpText: 'Date',
);

Future<TimeOfDay?> _platformPickTime(
  BuildContext context, {
  required TimeOfDay initial,
}) => showTimePicker(context: context, initialTime: initial, helpText: 'Time');

/// Opens the Schedule dialog (CMP-D6, ADR-0021 D4): a full-screen route below
/// [AppBreakpoints.mobile] wide, a centred dialog above. [initial] is the
/// schedule already set (offering "Remove schedule"); [hasMedia] adds the L-9
/// note; [notice] is a server refusal of the time to show under the pickers.
/// [clock], [pickDate] and [pickTime] are seams for tests.
Future<ScheduleDialogResult?> showScheduleDialog(
  BuildContext context, {
  DateTime? initial,
  bool hasMedia = false,
  String? notice,
  DateTime Function()? clock,
  SchedulePickDate pickDate = _platformPickDate,
  SchedulePickTime pickTime = _platformPickTime,
}) {
  final view = ScheduleDialogView(
    initial: initial,
    hasMedia: hasMedia,
    notice: notice,
    clock: clock,
    pickDate: pickDate,
    pickTime: pickTime,
  );
  if (MediaQuery.sizeOf(context).width < AppBreakpoints.mobile) {
    return Navigator.of(context).push(
      MaterialPageRoute<ScheduleDialogResult>(
        fullscreenDialog: true,
        builder: (_) => Scaffold(body: SafeArea(child: view)),
      ),
    );
  }
  return showDialog<ScheduleDialogResult>(
    context: context,
    builder: (_) => Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: view,
      ),
    ),
  );
}

/// The content of the Schedule dialog: Close, the title, a Confirm pill; the
/// "Will send on ..." summary, a date row and a time row (each opens the
/// platform picker), the read-only time zone, the helper text for a time out
/// of range, the images note, "Remove schedule" and the "Scheduled posts"
/// link. Scrolls, so it fits any text scale.
class ScheduleDialogView extends StatelessWidget {
  const ScheduleDialogView({
    super.key,
    this.initial,
    this.hasMedia = false,
    this.notice,
    this.clock,
    this.pickDate = _platformPickDate,
    this.pickTime = _platformPickTime,
  });

  final DateTime? initial;
  final bool hasMedia;
  final String? notice;
  final DateTime Function()? clock;
  final SchedulePickDate pickDate;
  final SchedulePickTime pickTime;

  @override
  Widget build(BuildContext context) {
    return BlocProvider<ScheduleDialogCubit>(
      create: (_) =>
          ScheduleDialogCubit(initial: initial, notice: notice, clock: clock),
      child: _ScheduleDialogBody(
        hasSchedule: initial != null,
        hasMedia: hasMedia,
        pickDate: pickDate,
        pickTime: pickTime,
      ),
    );
  }
}

class _ScheduleDialogBody extends StatelessWidget {
  const _ScheduleDialogBody({
    required this.hasSchedule,
    required this.hasMedia,
    required this.pickDate,
    required this.pickTime,
  });

  final bool hasSchedule;
  final bool hasMedia;
  final SchedulePickDate pickDate;
  final SchedulePickTime pickTime;

  Future<void> _pickDate(BuildContext context) async {
    final cubit = context.read<ScheduleDialogCubit>();
    final state = cubit.state;
    final first = DateUtils.dateOnly(state.now);
    final last = DateUtils.dateOnly(state.now.add(kScheduledHorizon));
    var initial = DateUtils.dateOnly(state.selected);
    if (initial.isBefore(first)) initial = first;
    if (initial.isAfter(last)) initial = last;
    final picked = await pickDate(
      context,
      initial: initial,
      first: first,
      last: last,
    );
    if (picked != null && !cubit.isClosed) cubit.dateChanged(picked);
  }

  Future<void> _pickTime(BuildContext context) async {
    final cubit = context.read<ScheduleDialogCubit>();
    final picked = await pickTime(
      context,
      initial: TimeOfDay.fromDateTime(cubit.state.selected),
    );
    if (picked != null && !cubit.isClosed) {
      cubit.timeChanged(picked.hour, picked.minute);
    }
  }

  void _confirm(BuildContext context) {
    final publishAt = context.read<ScheduleDialogCubit>().confirm();
    if (publishAt != null) {
      Navigator.of(context).pop(ScheduleChosen(publishAt));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final use24Hour = MediaQuery.alwaysUse24HourFormatOf(context);
    return BlocBuilder<ScheduleDialogCubit, ScheduleDialogState>(
      builder: (context, state) {
        final helper = state.helper;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AppFormHeader(
              title: 'Schedule',
              cancelLabel: 'Close',
              onCancel: () => Navigator.of(context).pop(),
              actionLabel: 'Confirm',
              onAction: state.canConfirm ? () => _confirm(context) : null,
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.md,
                        vertical: AppSpacing.sm,
                      ),
                      child: Semantics(
                        liveRegion: true,
                        child: Text(
                          willSendOnText(state.selected, use24Hour: use24Hour),
                          style: theme.textTheme.titleMedium,
                        ),
                      ),
                    ),
                    _PickerRow(
                      icon: Icons.calendar_today_outlined,
                      label: 'Date',
                      value: formatScheduledDate(state.selected),
                      hint: 'Choose a date',
                      onTap: () => _pickDate(context),
                    ),
                    _PickerRow(
                      icon: Icons.schedule_outlined,
                      label: 'Time',
                      value: formatScheduledClock(
                        state.selected,
                        use24Hour: use24Hour,
                      ),
                      hint: 'Choose a time',
                      onTap: () => _pickTime(context),
                    ),
                    _ZoneRow(label: scheduleZoneLabel(state.selected)),
                    if (helper != null)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(
                          AppSpacing.md,
                          AppSpacing.sm,
                          AppSpacing.md,
                          0,
                        ),
                        child: Semantics(
                          liveRegion: true,
                          child: Text(
                            helper,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.error,
                            ),
                          ),
                        ),
                      ),
                    if (hasMedia)
                      const Padding(
                        padding: EdgeInsets.fromLTRB(
                          AppSpacing.md,
                          AppSpacing.md,
                          AppSpacing.md,
                          0,
                        ),
                        child: ScheduleImagesNote(),
                      ),
                    const SizedBox(height: AppSpacing.sm),
                    if (hasSchedule)
                      _LinkButton(
                        label: 'Remove schedule',
                        icon: Icons.event_busy_outlined,
                        color: theme.colorScheme.error,
                        onPressed: () =>
                            Navigator.of(context).pop(const ScheduleRemoved()),
                      ),
                    const Divider(height: 1),
                    _LinkButton(
                      label: 'Scheduled posts',
                      icon: Icons.list_alt_outlined,
                      color: context.appColors.accentText,
                      onPressed: () =>
                          Navigator.of(context).pop(const ScheduleOpenList()),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// A tappable row of the dialog (date or time): a leading icon, a small
/// muted label over the value. At least 48dp high; at a large text scale the
/// two lines wrap instead of overflowing.
class _PickerRow extends StatelessWidget {
  const _PickerRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.hint,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String value;
  final String hint;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      button: true,
      label: '$label, $value',
      hint: hint,
      excludeSemantics: true,
      onTap: onTap,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: AppSpacing.minTapTarget),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.sm,
            ),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: AppIconSize.lg,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      Text(value, style: theme.textTheme.bodyLarge),
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

/// "Time zone: ..." as a read-only row.
class _ZoneRow extends StatelessWidget {
  const _ZoneRow({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      child: Semantics(
        label: label,
        excludeSemantics: true,
        child: Row(
          children: [
            Icon(
              Icons.public,
              size: AppIconSize.lg,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Text(
                label,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A start-aligned text button with a leading icon (48dp high).
class _LinkButton extends StatelessWidget {
  const _LinkButton({
    required this.label,
    required this.icon,
    required this.color,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
        child: TextButton.icon(
          style: TextButton.styleFrom(
            foregroundColor: color,
            minimumSize: const Size(0, AppSpacing.minTapTarget),
          ),
          onPressed: onPressed,
          icon: Icon(icon, size: AppIconSize.md),
          label: Text(label),
        ),
      ),
    );
  }
}
