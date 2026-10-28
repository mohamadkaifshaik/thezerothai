import 'package:connectrpc/connect.dart' as connect;
import 'package:fixnum/fixnum.dart' show Int64;
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pbenum.dart';
import 'package:protobuf/well_known_types/google/protobuf/timestamp.pb.dart'
    as ts;

/// Reference time of the messaging fixtures: the real clock captured once
/// (UTC, truncated to the second), never a fixed date (see the
/// `testing-strategy` skill, "Dates in tests").
final DateTime kMsgBase = _captureBase();

DateTime _captureBase() {
  final n = DateTime.now().toUtc();
  return DateTime.utc(n.year, n.month, n.day, n.hour, n.minute, n.second);
}

ts.Timestamp _stamp(DateTime t) => ts.Timestamp.fromDateTime(t);

/// A 32-character lower-case hex id built from [n].
String hexId(int n) => n.toRadixString(16).padLeft(32, '0');

/// A message sent [secondsAgo] seconds before [kMsgBase].
pb.Message msg(
  int n, {
  String conversationId = 'c1',
  int secondsAgo = 0,
  bool fromSelf = false,
  String text = 'hello',
}) {
  return pb.Message(
    id: hexId(n),
    conversationId: conversationId,
    fromSelf: fromSelf,
    text: text,
    state: MessageState.MESSAGE_STATE_VISIBLE,
    createdAt: _stamp(kMsgBase.subtract(Duration(seconds: secondsAgo))),
  );
}

/// Messages numbered [from]..[to] (inclusive), newest (highest number) first,
/// one second apart, as a server page would answer.
List<pb.Message> msgs(int from, int to, {String conversationId = 'c1'}) => [
  for (var n = to; n >= from; n--)
    msg(n, conversationId: conversationId, secondsAgo: 10000 - n),
];

pb.Conversation conv(
  String id, {
  int minutesAgo = 0,
  Folder folder = Folder.FOLDER_INBOX,
  ConversationState state = ConversationState.CONVERSATION_STATE_ACCEPTED,
  int unread = 0,
}) {
  return pb.Conversation(
    id: id,
    kind: ConversationKind.CONVERSATION_KIND_DIRECT,
    peer: common.AuthorSnapshot(
      userId: 'u-$id',
      handle: 'peer$id',
      displayName: 'Peer $id',
    ),
    state: state,
    folder: folder,
    unreadCount: Int64(unread),
    canReply: true,
    updatedAt: _stamp(kMsgBase.subtract(Duration(minutes: minutesAgo))),
  );
}

connect.ConnectException withDetail(
  connect.Code code,
  common.ErrorReason reason, {
  Map<String, String> metadata = const {},
}) {
  return connect.ConnectException(
    code,
    'server text',
    details: [
      connect.ErrorDetail(
        'type.googleapis.com/dzeroth.common.v1.ErrorDetail',
        common.ErrorDetail(
          reason: reason,
          message: 'server text',
          metadata: metadata.entries,
        ).writeToBuffer(),
      ),
    ],
  );
}
