import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import '../format/relative_time.dart';
import 'app_avatar.dart';
import 'poll_card.dart';
import 'post_media.dart';
import 'protected_post_box.dart';
import 'unavailable_post_box.dart';

/// Why a quote's embed is not shown as the quoted post.
enum EmbedPlaceholder {
  /// Deleted, hidden or otherwise gone (`EmbeddedPost.unavailable`).
  unavailable,

  /// The viewer blocks the quoted author (local relationship cache).
  blocked,

  /// The viewer mutes the quoted author.
  muted,

  /// The quoted author protects their posts and the viewer is not an approved
  /// follower (`EMBED_VIEWER_STATE_PROTECTED`, ADR-0025 D5): only the author
  /// is shown.
  protected,
}

/// The quoted post inside a QUOTE (ADR-0018 D12): a bordered, compact copy
/// of the frozen [pb.EmbeddedPost] snapshot - author, relative time, text
/// (at most [maxTextLines]) and its thumbnails. One level only: it never
/// shows an embed of its own. Tapping it calls [onTap] (opens the quoted
/// post).
///
/// With [placeholder] set it shows the "unavailable / blocked / muted" box
/// instead of any content from the snapshot, so nothing of a hidden author
/// leaks through a copy.
class EmbeddedPostCard extends StatelessWidget {
  const EmbeddedPostCard({
    super.key,
    required this.embedded,
    this.placeholder,
    this.onTap,
    this.now,
    this.maxTextLines = 6,
  });

  final pb.EmbeddedPost embedded;
  final EmbedPlaceholder? placeholder;
  final VoidCallback? onTap;
  final DateTime? now;
  final int maxTextLines;

  static String placeholderMessage(EmbedPlaceholder placeholder) {
    return switch (placeholder) {
      EmbedPlaceholder.unavailable => 'This post is unavailable',
      EmbedPlaceholder.blocked => 'You blocked this account',
      EmbedPlaceholder.muted => 'You muted this account',
      EmbedPlaceholder.protected =>
        'This post is from an account that protects its posts.',
    };
  }

  @override
  Widget build(BuildContext context) {
    final hidden = placeholder;
    if (hidden == EmbedPlaceholder.protected) {
      return ProtectedPostBox(author: embedded.author);
    }
    if (hidden != null) {
      return UnavailablePostBox(message: placeholderMessage(hidden));
    }
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final author = embedded.author;
    final name = author.displayName.isEmpty
        ? '@${author.handle}'
        : author.displayName;
    final reference = now ?? DateTime.now();
    final created = embedded.hasCreatedAt()
        ? embedded.createdAt.toDateTime()
        : null;
    final time = created == null ? '' : formatRelativeTime(created, reference);
    final spoken = created == null
        ? ''
        : formatRelativeTimeSpoken(created, reference);

    final card = DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: theme.dividerColor),
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.sm + AppSpacing.xs),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                AppAvatar(url: author.avatarUrl, radius: AppSpacing.sm),
                const SizedBox(width: AppSpacing.sm),
                Flexible(
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                const SizedBox(width: AppSpacing.xs),
                Flexible(
                  child: Text(
                    '@${author.handle}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(color: muted),
                  ),
                ),
                if (time.isNotEmpty)
                  Text(
                    ' · $time',
                    maxLines: 1,
                    style: theme.textTheme.bodyMedium?.copyWith(color: muted),
                  ),
              ],
            ),
            if (embedded.text.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.xs),
              Text(
                embedded.text,
                maxLines: maxTextLines,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(height: 1.35),
              ),
            ],
            if (embedded.media.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.sm),
              PostMedia(media: embedded.media),
            ],
            // W6-13: the frozen poll definition, compact and read-only; the
            // whole card opens the original for live results.
            if (embedded.hasPoll()) ...[
              const SizedBox(height: AppSpacing.xs),
              PollEmbedSummary(poll: embedded.poll, now: reference),
            ],
          ],
        ),
      ),
    );

    return Semantics(
      container: true,
      button: onTap != null,
      label: [
        'Quoted post by $name',
        '@${author.handle}',
        if (spoken.isNotEmpty) spoken,
        if (embedded.text.isNotEmpty) embedded.text,
        if (embedded.media.isNotEmpty) 'with ${embedded.media.length} photos',
        if (embedded.hasPoll())
          PollEmbedSummary.summary(embedded.poll, reference),
        if (embedded.hasPoll())
          PollEmbedSummary.summary(embedded.poll, reference),
      ].join(', '),
      excludeSemantics: true,
      onTap: onTap,
      child: onTap == null
          ? card
          : InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(AppRadius.lg),
              child: card,
            ),
    );
  }
}
