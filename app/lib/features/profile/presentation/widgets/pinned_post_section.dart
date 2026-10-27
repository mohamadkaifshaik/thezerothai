import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/feature_flags/feature_flags.dart';
import '../../../../core/network/app_exception.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import '../../../../shared/widgets/app_notice_banner.dart';
import '../../../../shared/widgets/post_list_skeleton.dart';
import '../../../../shared/widgets/post_pin_control.dart';
import '../../../engagement/domain/engagement_feature_flag.dart';
import '../../../graph/domain/graph_feature_flag.dart';
import '../../../moderation/domain/reports_feature_flag.dart';
import '../../../timeline/presentation/widgets/feed_post_row.dart';
import '../bloc/pinned_post_cubit.dart';
import '../bloc/pinned_post_state.dart';

/// The profile's Pinned row (W3-17, ADR-0024 D3): a muted pin icon and
/// "Pinned" above the pinned post, which is a normal feed row. Reads the
/// given [PinnedPostCubit] and shows nothing for no pin or a post that is
/// gone (silently), a one-row skeleton while it loads and a notice with Retry
/// when it could not be loaded.
///
/// It renders whenever the server returned a pin, whatever the viewer's own
/// flags are (rendering is never gated, only the Pin / Unpin menu rows).
class PinnedPostSection extends StatelessWidget {
  const PinnedPostSection({
    super.key,
    required this.cubit,
    required this.viewerUserId,
    this.onRelationshipChanged,
    this.pinControl,
  });

  final PinnedPostCubit cubit;
  final String? viewerUserId;
  final ValueChanged<graph.Relationship>? onRelationshipChanged;

  /// Unpin on the viewer's own pinned post (null: no menu row).
  final PostPinControl? pinControl;

  @override
  Widget build(BuildContext context) {
    final graphEnabled = isFeatureEnabled(context, kFeatureGraph);
    final reportsEnabled = isFeatureEnabled(context, kFeatureReports);
    final engagementEnabled = isFeatureEnabled(context, kFeatureEngagement);
    return BlocBuilder<PinnedPostCubit, PinnedPostState>(
      bloc: cubit,
      builder: (context, state) {
        final Widget body;
        switch (state.status) {
          case PinnedPostStatus.none:
          case PinnedPostStatus.hidden:
            return const SizedBox.shrink();
          case PinnedPostStatus.loading:
            body = Column(
              mainAxisSize: MainAxisSize.min,
              children: const [
                PostListSkeleton(
                  rows: 1,
                  mediaEvery: 0,
                  semanticsLabel: 'Loading pinned post',
                ),
                Divider(height: 1),
              ],
            );
          case PinnedPostStatus.ready:
            body = FeedPostRow(
              key: ValueKey('pinned-${state.postId}'),
              view: state.view!,
              viewerUserId: viewerUserId,
              graphEnabled: graphEnabled,
              reportsEnabled: reportsEnabled,
              engagementEnabled: engagementEnabled,
              onDelete: cubit.deletePinned,
              onRelationshipChanged: onRelationshipChanged,
              pinControl: pinControl,
            );
          case PinnedPostStatus.failed:
            final error = state.error!;
            body = AppNoticeBanner(
              message: pinnedPostErrorMessage(error),
              onRetry: noticeCanRetry(error) ? cubit.retry : null,
            );
        }
        return Column(
          key: const ValueKey('pinned-post-section'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [const _PinnedLabel(), body],
        );
      },
    );
  }
}

/// Text of the notice under the label when the pinned post could not be
/// loaded. Branches on the exception type, never on its text.
String pinnedPostErrorMessage(AppException error) {
  return switch (error) {
    NetworkException() =>
      "You're offline. The pinned post will load when you're back.",
    RateLimitedException() ||
    DegradedModeException() => "The pinned post can't be loaded right now.",
    _ => "Couldn't load the pinned post.",
  };
}

/// "Pinned" with a muted pin icon, aligned with the avatar column of the card
/// below (the same geometry as the "X reposted" line).
class _PinnedLabel extends StatelessWidget {
  const _PinnedLabel();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Semantics(
      container: true,
      label: 'Pinned post',
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsetsDirectional.only(
          start: AppSpacing.md,
          end: AppSpacing.md,
          top: AppSpacing.sm,
        ),
        child: Row(
          children: [
            SizedBox(
              width: AppSpacing.minTapTarget,
              child: Align(
                alignment: AlignmentDirectional.centerEnd,
                child: Icon(
                  Icons.push_pin_outlined,
                  size: AppIconSize.sm,
                  color: muted,
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                'Pinned',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: muted,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
