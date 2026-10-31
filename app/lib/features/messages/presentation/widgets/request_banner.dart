import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;
import '../../../../gen/dzeroth/messaging/v1/messaging.pbenum.dart';
import 'not_encrypted_note.dart';

/// Messages a sender may send to a request before the recipient accepts it
/// (`MESSAGES_REQUEST_MAX_UNANSWERED`, ADR-0027 D13). Copy only: the server
/// enforces the cap (`LIMIT_REACHED request_unanswered`).
const kMessageRequestMaxUnanswered = 3;

/// The sender's line on a request nobody has accepted yet.
const kSentRequestText =
    'Waiting for them to accept. You can send up to '
    '$kMessageRequestMaxUnanswered messages.';

/// A request the caller received and has not accepted: it sits in the
/// REQUESTS folder (ADR-0027 D5). The caller gets the banner, not a composer.
bool isReceivedRequest(pb.Conversation conversation) =>
    conversation.state == ConversationState.CONVERSATION_STATE_REQUEST &&
    conversation.folder == Folder.FOLDER_REQUESTS;

/// A request the caller sent and the peer has not accepted: it stays in the
/// caller's INBOX. A header with no folder is neither (nothing is guessed).
/// With `can_reply` false (blocked, or the peer's account is gone) the thread
/// is read-only and nothing is waited for, so it is not a pending request
/// either (W7-25b).
bool isSentRequest(pb.Conversation conversation) =>
    conversation.state == ConversationState.CONVERSATION_STATE_REQUEST &&
    conversation.folder == Folder.FOLDER_INBOX &&
    conversation.canReply;

/// What the request banner can ask of the conversation screen (W7-18). The
/// screen owns the confirmations, the calls and the snackbars; the banner only
/// draws buttons.
class ThreadRequestActions {
  const ThreadRequestActions({
    required this.accept,
    required this.delete,
    this.block,
    this.accepting = false,
    this.deleting = false,
    this.blocking = false,
  });

  /// Null hides Accept (W7-26: read-only Messages cannot accept; Delete, Block
  /// and the info menu's Report stay).
  final VoidCallback? accept;
  final VoidCallback delete;

  /// Null hides Block (the `graph` flag is off for the caller). While a block
  /// runs ([blocking]) it stays visible and, like the others, off.
  final VoidCallback? block;

  /// AcceptMessageRequest is in flight.
  final bool accepting;

  /// DeleteConversation is in flight.
  final bool deleting;

  /// The block flow (confirmation, then the graph call) is running.
  final bool blocking;

  bool get busy => accepting || deleting || blocking;
}

/// The `ThreadScreen.bannerBuilder` the router passes: the received-request
/// banner, the sender's waiting note, or nothing.
Widget? buildRequestBanner(
  BuildContext context,
  pb.Conversation conversation,
  ThreadRequestActions actions,
) {
  if (isReceivedRequest(conversation)) {
    return RequestBanner(
      peerName: requestPeerName(
        conversation.peer.displayName,
        conversation.peer.handle,
      ),
      actions: actions,
    );
  }
  if (isSentRequest(conversation)) return const SentRequestNote();
  return null;
}

/// The name a request line uses: the display name, else `@handle`.
String requestPeerName(String displayName, String handle) =>
    displayName.isNotEmpty ? displayName : '@$handle';

/// "`name` wants to message you" with Accept, Delete and Block (W7-18,
/// ADR-0027 D4), at the bottom of a request thread in place of the composer.
///
/// - Accept is the filled action; Delete and Block are outlined, Block in the
///   error colour. All three are 48dp and wrap at a large text scale.
/// - While Accept, Delete or Block runs, the three are off (Block stays
///   visible) and Accept shows a spinner, labelled "Accepting" for assistive
///   technology. Nothing is retried by itself.
/// - A live region, so the banner is announced when it appears; the buttons
///   are read in the order Accept, Delete, Block.
class RequestBanner extends StatelessWidget {
  const RequestBanner({
    super.key,
    required this.peerName,
    required this.actions,
  });

  final String peerName;
  final ThreadRequestActions actions;

  static const acceptKey = ValueKey('request-accept');
  static const deleteKey = ValueKey('request-delete');
  static const blockKey = ValueKey('request-block');

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final busy = actions.busy;
    const minSize = Size(0, AppSpacing.minTapTarget);
    return Semantics(
      container: true,
      liveRegion: true,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          color: colors.surface,
          border: Border(top: BorderSide(color: colors.outlineVariant)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '$peerName wants to message you',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: AppSpacing.xs),
            const NotEncryptedNote(),
            const SizedBox(height: AppSpacing.smd),
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: [
                if (actions.accept != null)
                  FilledButton(
                    key: acceptKey,
                    style: FilledButton.styleFrom(minimumSize: minSize),
                    onPressed: busy ? null : actions.accept,
                    child: actions.accepting
                        ? const SizedBox(
                            width: AppIconSize.md,
                            height: AppIconSize.md,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              semanticsLabel: 'Accepting',
                            ),
                          )
                        : const Text('Accept'),
                  ),
                OutlinedButton(
                  key: deleteKey,
                  style: OutlinedButton.styleFrom(minimumSize: minSize),
                  onPressed: busy ? null : actions.delete,
                  child: const Text('Delete'),
                ),
                if (actions.block != null)
                  OutlinedButton(
                    key: blockKey,
                    style: OutlinedButton.styleFrom(
                      minimumSize: minSize,
                      foregroundColor: colors.error,
                    ),
                    onPressed: busy ? null : actions.block,
                    child: const Text('Block'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// "Waiting for them to accept. You can send up to 3 messages." above the
/// composer of a request the caller sent (W7-18).
class SentRequestNote extends StatelessWidget {
  const SentRequestNote({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Semantics(
      container: true,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.sm,
        ),
        decoration: BoxDecoration(
          color: colors.surfaceContainerHigh,
          border: Border(top: BorderSide(color: colors.outlineVariant)),
        ),
        child: Text(
          kSentRequestText,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: colors.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

/// Whether the links of [message] may be tapped (W7-35, L-9): not while the
/// conversation is still a REQUEST and the message is the peer's. A stranger's
/// link is the phishing channel, so it shows as plain text until the request is
/// accepted. The caller's own messages are never held back; with no header yet
/// the answer is no (nothing is trusted before we know).
bool messageLinksEnabled(pb.Conversation? conversation, pb.Message message) =>
    message.fromSelf ||
    (conversation != null &&
        conversation.state != ConversationState.CONVERSATION_STATE_REQUEST);
