import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../core/feature_flags/feature_flags.dart';
import '../../../core/network/app_exception.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_error_view.dart';
import '../../../shared/widgets/post_card.dart';
import '../../graph/data/graph_repository.dart';
import '../../graph/domain/graph_feature_flag.dart';
import '../../onboarding/presentation/bloc/onboarding_bloc.dart';
import '../data/posts_repository.dart';
import '../domain/posts_feature_flag.dart';
import 'bloc/post_detail_cubit.dart';

/// `/post/:id` (T18): one post via `GetPost`. A missing, deleted or hidden
/// post shows "This post isn't available" with no retry; a post of an author
/// the viewer blocks sits behind a "You blocked @x - Show post" banner
/// (ADR-0010 D6, from the local relationship cache).
class PostDetailScreen extends StatelessWidget {
  const PostDetailScreen({super.key, required this.postId});

  final String postId;

  @override
  Widget build(BuildContext context) {
    if (!isFeatureEnabled(context, kFeaturePosts)) {
      return const _Frame(
        child: AppErrorView(
          error: FeatureDisabledException('Posts are not available.'),
        ),
      );
    }
    return BlocProvider<PostDetailCubit>(
      key: ValueKey('post-detail-$postId'),
      create: (context) => PostDetailCubit(
        postsRepository: context.read<PostsRepository>(),
        postId: postId,
      )..load(),
      child: const _PostDetailView(),
    );
  }
}

class _Frame extends StatelessWidget {
  const _Frame({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Post')),
      body: SafeArea(child: child),
    );
  }
}

class _PostDetailView extends StatefulWidget {
  const _PostDetailView();

  @override
  State<_PostDetailView> createState() => _PostDetailViewState();
}

class _PostDetailViewState extends State<_PostDetailView> {
  bool _showBlocked = false;

  void _leave(BuildContext context) {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(AppRouter.homePath);
    }
  }

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<PostDetailCubit, PostDetailState>(
      listenWhen: (before, after) => after.status == PostDetailStatus.deleted,
      listener: (context, state) => _leave(context),
      builder: (context, state) {
        final cubit = context.read<PostDetailCubit>();
        return _Frame(
          child: switch (state.status) {
            PostDetailStatus.loading || PostDetailStatus.deleted =>
              const Center(child: CircularProgressIndicator()),
            PostDetailStatus.notFound => _Unavailable(
              onHome: () => context.go(AppRouter.homePath),
            ),
            PostDetailStatus.error => AppErrorView(
              error: state.error!,
              onRetry: cubit.load,
            ),
            PostDetailStatus.ready => _ReadyPost(
              state: state,
              showBlocked: _showBlocked,
              onShowBlocked: () => setState(() => _showBlocked = true),
              // The request can outlive this screen.
              onRelationshipChanged: () {
                if (mounted) setState(() {});
              },
            ),
          },
        );
      },
    );
  }
}

class _ReadyPost extends StatelessWidget {
  const _ReadyPost({
    required this.state,
    required this.showBlocked,
    required this.onShowBlocked,
    required this.onRelationshipChanged,
  });

  final PostDetailState state;
  final bool showBlocked;
  final VoidCallback onShowBlocked;
  final VoidCallback onRelationshipChanged;

  @override
  Widget build(BuildContext context) {
    final view = state.view!;
    final graphEnabled = isFeatureEnabled(context, kFeatureGraph);
    final author = view.post.author;
    final blocked =
        graphEnabled &&
        (context.read<GraphRepository>().cached(author.userId)?.blocking ??
            false);
    final viewerUserId = context.read<OnboardingBloc>().state.profile?.userId;

    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= AppBreakpoints.mobile;
        return SingleChildScrollView(
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: isWide ? AppBreakpoints.mobile : double.infinity,
              ),
              child: blocked && !showBlocked
                  ? _BlockedPostBanner(
                      handle: author.handle,
                      onShow: onShowBlocked,
                    )
                  : PostCard(
                      view: view,
                      showFullImages: true,
                      viewerUserId: viewerUserId,
                      graphActionsEnabled: graphEnabled,
                      onDelete: (_) =>
                          context.read<PostDetailCubit>().deletePost(),
                      onRelationshipChanged: (_) => onRelationshipChanged(),
                    ),
            ),
          ),
        );
      },
    );
  }
}

class _BlockedPostBanner extends StatelessWidget {
  const _BlockedPostBanner({required this.handle, required this.onShow});

  final String handle;
  final VoidCallback onShow;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'You blocked @$handle ·',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
          TextButton(
            style: TextButton.styleFrom(
              minimumSize: const Size(0, AppSpacing.minTapTarget),
            ),
            onPressed: onShow,
            child: const Text('Show post'),
          ),
        ],
      ),
    );
  }
}

/// The final NOT_FOUND state: nothing to retry, and the same words for
/// missing, deleted and hidden (ADR-0010 D6).
class _Unavailable extends StatelessWidget {
  const _Unavailable({required this.onHome});

  final VoidCallback onHome;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      liveRegion: true,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.speaker_notes_off_outlined,
                size: 40,
                color: theme.colorScheme.error,
              ),
              const SizedBox(height: AppSpacing.md),
              Text(
                "This post isn't available",
                style: theme.textTheme.titleMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: AppSpacing.md),
              FilledButton.tonal(
                onPressed: onHome,
                child: const Text('Go to Home'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
