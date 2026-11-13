import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;
import '../../../../gen/dzeroth/messaging/v1/messaging.pbenum.dart';
import '../../../../shared/format/relative_time.dart';
import '../../../../shared/widgets/primitives/app_avatar.dart';
import '../../../../shared/widgets/primitives/app_badge.dart' show AppUnreadDot;

/// Text shown for a last message that has no text (tombstones).
const kConversationDeletedSnippet = 'Message deleted';
const kConversationRemovedSnippet = 'This message was removed';

/// The preview of a message that shares a post and carries no caption.
const kConversationSharedPostSnippet = 'Shared a post';

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
    // The snippet of a share is the sender's own text: a caption, or the post
    // link when there is none. The link is replaced; the post's text is never
    // in the preview (it must not outlive a delete or a protect).
    _ when last.sharedPost && _isBareLink(last.snippet) =>
      kConversationSharedPostSnippet,
    _ => last.snippet,
  };
  if (text.isEmpty) return '';
  return last.fromSelf ? '$kConversationSelfPrefix$text' : text;
}

/// Whether [text] is empty or a single link (no spaces): what a share
/// without a caption carries, possibly cut short by the server's preview.
bool _isBareLink(String text) {
  final t = text.trim();
  return t.isEmpty || (!t.contains(RegExp(r'\s')) && t.startsWith('http'));
}

/// One conversation in the inbox, presentational (dzeroth-mobile
/// Conversations, dz.css `.row`): a 50dp avatar, the bold name with the
/// relative time at the end of its line, the snippet under it, and the glowing
/// dot of an unread conversation at the far end.
///
/// - Unread: a bold snippet, the dot and "unread" in the spoken label (never
///   colour alone).
/// - [pb.Conversation.silent]: a muted-bell marker.
/// - The row is one reader stop ("Name, @handle, snippet, 5 minutes ago,
///   unread, muted"). The inbox wraps it in a `listItem` semantics node
///   inside its `list` (Flutter has no listbox role).
/// - With no [onTap] the row is drawn but not a button.
/// - [selected] marks the open conversation in a band B list pane (tablet
///   layout): the selected-row background and `selected` in semantics. With
///   the default false the tree is unchanged.
class ConversationRow extends StatelessWidget {
  const ConversationRow({
    super.key,
    required this.conversation,
    required this.now,
    this.onTap,
    this.selected = false,
  });

  final pb.Conversation conversation;

  /// The clock the relative time is drawn against (injected, never read here).
  final DateTime now;
  final VoidCallback? onTap;

  /// The conversation open beside the list (band B).
  final bool selected;

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
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: colors.onSurfaceVariant,
    );
    final gutter = MediaQuery.sizeOf(context).width < AppBreakpoints.mobile
        ? AppMessagesLayout.phoneGutter
        : AppMessagesLayout.wideGutter;

    final row = InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: AppSize.listRow),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: gutter,
            vertical: AppMessagesLayout.rowPaddingV,
          ),
          child: Row(
            children: [
              AppAvatar(
                url: peer.avatarUrl,
                radius: AppMessagesLayout.avatar / 2,
                name: name,
              ),
              const SizedBox(width: AppMessagesLayout.rowGap),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall,
                          ),
                        ),
                        if (shortTime.isNotEmpty) ...[
                          const SizedBox(width: AppSpacing.sm),
                          Text(shortTime, maxLines: 1, style: muted),
                        ],
                      ],
                    ),
                    if (snippet.isNotEmpty || silent)
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
                                fontWeight: unread ? FontWeight.w700 : null,
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
                        ],
                      ),
                  ],
                ),
              ),
              if (unread) ...[
                const SizedBox(width: AppSpacing.sm),
                // Not by colour alone: the bold snippet and the spoken
                // "unread" say it too.
                const AppUnreadDot(key: unreadDotKey, semanticsLabel: 'Unread'),
              ],
            ],
          ),
        ),
      ),
    );
    return Semantics(
      button: onTap != null,
      selected: selected ? true : null,
      label: label,
      excludeSemantics: true,
      onTap: onTap,
      child: selected
          ? Material(color: context.appColors.selectedRow, child: row)
          : row,
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
