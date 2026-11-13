import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../core/widgets/shell_bottom_inset_sliver.dart';
import '../../../core/feature_flags/feature_flags.dart';
import '../../../core/network/app_exception.dart';
import '../../../core/router/app_router.dart';
import '../../../core/widgets/app_error_view.dart';
import '../../../core/widgets/app_top_bar.dart';
import '../../../core/widgets/shell_geometry.dart';
import '../../../shared/widgets/post/blocked_post_gate.dart';
import '../../../shared/widgets/post/post_card.dart';
import '../../../shared/widgets/post/post_list_skeleton.dart';
import '../../engagement/domain/engagement_feature_flag.dart';
import '../../graph/domain/graph_feature_flag.dart';
import '../../moderation/domain/reports_feature_flag.dart';
import '../../onboarding/presentation/bloc/onboarding_bloc.dart';
import '../data/posts_repository.dart';
import '../domain/posts_feature_flag.dart';
import 'bloc/post_detail_cubit.dart';
import 'thread_screen.dart';
import 'widgets/post_unavailable_view.dart';

/// `/post/:id`: one post via `GetPost`. A missing, deleted or hidden
/// post shows "This post isn't available" with no retry; a post of an author
/// the viewer blocks sits behind a "You blocked @x - Show post" banner
/// (from the local relationship cache).
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
      appBar: AppTopBar.of(
        context,
        title: 'Post',
        onBack: () => leavePostScreen(context),
      ),
      // The floating bar overlays the page: the scroll view runs behind it and
      // ends with the bar's inset.
      body: SafeArea(bottom: false, child: child),
    );
  }
}

class _PostDetailView extends StatefulWidget {
  const _PostDetailView();

  @override
  State<_PostDetailView> createState() => _PostDetailViewState();
}

class _PostDetailViewState extends State<_PostDetailView> {
  @override
  Widget build(BuildContext context) {
    return BlocConsumer<PostDetailCubit, PostDetailState>(
      listenWhen: (before, after) => after.status == PostDetailStatus.deleted,
      listener: (context, state) => leavePostScreen(context),
      builder: (context, state) {
        final cubit = context.read<PostDetailCubit>();
        return _Frame(
          child: switch (state.status) {
            // The opened post's shape, not a bare spinner. A deleted post is
            // leaving: the same shape, announced as nothing.
            PostDetailStatus.loading || PostDetailStatus.deleted => Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: ShellGeometry.readableMaxWidth(context),
                ),
                child: FocalPostSkeleton(
                  announce: state.status == PostDetailStatus.loading,
                ),
              ),
            ),
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
    final reportsEnabled = isFeatureEnabled(context, kFeatureReports);
    final author = view.post.author;
    final viewerUserId = context.read<OnboardingBloc>().state.profile?.userId;

    return SingleChildScrollView(
      padding: shellBottomInsets(context),
      child: Center(
        child: ConstrainedBox(
          // 680 on the tablet layout (the readable column), else 600.
          constraints: BoxConstraints(
            maxWidth: ShellGeometry.readableMaxWidth(context),
          ),
          child: BlockedPostGate(
            authorId: author.userId,
            handle: author.handle,
            graphEnabled: graphEnabled,
            child: PostCard(
              view: view,
              focal: true,
              viewerUserId: viewerUserId,
              graphActionsEnabled: graphEnabled,
              reportsEnabled: reportsEnabled,
              engagementEnabled: isFeatureEnabled(context, kFeatureEngagement),
              onDelete: (_) => context.read<PostDetailCubit>().deletePost(),
              onRelationshipChanged: (_) => onRelationshipChanged(),
            ),
          ),
        ),
      ),
    );
  }
}
