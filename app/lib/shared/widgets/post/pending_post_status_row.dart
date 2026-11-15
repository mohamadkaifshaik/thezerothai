import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../features/posts/presentation/bloc/pending_posts_cubit.dart';

/// How many characters of the text a label or tooltip quotes.
const kLabelPreviewLength = 40;

/// The status row above Home for a post being sent in the background: a
/// small thumbnail (or an icon), what is happening ("Uploading 2 of 3
/// photos", "Posting...", "Posted", "Couldn't post"), a one-line preview of
/// the text and a progress bar. A failed post offers Retry, Edit and Dismiss
/// (and "Verify email" when the server asks for it).
///
/// Accessibility: the row is one container labelled with the post's preview,
/// so each action says which post it acts on. The status line is a live
/// region that announces only the state changes (sending, posted, failed),
/// never the upload counter.
class PendingPostStatusRow extends StatelessWidget {
  const PendingPostStatusRow({
    super.key,
    required this.post,
    this.onRetry,
    this.onEdit,
    this.onDismiss,
    this.onVerify,
  });

  final PendingPost post;
  final VoidCallback? onRetry;
  final VoidCallback? onEdit;
  final VoidCallback? onDismiss;
  final VoidCallback? onVerify;

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

  /// What a screen reader announces when the status changes: the state only.
  static String announcement(PendingPost p) {
    switch (p.status) {
      case PendingPostStatus.posted:
        return p.notice == null ? 'Posted' : 'Posted. ${p.notice}';
      case PendingPostStatus.failed:
        return "Couldn't post. ${p.error ?? ''}".trim();
      case PendingPostStatus.sending:
        return 'Posting';
    }
  }

  static String _preview(PendingPost p) {
    final collapsed = p.text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (collapsed.isNotEmpty) return collapsed;
    return p.thumbnails.isEmpty ? '' : 'Photo post';
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
    final preview = _preview(post);
    // Labels and tooltips name the post by its first words only.
    final short = preview.runes.length > kLabelPreviewLength
        ? '${String.fromCharCodes(preview.runes.take(kLabelPreviewLength))}…'
        : preview;
    final about = preview.isEmpty ? 'your post' : '"$short"';
    final minTap = Size(AppSpacing.minTapTarget, AppSpacing.minTapTarget);
    Widget action(String label, String semantics, VoidCallback onTap) =>
        Semantics(
          button: true,
          label: semantics,
          excludeSemantics: true,
          onTap: onTap,
          child: TextButton(
            style: TextButton.styleFrom(minimumSize: minTap),
            onPressed: onTap,
            child: Text(label),
          ),
        );
    return Semantics(
      container: true,
      label: 'Post: $about',
      child: Container(
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
                              errorBuilder: (_, _, _) =>
                                  Icon(icon, color: tone),
                            ),
                          ),
                  ),
                ),
                const SizedBox(width: AppSpacing.smd),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Announced on change; the visible text (with the photo
                      // counter) is not read out a second time.
                      Semantics(
                        liveRegion: true,
                        container: true,
                        label: announcement(post),
                        excludeSemantics: true,
                        child: Text(
                          status,
                          style: theme.textTheme.labelLarge?.copyWith(
                            color: failed ? scheme.error : scheme.onSurface,
                          ),
                        ),
                      ),
                      if (preview.isNotEmpty)
                        ExcludeSemantics(
                          child: Text(
                            preview,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                if (posted)
                  ExcludeSemantics(
                    child: Icon(Icons.check_circle, color: scheme.primary),
                  )
                else if (failed && onDismiss != null)
                  IconButton(
                    tooltip: 'Dismiss $about',
                    constraints: BoxConstraints(
                      minWidth: minTap.width,
                      minHeight: minTap.height,
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
                  if (post.needsVerify && onVerify != null)
                    action(
                      'Verify email',
                      'Verify email for $about',
                      onVerify!,
                    ),
                  if (onEdit != null)
                    action(
                      post.keepsPhotos || post.thumbnails.isEmpty
                          ? 'Edit'
                          : 'Edit text only',
                      post.keepsPhotos || post.thumbnails.isEmpty
                          ? 'Edit $about'
                          : 'Edit text of $about, photos will be removed',
                      onEdit!,
                    ),
                  if (post.canRetry && onRetry != null)
                    action('Retry', 'Retry sending $about', onRetry!),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
