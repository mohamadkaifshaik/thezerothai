import 'package:flutter_bloc/flutter_bloc.dart';

/// App-wide count of conversations with unread messages, behind the Messages
/// navigation badge (W7-19, ADR-0027 D10). Its own cubit: a message push never
/// touches `UnreadBadgeCubit`, which counts notification rows.
///
/// - Seeded from `GetMe.unread_conversation_count` (0 extra reads; capped at
///   100 server-side, shown as "99+" by `unreadBadgeLabel`) on every fresh
///   GetMe. A seed forgets what was counted locally: the server number is the
///   truth again.
/// - [onMessagePush]: a foreground push for a conversation that is not open
///   adds one. The count is of conversations, so a second push for the same one
///   adds nothing.
/// - [opened] / [closed] keep track of the open threads. A push for an open
///   conversation is not counted (the thread polls instead), and opening a
///   conversation a push counted takes it out again ("cleared per conversation
///   on open").
/// - [clearUnread]: the thread found the conversation unread when it opened
///   (the seed counted it), so it leaves the count. Once per conversation
///   since the last seed; a conversation that was read when opened and only
///   received messages while open never lowers it.
///
/// It never calls the API (no GetMe or ListConversations just for a badge).
/// Counts are never live: a conversation that is both in the seed and pushed
/// is counted twice until the next GetMe, which reconciles it.
class MessagesBadgeCubit extends Cubit<int> {
  MessagesBadgeCubit([super.initial = 0]);

  /// Open threads, counted: the same conversation can be on the stack twice.
  final Map<String, int> _open = {};

  /// Conversations a foreground push counted since the last seed.
  final Set<String> _pushed = {};

  /// Conversations that left the count since the last seed.
  final Set<String> _cleared = {};

  /// Sets the count from the server and forgets the local bookkeeping.
  /// Sign-out seeds 0.
  void seed(int count) {
    if (isClosed) return;
    _pushed.clear();
    _cleared.clear();
    emit(count < 0 ? 0 : count);
  }

  /// A foreground message push for [conversationId]. Returns true when it
  /// added to the count; false when the conversation is open (the caller polls
  /// it) or was already counted.
  bool onMessagePush(String conversationId) {
    if (isClosed || conversationId.isEmpty) return false;
    if (_open.containsKey(conversationId)) return false;
    if (!_pushed.add(conversationId)) return false;
    // Unread again after having been read.
    _cleared.remove(conversationId);
    emit(state + 1);
    return true;
  }

  /// The thread for [conversationId] is on screen. A conversation a push
  /// counted is cleared: its messages are about to be read.
  void opened(String conversationId) {
    if (isClosed || conversationId.isEmpty) return;
    _open[conversationId] = (_open[conversationId] ?? 0) + 1;
    if (_pushed.contains(conversationId)) clearUnread(conversationId);
  }

  /// The thread for [conversationId] left the screen.
  void closed(String conversationId) {
    final count = _open[conversationId];
    if (count == null) return;
    if (count <= 1) {
      _open.remove(conversationId);
    } else {
      _open[conversationId] = count - 1;
    }
  }

  /// [conversationId] was unread when it was opened, so it leaves the count,
  /// once since the last seed.
  void clearUnread(String conversationId) {
    if (isClosed || conversationId.isEmpty) return;
    if (!_cleared.add(conversationId)) return;
    _pushed.remove(conversationId);
    if (state > 0) emit(state - 1);
  }
}
