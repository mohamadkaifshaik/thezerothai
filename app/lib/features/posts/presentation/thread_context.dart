part of 'thread_screen.dart';

/// A parent/root shown above the focal post; tap opens its own thread.
class _ContextPost extends StatelessWidget {
  const _ContextPost({
    super.key,
    required this.view,
    required this.viewerUserId,
    required this.graphEnabled,
  });

  final pb.PostView view;
  final String? viewerUserId;
  final bool graphEnabled;

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
            child: PostCard(
              view: view,
              viewerUserId: viewerUserId,
              graphActionsEnabled: graphEnabled,
              reportsEnabled: isFeatureEnabled(context, kFeatureReports),
              engagementEnabled: isFeatureEnabled(context, kFeatureEngagement),
            ),
          ),
        ),
        const Divider(height: 1),
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
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(
        AppSpacing.md + AppSpacing.minTapTarget + AppSpacing.sm,
        AppSpacing.sm,
        AppSpacing.md,
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
