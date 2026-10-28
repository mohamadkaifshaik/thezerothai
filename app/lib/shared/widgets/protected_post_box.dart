import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../gen/dzeroth/common/v1/common.pb.dart' as common;

/// The bordered placeholder for a post whose author protects their posts
/// (ADR-0025 D5, `EMBED_VIEWER_STATE_PROTECTED`): a lock, the author's name and
/// @handle, and [message]. The server sends only the author snapshot for it,
/// and this box shows nothing else: no post text, no media, and no avatar
/// image either (so it makes no image request at all). It is not tappable:
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
              Icon(Icons.lock_outline, size: AppIconSize.lg, color: muted),
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
                    Text(
                      message,
                      style: theme.textTheme.bodyMedium?.copyWith(color: muted),
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
