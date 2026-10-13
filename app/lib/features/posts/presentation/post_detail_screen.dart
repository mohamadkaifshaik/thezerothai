import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../core/feature_flags/feature_flags.dart';
import '../../../core/network/app_exception.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_error_view.dart';
import '../../../shared/widgets/blocked_post_gate.dart';
import '../../../shared/widgets/post_card.dart';
import '../../graph/domain/graph_feature_flag.dart';
import '../../onboarding/presentation/bloc/onboarding_bloc.dart';
import '../data/posts_repository.dart';
import '../domain/posts_feature_flag.dart';
import 'bloc/post_detail_cubit.dart';
import 'thread_screen.dart';
import 'widgets/post_unavailable_view.dart';

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
    // FEATURE_REPLIES on: the conversation (GetThread). Off: the plain post
    // (GetPost) with zero thread RPCs; a server FEATURE_DISABLED degrades to
    // the same plain view.
    if (isFeatureEnabled(context, kPostsSubFeatureReplies)) {
      return ThreadScreen(postId: postId, fallbackBuilder: _plainPost);
    }
    return _plainPost(context);
  }

  Widget _plainPost(BuildContext context) {
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
            PostDetailStatus.notFound => PostUnavailableView(
              onHome: () => context.go(AppRouter.homePath),
            ),
            PostDetailStatus.error => AppErrorView(
              error: state.error!,
              onRetry: cubit.load,
            ),
            PostDetailStatus.ready => _ReadyPost(
              state: state,
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
  const _ReadyPost({required this.state, required this.onRelationshipChanged});

  final PostDetailState state;
  final VoidCallback onRelationshipChanged;

  @override
  Widget build(BuildContext context) {
    final view = state.view!;
    final graphEnabled = isFeatureEnabled(context, kFeatureGraph);
    final author = view.post.author;
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
              child: BlockedPostGate(
                authorId: author.userId,
                handle: author.handle,
                graphEnabled: graphEnabled,
                child: PostCard(
                  view: view,
                  showFullImages: true,
                  viewerUserId: viewerUserId,
                  graphActionsEnabled: graphEnabled,
                  onDelete: (_) => context.read<PostDetailCubit>().deletePost(),
                  onRelationshipChanged: (_) => onRelationshipChanged(),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
