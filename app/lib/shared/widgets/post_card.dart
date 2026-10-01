import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/network/app_exception.dart';
import '../../core/router/app_router.dart';
import '../../core/theme/app_theme.dart';
import '../../features/graph/data/graph_repository.dart';
import '../../features/graph/presentation/bloc/relationship_cubit.dart';
import '../../features/graph/presentation/graph_error_messages.dart';
import '../../features/posts/domain/post_text_parser.dart';
import '../../features/profile/presentation/widgets/block_confirmation_dialog.dart';
import '../../gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import '../../gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import '../format/relative_time.dart';

/// Opens [uri] in the external browser (a new tab on web). Only ever called
/// with an `http(s)` URL produced by [parsePostText].
Future<void> launchPostLink(Uri uri) async {
  await launchUrl(
    uri,
    mode: LaunchMode.externalApplication,
    webOnlyWindowName: '_blank',
  );
}

/// One post in any list (Home, profile tabs, detail): author row, relative
/// time, rich text and an overflow menu (T15, ADR-0010 D7).
///
/// - Text is rendered as spans only; HTML is never interpreted. Links are
///   `http(s)` only and open externally. Mention spans match
///   `mentions[].handle` case-insensitively and open the profile by
///   `mentions[].user_id`. Hashtags are tappable placeholders until Phase 2.
/// - The overflow menu shows Delete on the viewer's own posts (after a
///   confirmation, via [onDelete]) and Block/Mute on others' (reusing
///   [RelationshipCubit] and [showBlockConfirmationDialog]); it is absent
///   when nothing applies.
/// - The counts row stays hidden until engagement ships (P5).
///
/// Display only: 0 RPCs. Navigation and side effects are injectable so the
/// card is testable without a router or platform channels.
class PostCard extends StatelessWidget {
  const PostCard({
    super.key,
    required this.view,
    this.viewerUserId,
    this.now,
    this.graphActionsEnabled = true,
    this.onDelete,
    this.onOpenProfile,
    this.onOpenLink,
    this.onHashtagTap,
  });

  final pb.PostView view;

  /// The signed-in user's id; decides own-post vs other-post menu.
  final String? viewerUserId;

  /// Reference time for the relative timestamp; defaults to `DateTime.now()`
  /// at build time. Tests pass a fixed value.
  final DateTime? now;

  /// Whether the `graph` flag is on, i.e. Block/Mute may be offered.
  final bool graphActionsEnabled;

  /// Deletes a post after the user confirmed. Null hides Delete.
  final Future<void> Function(String postId)? onDelete;

  /// Opens a profile. Receives the user_id (authoritative) and the handle
  /// (the route key today). Defaults to pushing `/profile/<handle>` with the
  /// user_id as `extra`.
  final void Function(String userId, String handle)? onOpenProfile;

  /// Opens an `http(s)` link. Defaults to [launchPostLink].
  final void Function(Uri uri)? onOpenLink;

  /// Called when a hashtag is tapped. Defaults to a "coming soon" snackbar.
  final VoidCallback? onHashtagTap;

  pb.Post get _post => view.post;

  bool get _isOwn =>
      viewerUserId != null &&
      viewerUserId!.isNotEmpty &&
      _post.author.userId == viewerUserId;

  void _openProfile(BuildContext context, String userId, String handle) {
    final handler = onOpenProfile;
    if (handler != null) {
      handler(userId, handle);
      return;
    }
    if (handle.isEmpty) return;
    context.push(AppRouter.profilePath(handle), extra: userId);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final author = _post.author;
    final reference = now ?? DateTime.now();
    final created = _post.hasCreatedAt() ? _post.createdAt.toDateTime() : null;
    final shortTime = created == null
        ? ''
        : formatRelativeTime(created, reference);
    final spokenTime = created == null
        ? ''
        : formatRelativeTimeSpoken(created, reference);
    final displayName = author.displayName.isEmpty
        ? '@${author.handle}'
        : author.displayName;

    final authorLabel = [
      displayName,
      if (author.verified) 'verified',
      '@${author.handle}',
      if (spokenTime.isNotEmpty) spokenTime,
    ].join(', ');

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            button: true,
            label: 'Open profile of @${author.handle}',
            excludeSemantics: true,
            child: InkResponse(
              onTap: () => _openProfile(context, author.userId, author.handle),
              radius: AppSpacing.minTapTarget / 2,
              child: SizedBox(
                width: AppSpacing.minTapTarget,
                height: AppSpacing.minTapTarget,
                child: Center(child: _Avatar(url: author.avatarUrl)),
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
                          onTap: () => _openProfile(
                            context,
                            author.userId,
                            author.handle,
                          ),
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
                                time: shortTime,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    _OverflowMenu(
                      post: _post,
                      isOwn: _isOwn,
                      graphActionsEnabled: graphActionsEnabled,
                      onDelete: onDelete,
                    ),
                  ],
                ),
                PostRichText(
                  text: _post.text,
                  mentions: _post.mentions,
                  style: theme.textTheme.bodyLarge,
                  onOpenLink: onOpenLink ?? launchPostLink,
                  onOpenMention: (userId, handle) =>
                      _openProfile(context, userId, handle),
                  onHashtagTap:
                      onHashtagTap ?? () => _comingSoon(context, 'Hashtags'),
                ),
                const SizedBox(height: AppSpacing.xs),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

void _comingSoon(BuildContext context, String what) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text('$what are coming soon.')));
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.url});

  /// The 96 px thumbnail from the author snapshot (never the full image).
  final String url;

  @override
  Widget build(BuildContext context) {
    return CircleAvatar(
      radius: 20,
      backgroundImage: url.isEmpty
          ? null
          : CachedNetworkImageProvider(url, maxWidth: 96, maxHeight: 96),
      child: url.isEmpty ? const Icon(Icons.person_outline) : null,
    );
  }
}

class _AuthorLine extends StatelessWidget {
  const _AuthorLine({
    required this.displayName,
    required this.handle,
    required this.verified,
    required this.time,
  });

  final String displayName;
  final String handle;
  final bool verified;
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
          Icon(Icons.verified, size: 16, color: theme.colorScheme.primary),
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

/// The post body: [parsePostText] spans as tappable `TextSpan`s. Owns the
/// gesture recognizers (disposed with the widget) and re-parses only when
/// the text or mentions change.
class PostRichText extends StatefulWidget {
  const PostRichText({
    super.key,
    required this.text,
    required this.mentions,
    required this.onOpenLink,
    required this.onOpenMention,
    required this.onHashtagTap,
    this.style,
  });

  final String text;
  final List<pb.Mention> mentions;
  final TextStyle? style;
  final void Function(Uri uri) onOpenLink;
  final void Function(String userId, String handle) onOpenMention;
  final VoidCallback onHashtagTap;

  @override
  State<PostRichText> createState() => _PostRichTextState();
}

class _PostRichTextState extends State<PostRichText> {
  late List<PostSpan> _spans;
  final List<TapGestureRecognizer> _recognizers = [];

  @override
  void initState() {
    super.initState();
    _spans = parsePostText(widget.text, widget.mentions);
  }

  @override
  void didUpdateWidget(PostRichText old) {
    super.didUpdateWidget(old);
    if (old.text != widget.text ||
        !_sameMentions(old.mentions, widget.mentions)) {
      _spans = parsePostText(widget.text, widget.mentions);
    }
  }

  bool _sameMentions(List<pb.Mention> a, List<pb.Mention> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].handle != b[i].handle || a[i].userId != b[i].userId) {
        return false;
      }
    }
    return true;
  }

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  void _disposeRecognizers() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  TapGestureRecognizer _tap(VoidCallback onTap) {
    final recognizer = TapGestureRecognizer()..onTap = onTap;
    _recognizers.add(recognizer);
    return recognizer;
  }

  @override
  Widget build(BuildContext context) {
    _disposeRecognizers();
    final colors = Theme.of(context).colorScheme;
    final tappableStyle = TextStyle(color: colors.primary);
    final linkStyle = tappableStyle.copyWith(
      decoration: TextDecoration.underline,
      decorationColor: colors.primary,
    );

    final children = <InlineSpan>[
      for (final span in _spans)
        switch (span.kind) {
          PostSpanKind.plain => TextSpan(text: span.text),
          PostSpanKind.link => TextSpan(
            text: span.text,
            style: linkStyle,
            semanticsLabel: 'Link: ${span.text}',
            recognizer: _tap(() => widget.onOpenLink(span.url!)),
          ),
          PostSpanKind.mention => TextSpan(
            text: span.text,
            style: tappableStyle,
            semanticsLabel: 'Mention ${span.text}',
            recognizer: _tap(
              () => widget.onOpenMention(span.userId!, span.handle!),
            ),
          ),
          PostSpanKind.hashtag => TextSpan(
            text: span.text,
            style: tappableStyle,
            semanticsLabel: 'Hashtag ${span.text}',
            recognizer: _tap(widget.onHashtagTap),
          ),
        },
    ];

    return Text.rich(TextSpan(style: widget.style, children: children));
  }
}

enum _MenuAction { delete, block, mute }

class _OverflowMenu extends StatelessWidget {
  const _OverflowMenu({
    required this.post,
    required this.isOwn,
    required this.graphActionsEnabled,
    required this.onDelete,
  });

  final pb.Post post;
  final bool isOwn;
  final bool graphActionsEnabled;
  final Future<void> Function(String postId)? onDelete;

  @override
  Widget build(BuildContext context) {
    final handle = post.author.handle;
    final canDelete = isOwn && onDelete != null;
    final canGraph =
        !isOwn && graphActionsEnabled && post.author.userId.isNotEmpty;
    if (!canDelete && !canGraph) return const SizedBox.shrink();

    return PopupMenuButton<_MenuAction>(
      tooltip: 'More options',
      icon: const Icon(Icons.more_horiz),
      padding: const EdgeInsets.all(AppSpacing.md - AppSpacing.xs),
      onSelected: (action) => _onSelected(context, action),
      itemBuilder: (context) => [
        if (canDelete)
          const PopupMenuItem(value: _MenuAction.delete, child: Text('Delete')),
        if (canGraph) ...[
          PopupMenuItem(
            value: _MenuAction.block,
            child: Text('Block @$handle'),
          ),
          PopupMenuItem(value: _MenuAction.mute, child: Text('Mute @$handle')),
        ],
      ],
    );
  }

  Future<void> _onSelected(BuildContext context, _MenuAction action) async {
    switch (action) {
      case _MenuAction.delete:
        final confirmed = await _confirmDelete(context);
        if (confirmed) await onDelete!(post.postId);
      case _MenuAction.block:
        final confirmed = await showBlockConfirmationDialog(context);
        if (confirmed && context.mounted) {
          await _runGraphAction(context, (cubit) => cubit.block());
        }
      case _MenuAction.mute:
        await _runGraphAction(context, (cubit) => cubit.mute());
    }
  }

  Future<void> _runGraphAction(
    BuildContext context,
    Future<void> Function(RelationshipCubit cubit) action,
  ) async {
    final repository = context.read<GraphRepository>();
    final messenger = ScaffoldMessenger.of(context);
    final cubit = RelationshipCubit(
      graphRepository: repository,
      userId: post.author.userId,
      initial:
          repository.cached(post.author.userId) ??
          graph.Relationship(userId: post.author.userId),
    );
    try {
      await action(cubit);
      final AppException? error = cubit.state.error;
      if (error != null) {
        messenger
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(content: Text(relationshipErrorMessage(error))),
          );
      }
    } finally {
      await cubit.close();
    }
  }

  Future<bool> _confirmDelete(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this post?'),
        content: const Text("This can't be undone."),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }
}
