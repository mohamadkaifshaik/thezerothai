import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/telemetry/analytics_event.dart' show FollowSource;
import '../../../../core/theme/app_theme.dart';
import '../../../../shared/widgets/user/follow_button.dart';
import '../../../graph/data/graph_repository.dart';
import '../../../graph/presentation/bloc/relationship_cubit.dart';
import '../bloc/follow_back_cubit.dart';

/// F14's control on a follow notification: the shared [FollowButton], which
/// reads "Follow back" (the actor follows the viewer) and turns into
/// "Following" or "Requested" optimistically, with rollback and a message on
/// failure, exactly as on profiles and people lists.
///
/// Seeded from the page's one batched `GetRelationships`
/// ([FollowBackCubit]), or the session cache when it is newer (a follow made
/// from this row before it scrolled away). While the answer is still to come
/// it keeps the button's 48 dp line, so the row does not jump; after a
/// failed answer, or for an account the viewer blocks, it draws nothing.
class FollowBackSlot extends StatelessWidget {
  const FollowBackSlot({super.key, required this.cubit, required this.actorId});

  final FollowBackCubit cubit;
  final String actorId;

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<FollowBackCubit, FollowBackState>(
      bloc: cubit,
      buildWhen: (a, b) =>
          a.relationships[actorId] != b.relationships[actorId] ||
          a.failed.contains(actorId) != b.failed.contains(actorId),
      builder: (context, state) {
        final answered = state.relationships[actorId];
        if (answered == null) {
          return state.failed.contains(actorId)
              ? const SizedBox.shrink()
              : const SizedBox(
                  key: ValueKey('follow-back-pending'),
                  height: AppSpacing.minTapTarget,
                );
        }
        final graphRepository = context.read<GraphRepository>();
        final seed = graphRepository.cached(actorId) ?? answered;
        // A blocked account is not offered a follow (the shared button
        // would read "Unblock", which this row is not about).
        if (seed.blocking) return const SizedBox.shrink();
        return Align(
          alignment: AlignmentDirectional.centerStart,
          child: BlocProvider(
            create: (_) => RelationshipCubit(
              graphRepository: graphRepository,
              userId: actorId,
              initial: seed,
            ),
            child: const FollowButton(
              followedBy: true,
              source: FollowSource.other,
            ),
          ),
        );
      },
    );
  }
}
