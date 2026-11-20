import 'package:material_ui/material_ui.dart';

import '../../domain/e2ee/encryption_access.dart';
import '../e2ee/encryption_access_builder.dart';
import '../e2ee/encryption_copy.dart';
import 'not_encrypted_note.dart';

/// The one line under the inbox's empty state and the recipient picker's
/// header: what is true of messages on this device.
///
/// - Access `full` or `manage`: some conversations are encrypted
///   ([kEncryptionMixedNoteText]), in the same quiet style as the old note.
/// - `hidden` or `unsupported` (and no encryption wiring in the tree): the
///   existing [NotEncryptedNote], unchanged.
class MessagesEncryptionNote extends StatelessWidget {
  const MessagesEncryptionNote({super.key, this.textAlign});

  final TextAlign? textAlign;

  @override
  Widget build(BuildContext context) {
    return EncryptionAccessBuilder(
      builder: (context, access) {
        switch (access) {
          case EncryptionAccess.full:
          case EncryptionAccess.manage:
            final theme = Theme.of(context);
            return Text(
              kEncryptionMixedNoteText,
              textAlign: textAlign,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            );
          case EncryptionAccess.hidden:
          case EncryptionAccess.unsupported:
            return NotEncryptedNote(textAlign: textAlign);
        }
      },
    );
  }
}
