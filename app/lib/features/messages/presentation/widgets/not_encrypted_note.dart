import 'package:flutter/material.dart';

/// The disclosure every messaging surface shows (ADR-0027 D11, W7-31): the
/// operator can read messages. One constant, so the Inbox empty state, the
/// new-message screen and the request banner can never drift apart.
const kMessagesNotEncryptedText = 'Messages are not end-to-end encrypted.';

/// [kMessagesNotEncryptedText] as quiet secondary text: the theme's small
/// body style in the secondary colour. It is read by screen readers like any
/// other line (never excluded from semantics) and wraps at any text scale.
class NotEncryptedNote extends StatelessWidget {
  const NotEncryptedNote({super.key, this.textAlign});

  final TextAlign? textAlign;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      kMessagesNotEncryptedText,
      textAlign: textAlign,
      style: theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}
