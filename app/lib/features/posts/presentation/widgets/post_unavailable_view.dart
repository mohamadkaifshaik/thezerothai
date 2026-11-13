import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../shared/widgets/primitives/app_pill_button.dart';

/// The final NOT_FOUND state: nothing to retry, and the same words for
/// missing, deleted and hidden. Shared by the post and thread
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
                // The design's 17 sp at 800.
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: AppSpacing.md),
              AppPillButton(
                label: 'Go to Home',
                variant: AppButtonVariant.outline,
                onPressed: onHome,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
