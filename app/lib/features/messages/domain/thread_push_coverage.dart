import '../../../gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;
import '../../../gen/dzeroth/messaging/v1/messaging.pbenum.dart';

/// Whether a message push can reach the open thread, so its poll may use the
/// slower 30 s hot interval (ADR-0027 D7, D9).
///
/// True only on Android with the device registered ([deviceRegistered], from
/// `PushCubit.pushCoversThreads`), with the `notifications` flag on, and for a
/// conversation the server pushes: an accepted one the caller has not muted.
/// The server never pushes a muted (silent) conversation or a request, on
/// either side of it (REQUESTS folder for the recipient, state REQUEST for the
/// sender), so those poll at 15 s. An unknown header ([conversation] null,
/// nothing loaded yet) also polls at 15 s.
///
/// The server's per-recipient push limiter (20 per hour) is not visible to the
/// client: a thread whose pushes are being dropped by it still polls at 30 s.
bool pushCoversThread({
  required bool deviceRegistered,
  required bool notificationsEnabled,
  required pb.Conversation? conversation,
}) {
  if (!deviceRegistered || !notificationsEnabled || conversation == null) {
    return false;
  }
  if (conversation.silent) return false;
  if (conversation.folder == Folder.FOLDER_REQUESTS) return false;
  if (conversation.state == ConversationState.CONVERSATION_STATE_REQUEST) {
    return false;
  }
  return true;
}
