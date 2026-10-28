import 'package:dzeroth/features/messages/domain/thread_poller.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pbenum.dart';
import 'package:fixnum/fixnum.dart' show Int64;

import 'messaging_fixtures.dart' show hexId;

/// The id of the conversation the thread tests open (32 lower-case hex).
final String kThreadId = hexId(0xc1);

/// A conversation header for the thread screen: peer "Sam Rivera" (@sam).
pb.Conversation threadConv({
  bool canReply = true,
  int unread = 0,
  String id = '',
  ConversationState state = ConversationState.CONVERSATION_STATE_ACCEPTED,
}) {
  return pb.Conversation(
    id: id.isEmpty ? kThreadId : id,
    kind: ConversationKind.CONVERSATION_KIND_DIRECT,
    peer: common.AuthorSnapshot(
      userId: 'u-sam',
      handle: 'sam',
      displayName: 'Sam Rivera',
    ),
    state: state,
    folder: Folder.FOLDER_INBOX,
    unreadCount: Int64(unread),
    canReply: canReply,
  );
}

/// A [ThreadPoller] that records what the cubit asked of it.
class FakeThreadPoller implements ThreadPoller {
  bool running = false;
  bool disposed = false;
  int starts = 0;
  int stops = 0;
  int inputs = 0;
  int pushes = 0;
  final List<bool> visibility = [];

  @override
  bool get isRunning => running;

  @override
  void start() {
    running = true;
    starts++;
  }

  @override
  void stop() {
    running = false;
    stops++;
  }

  @override
  void noteInput() => inputs++;

  @override
  void setVisible(bool visible) => visibility.add(visible);

  @override
  void onPush() => pushes++;

  @override
  void dispose() {
    disposed = true;
    running = false;
  }
}
