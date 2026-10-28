import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;
import '../../../../gen/dzeroth/messaging/v1/messaging.pbenum.dart';
import '../../../../shared/format/relative_time.dart';
import '../../../../shared/widgets/app_avatar.dart';

/// Text shown for a last message that has no text (ADR-0027 D5 tombstones).
const kConversationDeletedSnippet = 'Message deleted';
const kConversationRemovedSnippet = 'This message was removed';

/// The prefix of a snippet the caller sent.
const kConversationSelfPrefix = 'You: ';

/// The second line of a row: the preview text with the "You: " prefix for the
/// caller's own messages, or the tombstone text. Empty when there is no
/// preview yet.
String conversationSnippet(pb.Conversation conversation) {
  if (!conversation.hasLastMessage()) return '';
  final last = conversation.lastMessage;
  final text = switch (last.state) {
    MessageState.MESSAGE_STATE_DELETED_ACCOUNT => kConversationDeletedSnippet,
    MessageState.MESSAGE_STATE_REMOVED => kConversationRemovedSnippet,
    _ => last.snippet,
  };
  if (text.isEmpty) return '';
  return last.fromSelf ? '$kConversationSelfPrefix$text' : text;
}

/// One conversation in the inbox (W7-14), presentational: a 72dp pitch, no
/// dividers, a 48dp avatar, the bold name, the muted handle and relative time
/// on the first line and the snippet on the second.
///
/// It follows the `UserListRow` layout (component row 17: avatar, name column,
/// muted handle) on the same tokens. It does not wrap `UserListRow` itself:
/// that widget takes a graph `UserListItem` and ends in a follow control, and
/// this row needs the time and the snippet in the name column.
///
/// - Unread: a bold snippet, an accent dot and "unread" in the spoken label
///   (never colour alone).
/// - [pb.Conversation.silent]: a muted-bell marker.
/// - The row is one reader stop ("Name, @handle, snippet, 5 minutes ago,
///   unread, muted"). The inbox wraps it in a `listItem` semantics node
///   inside its `list` (Flutter has no listbox role).
/// - With no [onTap] the row is drawn but not a button.
class ConversationRow extends StatelessWidget {
  const ConversationRow({
    super.key,
    required this.conversation,
    required this.now,
    this.onTap,
  });

  final pb.Conversation conversation;

  /// The clock the relative time is drawn against (injected, never read here).
  final DateTime now;
  final VoidCallback? onTap;

  /// Key of the accent dot of an unread row.
  static const unreadDotKey = ValueKey('conversation-unread-dot');

  /// Key of the muted marker of a `silent` row.
  static const silentMarkerKey = ValueKey('conversation-silent-marker');

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final peer = conversation.peer;
    final name = peer.displayName.isEmpty
        ? '@${peer.handle}'
        : peer.displayName;
    final unread = conversation.unreadCount > 0;
    final silent = conversation.silent;
    final snippet = conversationSnippet(conversation);
    final activity = _activityTime();
    final shortTime = activity == null ? '' : formatRelativeTime(activity, now);
    final spokenTime = activity == null
        ? ''
        : formatRelativeTimeSpoken(activity, now);
    final label = [
      name,
      if (peer.displayName.isNotEmpty) '@${peer.handle}',
      if (snippet.isNotEmpty) snippet,
      if (spokenTime.isNotEmpty) spokenTime,
      if (unread) 'unread',
      if (silent) 'muted',
    ].join(', ');
    final muted = theme.textTheme.bodyMedium?.copyWith(
      color: colors.onSurfaceVariant,
    );

    return Semantics(
      button: onTap != null,
      label: label,
      excludeSemantics: true,
      onTap: onTap,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: AppSize.listRow),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.smd,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AppAvatar(url: peer.avatarUrl, radius: AppSpacing.lg),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          if (peer.displayName.isNotEmpty) ...[
                            const SizedBox(width: AppSpacing.xs),
                            Flexible(
                              child: Text(
                                '@${peer.handle}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: muted,
                              ),
                            ),
                          ],
                          if (shortTime.isNotEmpty) ...[
                            const SizedBox(width: AppSpacing.xs),
                            Text('·', style: muted),
                            const SizedBox(width: AppSpacing.xs),
                            Text(shortTime, maxLines: 1, style: muted),
                          ],
                        ],
                      ),
                      if (snippet.isNotEmpty || unread || silent)
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                snippet,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: unread
                                      ? colors.onSurface
                                      : colors.onSurfaceVariant,
                                  fontWeight: unread
                                      ? FontWeight.w700
                                      : FontWeight.w400,
                                ),
                              ),
                            ),
                            if (silent) ...[
                              const SizedBox(width: AppSpacing.sm),
                              Icon(
                                Icons.notifications_off_outlined,
                                key: silentMarkerKey,
                                size: AppIconSize.sm,
                                color: colors.onSurfaceVariant,
                              ),
                            ],
                            if (unread) ...[
                              const SizedBox(width: AppSpacing.sm),
                              // Not by colour alone: the bold snippet and the
                              // spoken "unread" say it too.
                              Container(
                                key: unreadDotKey,
                                width: AppSpacing.sm,
                                height: AppSpacing.sm,
                                decoration: BoxDecoration(
                                  color: colors.primary,
                                  shape: BoxShape.circle,
                                ),
                              ),
                            ],
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

  /// The time shown: the last message's, else the entry's last activity.
  DateTime? _activityTime() {
    if (conversation.hasLastMessage() &&
        conversation.lastMessage.hasCreatedAt()) {
      return conversation.lastMessage.createdAt.toDateTime();
    }
    return conversation.hasUpdatedAt()
        ? conversation.updatedAt.toDateTime()
        : null;
  }
}
