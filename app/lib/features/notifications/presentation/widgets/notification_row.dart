import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../gen/dzeroth/notifications/v1/notifications.pb.dart' as pb;
import '../../../../gen/dzeroth/notifications/v1/notifications.pbenum.dart';
import '../../../../shared/format/relative_time.dart';
import '../../../../shared/widgets/post/post_card.dart' show postCardGutterOf;
import '../../../../shared/widgets/primitives/app_avatar.dart';
import '../../../../shared/widgets/primitives/app_badge.dart';
import '../../../../shared/widgets/primitives/app_tile_icon.dart';
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
    NotificationType.NOTIFICATION_TYPE_BEACON_REQUEST =>
      'asked to join your plan',
    NotificationType.NOTIFICATION_TYPE_BEACON_ACCEPTED =>
      'accepted you into their plan',
    NotificationType.NOTIFICATION_TYPE_BEACON_CANCELLED =>
      'cancelled a plan you joined',
    NotificationType.NOTIFICATION_TYPE_BEACON_UPDATED =>
      'changed a plan you joined',
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
  NotificationType.NOTIFICATION_TYPE_BEACON_REQUEST => Icons.event_outlined,
  NotificationType.NOTIFICATION_TYPE_BEACON_ACCEPTED =>
    Icons.how_to_reg_outlined,
  NotificationType.NOTIFICATION_TYPE_BEACON_CANCELLED =>
    Icons.event_busy_outlined,
  NotificationType.NOTIFICATION_TYPE_BEACON_UPDATED =>
    Icons.edit_calendar_outlined,
  _ => Icons.notifications_none,
};

/// Whether [type] belongs to the Mentions tab (mentions and replies to you).
bool isMentionType(NotificationType type) =>
    type == NotificationType.NOTIFICATION_TYPE_MENTION ||
    type == NotificationType.NOTIFICATION_TYPE_REPLY;

/// Whether [type] belongs to the Plans tab (F15): every plan (beacon) type.
bool isPlanType(NotificationType type) =>
    type == NotificationType.NOTIFICATION_TYPE_BEACON_REQUEST ||
    type == NotificationType.NOTIFICATION_TYPE_BEACON_ACCEPTED ||
    type == NotificationType.NOTIFICATION_TYPE_BEACON_CANCELLED ||
    type == NotificationType.NOTIFICATION_TYPE_BEACON_UPDATED;

/// Lines of "Name action" a row shows before it ends in an ellipsis.
const kNotificationTextLines = 3;

/// One notification in the list (dz.css `.post` with an `.ico` tile): the
/// type icon in a teal tile, then a column of the actor's avatar, "Name
/// action", an optional [action] control and a muted time. A full-width,
/// 48dp+ tap target (no ListTile); unread rows get a subtle primary tint, a
/// dot and a bolder name, and say "unread" to screen readers.
///
/// The row is one semantics node (the sentence, the time, "unread") that
/// opens [onTap]; [action] (the Follow back button) is its own node and its
/// own focus stop inside it, so it is announced and pressed on its own.
/// Row padding, the gap after the tile and the actor avatar (Notifications).
const double _kRowVertical = 14;
const double _kTileGap = 14;
const double _kActorAvatar = 30;

class NotificationRow extends StatelessWidget {
  const NotificationRow({
    super.key,
    required this.notification,
    required this.unread,
    required this.now,
    required this.onTap,
    this.action,
  });

  final pb.Notification notification;
  final bool unread;
  final DateTime now;
  final VoidCallback onTap;

  /// A control on its own line under the sentence (F14's Follow back);
  /// nothing when null.
  final Widget? action;

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
    final verb = notificationAction(notification);
    final label = [
      '$name$verb',
      if (spokenTime.isNotEmpty) spokenTime,
      if (unread) 'unread',
    ].join(', ');
    final action = this.action;
    final body = theme.textTheme.bodyLarge;

    return Semantics(
      container: true,
      button: true,
      label: label,
      onTap: onTap,
      child: Material(
        color: unread
            ? colors.primary.withValues(alpha: AppOpacity.rowTint)
            : Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            // The designs' rows: the post gutter, 14 dp above and below.
            padding: EdgeInsets.symmetric(
              horizontal: postCardGutterOf(context),
              vertical: _kRowVertical,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AppTileIcon(
                  icon: notificationIcon(notification.type),
                  size: AppIconSize.xl,
                ),
                const SizedBox(width: _kTileGap),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ExcludeSemantics(
                        child: AppAvatar(
                          url: actor.avatarUrl,
                          radius: _kActorAvatar / 2,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.sm),
                      ExcludeSemantics(
                        child: Text.rich(
                          maxLines: kNotificationTextLines,
                          overflow: TextOverflow.ellipsis,
                          TextSpan(
                            children: [
                              TextSpan(
                                text: name,
                                style: body?.copyWith(
                                  fontWeight: unread
                                      ? FontWeight.w800
                                      : FontWeight.w700,
                                ),
                              ),
                              TextSpan(
                                text: verb,
                                style: body?.copyWith(
                                  fontWeight: unread
                                      ? FontWeight.w600
                                      : FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      if (action != null) ...[
                        const SizedBox(height: AppSpacing.sm),
                        action,
                      ],
                      if (shortTime.isNotEmpty || unread) ...[
                        const SizedBox(height: AppSpacing.xs),
                        ExcludeSemantics(
                          child: Row(
                            children: [
                              if (unread) ...[
                                // Not by colour alone: a dot (and a bolder
                                // name) also mark an unread row.
                                const AppUnreadDot(
                                  key: ValueKey('notification-unread-dot'),
                                  semanticsLabel: 'Unread',
                                ),
                                const SizedBox(width: AppSpacing.sm),
                              ],
                              if (shortTime.isNotEmpty)
                                Flexible(
                                  child: Text(
                                    shortTime,
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: colors.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
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
/// use (`follow`, `follow_request`, `follow_accepted`, the plan types), else
/// empty.
String notificationTypeWire(NotificationType type) => switch (type) {
  NotificationType.NOTIFICATION_TYPE_FOLLOW => kNotificationTypeFollow,
  NotificationType.NOTIFICATION_TYPE_FOLLOW_REQUEST =>
    kNotificationTypeFollowRequest,
  NotificationType.NOTIFICATION_TYPE_FOLLOW_ACCEPTED =>
    kNotificationTypeFollowAccepted,
  NotificationType.NOTIFICATION_TYPE_BEACON_REQUEST =>
    kNotificationTypeBeaconRequest,
  NotificationType.NOTIFICATION_TYPE_BEACON_ACCEPTED =>
    kNotificationTypeBeaconAccepted,
  NotificationType.NOTIFICATION_TYPE_BEACON_CANCELLED =>
    kNotificationTypeBeaconCancelled,
  NotificationType.NOTIFICATION_TYPE_BEACON_UPDATED =>
    kNotificationTypeBeaconUpdated,
  _ => '',
};
