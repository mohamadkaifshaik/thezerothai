import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

/// The bordered "This post is unavailable" placeholder: a deleted, hidden or
/// otherwise unshowable post (thread context rows, quote and repost embeds
/// with `unavailable`, ADR-0018 D12). It never says why: the server does not
/// distinguish the causes either. [message] overrides the text for the
/// "you blocked / muted this account" variants of an embed.
class UnavailablePostBox extends StatelessWidget {
  const UnavailablePostBox({
    super.key,
    this.message = 'This post is unavailable',
  });

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Semantics(
      container: true,
      label: message,
      excludeSemantics: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: theme.dividerColor),
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Row(
            children: [
              Icon(
                Icons.speaker_notes_off_outlined,
                size: AppIconSize.lg,
                color: muted,
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  message,
                  style: theme.textTheme.bodyMedium?.copyWith(color: muted),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
