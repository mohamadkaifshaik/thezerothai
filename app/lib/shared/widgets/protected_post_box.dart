import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../gen/dzeroth/common/v1/common.pb.dart' as common;
import 'app_avatar.dart';

/// The bordered placeholder for a post whose author protects their posts
/// (ADR-0025 D5, `EMBED_VIEWER_STATE_PROTECTED`): the author's avatar, name and
/// @handle (public header data, founder 2026-10-28), a lock and [message]. The
/// server sends only the author snapshot for it, and this box shows nothing
/// else: no post text and no post media. It is not tappable:
/// opening the post would answer NOT_FOUND for a stranger.
class ProtectedPostBox extends StatelessWidget {
  const ProtectedPostBox({
    super.key,
    required this.author,
    this.message = 'This post is from an account that protects its posts.',
  });

  final common.AuthorSnapshot author;
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final name = author.displayName.isEmpty
        ? '@${author.handle}'
        : author.displayName;
    return Semantics(
      container: true,
      label: [
        name,
        if (author.handle.isNotEmpty) '@${author.handle}',
        message,
      ].join(', '),
      excludeSemantics: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: theme.dividerColor),
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AppAvatar(url: author.avatarUrl, radius: AppSpacing.md),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall,
                          ),
                        ),
                        if (author.displayName.isNotEmpty &&
                            author.handle.isNotEmpty) ...[
                          const SizedBox(width: AppSpacing.xs),
                          Flexible(
                            child: Text(
                              '@${author.handle}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: muted,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(top: AppSpacing.xs),
                          child: Icon(
                            Icons.lock_outline,
                            size: AppIconSize.sm,
                            color: muted,
                          ),
                        ),
                        const SizedBox(width: AppSpacing.xs),
                        Expanded(
                          child: Text(
                            message,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: muted,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
