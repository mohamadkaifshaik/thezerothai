import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import '../../../../gen/dzeroth/posts/v1/posts.pbenum.dart'
    show ScheduledPostStatus;
import '../../../../shared/format/scheduled_time.dart';

/// The "Schedule post" action in the composer's bottom bar (CMP-D6): a
/// schedule-send icon that is filled and accent-coloured while a schedule is
/// set. Disabled while the post is being sent.
class ScheduleButton extends StatelessWidget {
  const ScheduleButton({
    super.key,
    required this.scheduled,
    required this.enabled,
    required this.onPressed,
    this.tooltip = 'Schedule post',
  });

  /// A schedule is set.
  final bool scheduled;
  final bool enabled;
  final VoidCallback onPressed;

  /// The tooltip; the reason when the button is off for a rule (a poll).
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      isSelected: scheduled,
      icon: const Icon(Icons.schedule_send_outlined),
      selectedIcon: Icon(
        Icons.schedule_send,
        color: context.appColors.accentText,
      ),
      onPressed: enabled ? onPressed : null,
    );
  }
}

/// "Will send on Sun, Oct 25, 2026 at 9:37 PM" above the text of the composer
/// once a schedule is set (X shows it above the audience pill; this app has
/// none, so it sits above the text row). A clock icon and the text in the
/// accent colour; the whole line is one 48dp button that reopens the Schedule
/// dialog, and its semantics label is the same text.
class ScheduleLine extends StatelessWidget {
  const ScheduleLine({
    super.key,
    required this.publishAt,
    required this.enabled,
    required this.onTap,
  });

  /// The scheduled instant (UTC or local; shown in the device zone).
  final DateTime publishAt;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = enabled
        ? context.appColors.accentText
        : theme.colorScheme.onSurfaceVariant;
    final text = willSendOnText(
      publishAt,
      use24Hour: MediaQuery.alwaysUse24HourFormatOf(context),
    );
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: Semantics(
        button: true,
        enabled: enabled,
        label: text,
        hint: 'Change or remove the schedule',
        excludeSemantics: true,
        onTap: enabled ? onTap : null,
        child: InkWell(
          onTap: enabled ? onTap : null,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minHeight: AppSpacing.minTapTarget,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.schedule_outlined,
                    size: AppIconSize.md,
                    color: color,
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Flexible(
                    child: Text(
                      text,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: color,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The toast after SchedulePost succeeded: `Your post will be sent on
/// <time>` with the time the SERVER stored (`publish_at`, whole minute), which
/// is what X shows too. A replay of an item that has moved on (a lost
/// response, retried much later) says so instead.
String scheduledToastText(pb.ScheduledPost item, {bool use24Hour = false}) {
  switch (item.status) {
    case ScheduledPostStatus.SCHEDULED_POST_STATUS_PUBLISHED:
      return 'Your post has already been sent.';
    case ScheduledPostStatus.SCHEDULED_POST_STATUS_CANCELLED:
    case ScheduledPostStatus.SCHEDULED_POST_STATUS_FAILED:
      return 'That scheduled post is no longer pending.';
    default:
      if (!item.hasPublishAt()) return 'Your post was scheduled.';
      return 'Your post will be sent on '
          '${formatScheduledTime(item.publishAt.toDateTime(), use24Hour: use24Hour)}';
  }
}

/// Whether the toast offers "View" (the Scheduled list): only for an item
/// that is still pending.
bool scheduledToastHasView(pb.ScheduledPost item) =>
    item.status != ScheduledPostStatus.SCHEDULED_POST_STATUS_PUBLISHED &&
    item.status != ScheduledPostStatus.SCHEDULED_POST_STATUS_CANCELLED &&
    item.status != ScheduledPostStatus.SCHEDULED_POST_STATUS_FAILED;
