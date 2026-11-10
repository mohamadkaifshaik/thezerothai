import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../shared/widgets/primitives/app_dialog.dart';

/// The answer to "Save post?".
enum SavePostChoice { save, discard }

/// The copy for [SavePostDialog.mediaNote]: drafts never keep media.
const kDraftsPhotosNote = "Photos aren't saved in drafts.";
const kDraftsGifNote = "A GIF isn't saved in drafts.";

/// "Save post?": shown when the composer is left with
/// unsent content. Resolves to [SavePostChoice.save] or
/// [SavePostChoice.discard], or null for "Keep editing" and a dismissed
/// dialog (the composer stays open). [mediaNote] is the extra line about
/// photos or a GIF.
Future<SavePostChoice?> showSavePostDialog(
  BuildContext context, {
  String? mediaNote,
}) => showAppMaterialDialog<SavePostChoice>(
  context: context,
  builder: (_) => SavePostDialog(mediaNote: mediaNote),
);

class SavePostDialog extends StatelessWidget {
  const SavePostDialog({super.key, this.mediaNote});

  final String? mediaNote;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    const shape = StadiumBorder();
    const size = Size.fromHeight(AppSpacing.minTapTarget);
    final note = mediaNote;
    return AlertDialog(
      title: Text(
        'Save post?',
        style: theme.textTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w700,
        ),
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'You can save this to send later from your drafts.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
            if (note != null) ...[
              const SizedBox(height: AppSpacing.sm),
              Text(
                note,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: AppSpacing.lg),
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: size, shape: shape),
              onPressed: () => Navigator.of(context).pop(SavePostChoice.save),
              child: const Text('Save'),
            ),
            const SizedBox(height: AppSpacing.sm),
            OutlinedButton(
              style: OutlinedButton.styleFrom(
                minimumSize: size,
                shape: shape,
                foregroundColor: colors.error,
              ),
              onPressed: () =>
                  Navigator.of(context).pop(SavePostChoice.discard),
              child: const Text('Discard'),
            ),
            const SizedBox(height: AppSpacing.sm),
            TextButton(
              style: TextButton.styleFrom(minimumSize: size, shape: shape),
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Keep editing'),
            ),
          ],
        ),
      ),
    );
  }
}

/// "Discard unsent posts?" (Edit mode): a red filled pill for the
/// destructive answer and an outlined one for the safe one. Resolves to true
/// for Discard, false for Keep or a dismissed dialog. [count] words the
/// sentence.
Future<bool> showDiscardDraftsDialog(
  BuildContext context, {
  required int count,
}) async {
  final discard = await showAppMaterialDialog<bool>(
    context: context,
    builder: (_) => DiscardDraftsDialog(count: count),
  );
  return discard ?? false;
}

class DiscardDraftsDialog extends StatelessWidget {
  const DiscardDraftsDialog({super.key, required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    const shape = StadiumBorder();
    const size = Size.fromHeight(AppSpacing.minTapTarget);
    return AlertDialog(
      title: Text(
        'Discard unsent posts?',
        style: theme.textTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w700,
        ),
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              count == 1
                  ? 'This unsent post will be deleted from this device. It '
                        "can't be undone."
                  : 'These $count unsent posts will be deleted from this '
                        "device. It can't be undone.",
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: colors.error,
                foregroundColor: colors.onError,
                minimumSize: size,
                shape: shape,
              ),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Discard'),
            ),
            const SizedBox(height: AppSpacing.sm),
            OutlinedButton(
              style: OutlinedButton.styleFrom(minimumSize: size, shape: shape),
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Keep'),
            ),
          ],
        ),
      ),
    );
  }
}

/// The answer to "Sign out?" when this device holds the account's unsent
/// posts.
enum SignOutDraftsChoice {
  /// Sign out and delete the unsent posts from this device.
  delete,

  /// Sign out and keep them (the owner gets them back on the next sign-in).
  keep,
}

/// The sign-out notice (security L-5): said once, plainly, because on a
/// shared computer the rows stay readable in the browser profile.
const kSignOutDraftsBody = 'Your unsent posts stay on this device.';

/// "Sign out?" for an account that has unsent posts on this device.
/// Resolves to [SignOutDraftsChoice.delete] or [SignOutDraftsChoice.keep], or
/// null for "Cancel" and a dismissed dialog (the user stays signed in).
Future<SignOutDraftsChoice?> showSignOutDraftsDialog(BuildContext context) =>
    showAppMaterialDialog<SignOutDraftsChoice>(
      context: context,
      builder: (_) => const SignOutDraftsDialog(),
    );

class SignOutDraftsDialog extends StatelessWidget {
  const SignOutDraftsDialog({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    const shape = StadiumBorder();
    const size = Size.fromHeight(AppSpacing.minTapTarget);
    return AlertDialog(
      title: Text(
        'Sign out?',
        style: theme.textTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w700,
        ),
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              kSignOutDraftsBody,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: colors.error,
                foregroundColor: colors.onError,
                minimumSize: size,
                shape: shape,
              ),
              onPressed: () =>
                  Navigator.of(context).pop(SignOutDraftsChoice.delete),
              child: const Text('Delete them'),
            ),
            const SizedBox(height: AppSpacing.sm),
            OutlinedButton(
              style: OutlinedButton.styleFrom(minimumSize: size, shape: shape),
              onPressed: () =>
                  Navigator.of(context).pop(SignOutDraftsChoice.keep),
              child: const Text('Keep'),
            ),
            const SizedBox(height: AppSpacing.sm),
            TextButton(
              style: TextButton.styleFrom(minimumSize: size, shape: shape),
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
          ],
        ),
      ),
    );
  }
}
