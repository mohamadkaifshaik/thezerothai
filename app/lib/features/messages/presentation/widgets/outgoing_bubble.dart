import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../bloc/message_composer_cubit.dart';
import 'message_bubble.dart' show kBubbleMaxWidthFraction;

/// The status line under a bubble that is on its way.
const kOutgoingSendingText = 'Sending…';

/// The status line (and the whole tap target) of a bubble that failed.
const kOutgoingNotSentText = 'Not sent. Tap to retry';

/// A message the caller just sent, before the thread holds the server's copy
/// (W7-16). Presentational.
///
/// - Sending: the own-message bubble dimmed, with "Sending…" under it.
/// - Failed: the bubble with "Not sent. Tap to retry" under it in the error
///   colour; the whole column is one 48dp target that calls [onRetry].
/// - Semantics: one node, "You said ..., sending" or "... Not sent. Tap to
///   retry" (a button).
class OutgoingBubble extends StatelessWidget {
  const OutgoingBubble({
    super.key,
    required this.message,
    required this.onRetry,
    this.topGap = AppSpacing.xs,
  });

  final OutgoingMessage message;

  /// Called with the row's idempotency key when a failed bubble is tapped.
  final void Function(String localId) onRetry;

  /// The gap above (larger at the start of a group of own messages).
  final double topGap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final failed = message.status == OutgoingStatus.failed;
    final status = failed ? kOutgoingNotSentText : kOutgoingSendingText;
    const radius = Radius.circular(AppRadius.lg);
    final bubble = Opacity(
      opacity: failed ? 1 : 0.6,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.primary,
          borderRadius: const BorderRadiusDirectional.all(radius),
          border: failed ? Border.all(color: colors.error) : null,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.smd,
            vertical: AppSpacing.sm,
          ),
          child: Text(
            message.text,
            style: theme.textTheme.bodyLarge?.copyWith(color: colors.onPrimary),
          ),
        ),
      ),
    );
    final column = Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        bubble,
        ConstrainedBox(
          constraints: failed
              ? const BoxConstraints(minHeight: AppSpacing.minTapTarget)
              : const BoxConstraints(),
          child: Padding(
            padding: const EdgeInsets.only(top: AppSpacing.xs),
            child: Text(
              status,
              style: theme.textTheme.bodySmall?.copyWith(
                color: failed ? colors.error : colors.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ],
    );
    return Padding(
      padding: EdgeInsetsDirectional.only(
        start: AppSpacing.md,
        end: AppSpacing.md,
        top: topGap,
      ),
      child: Align(
        alignment: AlignmentDirectional.centerEnd,
        child: LayoutBuilder(
          builder: (context, constraints) => ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: constraints.maxWidth * kBubbleMaxWidthFraction,
            ),
            child: Semantics(
              container: true,
              excludeSemantics: true,
              button: failed,
              label: failed
                  ? 'You said ${message.text}. $kOutgoingNotSentText'
                  : 'You said ${message.text}, sending',
              onTap: failed ? () => onRetry(message.localId) : null,
              child: failed
                  ? InkWell(
                      borderRadius: BorderRadius.circular(AppRadius.lg),
                      onTap: () => onRetry(message.localId),
                      child: column,
                    )
                  : column,
            ),
          ),
        ),
      ),
    );
  }
}
