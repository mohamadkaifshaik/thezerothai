import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';

/// The final NOT_FOUND state: nothing to retry, and the same words for
/// missing, deleted and hidden (ADR-0010 D6). Shared by the post and thread
/// screens.
class PostUnavailableView extends StatelessWidget {
  const PostUnavailableView({super.key, required this.onHome});

  final VoidCallback onHome;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      liveRegion: true,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.speaker_notes_off_outlined,
                size: AppIconSize.xl,
                color: theme.colorScheme.error,
              ),
              const SizedBox(height: AppSpacing.md),
              Text(
                "This post isn't available",
                style: theme.textTheme.titleMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: AppSpacing.md),
              FilledButton.tonal(
                onPressed: onHome,
                child: const Text('Go to Home'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
