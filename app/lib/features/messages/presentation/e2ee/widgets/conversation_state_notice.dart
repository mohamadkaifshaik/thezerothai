import 'package:material_ui/material_ui.dart';

import '../../../../../core/theme/app_theme.dart';
import '../../../domain/e2ee/encrypted_messaging.dart';
import '../encryption_copy.dart';

/// A notice's words: a title and a body (either may be empty, never both).
typedef _Words = ({String title, String body});

_Words? _wordsOf(ConversationSecurity s) => switch (s.state) {
  ConversationEncryptionState.ready ||
  ConversationEncryptionState.syncing ||
  ConversationEncryptionState.sendPaused ||
  ConversationEncryptionState.pendingRequest => null,
  ConversationEncryptionState.listUnverifiable => (
    title: kStateListUnverifiableTitle,
    body: kStateListUnverifiableBody,
  ),
  ConversationEncryptionState.peerHasNoDevice => (
    title: '',
    body: kStatePeerNoDeviceText,
  ),
  ConversationEncryptionState.waitingForDevice => (
    title: kStateWaitingTitle,
    body: kStateWaitingBody,
  ),
  ConversationEncryptionState.stuck => (
    title: kStateStuckTitle,
    body: s.canReset ? kStateStuckBodyCanReset : kStateStuckBodyNoReset,
  ),
  ConversationEncryptionState.unknownDevice => (
    title: kLineUnknownDevice,
    body: kStateUnknownDeviceBody,
  ),
  // The composer, not the state, says which of the two changesBlocked
  // notices is true: with canSend an unknown device is NOT present.
  ConversationEncryptionState.changesBlocked =>
    s.canSend
        ? (title: kStateBlockedCanSendTitle, body: kStateBlockedCanSendBody)
        : (
            title: kStateBlockedTitle,
            body: s.canReset
                ? kStateBlockedBodyCanReset
                : kStateBlockedBodyNoReset,
          ),
};

/// Whether [security]'s state has a notice at all.
bool conversationStateHasNotice(ConversationSecurity security) =>
    _wordsOf(security) != null;

/// The notice of a conversation state (Plan 5b Task 5), above the composer or
/// in its place. It decides nothing about the composer: the thread does, from
/// `canSend`. Actions: Block when [onBlock] is given, and Reset encryption
/// only with [onReset], `canReset`, and never for a sent request. A live
/// region with a header title; at a large text scale and on a phone the
/// actions stack full width, otherwise they sit in one row at the end.
class ConversationStateNotice extends StatelessWidget {
  const ConversationStateNotice({
    super.key,
    required this.security,
    required this.peerName,
    this.onReset,
    this.resetting = false,
    this.onBlock,
    this.focusFirstAction = false,
  });

  final ConversationSecurity security;

  /// Not drawn (the fixed copy names nobody); kept for the actions' labels.
  final String peerName;
  final VoidCallback? onReset;
  final bool resetting;
  final VoidCallback? onBlock;

  /// The notice replaces the composer: focus moves to its first action.
  final bool focusFirstAction;

  static const resetKey = ValueKey('conversation-notice-reset');
  static const blockKey = ValueKey('conversation-notice-block');

  @override
  Widget build(BuildContext context) {
    final words = _wordsOf(security);
    if (words == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final showReset =
        onReset != null && security.canReset && !security.sentRequest;
    final stacked =
        MediaQuery.sizeOf(context).width < AppBreakpoints.mobile ||
        MediaQuery.textScalerOf(context).scale(1) >= 1.5;
    const minSize = Size(0, AppSpacing.minTapTarget);
    var first = true;
    bool takeFocus() {
      final v = first && focusFirstAction;
      first = false;
      return v;
    }

    final actions = <Widget>[
      if (onBlock != null)
        TextButton(
          key: blockKey,
          autofocus: takeFocus(),
          style: TextButton.styleFrom(
            minimumSize: minSize,
            foregroundColor: colors.error,
          ),
          onPressed: onBlock,
          child: const Text('Block'),
        ),
      if (showReset)
        TextButton(
          key: resetKey,
          autofocus: takeFocus(),
          style: TextButton.styleFrom(minimumSize: minSize),
          onPressed: resetting ? null : onReset,
          child: resetting
              ? const SizedBox(
                  width: AppIconSize.md,
                  height: AppIconSize.md,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    semanticsLabel: kResetRunningLabel,
                  ),
                )
              : const Text(kConversationResetAction),
        ),
    ];
    return Semantics(
      container: true,
      liveRegion: true,
      child: Align(
        alignment: Alignment.bottomCenter,
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(AppSpacing.md),
            decoration: BoxDecoration(
              color: colors.surfaceContainerHigh,
              border: Border(top: BorderSide(color: colors.outlineVariant)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (words.title.isNotEmpty)
                  Semantics(
                    header: true,
                    child: Text(
                      words.title,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                if (words.title.isNotEmpty)
                  const SizedBox(height: AppSpacing.xs),
                Text(
                  words.body,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
                if (actions.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.sm),
                  if (stacked)
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: actions,
                    )
                  else
                    Wrap(
                      alignment: WrapAlignment.end,
                      spacing: AppSpacing.sm,
                      children: actions,
                    ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
