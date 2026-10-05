import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/theme/app_theme.dart';
import '../../features/graph/presentation/bloc/relationship_cubit.dart';
import '../../features/graph/presentation/bloc/relationship_state.dart';
import '../../features/graph/presentation/graph_error_messages.dart';
import '../../gen/dzeroth/graph/v1/graph.pb.dart' as graph;

/// Follow / Following / Unblock button, driven by a [RelationshipCubit]
/// already provided above it in the widget tree (one cubit per profile
/// header or list row — see `UserListRow`/`ProfileHeader`).
///
/// - Shows "Follow" (filled) when the caller has no relationship, "Following"
///   (outlined) when following, and "Unblock" (outlined) when the caller
///   blocks the target — Follow is never offered while blocking (calling it
///   would just fail with `TARGET_BLOCKED`).
/// - A `FOLLOW_STATE_REQUESTED` row renders a disabled "Requested" state:
///   unreachable until private accounts ship (ADR-0008 D1), but handled
///   defensively since the enum value exists on the wire.
/// - Updates optimistically (via the cubit) and shows a friendly snackbar,
///   never the raw server message, if the server rejects the action.
const _minSize = Size(88, AppSpacing.minTapTarget);

class FollowButton extends StatelessWidget {
  const FollowButton({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<RelationshipCubit, RelationshipState>(
      listener: (context, state) {
        final error = state.error;
        if (error == null) return;
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
        final bool filled;

        if (relationship.blocking) {
          label = 'Unblock';
          filled = false;
          onPressed = state.isUpdating ? null : cubit.unblock;
        } else if (relationship.followState ==
            graph.FollowState.FOLLOW_STATE_FOLLOWING) {
          label = 'Following';
          filled = false;
          onPressed = state.isUpdating ? null : cubit.unfollow;
        } else if (relationship.followState ==
            graph.FollowState.FOLLOW_STATE_REQUESTED) {
          label = 'Requested';
          filled = false;
          onPressed = null;
        } else {
          label = 'Follow';
          filled = true;
          onPressed = state.isUpdating ? null : cubit.follow;
        }

        final child = state.isUpdating
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Text(label);

        // The app theme gives buttons a full-width 48dp minimum
        // (`Size.fromHeight`), which is an infinite width inside a Row (the
        // profile header puts this button in one). Keep the 48dp height and
        // use a finite minimum width.
        return Semantics(
          button: true,
          label: label,
          child: filled
              ? FilledButton(
                  style: FilledButton.styleFrom(minimumSize: _minSize),
                  onPressed: onPressed,
                  child: child,
                )
              : OutlinedButton(
                  style: OutlinedButton.styleFrom(minimumSize: _minSize),
                  onPressed: onPressed,
                  child: child,
                ),
        );
      },
    );
  }
}
