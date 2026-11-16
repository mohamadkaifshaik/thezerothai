part of 'thread_screen.dart';

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
              // The floating bar overlays the page: the scroll view runs
              // behind it and ends with the bar's inset.
              bottom: false,
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

