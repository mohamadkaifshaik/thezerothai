import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:uuid/uuid.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import '../../../graph/data/graph_repository.dart';
import '../../../graph/presentation/graph_error_messages.dart';
import '../../../onboarding/presentation/bloc/onboarding_bloc.dart';
import '../../../onboarding/presentation/bloc/onboarding_event.dart';
import '../bloc/follow_requests_preview_cubit.dart';
import 'follow_requests_card.dart';

/// F16: the follow-requests card in the desktop side column beside
/// Notifications. It owns its `ListFollowRequests(3)` (one call, made when
/// the column first draws it) and the Accept that goes with it: as on the
/// Follow requests page, the count goes down once the server took it, and
/// "Follow back" is offered when the caller does not follow the requester yet.
class FollowRequestsSideCard extends StatefulWidget {
  const FollowRequestsSideCard({super.key});

  @override
  State<FollowRequestsSideCard> createState() => _FollowRequestsSideCardState();
}

class _FollowRequestsSideCardState extends State<FollowRequestsSideCard> {
  late final FollowRequestsPreviewCubit _requests;

  @override
  void initState() {
    super.initState();
    _requests = FollowRequestsPreviewCubit(
      graph: context.read<GraphRepository>(),
    );
    unawaited(_requests.loadOnce());
  }

  @override
  void dispose() {
    unawaited(_requests.close());
    super.dispose();
  }

  void _say(String text, {SnackBarAction? action}) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text), action: action));
  }

  Future<void> _accept(graph.UserListItem item) async {
    final onboarding = context.read<OnboardingBloc>();
    final graphRepository = context.read<GraphRepository>();
    final result = await _requests.accept(item);
    if (result == null) return;
    final handle = item.user.handle;
    switch (result) {
      case FollowRequestAccepted(:final relationship):
        onboarding.add(const OnboardingFollowRequestAnswered());
        if (!mounted) return;
        final followsAlready =
            relationship.followState ==
                graph.FollowState.FOLLOW_STATE_FOLLOWING ||
            relationship.followState ==
                graph.FollowState.FOLLOW_STATE_REQUESTED;
        if (followsAlready) {
          _say('Accepted @$handle.');
        } else {
          _say(
            '@$handle can now see your posts.',
            action: SnackBarAction(
              label: 'Follow back',
              onPressed: () => _followBack(graphRepository, item.user.userId),
            ),
          );
        }
      case FollowRequestAcceptFailed(:final error):
        if (!mounted) return;
        _say(followRequestErrorMessage(error, handle: handle));
    }
  }

  Future<void> _followBack(GraphRepository repository, String userId) async {
    try {
      await repository.follow(
        userId: userId,
        idempotencyKey: const Uuid().v4(),
      );
    } on AppException catch (e) {
      if (!mounted) return;
      _say(relationshipErrorMessage(e));
    }
  }

  @override
  Widget build(BuildContext context) =>
      BlocBuilder<FollowRequestsPreviewCubit, FollowRequestsPreviewState>(
        bloc: _requests,
        builder: (context, state) => FollowRequestsCard(
          state: state,
          onAccept: _accept,
          onRetry: _requests.reload,
        ),
      );
}
