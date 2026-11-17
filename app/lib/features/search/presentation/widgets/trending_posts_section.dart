import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:uuid/uuid.dart';

import '../../../../core/feature_flags/feature_flags.dart';
import '../../../../gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import '../../../../shared/widgets/post/post_list_skeleton.dart';
import '../../../../shared/widgets/primitives/app_notice_banner.dart';
import '../../../engagement/domain/engagement_feature_flag.dart';
import '../../../graph/domain/graph_feature_flag.dart';
import '../../../moderation/domain/reports_feature_flag.dart';
import '../../../onboarding/presentation/bloc/onboarding_bloc.dart';
import '../../../posts/data/posts_repository.dart';
import '../../../timeline/presentation/widgets/feed_post_row.dart';
import '../bloc/trending_feed_cubit.dart';
import '../bloc/trending_feed_state.dart';
import '../bloc/trending_paged_cubit.dart';
import 'trending_section_scroll.dart';
import 'trending_section_views.dart';

/// The Posts section of the Trending tab: the newest public posts (or the
/// newest of the selected hashtag) as feed rows, with the loading, empty,
/// stalled, failed and end states of the design. [slivers] draws the cubit's
/// current state inside a `TrendingSectionScroll`; the cubit is started by its
/// owner.
class TrendingPostsSection {
  const TrendingPostsSection({
    required this.cubit,
    required this.tag,
    required this.onClearFilter,
  });

  final TrendingFeedCubit cubit;
  final String? tag;
  final VoidCallback onClearFilter;

  List<Widget> slivers(BuildContext context, TrendingSliverWrap wrap) {
    // Read once for the whole list, not once per row.
    final graphEnabled = featureEnabledSnapshot(context, kFeatureGraph);
    final reportsEnabled = featureEnabledSnapshot(context, kFeatureReports);
    final engagementEnabled = featureEnabledSnapshot(
      context,
      kFeatureEngagement,
    );
    final viewerUserId = context.read<OnboardingBloc>().state.profile?.userId;
    final posts = context.read<PostsRepository>;
    final state = cubit.state;
    Widget one(Widget child) => wrap(SliverToBoxAdapter(child: child));
    return switch (state.status) {
      PagedStatus.initial ||
      PagedStatus.loading => [one(const PostListSkeleton(rows: 4))],
      PagedStatus.unavailable => [
        const SliverToBoxAdapter(child: SizedBox.shrink()),
      ],
      PagedStatus.failed => [
        one(TrendingFailureView(error: state.error, onRetry: cubit.retry)),
      ],
      PagedStatus.ready => [
        if (state.notice != null && state.rows.isNotEmpty)
          one(
            AppNoticeBanner(
              message: "Couldn't refresh. Showing the last posts.",
              onRetry: cubit.refresh,
            ),
          ),
        if (state.rows.isEmpty)
          one(_empty(state))
        else ...[
          wrap(
            SliverList.builder(
              itemCount: state.rows.length,
              findChildIndexCallback: (key) {
                if (key is! ValueKey<String>) return null;
                final i = state.rows.indexWhere(
                  (v) => 'trending-post-${v.post.postId}' == key.value,
                );
                return i < 0 ? null : i;
              },
              itemBuilder: (context, i) {
                final view = state.rows[i];
                return FeedPostRow(
                  key: ValueKey('trending-post-${view.post.postId}'),
                  view: view,
                  viewerUserId: viewerUserId,
                  graphEnabled: graphEnabled,
                  reportsEnabled: reportsEnabled,
                  engagementEnabled: engagementEnabled,
                  onDelete: (id) => _delete(posts, id),
                  onRelationshipChanged: _onRelationship,
                );
              },
            ),
          ),
          one(_footer(state)),
        ],
      ],
    };
  }

  Widget _empty(TrendingFeedState state) {
    if (state.stalled) {
      return TrendingStalledView(
        noun: 'posts',
        onLoadMore: cubit.continueAfterStall,
      );
    }
    if (state.pagingFailed) return _footer(state);
    if (state.hasMore) return const PostListSkeleton(rows: 4);
    return TrendingEmptyView(
      icon: Icons.dynamic_feed_outlined,
      noun: 'posts',
      emptySubtitle: 'New public posts show up here.',
      tag: tag,
      onClearFilter: onClearFilter,
    );
  }

  Widget _footer(TrendingFeedState state) => TrendingFooter(
    loadingMore: state.loadingMore,
    pagingFailed: state.pagingFailed,
    stalled: state.stalled,
    failedLabel: "Couldn't load more posts. Retry",
    stalledLabel: 'Load more posts',
    onRetry: cubit.retryMore,
    onLoadMore: cubit.continueAfterStall,
  );

  /// A block or mute from a card hides that author's rows at once; undoing it
  /// brings them back (Home's rule).
  void _onRelationship(graph.Relationship relationship) {
    if (cubit.isClosed) return;
    if (relationship.blocking || relationship.muting) {
      cubit.hideAuthor(relationship.userId);
    } else {
      cubit.restoreAuthor(relationship.userId);
    }
  }

  /// The caller's own post: it leaves at once and returns if the delete
  /// fails.
  Future<void> _delete(PostsRepository Function() posts, String postId) async {
    final repository = posts();
    cubit.removePost(postId);
    try {
      await repository.deletePost(
        postId: postId,
        idempotencyKey: const Uuid().v4(),
      );
    } catch (_) {
      if (!cubit.isClosed) cubit.restorePost(postId);
      rethrow;
    }
  }
}
