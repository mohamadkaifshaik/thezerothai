import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/router/app_router.dart';
import '../../../../gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import '../../../../gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import '../../../../shared/widgets/post_card.dart';
import '../../../../shared/widgets/post_pin_control.dart';

/// One post row of a feed: a [PostCard] that opens `/post/:id` on tap, then
/// the 1dp divider. Shared by [TimelineFeedView]'s list and the profile's
/// Pinned row, so a post looks and acts the same in both places.
///
/// The flags are passed in (the caller reads them once for the whole list,
/// not once per row). Display only: every action is a callback.
class FeedPostRow extends StatelessWidget {
  const FeedPostRow({
    super.key,
    required this.view,
    required this.viewerUserId,
    this.now,
    required this.graphEnabled,
    required this.reportsEnabled,
    required this.engagementEnabled,
    this.onDelete,
    this.onRelationshipChanged,
    this.pinControl,
  });

  final pb.PostView view;
  final String? viewerUserId;

  /// Reference time of the relative timestamp (the feed's tick); null reads
  /// the clock when the card is built.
  final DateTime? now;
  final bool graphEnabled;
  final bool reportsEnabled;
  final bool engagementEnabled;
  final Future<void> Function(String postId)? onDelete;
  final ValueChanged<graph.Relationship>? onRelationshipChanged;

  /// Pin / Unpin rows on the viewer's own posts (null: none).
  final PostPinControl? pinControl;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          onTap: () => context.push(AppRouter.postPath(view.post.postId)),
          child: PostCard(
            view: view,
            viewerUserId: viewerUserId,
            now: now,
            graphActionsEnabled: graphEnabled,
            reportsEnabled: reportsEnabled,
            engagementEnabled: engagementEnabled,
            onDelete: onDelete,
            onRelationshipChanged: onRelationshipChanged,
            pinControl: pinControl,
          ),
        ),
        const Divider(height: 1),
      ],
    );
  }
}
