import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../gen/dzeroth/notifications/v1/notifications.pb.dart' as pb;
import '../../../../gen/dzeroth/notifications/v1/notifications.pbenum.dart';
import '../../../../shared/format/relative_time.dart';
import '../../../../shared/widgets/app_avatar.dart';
import '../../domain/notification_location.dart';

/// "Alice followed you", "Alice and 2 others liked your post": the action
/// text after the actor's name, and the whole sentence for semantics.
String notificationAction(pb.Notification n) {
  final others = n.actorCount > 1 ? n.actorCount - 1 : 0;
  final subject = others == 0
      ? ''
      : (others == 1 ? ' and 1 other' : ' and $others others');
  final verb = switch (n.type) {
    NotificationType.NOTIFICATION_TYPE_FOLLOW => 'followed you',
    NotificationType.NOTIFICATION_TYPE_MENTION => 'mentioned you',
    NotificationType.NOTIFICATION_TYPE_REPLY => 'replied to your post',
    NotificationType.NOTIFICATION_TYPE_LIKE => 'liked your post',
    NotificationType.NOTIFICATION_TYPE_REPOST => 'reposted your post',
    NotificationType.NOTIFICATION_TYPE_QUOTE => 'quoted your post',
    NotificationType.NOTIFICATION_TYPE_FOLLOW_REQUEST =>
      'requested to follow you',
    NotificationType.NOTIFICATION_TYPE_FOLLOW_ACCEPTED =>
      'accepted your follow request',
    _ => 'interacted with you',
  };
  return '$subject $verb';
}

IconData notificationIcon(NotificationType type) => switch (type) {
  NotificationType.NOTIFICATION_TYPE_FOLLOW => Icons.person_add_alt_outlined,
  NotificationType.NOTIFICATION_TYPE_MENTION => Icons.alternate_email,
  NotificationType.NOTIFICATION_TYPE_REPLY => Icons.chat_bubble_outline,
  NotificationType.NOTIFICATION_TYPE_LIKE => Icons.favorite_border,
  NotificationType.NOTIFICATION_TYPE_REPOST => Icons.repeat,
  NotificationType.NOTIFICATION_TYPE_QUOTE => Icons.format_quote,
  NotificationType.NOTIFICATION_TYPE_FOLLOW_REQUEST =>
    Icons.person_add_alt_outlined,
  NotificationType.NOTIFICATION_TYPE_FOLLOW_ACCEPTED =>
    Icons.how_to_reg_outlined,
  _ => Icons.notifications_none,
};

/// The type icon's colour (X's: like pink, repost green, the rest the accent).
Color notificationIconColor(BuildContext context, NotificationType type) {
  final colors = context.appColors;
  return switch (type) {
    NotificationType.NOTIFICATION_TYPE_LIKE => colors.like,
    NotificationType.NOTIFICATION_TYPE_REPOST => colors.repost,
    _ => Theme.of(context).colorScheme.primary,
  };
}

/// Whether [type] belongs to the Mentions tab (mentions and replies to you).
bool isMentionType(NotificationType type) =>
    type == NotificationType.NOTIFICATION_TYPE_MENTION ||
    type == NotificationType.NOTIFICATION_TYPE_REPLY;

/// Lines of "Name action" a row shows before it ends in an ellipsis.
const kNotificationTextLines = 3;

/// One notification in the list: type icon, actor avatar, "Name action" and a
/// muted time. A full-width, 48dp+ tap target (no ListTile); unread rows get
/// a subtle primary tint and say "unread" to screen readers.
class NotificationRow extends StatelessWidget {
  const NotificationRow({
    super.key,
    required this.notification,
    required this.unread,
    required this.now,
    required this.onTap,
  });

  final pb.Notification notification;
  final bool unread;
  final DateTime now;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final actor = notification.actor;
    final name = actor.displayName.isEmpty
        ? '@${actor.handle}'
        : actor.displayName;
    final created = notification.hasCreatedAt()
        ? notification.createdAt.toDateTime()
        : null;
    final shortTime = created == null ? '' : formatRelativeTime(created, now);
    final spokenTime = created == null
        ? ''
        : formatRelativeTimeSpoken(created, now);
    final action = notificationAction(notification);
    final label = [
      '$name$action',
      if (spokenTime.isNotEmpty) spokenTime,
      if (unread) 'unread',
    ].join(', ');

    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      onTap: onTap,
      child: Material(
        color: unread
            ? colors.primary.withValues(alpha: AppOpacity.rowTint)
            : Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.sm,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: AppIconSize.xl,
                  child: Padding(
                    padding: const EdgeInsets.only(top: AppSpacing.xs),
                    child: Icon(
                      notificationIcon(notification.type),
                      size: AppIconSize.lg,
                      color: notificationIconColor(context, notification.type),
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          AppAvatar(
                            url: actor.avatarUrl,
                            radius: AppSpacing.md,
                          ),
                          const Spacer(),
                          if (unread) ...[
                            // Not by colour alone: a dot (and a bold name)
                            // also mark an unread row.
                            Container(
                              key: const ValueKey('notification-unread-dot'),
                              width: AppSpacing.sm,
                              height: AppSpacing.sm,
                              decoration: BoxDecoration(
                                color: colors.primary,
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: AppSpacing.sm),
                          ],
                          if (shortTime.isNotEmpty)
                            Text(
                              shortTime,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: colors.onSurfaceVariant,
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: AppSpacing.sm),
                      Text.rich(
                        maxLines: kNotificationTextLines,
                        overflow: TextOverflow.ellipsis,
                        TextSpan(
                          children: [
                            TextSpan(
                              text: name,
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: unread
                                    ? FontWeight.w800
                                    : FontWeight.w600,
                              ),
                            ),
                            TextSpan(
                              text: action,
                              style: theme.textTheme.bodyLarge?.copyWith(
                                fontWeight: unread
                                    ? FontWeight.w600
                                    : FontWeight.w400,
                              ),
                            ),
                          ],
                        ),
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

/// The `type` string of [type] that [notificationLocation] and the push data
/// use (`follow`, `follow_request`, `follow_accepted`), else empty.
String notificationTypeWire(NotificationType type) => switch (type) {
  NotificationType.NOTIFICATION_TYPE_FOLLOW => kNotificationTypeFollow,
  NotificationType.NOTIFICATION_TYPE_FOLLOW_REQUEST =>
    kNotificationTypeFollowRequest,
  NotificationType.NOTIFICATION_TYPE_FOLLOW_ACCEPTED =>
    kNotificationTypeFollowAccepted,
  _ => '',
};
