import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../core/feature_flags/feature_flags.dart';
import '../../../core/network/app_exception.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_error_view.dart';
import '../../../core/widgets/scroll_constants.dart';
import '../../../gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import '../../../gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import '../../../shared/widgets/app_empty_view.dart';
import '../../../shared/widgets/blocked_post_gate.dart';
import '../../../shared/widgets/character_counter.dart';
import '../../../shared/widgets/pending_post_row.dart';
import '../../../shared/widgets/post_card.dart';
import '../../../shared/widgets/post_list_skeleton.dart';
import '../../../shared/widgets/unavailable_post_box.dart';
import '../../engagement/domain/engagement_feature_flag.dart';
import '../../graph/domain/graph_feature_flag.dart';
import '../../moderation/domain/reports_feature_flag.dart';
import '../../onboarding/presentation/bloc/onboarding_bloc.dart';
import '../data/posts_repository.dart';
import '../domain/viewer_author_snapshot.dart';
import 'bloc/composer_cubit.dart';
import 'bloc/thread_cubit.dart';
import 'composer_screen.dart';
import 'post_error_messages.dart';
import 'widgets/draft_problem_hint.dart';
import 'widgets/post_unavailable_view.dart';

/// Width of the reply button: wide enough that "Reply" and the sending
/// spinner do not make the field jump.
const double _kReplyButtonWidth = AppSpacing.xxl + AppSpacing.lg;

/// `/post/:id` with FEATURE_REPLIES on: the post, its parent/root context
/// (or "This post is unavailable" tombstones), its replies and an inline
/// reply composer (replies-and-threads T7).
///
/// - One `GetThread` per open (default page of 10), more replies on demand
///   (scroll near the end or "Show more replies"), pull-to-refresh; no
///   polling.
/// - FEATURE_DISABLED from the server (flag turned off under us) renders
///   [fallbackBuilder], the plain post view, instead of an error.
/// - A new reply is appended from the CreatePost response (no refetch);
///   a failed one keeps its text and shows a snackbar.
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
        BlocProvider<ComposerCubit>(
          create: (context) => ComposerCubit.reply(
            postsRepository: context.read<PostsRepository>(),
            replyToPostId: postId,
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

  void _leave(BuildContext context) {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(AppRouter.homePath);
    }
  }

  @override
  Widget build(BuildContext context) {
    return MultiBlocListener(
      listeners: [
        BlocListener<ThreadCubit, ThreadState>(
          listenWhen: (before, after) =>
              after.status == ThreadStatus.deleted &&
              before.status != ThreadStatus.deleted,
          listener: (context, state) => _leave(context),
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
            ScaffoldMessenger.of(context)
              ..hideCurrentSnackBar()
              ..showSnackBar(SnackBar(content: Text(replyErrorMessage(error))));
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
          return Scaffold(
            appBar: AppBar(title: const Text('Post')),
            body: SafeArea(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: AppBreakpoints.mobile,
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

class _ThreadBody extends StatelessWidget {
  const _ThreadBody();

  @override
  Widget build(BuildContext context) {
    final canReply = context.select(
      (ThreadCubit c) => !c.state.repliesDisabled,
    );
    return Column(
      children: [
        const Expanded(child: _ThreadList()),
        if (canReply) const _ReplyComposer(),
      ],
    );
  }
}

class _ThreadList extends StatelessWidget {
  const _ThreadList();

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<ThreadCubit>();
    final graphEnabled = isFeatureEnabled(context, kFeatureGraph);
    final reportsEnabled = isFeatureEnabled(context, kFeatureReports);
    final engagementEnabled = isFeatureEnabled(context, kFeatureEngagement);
    final viewerUserId = context.read<OnboardingBloc>().state.profile?.userId;
    return BlocBuilder<ThreadCubit, ThreadState>(
      builder: (context, state) {
        final focal = state.focal;
        if (focal == null) return const SizedBox.shrink();
        final replies = state.visibleReplies;
        void onRelationship(graph.Relationship r) =>
            cubit.setAuthorHidden(r.userId, hidden: r.blocking || r.muting);

        // Root above parent. A first-level reply has the same post as parent
        // and root: it is shown once.
        final isReply = focal.post.replyToPostId.isNotEmpty;
        final sameContext =
            isReply && focal.post.replyToPostId == focal.post.conversationId;
        Widget slot(pb.PostView? view, bool unavailable, String key) =>
            view != null
            ? _ContextPost(
                key: ValueKey('context-${view.post.postId}'),
                view: view,
                viewerUserId: viewerUserId,
                graphEnabled: graphEnabled,
              )
            : (unavailable
                  ? _Tombstone(key: ValueKey(key))
                  : const SizedBox.shrink());
        final contextSlots = <Widget>[
          if (isReply && !sameContext)
            slot(state.root, state.rootUnavailable, 'root-unavailable'),
          if (isReply)
            slot(
              sameContext ? (state.parent ?? state.root) : state.parent,
              state.parentUnavailable || (sameContext && state.rootUnavailable),
              'parent-unavailable',
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
                  child: Column(
                    key: ValueKey('focal-${focal.post.postId}'),
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (focal.post.replyToHandle.isNotEmpty)
                        _ReplyingTo(handle: focal.post.replyToHandle),
                      BlockedPostGate(
                        authorId: focal.post.author.userId,
                        handle: focal.post.author.handle,
                        graphEnabled: graphEnabled,
                        child: PostCard(
                          view: focal,
                          showFullImages: true,
                          viewerUserId: viewerUserId,
                          graphActionsEnabled: graphEnabled,
                          reportsEnabled: reportsEnabled,
                          engagementEnabled: engagementEnabled,
                          // The reply composer is right below.
                          showReply: false,
                          onDelete: cubit.deletePost,
                          onRelationshipChanged: onRelationship,
                        ),
                      ),
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
                    return Column(
                      key: ValueKey('reply-${view.post.postId}'),
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (view.post.replyToPostId != focal.post.postId &&
                            view.post.replyToHandle.isNotEmpty)
                          _ReplyingTo(handle: view.post.replyToHandle),
                        InkWell(
                          onTap: () => context.push(
                            AppRouter.postPath(view.post.postId),
                          ),
                          child: PostCard(
                            view: view,
                            viewerUserId: viewerUserId,
                            graphActionsEnabled: graphEnabled,
                            reportsEnabled: reportsEnabled,
                            engagementEnabled: engagementEnabled,
                            onDelete: cubit.deletePost,
                            onRelationshipChanged: onRelationship,
                          ),
                        ),
                        const Divider(height: 1),
                      ],
                    );
                  },
                ),
                SliverToBoxAdapter(
                  child: _Footer(state: state, empty: replies.isEmpty),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

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

/// Below the replies: the viewer's reply in flight, then the page state
/// (spinner / inline retry / "Show more replies" / empty guidance).
class _Footer extends StatelessWidget {
  const _Footer({required this.state, required this.empty});

  final ThreadState state;
  final bool empty;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cubit = context.read<ThreadCubit>();
    final Widget page;
    if (state.loadingMore) {
      page = const Padding(
        padding: EdgeInsets.all(AppSpacing.md),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    } else if (state.loadMoreError != null) {
      page = Padding(
        padding: const EdgeInsets.all(AppSpacing.sm),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Flexible(
              child: Text(
                "Couldn't load more replies.",
                style: theme.textTheme.bodyMedium,
              ),
            ),
            TextButton(
              style: TextButton.styleFrom(
                minimumSize: const Size(0, AppSpacing.minTapTarget),
              ),
              onPressed: cubit.retryLoadMore,
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    } else if (state.hasMore) {
      // Pages can come back short; the button always makes progress.
      page = Center(
        child: TextButton(
          style: TextButton.styleFrom(
            minimumSize: const Size(0, AppSpacing.minTapTarget),
          ),
          onPressed: cubit.loadMore,
          child: const Text('Show more replies'),
        ),
      );
    } else if (empty) {
      page = const AppEmptyView(
        icon: Icons.chat_bubble_outline,
        title: 'No replies yet',
        subtitle: 'Start the conversation below.',
      );
    } else {
      page = const SizedBox.shrink();
    }
    return Column(
      children: [
        BlocBuilder<ComposerCubit, ComposerState>(
          buildWhen: (a, b) => a.isSubmitting != b.isSubmitting,
          builder: (context, composer) => composer.isSubmitting
              ? Column(
                  children: [
                    PendingPostRow(
                      text: composer.draft.text,
                      author: viewerAuthorSnapshot(
                        context.read<OnboardingBloc>().state.profile,
                      ),
                      // The spinner on the button is the one live
                      // announcement ("Sending reply").
                      semanticsLabel: null,
                    ),
                    const Divider(height: 1),
                  ],
                )
              : const SizedBox.shrink(),
        ),
        page,
      ],
    );
  }
}

/// Inline composer docked under the thread: replies to the open post. The
/// same 280 code-point rules and counter as the main composer.
class _ReplyComposer extends StatefulWidget {
  const _ReplyComposer();

  @override
  State<_ReplyComposer> createState() => _ReplyComposerState();
}

class _ReplyComposerState extends State<_ReplyComposer> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cubit = context.read<ComposerCubit>();
    return BlocConsumer<ComposerCubit, ComposerState>(
      listenWhen: (before, after) =>
          after.status == ComposerStatus.posted &&
          before.status != ComposerStatus.posted,
      listener: (context, state) {
        _controller.clear();
        cubit.textChanged('');
      },
      builder: (context, state) {
        return DecoratedBox(
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            border: Border(top: BorderSide(color: theme.dividerColor)),
          ),
          child: Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(
              AppSpacing.md,
              AppSpacing.sm,
              AppSpacing.sm,
              AppSpacing.sm,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _controller,
                        enabled: !state.isSubmitting,
                        minLines: 1,
                        maxLines: 5,
                        keyboardType: TextInputType.multiline,
                        textCapitalization: TextCapitalization.sentences,
                        inputFormatters: [
                          LengthLimitingTextInputFormatter(kComposerInputCap),
                        ],
                        style: theme.textTheme.bodyLarge,
                        decoration: InputDecoration(
                          hintText: 'Post your reply',
                          hintStyle: theme.textTheme.bodyLarge?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                          filled: false,
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          disabledBorder: InputBorder.none,
                        ),
                        onChanged: cubit.textChanged,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    FilledButton(
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(
                          _kReplyButtonWidth,
                          AppSpacing.minTapTarget,
                        ),
                      ),
                      onPressed: state.canSubmit ? cubit.submit : null,
                      child: state.isSubmitting
                          ? Semantics(
                              label: 'Sending reply',
                              liveRegion: true,
                              child: const SizedBox(
                                width: AppIconSize.md,
                                height: AppIconSize.md,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                            )
                          : const Text('Reply'),
                    ),
                  ],
                ),
                if (state.draft.text.isNotEmpty)
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      DraftProblemHint(problem: state.draft.problem),
                      CharacterCounter(remaining: state.draft.remaining),
                    ],
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
