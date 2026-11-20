import 'dart:typed_data';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/session_wiring.dart' show UnexpectedErrorReporter;
import '../../../gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;
import '../../../gen/dzeroth/messaging/v1/messaging.pbenum.dart';
import '../../../gen/dzeroth/moderation/v1/moderation.pbenum.dart';
import '../../moderation/presentation/report_sheet.dart';
import '../domain/e2ee/encrypted_messaging.dart';
import '../domain/e2ee/message_content_codec.dart' show MessageCheck;
import 'bloc/thread_cubit.dart' show isConversationId;
import 'e2ee/encryption_copy.dart';

/// The toast after a report was sent: the thread does not change.
const kReportSentText = 'Report sent';

/// The sentence the message report sheet adds under its intro: the reviewers
/// get this one message, nothing else of the conversation.
const kReportMessageDetail =
    'Only this message is shared with our reviewers, not the rest of the '
    'conversation.';

/// Whether [message] can be reported: the peer's own, still
/// visible message. The caller's messages and tombstones (no text is left to
/// review) are not offered; the server answers VALIDATION for the first and
/// NOT_FOUND for the second.
bool canReportMessage(pb.Message message) =>
    !message.fromSelf &&
    message.state == MessageState.MESSAGE_STATE_VISIBLE &&
    isConversationId(message.id);

/// The `target_id` of a message report: `"<convId>:<msgId>"`, 32 lower-case hex
/// each. Throws [ArgumentError] for a message that cannot be
/// reported or an id of the wrong shape, so a malformed request is never sent.
String messageReportTargetId(String conversationId, pb.Message message) {
  if (!canReportMessage(message) || !isConversationId(conversationId)) {
    throw ArgumentError('This message cannot be reported');
  }
  return '$conversationId:${message.id}';
}

/// Opens the report sheet for one peer [message]: the shared
/// [showReportSheet] with `REPORT_TARGET_TYPE_MESSAGE`. A sent report ends
/// with the [kReportSentText] toast; the thread is not touched. No Block
/// follow-up is offered: Block is one tap away in the conversation menu.
Future<void> reportPeerMessage(
  BuildContext context, {
  required String conversationId,
  required pb.Message message,
  required String peerHandle,
}) async {
  final targetId = messageReportTargetId(conversationId, message);
  final messenger = ScaffoldMessenger.of(context);
  final outcome = await showReportSheet(
    context,
    targetType: ReportTargetType.REPORT_TARGET_TYPE_MESSAGE,
    targetId: targetId,
    subject: peerHandle.isEmpty ? 'this message' : "@$peerHandle's message",
    detail: kReportMessageDetail,
  );
  thankForReport(messenger, outcome);
}

/// The `target_id` of an encrypted message report: `"<convId>:<msgId>"`.
/// Throws [ArgumentError] unless [message] is the peer's visible message that
/// can be reported and both ids have the right shape.
String encryptedReportTargetId(
  String conversationId,
  DecryptedMessage message,
) {
  if (!message.canReport ||
      message.mine ||
      message.state != EncryptedMessageState.visible ||
      !isConversationId(conversationId) ||
      !isConversationId(message.id)) {
    throw ArgumentError('This message cannot be reported');
  }
  return '$conversationId:${message.id}';
}

/// Opens the shared report sheet for one decrypted peer [message] (R13).
///
/// Called after the user chose "Report message". Reads the message's exact
/// bytes from the port once, and passes them into the sheet; nothing is sent
/// until the user presses "Send report" in that sheet, whose intro says what
/// is shared. No payload (null, empty, over 8192 bytes, or a failed read):
/// the [kReportUnavailableText] snackbar and no sheet. A failed read reaches
/// `UnexpectedErrorReporter` as a fixed `StateError('reportPayload')`.
Future<void> reportEncryptedMessage(
  BuildContext context, {
  required String conversationId,
  required DecryptedMessage message,
  required String peerHandle,
}) async {
  final targetId = encryptedReportTargetId(conversationId, message);
  final port = context.read<EncryptedMessaging?>();
  final reporter = context.read<UnexpectedErrorReporter>();
  final messenger = ScaffoldMessenger.of(context);
  Uint8List? payload;
  try {
    payload = await port?.reportPayload(conversationId, message.id);
  } on Object catch (_, stack) {
    reporter.call(StateError('reportPayload'), stack);
  }
  if (payload != null && (payload.isEmpty || payload.length > 8192)) {
    payload = null;
  }
  if (!context.mounted) return;
  if (payload == null) {
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text(kReportUnavailableText)));
    return;
  }
  final outcome = await showReportSheet(
    context,
    targetType: ReportTargetType.REPORT_TARGET_TYPE_MESSAGE,
    targetId: targetId,
    subject: peerHandle.isEmpty ? 'this message' : "@$peerHandle's message",
    detail: message.check == MessageCheck.ok
        ? kReportEncryptedDetail
        : '$kReportEncryptedDetail $kReportUnverifiedDetail',
    messagePayload: payload,
  );
  thankForReport(messenger, outcome);
}

/// `ThreadScreen.onReport` (the info menu's "Report @handle"): reports the
/// peer's account through the same sheet, `REPORT_TARGET_TYPE_ACCOUNT`.
Future<void> reportConversationPeer(
  BuildContext context,
  pb.Conversation conversation,
) async {
  final peer = conversation.peer;
  if (peer.userId.isEmpty) return;
  final messenger = ScaffoldMessenger.of(context);
  final outcome = await showReportSheet(
    context,
    targetType: ReportTargetType.REPORT_TARGET_TYPE_ACCOUNT,
    targetId: peer.userId,
    subject: peer.handle.isEmpty ? 'this account' : '@${peer.handle}',
  );
  thankForReport(messenger, outcome);
}

/// The "Report sent" toast for a finished report sheet; nothing for a
/// cancelled one or one the server already had (the sheet said so).
void thankForReport(ScaffoldMessengerState messenger, ReportOutcome outcome) {
  // Cancelled: nothing was sent. Already reported: the sheet said so (the
  // server had it), so no toast on top of that.
  if (outcome == ReportOutcome.cancelled ||
      outcome == ReportOutcome.alreadyReported) {
    return;
  }
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(const SnackBar(content: Text(kReportSentText)));
}
