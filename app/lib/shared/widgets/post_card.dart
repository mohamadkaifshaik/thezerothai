import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

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
import 'app_avatar.dart';

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
/// - The counts row stays hidden until engagement ships (P5).
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
    this.onDelete,
    this.onOpenProfile,
    this.onOpenLink,
    this.onHashtagTap,
    this.onRelationshipChanged,
  });

  final pb.PostView view;

  /// The signed-in user's id; decides own-post vs other-post menu.
  final String? viewerUserId;

  /// Reference time for the relative timestamp; defaults to `DateTime.now()`
  /// at build time. Tests pass a fixed value. The card does not tick: a
  /// screen that wants live "5m" labels rebuilds its list periodically.
  final DateTime? now;

  /// Whether the `graph` flag is on, i.e. Block/Mute may be offered.
  final bool graphActionsEnabled;

  /// Deletes a post after the user confirmed. Null hides Delete. A thrown
  /// error is reported with a snackbar.
  final Future<void> Function(String postId)? onDelete;

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
                      graphActionsEnabled: graphActionsEnabled,
                      onDelete: onDelete,
                      onRelationshipChanged: onRelationshipChanged,
                    ),
                  ],
                ),
                PostRichText(
                  text: _post.text,
                  mentions: _post.mentions,
                  style: theme.textTheme.bodyLarge,
                  onOpenLink: (uri) => _openLink(context, uri),
                  onOpenMention: (userId, handle) =>
                      _openProfile(context, userId),
                  onHashtagTap:
                      onHashtagTap ??
                      () => _showMessage(context, 'Hashtags are coming soon.'),
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

/// Closes [cubit] now, or once its in-flight Block/Mute settles, so the
/// awaiting `_run` still sees the real outcome (never an optimistic state).
void _closeWhenSettled(RelationshipCubit cubit) {
  if (cubit.isClosed) return;
  if (cubit.state.isUpdating) {
    cubit.stream
        .firstWhere((s) => !s.isUpdating)
        .then((_) => cubit.close(), onError: (_) => cubit.close());
  } else {
    cubit.close();
  }
}

/// The overflow menu. For another author it holds ONE [RelationshipCubit]
/// for the card's lifetime (created on first open), so a retry after a
/// failed Block/Mute reuses the same idempotency key (CLAUDE.md rule 4).
class _PostMenu extends StatefulWidget {
  const _PostMenu({
    required this.post,
    required this.isOwn,
    required this.graphActionsEnabled,
    required this.onDelete,
    required this.onRelationshipChanged,
  });

  final pb.Post post;
  final bool isOwn;
  final bool graphActionsEnabled;
  final Future<void> Function(String postId)? onDelete;
  final ValueChanged<graph.Relationship>? onRelationshipChanged;

  @override
  State<_PostMenu> createState() => _PostMenuState();
}

class _PostMenuState extends State<_PostMenu> {
  RelationshipCubit? _cubit;

  RelationshipCubit _cubitFor(BuildContext context) {
    final existing = _cubit;
    if (existing != null && existing.userId == widget.post.author.userId) {
      return existing;
    }
    if (existing != null) _closeWhenSettled(existing);
    final repository = context.read<GraphRepository>();
    final userId = widget.post.author.userId;
    return _cubit = RelationshipCubit(
      graphRepository: repository,
      userId: userId,
      initial: repository.cached(userId) ?? graph.Relationship(userId: userId),
    );
  }

  @override
  void dispose() {
    // A Block/Mute still in flight keeps its cubit until it settles, so
    // `_run` can still report the result (the server applied it).
    final cubit = _cubit;
    if (cubit != null) _closeWhenSettled(cubit);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final handle = widget.post.author.handle;
    final canDelete = widget.isOwn && widget.onDelete != null;
    final canGraph =
        !widget.isOwn &&
        widget.graphActionsEnabled &&
        widget.post.author.userId.isNotEmpty;
    if (!canDelete && !canGraph) return const SizedBox.shrink();

    return PopupMenuButton<_MenuAction>(
      tooltip: 'More options',
      icon: const Icon(Icons.more_horiz),
      padding: const EdgeInsets.all(AppSpacing.md - AppSpacing.xs),
      onSelected: (action) => _onSelected(context, action),
      itemBuilder: (context) {
        final relationship = canGraph
            ? _cubitFor(context).state.relationship
            : null;
        return [
          if (canDelete)
            const PopupMenuItem(
              value: _MenuAction.delete,
              child: Text('Delete'),
            ),
          if (relationship != null) ...[
            PopupMenuItem(
              value: _MenuAction.block,
              child: Text(
                relationship.blocking ? 'Unblock @$handle' : 'Block @$handle',
              ),
            ),
            PopupMenuItem(
              value: _MenuAction.mute,
              child: Text(
                relationship.muting ? 'Unmute @$handle' : 'Mute @$handle',
              ),
            ),
          ],
        ];
      },
    );
  }

  Future<void> _onSelected(BuildContext context, _MenuAction action) async {
    switch (action) {
      case _MenuAction.delete:
        await _delete(context);
      case _MenuAction.block:
        final cubit = _cubitFor(context);
        if (cubit.state.relationship.blocking) {
          await _run(context, cubit.unblock, 'Unblocked');
        } else {
          final confirmed = await showBlockConfirmationDialog(context);
          if (confirmed && context.mounted) {
            await _run(context, cubit.block, 'Blocked');
          }
        }
      case _MenuAction.mute:
        final cubit = _cubitFor(context);
        if (cubit.state.relationship.muting) {
          await _run(context, cubit.unmute, 'Unmuted');
        } else {
          await _run(context, cubit.mute, 'Muted');
        }
    }
  }

  Future<void> _run(
    BuildContext context,
    Future<void> Function() action,
    String done,
  ) async {
    final cubit = _cubit!;
    final messenger = ScaffoldMessenger.of(context);
    // Captured now: the card may be disposed while the request is in flight.
    final onChanged = widget.onRelationshipChanged;
    final handle = widget.post.author.handle;
    await action();
    final error = cubit.state.error;
    // The snackbar only makes sense while the card is still on screen; the
    // callback fires either way because the server applied the change.
    void say(String text) {
      if (!mounted) return;
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(text)));
    }

    if (error != null) {
      say(relationshipErrorMessage(error));
      return;
    }
    say('$done @$handle.');
    onChanged?.call(cubit.state.relationship);
  }

  Future<void> _delete(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
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
    if (confirmed != true) return;
    try {
      await widget.onDelete!(widget.post.postId);
    } catch (_) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text("Couldn't delete the post. Please try again."),
          ),
        );
    }
  }
}
