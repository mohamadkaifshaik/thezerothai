part of 'thread_screen.dart';

/// A parent/root shown above the focal post; tap opens its own thread.
class _ContextPost extends StatelessWidget {
  const _ContextPost({
    super.key,
    required this.view,
    required this.viewerUserId,
    required this.graphEnabled,
    this.connectBefore = false,
    this.connectAfter = false,
  });

  final pb.PostView view;
  final String? viewerUserId;
  final bool graphEnabled;
  final bool connectBefore;
  final bool connectAfter;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        BlockedPostGate(
          authorId: view.post.author.userId,
          handle: view.post.author.handle,
          graphEnabled: graphEnabled,
          child: InkWell(
            onTap: () => context.push(AppRouter.postPath(view.post.postId)),
            child: ConversationRow(
              connectBefore: connectBefore,
              connectAfter: connectAfter,
              child: PostCard(
                view: view,
                viewerUserId: viewerUserId,
                graphActionsEnabled: graphEnabled,
                reportsEnabled: isFeatureEnabled(context, kFeatureReports),
                engagementEnabled: isFeatureEnabled(
                  context,
                  kFeatureEngagement,
                ),
              ),
            ),
          ),
        ),
        if (!connectAfter) const Divider(height: 1),
      ],
    );
  }
}

/// Stands in for a parent/root that was deleted or cannot be shown; never
/// says which (the server does not distinguish them either).
class _Tombstone extends StatelessWidget {
  const _Tombstone({super.key});

  @override
  Widget build(BuildContext context) {
    return const Column(
      children: [
        Padding(
          padding: EdgeInsets.all(AppSpacing.md),
          child: UnavailablePostBox(),
        ),
        Divider(height: 1),
      ],
    );
  }
}

/// "Replying to @handle" above a post, aligned with the content column.
class _ReplyingTo extends StatelessWidget {
  const _ReplyingTo({required this.handle});

  final String handle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final gutter = postCardGutterOf(context);
    return Padding(
      // Where the post body starts (the card's gutter, avatar column and gap).
      padding: EdgeInsetsDirectional.fromSTEB(
        gutter + kPostBodyStart,
        AppSpacing.sm,
        gutter,
        0,
      ),
      child: Text(
        'Replying to @$handle',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// The open post among a self-thread's equal cards: the highlighted-row
/// tint (as an unread notification), a hint only; the post's own semantics
/// are unchanged. [on] false draws [child] alone.
class _OpenPostHighlight extends StatelessWidget {
  const _OpenPostHighlight({required this.on, required this.child});

  final bool on;
  final Widget child;

  @override
  Widget build(BuildContext context) => on
      ? ColoredBox(
          key: const ValueKey('open-post-highlight'),
          color: Theme.of(context).colorScheme.primary
              .withValues(alpha: AppOpacity.rowTint),
          child: child,
        )
      : child;
}
