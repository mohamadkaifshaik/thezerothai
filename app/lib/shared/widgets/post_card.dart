import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/network/app_exception.dart';
import '../../core/router/app_router.dart';
import '../../core/theme/app_theme.dart';
import '../../features/engagement/domain/engagement_entry.dart';
import '../../features/engagement/presentation/bloc/engagement_cubit.dart';
import '../../features/engagement/presentation/widgets/post_engagement_bar.dart';
import '../../features/graph/data/graph_repository.dart';
import '../../features/graph/presentation/bloc/relationship_cubit.dart';
import '../../features/graph/presentation/graph_error_messages.dart';
import '../../features/moderation/presentation/report_sheet.dart';
import '../../features/posts/domain/post_text_parser.dart';
import '../../features/profile/presentation/pin_error_messages.dart';
import '../../features/profile/presentation/widgets/block_confirmation_dialog.dart';
import '../../gen/dzeroth/common/v1/common.pb.dart' as common;
import '../../gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import '../../gen/dzeroth/moderation/v1/moderation.pbenum.dart'
    show ReportTargetType;
import '../../gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import '../../gen/dzeroth/posts/v1/posts.pbenum.dart' show PostKind;
import '../format/relative_time.dart';
import 'app_avatar.dart';
import 'app_menu_item_row.dart';
import 'embedded_post_card.dart';
import 'post_action_bar.dart';
import 'post_media.dart';
import 'post_pin_control.dart';
import 'protected_badge.dart';
import 'protected_post_box.dart';
import 'unavailable_post_box.dart';

part 'post_card_menu.dart';
part 'post_rich_text.dart';

/// Opens [uri] in the external browser (a new tab on web). Only ever called
/// with an `http(s)` URL produced by [parsePostText]. Returns false when the
/// platform could not open it (never throws).
Future<bool> launchPostLink(Uri uri) async {
  try {
    return await launchUrl(
      uri,
      mode: LaunchMode.externalApplication,
      webOnlyWindowName: '_blank',
    );
  } catch (_) {
    return false;
  }
}

/// Lines of post text a list card shows before "Show more" (the post
/// detail view shows all of it).
const kPostTextClampLines = 6;

/// One post in any list (Home, profile tabs, detail): author row, relative
/// time, rich text and an overflow menu (T15, ADR-0010 D7).
///
/// - Text is rendered as spans only; HTML is never interpreted. Links are
///   `http(s)` only and open externally. Mention spans match
///   `mentions[].handle` case-insensitively and open the profile **by
///   user_id** (`/u/:userId`), never by handle: handles can be changed and
///   re-claimed, and `mentions[].handle` is frozen at write time.
///   Hashtags are tappable placeholders until Phase 2.
/// - The overflow menu shows Delete on the viewer's own posts (after a
///   confirmation, via [onDelete]) and Block/Mute (or Unblock/Unmute, from
///   the relationship cache) on others' (reusing [RelationshipCubit] and
///   [showBlockConfirmationDialog]); it is absent when nothing applies.
/// - Engagement (P5, ADR-0018): with [engagementEnabled] (the `engagement`
///   flag; screens pass `isFeatureEnabled(context, kFeatureEngagement)`) the
///   card shows the reply / repost / like row ([PostEngagementBar]); off, no
///   row and no engagement code runs. A REPOST item renders as the original
///   (from its frozen `embedded` snapshot) under a "X reposted" line, and a
///   QUOTE renders its text followed by a compact embed of the quoted post.
///   An embed that is deleted/hidden (`unavailable`), or whose author the
///   viewer blocks or mutes (local relationship cache), is replaced by a
///   placeholder that shows nothing of the snapshot (D12/D13).
///
/// Display only: 0 RPCs of its own. Navigation and side effects are
/// injectable so the card is testable without a router or platform channels.
class PostCard extends StatelessWidget {
  const PostCard({
    super.key,
    required this.view,
    this.viewerUserId,
    this.now,
    this.graphActionsEnabled = true,
    this.reportsEnabled = false,
    this.onDelete,
    this.onOpenProfile,
    this.onOpenLink,
    this.onHashtagTap,
    this.onRelationshipChanged,
    this.actions,
    this.showFullImages = false,
    this.engagementEnabled = false,
    this.showReply = true,
    this.onOpenPost,
    this.bookmarkEnabled,
    this.pinControl,
  });

  final pb.PostView view;

  /// Overrides whether the engagement row shows the bookmark icon: null
  /// follows the `bookmarks` flag; the Bookmarks screen passes true (a caller
  /// dropped from the allowlist can still remove what they saved).
  final bool? bookmarkEnabled;

  /// Show full-size images instead of thumbnails: the detail view only. Every
  /// list keeps the default (thumbnails, review #110 M2).
  final bool showFullImages;

  /// Low-level action callbacks (the bar dispatches them as events; the card
  /// holds no state). Null (the default) leaves the bar to
  /// [engagementEnabled].
  final PostActions? actions;

  /// Whether the `engagement` flag is on: shows the like / repost / reply
  /// row driven by the session's `EngagementCubit` (which must be provided
  /// above). Off by default: a screen opts in.
  final bool engagementEnabled;

  /// Offer Reply in the engagement row (false on the focal post of a thread,
  /// which has its own reply composer).
  final bool showReply;

  /// Opens a post by id (a quoted post). Defaults to pushing `/post/<id>`.
  final void Function(String postId)? onOpenPost;

  /// The signed-in user's id; decides own-post vs other-post menu.
  final String? viewerUserId;

  /// Reference time for the relative timestamp; defaults to `DateTime.now()`
  /// at build time. Tests pass a fixed value. The card does not tick: a
  /// screen that wants live "5m" labels rebuilds its list periodically.
  final DateTime? now;

  /// Whether the `graph` flag is on, i.e. Block/Mute may be offered.
  final bool graphActionsEnabled;

  /// Whether the `reports` flag is on, i.e. "Report post" may be offered on
  /// other people's posts (ADR-0016). Off by default: a screen opts in.
  final bool reportsEnabled;

  /// Deletes a post after the user confirmed. Null hides Delete. A thrown
  /// error is reported with a snackbar.
  final Future<void> Function(String postId)? onDelete;

  /// Pin / Unpin rows for the viewer's own POST, QUOTE or REPLY (W3-17).
  /// Null (the default) offers none: a screen that can pin passes one.
  final PostPinControl? pinControl;

  /// Opens a profile by user_id. Defaults to pushing `/u/<userId>`.
  final void Function(String userId)? onOpenProfile;

  /// Opens an `http(s)` link. Defaults to [launchPostLink] plus a
  /// "Couldn't open link" snackbar on failure.
  final void Function(Uri uri)? onOpenLink;

  /// Called when a hashtag is tapped. Defaults to a "coming soon" snackbar.
  final VoidCallback? onHashtagTap;

  /// Called with the author's new relationship after Block/Unblock/Mute/
  /// Unmute succeeded (the timeline hides blocked/muted authors, D6).
  final ValueChanged<graph.Relationship>? onRelationshipChanged;

  pb.Post get _post => view.post;

  bool get _isOwn =>
      viewerUserId != null &&
      viewerUserId!.isNotEmpty &&
      _post.author.userId == viewerUserId;

  bool _isViewer(String userId) =>
      viewerUserId != null &&
      viewerUserId!.isNotEmpty &&
      userId == viewerUserId;

  /// What Report / Block / Mute act on. A REPOST row that shows its original
  /// targets the ORIGINAL post and author (the account the card displays);
  /// everything else (own posts, QUOTE rows, a REPOST whose original is
  /// hidden) targets the row's own post and author.
  _MenuTarget _menuTarget({pb.EmbeddedPost? original}) {
    if (original != null) {
      return _MenuTarget(
        userId: original.author.userId,
        handle: original.author.handle,
        postId: original.postId,
        isOwn: _isViewer(original.author.userId),
        reportLabel: 'Report post',
        subject: "@${original.author.handle}'s post",
      );
    }
    final isRepost = _post.kind == PostKind.POST_KIND_REPOST;
    return _MenuTarget(
      userId: _post.author.userId,
      handle: _post.author.handle,
      postId: _post.postId,
      isOwn: _isOwn,
      reportLabel: isRepost ? 'Report repost' : 'Report post',
      subject: isRepost
          ? "@${_post.author.handle}'s repost"
          : "@${_post.author.handle}'s post",
    );
  }

  void _openProfile(BuildContext context, String userId) {
    if (userId.isEmpty) return;
    final handler = onOpenProfile;
    if (handler != null) {
      handler(userId);
      return;
    }
    context.push(AppRouter.profileByIdPath(userId));
  }

  Future<void> _openLink(BuildContext context, Uri uri) async {
    final handler = onOpenLink;
    if (handler != null) {
      handler(uri);
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    if (!await launchPostLink(uri)) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text("Couldn't open link.")));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isRepost =
        _post.kind == PostKind.POST_KIND_REPOST &&
        _post.hasEmbedded() &&
        _post.embedded.postId.isNotEmpty;
    final embedded = _post.hasEmbedded() ? _post.embedded : null;
    final placeholder = embedded == null
        ? null
        : _placeholderFor(context, embedded);
    if (isRepost && placeholder != null) {
      // The caller's own REPOST of a protected author they can no longer see
      // (W3-41b): the box carries Undo repost, acting on the original's id, and
      // the row has that one action only: Delete is an equivalent server-side
      // undo (DeletePost of a REPOST releases its reposts doc and the count), so
      // the menu is kept only when Undo repost is not offered.
      final undoable =
          placeholder == EmbedPlaceholder.protected &&
          canUndoProtectedRepost(
            view,
            viewerUserId: viewerUserId,
            engagementEnabled: engagementEnabled,
          );
      return _RepostPlaceholder(
        reposter: _post.author,
        isOwn: _isOwn,
        placeholder: placeholder,
        original: embedded!.author,
        onUndo: undoable
            ? () => unawaited(
                context.read<EngagementCubit>().setReposted(
                  embedded.postId,
                  reposted: false,
                  shown: EngagementEntry.fromView(view),
                ),
              )
            : null,
        menu: undoable
            ? const SizedBox.shrink()
            : _PostMenu(
                post: _post,
                isOwn: _isOwn,
                target: _menuTarget(),
                graphActionsEnabled: graphActionsEnabled,
                reportsEnabled: reportsEnabled,
                onDelete: onDelete,
                pinControl: pinControl,
                onRelationshipChanged: onRelationshipChanged,
              ),
      );
    }
    // A REPOST shows the original it points to (its frozen snapshot).
    final author = isRepost ? embedded!.author : _post.author;
    final text = isRepost ? embedded!.text : _post.text;
    final media = isRepost ? embedded!.media : _post.media;
    final mentions = isRepost ? const <pb.Mention>[] : _post.mentions;
    final createdAt = isRepost
        ? (embedded!.hasCreatedAt() ? embedded.createdAt : null)
        : (_post.hasCreatedAt() ? _post.createdAt : null);
    final reference = now ?? DateTime.now();
    final created = createdAt?.toDateTime();
    final shortTime = created == null
        ? ''
        : formatRelativeTime(created, reference);
    final spokenTime = created == null
        ? ''
        : formatRelativeTimeSpoken(created, reference);
    final displayName = author.displayName.isEmpty
        ? '@${author.handle}'
        : author.displayName;

    // The viewer may see this post only because the author protects their
    // posts and the viewer is the author or an approved follower (ADR-0025 D4).
    final protectedAuthor =
        !isRepost && _post.visibility == pb.Visibility.VISIBILITY_FOLLOWERS;

    final authorLabel = [
      displayName,
      if (protectedAuthor) 'protected account',
      if (author.verified) 'verified',
      '@${author.handle}',
      if (spokenTime.isNotEmpty) spokenTime,
    ].join(', ');

    final row = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          button: true,
          label: 'Open profile of @${author.handle}',
          excludeSemantics: true,
          child: InkResponse(
            onTap: () => _openProfile(context, author.userId),
            radius: AppSpacing.minTapTarget / 2,
            child: SizedBox(
              width: AppSpacing.minTapTarget,
              height: AppSpacing.minTapTarget,
              child: Center(child: AppAvatar(url: author.avatarUrl)),
            ),
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Semantics(
                      button: true,
                      label: authorLabel,
                      excludeSemantics: true,
                      child: InkWell(
                        onTap: () => _openProfile(context, author.userId),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(
                            minHeight: AppSpacing.minTapTarget,
                          ),
                          child: Align(
                            alignment: AlignmentDirectional.centerStart,
                            child: _AuthorLine(
                              displayName: displayName,
                              handle: author.handle,
                              verified: author.verified,
                              protected: protectedAuthor,
                              time: shortTime,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  _PostMenu(
                    post: _post,
                    isOwn: _isOwn,
                    target: _menuTarget(original: isRepost ? embedded : null),
                    graphActionsEnabled: graphActionsEnabled,
                    reportsEnabled: reportsEnabled,
                    onDelete: onDelete,
                    pinControl: pinControl,
                    onRelationshipChanged: onRelationshipChanged,
                  ),
                ],
              ),
              // An image-only post has empty text: no empty line above the images.
              if (text.isNotEmpty)
                PostRichText(
                  maxLines: showFullImages ? null : kPostTextClampLines,
                  text: text,
                  mentions: mentions,
                  style: theme.textTheme.bodyLarge,
                  onOpenLink: (uri) => _openLink(context, uri),
                  onOpenMention: (userId, handle) =>
                      _openProfile(context, userId),
                  onHashtagTap:
                      onHashtagTap ??
                      () => _showMessage(context, 'Hashtags are coming soon.'),
                ),
              if (media.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.sm),
                PostMedia(media: media, useFullImage: showFullImages),
              ],
              if (!isRepost &&
                  _post.kind == PostKind.POST_KIND_QUOTE &&
                  embedded != null &&
                  embedded.postId.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.sm),
                EmbeddedPostCard(
                  embedded: embedded,
                  placeholder: placeholder,
                  now: now,
                  onTap: placeholder == null
                      ? () => _openPost(context, embedded.postId)
                      : null,
                ),
              ],
              if (actions != null) ...[
                const SizedBox(height: AppSpacing.sm),
                PostActionBar(
                  likeCount: _post.likeCount.toInt(),
                  repostCount: _post.repostCount.toInt(),
                  replyCount: _post.replyCount.toInt(),
                  liked: view.likedByViewer,
                  reposted: view.repostedByViewer,
                  actions: actions!,
                ),
              ] else if (engagementEnabled) ...[
                const SizedBox(height: AppSpacing.sm),
                PostEngagementBar(
                  view: view,
                  showReply: showReply,
                  bookmarkEnabled: bookmarkEnabled,
                ),
              ] else
                const SizedBox(height: AppSpacing.xs),
            ],
          ),
        ),
      ],
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.smd,
        AppSpacing.md,
        AppSpacing.smd,
      ),
      child: isRepost
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _RepostedBy(reposter: _post.author, isOwn: _isOwn),
                row,
              ],
            )
          : row,
    );
  }

  void _openPost(BuildContext context, String postId) {
    final handler = onOpenPost;
    if (handler != null) {
      handler(postId);
      return;
    }
    context.push(AppRouter.postPath(postId));
  }

  /// Why [embedded] must not be shown, if so: gone (`unavailable`), or its
  /// author is blocked / muted by the viewer. The server says so on the
  /// detail views (`embed_viewer_state`, issue #152), which holds even when
  /// the local relationship cache is cold after a restart; otherwise (an older
  /// server, a feed row cached before the block) the local cache decides, 0
  /// RPCs. The server already drops such copies from feeds. The viewer's own
  /// posts are never hidden.
  EmbedPlaceholder? _placeholderFor(
    BuildContext context,
    pb.EmbeddedPost embedded,
  ) {
    if (embedded.unavailable) return EmbedPlaceholder.unavailable;
    switch (view.embedViewerState) {
      case pb.EmbedViewerState.EMBED_VIEWER_STATE_BLOCKED:
        return EmbedPlaceholder.blocked;
      case pb.EmbedViewerState.EMBED_VIEWER_STATE_MUTED:
        return EmbedPlaceholder.muted;
      case pb.EmbedViewerState.EMBED_VIEWER_STATE_PROTECTED:
        return EmbedPlaceholder.protected;
      default:
        break;
    }
    final authorId = embedded.author.userId;
    if (!graphActionsEnabled || authorId.isEmpty || authorId == viewerUserId) {
      return null;
    }
    final relationship = context.read<GraphRepository>().cached(authorId);
    if (relationship == null) return null;
    if (relationship.blocking) return EmbedPlaceholder.blocked;
    if (relationship.muting) return EmbedPlaceholder.muted;
    return null;
  }
}

String _repostedByLabel(common.AuthorSnapshot reposter, bool isOwn) {
  if (isOwn) return 'You reposted';
  final name = reposter.displayName.isEmpty
      ? '@${reposter.handle}'
      : reposter.displayName;
  return '$name reposted';
}

/// The "X reposted" line above a REPOST item, aligned with the avatar
/// column (the viewer's own repost reads "You reposted").
class _RepostedBy extends StatelessWidget {
  const _RepostedBy({
    required this.reposter,
    required this.isOwn,
    this.trailing,
  });

  final common.AuthorSnapshot reposter;
  final bool isOwn;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final label = _repostedByLabel(reposter, isOwn);
    return Semantics(
      container: true,
      label: label,
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.xs),
        child: Row(
          children: [
            SizedBox(
              width: AppSpacing.minTapTarget,
              child: Align(
                alignment: AlignmentDirectional.centerEnd,
                child: Icon(Icons.repeat, size: AppIconSize.sm, color: muted),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(color: muted),
              ),
            ),
            ?trailing,
          ],
        ),
      ),
    );
  }
}

/// A REPOST whose original cannot be shown (blocked / muted author, or
/// already tombstoned): the "X reposted" line over a placeholder box, with
/// nothing from the snapshot.
class _RepostPlaceholder extends StatelessWidget {
  const _RepostPlaceholder({
    required this.reposter,
    required this.isOwn,
    required this.placeholder,
    required this.original,
    required this.menu,
    this.onUndo,
  });

  final common.AuthorSnapshot reposter;
  final bool isOwn;
  final EmbedPlaceholder placeholder;

  /// The original's author: shown only for the protected placeholder.
  final common.AuthorSnapshot original;

  /// Actions on the repost itself (the hidden original gets none).
  final Widget menu;

  /// Undo repost on the caller's own protected REPOST (W3-41b); null: none.
  final VoidCallback? onUndo;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.sm,
        AppSpacing.md,
        AppSpacing.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _RepostedBy(reposter: reposter, isOwn: isOwn, trailing: menu),
          Padding(
            padding: const EdgeInsetsDirectional.only(
              start: AppSpacing.minTapTarget + AppSpacing.sm,
            ),
            child: placeholder == EmbedPlaceholder.protected
                ? ProtectedPostBox(
                    author: original,
                    actionLabel: onUndo == null ? null : 'Undo repost',
                    actionSemanticLabel:
                        "Undo repost of @${original.handle}'s post",
                    onAction: onUndo,
                  )
                : UnavailablePostBox(
                    message: EmbeddedPostCard.placeholderMessage(placeholder),
                  ),
          ),
        ],
      ),
    );
  }
}

void _showMessage(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

class _AuthorLine extends StatelessWidget {
  const _AuthorLine({
    required this.displayName,
    required this.handle,
    required this.verified,
    required this.time,
    this.protected = false,
  });

  final String displayName;
  final String handle;
  final bool verified;
  final bool protected;
  final String time;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Row(
      children: [
        Flexible(
          child: Text(
            displayName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleSmall,
          ),
        ),
        if (verified) ...[
          const SizedBox(width: AppSpacing.xs),
          Icon(
            Icons.verified,
            size: AppIconSize.sm,
            color: theme.colorScheme.primary,
          ),
        ],
        if (protected) ...[
          const SizedBox(width: AppSpacing.xs),
          const ProtectedBadge(),
        ],
        const SizedBox(width: AppSpacing.xs),
        Flexible(
          child: Text(
            '@$handle',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(color: muted),
          ),
        ),
        if (time.isNotEmpty) ...[
          Text(
            ' · ',
            style: theme.textTheme.bodyMedium?.copyWith(color: muted),
          ),
          Text(
            time,
            maxLines: 1,
            style: theme.textTheme.bodyMedium?.copyWith(color: muted),
          ),
        ],
      ],
    );
  }
}
