import 'package:flutter/material.dart';

import '../../../gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;
import '../../../gen/dzeroth/messaging/v1/messaging.pbenum.dart';
import '../../../gen/dzeroth/moderation/v1/moderation.pbenum.dart';
import '../../moderation/presentation/report_sheet.dart';
import 'bloc/thread_cubit.dart' show isConversationId;

/// The toast after a report was sent (W7-18): the thread does not change.
const kReportSentText = 'Report sent';

/// The sentence the message report sheet adds under its intro: the reviewers
/// get this one message (ADR-0027 D12), nothing else of the conversation.
const kReportMessageDetail =
    'Only this message is shared with our reviewers, not the rest of the '
    'conversation.';

/// Whether [message] can be reported (ADR-0027 D12): the peer's own, still
/// visible message. The caller's messages and tombstones (no text is left to
/// review) are not offered; the server answers VALIDATION for the first and
/// NOT_FOUND for the second.
bool canReportMessage(pb.Message message) =>
    !message.fromSelf &&
    message.state == MessageState.MESSAGE_STATE_VISIBLE &&
    isConversationId(message.id);

/// The `target_id` of a message report: `"<convId>:<msgId>"`, 32 lower-case hex
/// each (ADR-0027 D12). Throws [ArgumentError] for a message that cannot be
/// reported or an id of the wrong shape, so a malformed request is never sent.
String messageReportTargetId(String conversationId, pb.Message message) {
  if (!canReportMessage(message) || !isConversationId(conversationId)) {
    throw ArgumentError('This message cannot be reported');
  }
  return '$conversationId:${message.id}';
}

/// Opens the report sheet for one peer [message] (W7-18): the shared
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
