import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../features/posts/presentation/bloc/pending_posts_cubit.dart';

/// The status row above Home for a post being sent in the background: a
/// small thumbnail (or an icon), what is happening ("Uploading 2 of 3
/// photos", "Posting...", "Posted", "Couldn't post"), a one-line preview of
/// the text and a progress bar. A failed post offers Retry, Edit and Dismiss.
///
/// The status line is a live region, so a screen reader announces each
/// change (sending, failed, posted) without the user moving focus.
class PendingPostStatusRow extends StatelessWidget {
  const PendingPostStatusRow({
    super.key,
    required this.post,
    this.onRetry,
    this.onEdit,
    this.onDismiss,
  });

  final PendingPost post;
  final VoidCallback? onRetry;
  final VoidCallback? onEdit;
  final VoidCallback? onDismiss;

  /// The words for the status line.
  static String statusText(PendingPost p) {
    switch (p.status) {
      case PendingPostStatus.posted:
        return p.notice == null ? 'Posted' : 'Posted. ${p.notice}';
      case PendingPostStatus.failed:
        return p.error ?? "Couldn't post";
      case PendingPostStatus.sending:
        if (p.uploading && p.photosTotal > 0) {
          final n = (p.photosDone + 1).clamp(1, p.photosTotal);
          return p.photosTotal == 1
              ? 'Uploading photo...'
              : 'Uploading $n of ${p.photosTotal} photos...';
        }
        return 'Posting...';
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final failed = post.status == PendingPostStatus.failed;
    final posted = post.status == PendingPostStatus.posted;
    final status = statusText(post);
    final thumb = post.thumbnails.isEmpty ? null : post.thumbnails.first;
    final icon = failed
        ? Icons.error_outline
        : posted
        ? Icons.check_circle_outline
        : Icons.schedule_send_outlined;
    final tone = failed ? scheme.error : scheme.onSurfaceVariant;
    final preview = post.text.trim().isEmpty
        ? (post.thumbnails.isEmpty ? '' : 'Photo post')
        : post.text.replaceAll(RegExp(r'\s+'), ' ');
    return Container(
      margin: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      padding: const EdgeInsets.all(AppSpacing.smd),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(
          color: failed ? scheme.error : scheme.outlineVariant,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(AppRadius.sm),
                child: SizedBox.square(
                  dimension: AppSpacing.xl,
                  child: thumb == null
                      ? ColoredBox(
                          color: scheme.surfaceContainer,
                          child: Icon(icon, color: tone),
                        )
                      : ExcludeSemantics(
                          child: Image.memory(
                            thumb,
                            fit: BoxFit.cover,
                            gaplessPlayback: true,
                            errorBuilder: (_, _, _) => Icon(icon, color: tone),
                          ),
                        ),
                ),
              ),
              const SizedBox(width: AppSpacing.smd),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Semantics(
                      liveRegion: true,
                      container: true,
                      child: Text(
                        status,
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: failed ? scheme.error : scheme.onSurface,
                        ),
                      ),
                    ),
                    if (preview.isNotEmpty)
                      Text(
                        preview,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
              if (posted)
                Icon(Icons.check_circle, color: scheme.primary)
              else if (failed && onDismiss != null)
                IconButton(
                  tooltip: 'Dismiss',
                  constraints: const BoxConstraints(
                    minWidth: AppSpacing.minTapTarget,
                    minHeight: AppSpacing.minTapTarget,
                  ),
                  onPressed: onDismiss,
                  icon: const Icon(Icons.close),
                ),
            ],
          ),
          if (post.status == PendingPostStatus.sending) ...[
            const SizedBox(height: AppSpacing.sm),
            ExcludeSemantics(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(AppRadius.sm),
                child: LinearProgressIndicator(value: post.progress),
              ),
            ),
          ],
          if (failed)
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (onEdit != null)
                  TextButton(
                    style: TextButton.styleFrom(
                      minimumSize: const Size(
                        AppSpacing.minTapTarget,
                        AppSpacing.minTapTarget,
                      ),
                    ),
                    onPressed: onEdit,
                    child: Text(post.thumbnails.isEmpty ? 'Edit' : 'Edit text'),
                  ),
                if (post.canRetry && onRetry != null)
                  TextButton(
                    style: TextButton.styleFrom(
                      minimumSize: const Size(
                        AppSpacing.minTapTarget,
                        AppSpacing.minTapTarget,
                      ),
                    ),
                    onPressed: onRetry,
                    child: const Text('Retry'),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}
