import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../core/feature_flags/feature_flags.dart';
import '../../../core/network/app_exception.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_error_view.dart';
import '../../../gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import '../../../gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import '../../../shared/widgets/app_avatar.dart';
import '../../../shared/widgets/post_card.dart';
import '../../graph/domain/graph_feature_flag.dart';
import '../../onboarding/presentation/bloc/onboarding_bloc.dart';
import '../data/posts_repository.dart';
import 'bloc/composer_cubit.dart';
import 'bloc/thread_cubit.dart';
import 'composer_screen.dart';
import 'post_detail_screen.dart';
import 'post_error_messages.dart';

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
          create: (context) => ComposerCubit(
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
        BlocListener<ComposerCubit, ComposerState>(
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
                    ThreadStatus.deleted => const _ThreadSkeleton(),
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

/// Placeholder rows in the shape of a post while the first page loads.
class _ThreadSkeleton extends StatelessWidget {
  const _ThreadSkeleton();

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.surfaceContainerHighest;
    Widget bar(double widthFactor, double height) => FractionallySizedBox(
      widthFactor: widthFactor,
      alignment: AlignmentDirectional.centerStart,
      child: Container(
        height: height,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(AppRadius.sm),
        ),
      ),
    );
    return Semantics(
      label: 'Loading conversation',
      liveRegion: true,
      excludeSemantics: true,
      child: Column(
        children: [
          for (var i = 0; i < 3; i++)
            Padding(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  CircleAvatar(
                    radius: AppSpacing.md + 4,
                    backgroundColor: color,
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Column(
                      children: [
                        bar(0.4, AppSpacing.md),
                        const SizedBox(height: AppSpacing.sm),
                        bar(1, AppSpacing.md),
                        const SizedBox(height: AppSpacing.sm),
                        bar(0.7, AppSpacing.md),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ],
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
            if (n.metrics.extentAfter < 400) cubit.loadMore();
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
                      PostCard(
                        view: focal,
                        showFullImages: true,
                        viewerUserId: viewerUserId,
                        graphActionsEnabled: graphEnabled,
                        onDelete: cubit.deletePost,
                        onRelationshipChanged: onRelationship,
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
        InkWell(
          onTap: () => context.push(AppRouter.postPath(view.post.postId)),
          child: PostCard(
            view: view,
            viewerUserId: viewerUserId,
            graphActionsEnabled: graphEnabled,
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
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Column(
      children: [
        Semantics(
          container: true,
          label: 'This post is unavailable',
          excludeSemantics: true,
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: Border.all(color: theme.dividerColor),
                borderRadius: BorderRadius.circular(AppRadius.md),
              ),
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.md),
                child: Row(
                  children: [
                    Icon(
                      Icons.speaker_notes_off_outlined,
                      size: AppIconSize.lg,
                      color: muted,
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Text(
                        'This post is unavailable',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: muted,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        const Divider(height: 1),
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
              onPressed: cubit.loadMore,
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
      page = Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          children: [
            Icon(
              Icons.chat_bubble_outline,
              size: AppIconSize.lg,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: AppSpacing.sm),
            Text('No replies yet', style: theme.textTheme.titleMedium),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Start the conversation below.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    } else {
      page = const SizedBox.shrink();
    }
    return Column(
      children: [
        BlocBuilder<ComposerCubit, ComposerState>(
          buildWhen: (a, b) => a.isSubmitting != b.isSubmitting,
          builder: (context, composer) => composer.isSubmitting
              ? _PendingReply(text: composer.draft.text)
              : const SizedBox.shrink(),
        ),
        page,
      ],
    );
  }
}

/// The optimistic row for a reply being sent (rolled back by simply
/// disappearing when it fails; the text stays in the composer).
class _PendingReply extends StatelessWidget {
  const _PendingReply({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Semantics(
      label: 'Sending your reply: $text',
      liveRegion: true,
      excludeSemantics: true,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(
                  width: AppSpacing.minTapTarget,
                  child: Center(child: AppAvatar(url: '')),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        text,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          color: muted,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      Text(
                        'Sending…',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: muted,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
        ],
      ),
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
                        minimumSize: const Size(72, AppSpacing.minTapTarget),
                      ),
                      onPressed: state.canSubmit ? cubit.submit : null,
                      child: state.isSubmitting
                          ? const SizedBox(
                              width: AppIconSize.md,
                              height: AppIconSize.md,
                              child: CircularProgressIndicator(strokeWidth: 2),
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
                      CharacterCounter(draft: state.draft),
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
