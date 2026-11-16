import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/network/app_exception.dart';
import '../../../core/telemetry/analytics_event.dart';
import '../../../core/telemetry/usage_reporter.dart';
import '../../../features/graph/presentation/bloc/relationship_cubit.dart';
import '../../../features/graph/presentation/bloc/relationship_state.dart';
import '../../../features/graph/presentation/graph_error_messages.dart';
import '../../../gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import 'cancel_follow_request_dialog.dart';
import 'follow_pill.dart';

/// Follow / Following / Unblock button, driven by a [RelationshipCubit]
/// already provided above it in the widget tree (one cubit per profile
/// header or list row — see `UserListRow`/`ProfileHeader`).
///
/// - Draws the x.com pill ([FollowPill]): "Follow" (filled) when the caller
///   has no relationship, "Following" (outlined, "Unfollow" in red on hover)
///   when following, and "Unblock" (red) when the caller
///   blocks the target — Follow is never offered while blocking (calling it
///   would just fail with `TARGET_BLOCKED`).
/// - [followedBy] turns "Follow" into "Follow back" (the profile header).
/// - A `FOLLOW_STATE_REQUESTED` row (a protected account) renders
///   an outlined "Requested". Tapping it asks "Cancel your follow request?" and
///   then sends one Unfollow, which withdraws the request. Withdrawing is never
///   gated on `private_accounts` (the undo rule).
/// - Updates optimistically (via the cubit) and shows a friendly snackbar,
///   never the raw server message, if the server rejects the action.
/// - [onGone] (optional): the server answered NOT_FOUND, so the account is
///   blocked, suspended or deleted. It is called once instead of the
///   snackbar: a list that offers accounts (the "Who to follow" card) drops
///   the row rather than say "This account doesn't exist anymore.".
class FollowButton extends StatelessWidget {
  /// [followedBy]: the other user follows the viewer, so the not-following
  /// state reads "Follow back" (only the profile header knows this; list rows
  /// pass nothing).
  const FollowButton({
    super.key,
    this.followedBy = false,
    this.onGone,
    this.source = FollowSource.other,
    this.large = false,
    this.onDark = false,
  });

  /// The 36dp pill of the profile header (32dp otherwise).
  final bool large;

  /// Drawn as on the dark theme whatever the theme is (the navy hero).
  final bool onDark;

  final bool followedBy;

  /// Where this button sits, for the `follow` usage event. Reported
  /// once, when the server confirmed a follow (never the optimistic step, never
  /// a rolled-back one).
  final FollowSource source;

  /// Called, with no snackbar, when the action fails with NOT_FOUND.
  final VoidCallback? onGone;

  @override
  Widget build(BuildContext context) {
    final usage = UsageScope.of(context);
    return BlocConsumer<RelationshipCubit, RelationshipState>(
      listener: (context, state) {
        final error = state.error;
        if (error == null) return;
        final onGone = this.onGone;
        if (error is NotFoundException && onGone != null) {
          onGone();
          return;
        }
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(content: Text(relationshipErrorMessage(error))),
          );
      },
      builder: (context, state) {
        final cubit = context.read<RelationshipCubit>();
        final relationship = state.relationship;

        final String label;
        final VoidCallback? onPressed;
        final FollowPillStyle style;
        String? hoverLabel;

        if (relationship.blocking) {
          label = 'Unblock';
          style = FollowPillStyle.danger;
          onPressed = state.isUpdating ? null : cubit.unblock;
        } else if (relationship.followState ==
            graph.FollowState.FOLLOW_STATE_FOLLOWING) {
          label = 'Following';
          style = FollowPillStyle.outlined;
          hoverLabel = 'Unfollow';
          onPressed = state.isUpdating ? null : cubit.unfollow;
        } else if (relationship.followState ==
            graph.FollowState.FOLLOW_STATE_REQUESTED) {
          label = 'Requested';
          style = FollowPillStyle.outlined;
          hoverLabel = 'Cancel';
          onPressed = state.isUpdating
              ? null
              : () async {
                  final cancel = await showCancelFollowRequestDialog(context);
                  if (cancel && context.mounted) cubit.unfollow();
                };
        } else {
          label = followedBy ? 'Follow back' : 'Follow';
          style = FollowPillStyle.filled;
          onPressed = state.isUpdating
              ? null
              : () async {
                  await cubit.follow();
                  // Only a confirmed follow is reported: a refusal rolls
                  // back with an `error`, and a cubit closed mid-request is left
                  // in its optimistic, still-updating state.
                  if (cubit.state.isConfirmedFollow) {
                    usage.log(FollowMade(source: source));
                  }
                };
        }

        return Semantics(
          button: true,
          label: label,
          excludeSemantics: true,
          enabled: onPressed != null,
          onTap: onPressed,
          child: FollowPill(
            label: label,
            hoverLabel: hoverLabel,
            style: style,
            large: large,
            onDark: onDark,
            busy: state.isUpdating,
            onPressed: onPressed,
          ),
        );
      },
    );
  }
}
