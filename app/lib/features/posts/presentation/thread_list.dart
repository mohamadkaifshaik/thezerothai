part of 'thread_screen.dart';

class _ThreadBody extends StatefulWidget {
  const _ThreadBody();

  @override
  State<_ThreadBody> createState() => _ThreadBodyState();
}

class _ThreadBodyState extends State<_ThreadBody> {
  // Reply on the open post focuses the composer (X's post page).
  final _replyFocus = FocusNode(debugLabel: 'thread reply');

  @override
  void dispose() {
    _replyFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final canReply = context.select(
      (ThreadCubit c) => !c.state.repliesDisabled,
    );
    // Advisory: only an explicit NOT_ALLOWED disables it.
    final replyBlocked = context.select((ThreadCubit c) {
      final focal = c.state.focal;
      return focal != null && replyKnownNotAllowed(focal);
    });
    // A post in a community: only its members may reply, and the hint says so.
    final blockedHint = context.select((ThreadCubit c) {
      final focal = c.state.focal;
      return focal == null ? kReplyNotAllowedHint : replyNotAllowedHint(focal);
    });
    // The reply entry is the row right under the open post at every width
    // (the PostDetail designs); below the mobile breakpoint it is the compact
    // one: a 36 dp avatar, a plain prompt and a compact Reply.
    final compact = MediaQuery.sizeOf(context).width < AppBreakpoints.mobile;
    final composer = _ReplyComposer(
      focusNode: _replyFocus,
      blocked: replyBlocked,
      blockedHint: blockedHint,
      compact: compact,
    );
    return _ThreadList(
      onReply: canReply ? _replyFocus.requestFocus : null,
      inlineComposer: canReply ? composer : null,
    );
  }
}

class _ThreadList extends StatelessWidget {
  const _ThreadList({this.onReply, this.inlineComposer});

  /// Reply on the open post; null leaves the default (opens the post).
  final VoidCallback? onReply;

  /// The reply composer placed right under the open post (wide screens).
  final Widget? inlineComposer;

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<ThreadCubit>();
    final graphEnabled = isFeatureEnabled(context, kFeatureGraph);
    final reportsEnabled = isFeatureEnabled(context, kFeatureReports);
    final engagementEnabled = isFeatureEnabled(context, kFeatureEngagement);
    final communitiesEnabled = isFeatureEnabled(context, kFeatureCommunities);
    final moderation = context.read<ThreadModerationCubit>();
    final moderationState = context.watch<ThreadModerationCubit>().state;
    final viewerUserId = context.read<OnboardingBloc>().state.profile?.userId;
    return BlocBuilder<ThreadCubit, ThreadState>(
      builder: (context, state) {
        final focal = state.focal;
        if (focal == null) return const SizedBox.shrink();
        // "Remove from Community" on replies: the root carries the
        // label, the role is the server's `viewer_role`; null = no row.
        final community = state.rootCommunity;
        final PostModerationControl? replyModeration =
            communitiesEnabled &&
                community != null &&
                moderationState.canModerate &&
                moderationState.communityId == community.id
            ? PostModerationControl(
                communityId: community.id,
                communityName: community.name,
                repliesOnly: true,
                onHide: (replyId) async {
                  cubit.hideReplyLocally(replyId);
                  final error = await moderation.hide(replyId);
                  if (error != null) {
                    cubit.showReplyAgain(replyId);
                    throw error;
                  }
                },
                onRestore: (replyId) async {
                  final error = await moderation.restore(replyId);
                  if (error != null) throw error;
                  cubit.showReplyAgain(replyId);
                },
              )
            : null;
        // A self-thread (PostThread mock): the open post and the author's
        // replies that continue it are one chain of equal cards joined by
        // the rail; the reply entry and everyone else's replies follow it.
        final selfThread = state.selfThreadLength > 0;
        final tail = state.selfThreadTail;
        final tailIds = {for (final v in tail) v.post.postId};
        final replies = tail.isEmpty
            ? state.visibleReplies
            : [
                for (final r in state.visibleReplies)
                  if (!tailIds.contains(r.post.postId)) r,
              ];
        void onRelationship(graph.Relationship r) =>
            cubit.setAuthorHidden(r.userId, hidden: r.blocking || r.muting);
        Future<void> replyTo(pb.PostView view) async {
          final created = await context.push<pb.PostView>(
            AppRouter.composeReplyPath(view.post.postId),
          );
          if (created != null && !cubit.isClosed) {
            cubit.replyPosted(created);
          }
        }

        // Root above parent. A first-level reply has the same post as parent
        // and root: it is shown once.
        final isReply = focal.post.replyToPostId.isNotEmpty;
        final sameContext =
            isReply && focal.post.replyToPostId == focal.post.conversationId;
        Widget slot(
          pb.PostView? view,
          bool unavailable,
          String key, {
          bool before = false,
          bool after = false,
        }) => view != null
            ? _ContextPost(
                key: ValueKey('context-${view.post.postId}'),
                view: view,
                viewerUserId: viewerUserId,
                graphEnabled: graphEnabled,
                connectBefore: before,
                connectAfter: after,
              )
            : (unavailable
                  ? _Tombstone(key: ValueKey(key))
                  : const SizedBox.shrink());
        final contextSlots = <Widget>[
          if (isReply && !sameContext)
            slot(
              state.root,
              state.rootUnavailable,
              'root-unavailable',
              after:
                  state.root != null &&
                  state.parent?.post.replyToPostId == state.root!.post.postId,
            ),
          if (isReply)
            slot(
              sameContext ? (state.parent ?? state.root) : state.parent,
              state.parentUnavailable || (sameContext && state.rootUnavailable),
              'parent-unavailable',
              before:
                  !sameContext &&
                  state.root != null &&
                  state.parent?.post.replyToPostId == state.root!.post.postId,
              after:
                  (state.parent ?? (sameContext ? state.root : null))
                      ?.post
                      .postId ==
                  focal.post.replyToPostId,
            ),
        ];

        return NotificationListener<ScrollNotification>(
          onNotification: (n) {
            // Only this list's own scrolling (not nested scrollables, e.g. a
            // text field), prefetching like the feed does.
            if (n.depth == 0 &&
                n.metrics.maxScrollExtent > 0 &&
                n.metrics.pixels >=
                    kPrefetchFraction * n.metrics.maxScrollExtent) {
              cubit.loadMore();
            }
            return false;
          },
          child: RefreshIndicator(
            onRefresh: cubit.refresh,
            child: CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                for (final widget in contextSlots)
                  SliverToBoxAdapter(child: widget),
                SliverToBoxAdapter(
                  // X's post page: the open post on the plain background,
                  // with no heading between it and its replies.
                  child: Column(
                    key: ValueKey('focal-${focal.post.postId}'),
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (focal.post.replyToHandle.isNotEmpty &&
                          state.parent == null &&
                          state.root == null)
                        _ReplyingTo(handle: focal.post.replyToHandle),
                      BlockedPostGate(
                        authorId: focal.post.author.userId,
                        handle: focal.post.author.handle,
                        graphEnabled: graphEnabled,
                        child: _OpenPostHighlight(
                          // In a self-thread the open post is one of the
                          // chain's cards, told apart by a light tint.
                          on: selfThread,
                          child: ConversationRow(
                            connectBefore:
                                isReply &&
                                (state.parent ??
                                            (sameContext ? state.root : null))
                                        ?.post
                                        .postId ==
                                    focal.post.replyToPostId,
                            connectAfter: tail.isNotEmpty,
                            child: PostCard(
                              indentBody: true,
                              view: focal,
                              focal: !selfThread,
                              viewerUserId: viewerUserId,
                              graphActionsEnabled: graphEnabled,
                              reportsEnabled: reportsEnabled,
                              engagementEnabled: engagementEnabled,
                              // Reply focuses the composer; with replies
                              // closed there is no composer and no Reply.
                              showReply: onReply != null,
                              onReply: onReply,
                              onDelete: cubit.deletePost,
                              onRelationshipChanged: onRelationship,
                            ),
                          ),
                        ),
                      ),
                      for (final (i, view) in tail.indexed)
                        InkWell(
                          key: ValueKey('chain-${view.post.postId}'),
                          onTap: () => context.push(
                            AppRouter.postPath(view.post.postId),
                          ),
                          child: ConversationRow(
                            connectBefore: true,
                            connectAfter: i + 1 < tail.length,
                            child: PostCard(
                              indentBody: true,
                              view: view,
                              viewerUserId: viewerUserId,
                              graphActionsEnabled: graphEnabled,
                              reportsEnabled: reportsEnabled,
                              engagementEnabled: engagementEnabled,
                              moderationControl: replyModeration,
                              onDelete: cubit.deletePost,
                              onRelationshipChanged: onRelationship,
                              onReply: () => replyTo(view),
                            ),
                          ),
                        ),
                      if (inlineComposer case final composer?)
                        composer
                      else
                        const Divider(height: 1),
                    ],
                  ),
                ),
                SliverList.builder(
                  itemCount: replies.length,
                  findChildIndexCallback: (key) {
                    if (key is! ValueKey<String>) return null;
                    final i = replies.indexWhere(
                      (r) => 'reply-${r.post.postId}' == key.value,
                    );
                    return i < 0 ? null : i;
                  },
                  itemBuilder: (context, index) {
                    final view = replies[index];
                    final before =
                        index > 0 &&
                        view.post.replyToPostId ==
                            replies[index - 1].post.postId;
                    final after =
                        index + 1 < replies.length &&
                        replies[index + 1].post.replyToPostId ==
                            view.post.postId;
                    return Column(
                      key: ValueKey('reply-${view.post.postId}'),
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (!before &&
                            view.post.replyToPostId != focal.post.postId &&
                            view.post.replyToHandle.isNotEmpty)
                          _ReplyingTo(
                            handle: view.post.replyToHandle,
                            indented: after,
                          ),
                        InkWell(
                          onTap: () => context.push(
                            AppRouter.postPath(view.post.postId),
                          ),
                          child: ConversationRow(
                            connectBefore: before,
                            connectAfter: after,
                            child: PostCard(
                              indentBody: before || after,
                              view: view,
                              viewerUserId: viewerUserId,
                              graphActionsEnabled: graphEnabled,
                              reportsEnabled: reportsEnabled,
                              engagementEnabled: engagementEnabled,
                              moderationControl: replyModeration,
                              onDelete: cubit.deletePost,
                              onRelationshipChanged: onRelationship,
                              onReply: () => replyTo(view),
                            ),
                          ),
                        ),
                        if (!after) const Divider(height: 1),
                      ],
                    );
                  },
                ),
                SliverToBoxAdapter(
                  child: _Footer(
                    state: state,
                    // The chain's own replies are the conversation so far.
                    empty: replies.isEmpty && tail.isEmpty,
                  ),
                ),
                const ShellBottomInsetSliver(),
              ],
            ),
          ),
        );
      },
    );
  }
}
