import 'package:material_ui/material_ui.dart';

import '../e2ee/encryption_copy.dart' show kRequiredNoteText;

/// The disclosure every messaging surface shows: the
/// operator can read messages. One constant, so the Inbox empty state, the
/// new-message screen and the request banner can never drift apart.
const kMessagesNotEncryptedText = 'Messages are not end-to-end encrypted.';

/// [kMessagesNotEncryptedText] as quiet secondary text: the theme's small
/// body style in the secondary colour. It is read by screen readers like any
/// other line (never excluded from semantics) and wraps at any text scale.
///
/// [encryptionRequired] (Plan 6 Task 1.B): a thread that is not encrypted yet
/// while `e2ee_required` is on shows [kRequiredNoteText] instead (no new
/// message there goes out in plaintext). Only the thread and the draft pass
/// it; every other surface keeps the not-encrypted line.
class NotEncryptedNote extends StatelessWidget {
  const NotEncryptedNote({
    super.key,
    this.textAlign,
    this.encryptionRequired = false,
  });

  final TextAlign? textAlign;
  final bool encryptionRequired;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      encryptionRequired ? kRequiredNoteText : kMessagesNotEncryptedText,
      textAlign: textAlign,
      style: theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}
