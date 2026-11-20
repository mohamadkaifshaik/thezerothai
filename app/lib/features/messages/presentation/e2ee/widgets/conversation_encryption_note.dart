import 'package:material_ui/material_ui.dart';

import '../../../../../core/theme/app_theme.dart';
import '../../widgets/not_encrypted_note.dart';
import '../encryption_copy.dart';

/// The per-conversation note (spec 7.10.1). `encrypted: true` draws a lock and
/// [kEncryptedNoteText] with a "How this works" link (only when [onLearnMore]
/// is set); `encrypted: false` draws the existing [NotEncryptedNote]
/// unchanged. Ordinary text plus a link: it wraps at any text scale and is
/// centred by its parent.
class ConversationEncryptionNote extends StatelessWidget {
  const ConversationEncryptionNote({
    super.key,
    required this.encrypted,
    this.textAlign,
    this.onLearnMore,
  });

  final bool encrypted;
  final TextAlign? textAlign;

  /// Opens the explanation panel; null hides the link.
  final VoidCallback? onLearnMore;

  /// Key of the "How this works" link.
  static const learnMoreKey = ValueKey('encryption-note-learn-more');

  @override
  Widget build(BuildContext context) {
    if (!encrypted) return NotEncryptedNote(textAlign: textAlign);
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.xs / 2),
              child: ExcludeSemantics(
                child: Icon(
                  Icons.lock_outline,
                  size: AppIconSize.sm,
                  color: muted,
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.xs),
            Flexible(
              child: Text(
                kEncryptedNoteText,
                textAlign: textAlign,
                style: theme.textTheme.bodySmall?.copyWith(color: muted),
              ),
            ),
          ],
        ),
        if (onLearnMore != null)
          TextButton(
            key: learnMoreKey,
            style: TextButton.styleFrom(
              minimumSize: const Size(0, AppSpacing.minTapTarget),
              textStyle: theme.textTheme.bodySmall,
            ),
            onPressed: onLearnMore,
            child: const Text(kEncryptionHowItWorksLabel),
          ),
      ],
    );
  }
}
