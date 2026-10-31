import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../bloc/composer_cubit.dart';

/// What the user chose in [SendConflictDialog].
enum SendConflictChoice {
  /// Look at the profile (or the scheduled posts) to see what was sent.
  look,

  /// Send again under a NEW key: the explicit choice to risk a second post.
  sendAnyway,
}

/// The words of one [SendConflict] (W6-39, ADR-0029 Amendment 1 A4).
class SendConflictCopy {
  const SendConflictCopy({
    required this.title,
    required this.body,
    required this.lookLabel,
    this.sendAnywayLabel,
  });

  final String title;
  final String body;

  /// "View profile", or "Scheduled posts" when the pending send is a schedule.
  final String lookLabel;

  /// Null when sending again is not offered.
  final String? sendAnywayLabel;

  static const _viewProfile = 'View profile';

  static SendConflictCopy of(SendConflict conflict) => switch (conflict) {
    SendConflict.earlierVersionSent => const SendConflictCopy(
      title: 'An earlier version of this post was sent',
      body: 'Check your profile first. You can still post this version too.',
      lookLabel: _viewProfile,
      sendAnywayLabel: 'Post this version too',
    ),
    SendConflict.draftGone => const SendConflictCopy(
      title: 'This draft was already sent',
      body:
          'It was sent or deleted in another window. Check your profile '
          'before posting it again.',
      lookLabel: _viewProfile,
    ),
    SendConflict.pendingPost => const SendConflictCopy(
      title: 'This post may already be out',
      body:
          'An earlier try at posting this may have gone through. Check '
          'your profile before scheduling it.',
      lookLabel: _viewProfile,
      sendAnywayLabel: 'Schedule anyway',
    ),
    SendConflict.pendingSchedule => const SendConflictCopy(
      title: 'This post may already be scheduled',
      body:
          'An earlier try at scheduling this may have gone through. Check '
          'your scheduled posts before posting it now.',
      lookLabel: 'Scheduled posts',
      sendAnywayLabel: 'Post now anyway',
    ),
    SendConflict.unconfirmed => const SendConflictCopy(
      title: "We couldn't confirm this was posted",
      body:
          'An earlier try was a while ago and we can no longer check it. '
          'Check your profile first.',
      lookLabel: _viewProfile,
      sendAnywayLabel: 'Post anyway',
    ),
  };
}

/// Shows [SendConflictDialog]. Resolves to the choice, or null when the
/// dialog was dismissed (the composer stays as it was, nothing is sent).
Future<SendConflictChoice?> showSendConflictDialog(
  BuildContext context,
  SendConflict conflict,
) => showDialog<SendConflictChoice>(
  context: context,
  builder: (_) => SendConflictDialog(conflict: conflict),
);

/// Tells the user a draft send was stopped, or answered by the server as an
/// earlier send, and lets them look first. The look button is the filled one:
/// looking is the safe answer; sending again is the outlined one.
class SendConflictDialog extends StatelessWidget {
  const SendConflictDialog({super.key, required this.conflict});

  final SendConflict conflict;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    const shape = StadiumBorder();
    const size = Size.fromHeight(AppSpacing.minTapTarget);
    final copy = SendConflictCopy.of(conflict);
    final again = copy.sendAnywayLabel;
    return AlertDialog(
      title: Text(
        copy.title,
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
              copy.body,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: size, shape: shape),
              onPressed: () =>
                  Navigator.of(context).pop(SendConflictChoice.look),
              child: Text(copy.lookLabel),
            ),
            if (again != null) ...[
              const SizedBox(height: AppSpacing.sm),
              OutlinedButton(
                style: OutlinedButton.styleFrom(
                  minimumSize: size,
                  shape: shape,
                ),
                onPressed: () =>
                    Navigator.of(context).pop(SendConflictChoice.sendAnyway),
                child: Text(again),
              ),
            ],
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
