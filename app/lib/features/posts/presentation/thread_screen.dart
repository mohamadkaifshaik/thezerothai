import 'post_subscription_policy.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../core/feature_flags/feature_flags.dart';
import '../../../core/network/app_exception.dart';
import '../../../core/router/app_router.dart';
import '../../../core/storage/app_database.dart';
import '../../../core/telemetry/usage_reporter.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_error_view.dart';
import '../../../core/widgets/app_top_bar.dart';
import '../../../core/widgets/scroll_constants.dart';
import '../../../core/widgets/shell_geometry.dart';
import '../../../gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import '../../../gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import '../../../shared/widgets/primitives/app_avatar.dart';
import '../../../shared/widgets/primitives/app_empty_view.dart';
import '../../../shared/widgets/primitives/app_pill_button.dart';
import '../../../shared/widgets/post/blocked_post_gate.dart';
import '../../../shared/widgets/post/conversation_row.dart';
import '../../../shared/widgets/primitives/character_counter.dart';
import '../../../shared/widgets/post/pending_post_row.dart';
import '../../../shared/widgets/post/post_card.dart';
import '../../../shared/widgets/post/post_moderation_control.dart';
import '../../../shared/widgets/post/post_list_skeleton.dart';
import '../../../shared/widgets/post/unavailable_post_box.dart';
import '../../communities/data/communities_repository.dart';
import '../../communities/domain/communities_feature_flag.dart';
import '../../engagement/domain/engagement_feature_flag.dart';
import '../../graph/domain/graph_feature_flag.dart';
import '../../moderation/domain/reports_feature_flag.dart';
import '../../onboarding/presentation/bloc/onboarding_bloc.dart';
import '../data/posts_repository.dart';
import '../domain/reply_audience.dart';
import '../domain/viewer_author_snapshot.dart';
import 'bloc/composer_cubit.dart';
import 'bloc/thread_cubit.dart';
import 'bloc/thread_moderation_cubit.dart';
import 'composer_screen.dart';
import 'post_error_messages.dart';
import 'widgets/draft_problem_hint.dart';
import 'widgets/post_unavailable_view.dart';
import '../../../core/widgets/shell_bottom_inset_sliver.dart';

part 'thread_context.dart';
part 'thread_footer.dart';

/// `/post/:id` with FEATURE_REPLIES on: the post, its parent/root context
/// (or "This post is unavailable" tombstones), its replies and an inline
/// reply composer (replies-and-threads).
///
/// - One `GetThread` per open (default page of 10), more replies on demand
///   (scroll near the end or "Show more replies"), pull-to-refresh; no
///   polling.
/// - FEATURE_DISABLED from the server (flag turned off under us) renders
///   [fallbackBuilder], the plain post view, instead of an error.
/// - A new reply is appended from the CreatePost response (no refetch);
///   a failed one keeps its text and shows a snackbar.
/// The communities repository while `communities` is on, else null:
/// a thread never reads it for a caller who cannot see Communities.
CommunitiesRepository? _communitiesRepositoryIfOn(BuildContext context) {
  if (!featureEnabledSnapshot(context, kFeatureCommunities)) return null;
  try {
    return context.read<CommunitiesRepository>();
  } on ProviderNotFoundException {
    return null;
  }
}

/// Back from a post page: the previous page, or Home when there is none (a
/// deep link).
void leavePostScreen(BuildContext context) {
  if (context.canPop()) {
    context.pop();
  } else {
    context.go(AppRouter.homePath);
  }
}

class ThreadScreen extends StatelessWidget {
  const ThreadScreen({
    super.key,
    required this.postId,
    required this.fallbackBuilder,
  });

  final String postId;

  /// The pre-replies post screen, used when replies are unavailable.
  final WidgetBuilder fallbackBuilder;

  @override
  Widget build(BuildContext context) {
    return MultiBlocProvider(
      key: ValueKey('thread-$postId'),
      providers: [
        BlocProvider<ThreadCubit>(
          create: (context) => ThreadCubit(
            postsRepository: context.read<PostsRepository>(),
            postId: postId,
          )..load(),
        ),
        BlocProvider<ThreadModerationCubit>(
          create: (context) => ThreadModerationCubit(
            communities: _communitiesRepositoryIfOn(context),
          ),
        ),
        BlocProvider<ComposerCubit>(
          create: (context) => ComposerCubit.reply(
            postTextLimit: () => subscriptionPostLimit(context),
            postPolicyChanges: subscriptionPostChanges(context),
            postsRepository: context.read<PostsRepository>(),
            replyToPostId: postId,
            usage: UsageScope.of(context),
            // Bound to the session the thread was opened in: after a
            // sign-out or an account switch the reply bar empties and sends
            // nothing (the thread page itself stays).
            sessionEpoch: context.read<AppDatabase?>()?.sessionEpoch,
          ),
        ),
      ],
      child: _ThreadView(fallbackBuilder: fallbackBuilder),
    );
  }
}

class _ThreadView extends StatelessWidget {
  const _ThreadView({required this.fallbackBuilder});

  final WidgetBuilder fallbackBuilder;

  @override
  Widget build(BuildContext context) {
    return MultiBlocListener(
      listeners: [
        BlocListener<ThreadCubit, ThreadState>(
          listenWhen: (before, after) =>
              before.rootCommunity?.id != after.rootCommunity?.id,
          listener: (context, state) {
            final id = state.rootCommunity?.id;
            if (id != null) {
              unawaited(context.read<ThreadModerationCubit>().resolve(id));
            }
          },
        ),
        BlocListener<ThreadCubit, ThreadState>(
          listenWhen: (before, after) =>
              after.status == ThreadStatus.deleted &&
              before.status != ThreadStatus.deleted,
          listener: (context, state) => leavePostScreen(context),
        ),
        BlocListener<ThreadCubit, ThreadState>(
          listenWhen: (before, after) =>
              after.refreshError != null &&
              after.refreshError != before.refreshError,
          listener: (context, state) {
            final error = state.refreshError!;
            ScaffoldMessenger.of(context)
              ..hideCurrentSnackBar()
              ..showSnackBar(
                SnackBar(content: Text(threadRefreshErrorMessage(error))),
              );
            context.read<ThreadCubit>().refreshErrorShown();
          },
        ),
        BlocListener<ComposerCubit, ComposerState>(
          listenWhen: (before, after) =>
              (after.status == ComposerStatus.posted &&
                  before.status != ComposerStatus.posted) ||
              (after.error != null && after.error != before.error),
          listener: (context, state) {
            final thread = context.read<ThreadCubit>();
            final created = state.created;
            if (state.status == ComposerStatus.posted && created != null) {
              thread.replyPosted(created);
              // Cleared here, where it is always mounted, so a sent reply
              // never comes back as a draft (the field clears itself).
              context.read<ComposerCubit>().textChanged('');
              return;
            }
            final error = state.error;
            if (error == null) return;
            if (error is FeatureDisabledException) {
              thread.repliesBecameUnavailable();
            }
            if (error is NotFoundException) {
              // The post vanished under us: reload to the unavailable view.
              thread.load();
            }
            final focal = thread.state.focal;
            final communityName = focal != null && focal.post.hasCommunity()
                ? focal.post.community.name
                : '';
            ScaffoldMessenger.of(context)
              ..hideCurrentSnackBar()
              ..showSnackBar(
                SnackBar(
                  content: Text(
                    replyErrorMessage(error, communityName: communityName),
                  ),
                ),
              );
            context.read<ComposerCubit>().errorShown();
          },
        ),
      ],
      child: BlocBuilder<ThreadCubit, ThreadState>(
        buildWhen: (before, after) => before.status != after.status,
        builder: (context, state) {
          if (state.status == ThreadStatus.disabled) {
            return fallbackBuilder(context);
          }
          // The header lists the posts of a self-thread; it follows the
          // loaded chain, not only the status.
          final chain = context.select(
            (ThreadCubit c) => c.state.selfThreadLength,
          );
          return Scaffold(
            appBar: AppTopBar.of(
              context,
              title: 'Post',
              subtitle: chain > 0 ? 'Thread · $chain posts' : null,
              onBack: () => leavePostScreen(context),
            ),
            body: SafeArea(
              child: Center(
                child: ConstrainedBox(
                  // 680 on the tablet layout (the readable column), else
                  // 600.
                  constraints: BoxConstraints(
                    maxWidth: ShellGeometry.readableMaxWidth(context),
                  ),
                  child: switch (state.status) {
                    ThreadStatus.loading ||
                    ThreadStatus.deleted => const PostListSkeleton(
                      rows: 3,
                      semanticsLabel: 'Loading conversation',
                    ),
                    ThreadStatus.notFound => PostUnavailableView(
                      onHome: () => context.go(AppRouter.homePath),
                    ),
                    ThreadStatus.error => AppErrorView(
                      error: state.error!,
                      onRetry: context.read<ThreadCubit>().load,
                    ),
                    _ => const _ThreadBody(),
                  },
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

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
                          _ReplyingTo(handle: view.post.replyToHandle),
                        InkWell(
                          onTap: () => context.push(
                            AppRouter.postPath(view.post.postId),
                          ),
                          child: ConversationRow(
                            connectBefore: before,
                            connectAfter: after,
                            child: PostCard(
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
