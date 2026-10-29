import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../gen/dzeroth/common/v1/common.pb.dart' as common;
import '../../gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import '../../gen/dzeroth/posts/v1/posts.pbenum.dart' show PostKind;
import 'app_avatar.dart';

/// Whether [view] is a REPOST whose original the server withheld because its
/// author protects their posts (`EMBED_VIEWER_STATE_PROTECTED`). Other viewers
/// never get such a row (ADR-0025 D4); the caller gets their own on their own
/// profile so they can undo it (note W3-36 L-2). Nothing opens from it: the
/// original answers NOT_FOUND. A gone original (`embedded.unavailable`)
/// is not this case: `PostCard` answers it with the unavailable box first.
bool isProtectedRepost(pb.PostView view) {
  final post = view.post;
  return post.kind == PostKind.POST_KIND_REPOST &&
      view.embedViewerState ==
          pb.EmbedViewerState.EMBED_VIEWER_STATE_PROTECTED &&
      post.hasEmbedded() &&
      !post.embedded.unavailable &&
      post.embedded.postId.isNotEmpty;
}

/// Whether [view] is the caller's own protected REPOST and Undo repost can be
/// offered on it (W3-41b): [isProtectedRepost], the reposter is
/// [viewerUserId], the server says the caller reposted the original, and the
/// `engagement` flag is on for the caller ([engagementEnabled], like the repost
/// button). Never gated on `private_accounts`: an undo works whatever that
/// flag is (ADR-0025).
bool canUndoProtectedRepost(
  pb.PostView view, {
  required String? viewerUserId,
  required bool engagementEnabled,
}) =>
    engagementEnabled &&
    isProtectedRepost(view) &&
    view.repostedByViewer &&
    viewerUserId != null &&
    viewerUserId.isNotEmpty &&
    view.post.author.userId == viewerUserId;

/// The bordered placeholder for a post whose author protects their posts
/// (ADR-0025 D5, `EMBED_VIEWER_STATE_PROTECTED`): the author's avatar, name and
/// @handle (public header data, founder 2026-10-28), a lock and [message]. The
/// server sends only the author snapshot for it, and this box shows nothing
/// else: no post text and no post media. It is not tappable:
/// opening the post would answer NOT_FOUND for a stranger.
///
/// The caller's own rows of a protected author they can no longer see (their
/// REPOST, Like and Bookmark, W3-41b) add ONE action under the box:
/// [actionLabel] with [onAction] ("Undo repost", "Unlike", "Remove bookmark").
/// The button is a sibling of the box's labelled node, so a screen reader
/// reads the box first and then the button. It is an outlined 48dp-high
/// button under the box (never beside it), so it cannot overflow at a large
/// text scale. Without [actionLabel] the box is exactly the read-only one.
class ProtectedPostBox extends StatelessWidget {
  const ProtectedPostBox({
    super.key,
    required this.author,
    this.message = 'This post is from an account that protects its posts.',
    this.actionLabel,
    this.onAction,
    this.actionSemanticLabel,
  });

  final common.AuthorSnapshot author;
  final String message;

  /// The visible label of the one action; null draws none.
  final String? actionLabel;

  /// Runs the action; null with an [actionLabel] draws the button disabled.
  final VoidCallback? onAction;

  /// What a screen reader says for the button; defaults to [actionLabel].
  final String? actionSemanticLabel;

  @override
  Widget build(BuildContext context) {
    final box = _box(context);
    final label = actionLabel;
    if (label == null) return box;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        box,
        const SizedBox(height: AppSpacing.sm),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: Semantics(
            button: true,
            enabled: onAction != null,
            label: actionSemanticLabel ?? label,
            excludeSemantics: true,
            onTap: onAction,
            child: OutlinedButton(
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(
                  AppSpacing.minButtonWidth,
                  AppSpacing.minTapTarget,
                ),
              ),
              onPressed: onAction,
              child: Text(label),
            ),
          ),
        ),
      ],
    );
  }

  Widget _box(BuildContext context) {
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
