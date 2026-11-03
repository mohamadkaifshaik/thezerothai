import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/feature_flags/feature_flags.dart';
import '../../../../core/network/app_exception.dart';
import '../../../../core/router/app_router.dart';
import '../../../../core/widgets/app_error_view.dart';
import '../../../../gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import '../../../../shared/widgets/post/blocked_post_gate.dart';
import '../../../graph/domain/graph_feature_flag.dart';
import '../../data/posts_repository.dart';
import '../../domain/posts_feature_flag.dart';
import '../bloc/post_detail_cubit.dart';
import 'post_unavailable_view.dart';

/// Reloadable, permission-checked content for post overlays, including deep links.
class LoadedPost extends StatelessWidget {
  const LoadedPost({
    super.key,
    required this.postId,
    required this.builder,
    this.loadingFrame,
  });

  final String postId;
  final Widget Function(BuildContext, pb.PostView) builder;
  final Widget Function(Widget)? loadingFrame;

  Widget _frame(Widget child) => loadingFrame?.call(child) ?? child;

  @override
  Widget build(BuildContext context) {
    if (!isFeatureEnabled(context, kFeaturePosts)) {
      return _frame(
        const AppErrorView(
          error: FeatureDisabledException('Posts are not available.'),
        ),
      );
    }
    final graphOn = isFeatureEnabled(context, kFeatureGraph);
    return BlocProvider(
      key: ValueKey(postId),
      create: (context) => PostDetailCubit(
        postsRepository: context.read<PostsRepository>(),
        postId: postId,
      )..load(),
      child: BlocBuilder<PostDetailCubit, PostDetailState>(
        builder: (context, state) {
          final view = state.view;
          if (state.status == PostDetailStatus.ready && view != null) {
            return BlockedPostGate(
              authorId: view.post.author.userId,
              handle: view.post.author.handle,
              graphEnabled: graphOn,
              child: Builder(builder: (context) => builder(context, view)),
            );
          }
          if (state.status == PostDetailStatus.error) {
            return _frame(
              AppErrorView(
                error: state.error!,
                onRetry: context.read<PostDetailCubit>().load,
              ),
            );
          }
          if (state.status == PostDetailStatus.notFound ||
              state.status == PostDetailStatus.deleted) {
            return _frame(
              PostUnavailableView(onHome: () => context.go(AppRouter.homePath)),
            );
          }
          return _frame(const Center(child: CircularProgressIndicator()));
        },
      ),
    );
  }
}
