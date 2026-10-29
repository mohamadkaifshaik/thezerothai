import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/router/app_router.dart';
import '../../../../gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import '../../../../gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import '../../../../shared/widgets/post_card.dart';
import '../../../../shared/widgets/post_pin_control.dart';
import '../../../../shared/widgets/protected_post_box.dart';
import '../../../engagement/domain/engagement_entry.dart';
import '../../../engagement/presentation/bloc/engagement_cubit.dart';
import '../../../engagement/presentation/bloc/engagement_state.dart';
import '../../../engagement/presentation/engagement_error_messages.dart';

/// One post row of a feed: a [PostCard] that opens `/post/:id` on tap, then
/// the 1dp divider. Shared by [TimelineFeedView]'s list and the profile's
/// Pinned row, so a post looks and acts the same in both places.
///
/// A REPOST of a protected author's post (`embed_viewer_state = PROTECTED`,
/// the caller's own REPOST on their own profile, W3-41b) is the exception: it
/// opens nothing (the original answers NOT_FOUND), and with `engagement` on
/// its box carries Undo repost, which removes the row at once and puts it
/// back, with the failure's snackbar, if the undo fails.
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

  PostCard _card() => PostCard(
    view: view,
    viewerUserId: viewerUserId,
    now: now,
    graphActionsEnabled: graphEnabled,
    reportsEnabled: reportsEnabled,
    engagementEnabled: engagementEnabled,
    onDelete: onDelete,
    onRelationshipChanged: onRelationshipChanged,
    pinControl: pinControl,
  );

  @override
  Widget build(BuildContext context) {
    if (isProtectedRepost(view)) {
      if (canUndoProtectedRepost(
        view,
        viewerUserId: viewerUserId,
        engagementEnabled: engagementEnabled,
      )) {
        return _UndoableProtectedRepostRow(view: view, card: _card());
      }
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [_card(), const Divider(height: 1)],
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          onTap: () => context.push(AppRouter.postPath(view.post.postId)),
          child: _card(),
        ),
        const Divider(height: 1),
      ],
    );
  }
}

/// The caller's own REPOST of a protected author's post: the row leaves while
/// the session's [EngagementCubit] says the original is not reposted (the
/// request runs, or it succeeded and the row still says what it said:
/// `EngagementEntry.matches`, the rule the repost button uses) and returns by
/// itself if the undo is rolled back. It stays mounted while hidden, so the
/// failure of the undo is worded here, once, from the same row.
class _UndoableProtectedRepostRow extends StatelessWidget {
  const _UndoableProtectedRepostRow({required this.view, required this.card});

  final pb.PostView view;
  final PostCard card;

  @override
  Widget build(BuildContext context) {
    final target = engagementTargetId(view.post);
    final cubit = context.read<EngagementCubit>();
    return BlocConsumer<EngagementCubit, EngagementState>(
      listenWhen: (before, after) {
        final failure = after.failure;
        return failure != null &&
            failure.postId == target &&
            failure.action == EngagementAction.undoRepost &&
            before.failure?.serial != failure.serial;
      },
      listener: (context, state) {
        // A page opened over this one shows its own failures.
        if (!(ModalRoute.of(context)?.isCurrent ?? true)) return;
        final failure = state.failure!;
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text(
                engagementErrorMessage(failure.error, action: failure.action),
              ),
            ),
          );
        cubit.failureShown();
      },
      buildWhen: (before, after) =>
          before.entries[target] != after.entries[target],
      builder: (context, state) {
        final entry = state.entries[target];
        if (entry != null && entry.matches(view) && !entry.reposted) {
          return const SizedBox.shrink();
        }
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [card, const Divider(height: 1)],
        );
      },
    );
  }
}
