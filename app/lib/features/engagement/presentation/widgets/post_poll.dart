import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/feature_flags/feature_flags.dart';
import '../../../../gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import '../../../../shared/widgets/poll_card.dart';
import '../../domain/engagement_feature_flag.dart';
import '../../domain/poll_display.dart';
import '../bloc/poll_cubit.dart';
import '../bloc/poll_state.dart';
import '../engagement_error_messages.dart';

/// The poll of one post, wired to the session's [PollCubit] (W6-13).
///
/// - [targetId] is the *original* post id (the id `VotePoll` takes; a REPOST
///   row never reaches here, it uses [PollEmbedSummary]).
/// - Vote buttons need `engagement` for the viewer and a server that has not
///   refused voting; the author never gets them.
/// - The overlay (an in-flight vote, the committed counts, a re-read) wins
///   over [view] unless the row itself already carries counts the viewer may
///   see.
/// - A failed vote or "See final results" read is worded once, as a snackbar,
///   by the card on the page on top.
/// - With no `PollCubit` above (a card outside the app, some tests) the card
///   is read-only.
class PostPoll extends StatelessWidget {
  const PostPoll({
    super.key,
    required this.view,
    required this.targetId,
    required this.isAuthor,
    this.now,
  });

  final pb.PostView view;
  final String targetId;
  final bool isAuthor;
  final DateTime? now;

  static PollCubit? _cubit(BuildContext context) {
    try {
      return context.read<PollCubit>();
    } on ProviderNotFoundException {
      return null;
    }
  }

  static bool _engagementOn(BuildContext context) {
    try {
      return isFeatureEnabled(context, kFeatureEngagement);
    } on ProviderNotFoundException {
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final reference = now ?? DateTime.now();
    final cubit = _cubit(context);
    final engagementOn = _engagementOn(context);
    if (cubit == null) {
      return PollCard(
        display: PollDisplay.of(
          poll: view.post.poll,
          viewerChoice: view.viewerPollChoice,
          isAuthor: isAuthor,
          now: reference,
          canVote: false,
        ),
        now: reference,
      );
    }
    return BlocConsumer<PollCubit, PollState>(
      bloc: cubit,
      listenWhen: (previous, current) =>
          current.failure != null &&
          current.failure != previous.failure &&
          current.failure!.postId == targetId,
      listener: (context, state) {
        final failure = state.failure!;
        if (!(ModalRoute.of(context)?.isCurrent ?? true)) return;
        ScaffoldMessenger.maybeOf(context)
          ?..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(content: Text(pollErrorMessage(failure.error, action: failure.action))),
          );
        cubit.failureShown();
      },
      buildWhen: (previous, current) =>
          previous.entries[targetId] != current.entries[targetId] ||
          previous.votingOff != current.votingOff,
      builder: (context, state) {
        final entry = state.entries[targetId] ?? const PollEntry();
        final fresh = entry.fresh;
        // A row that already shows the counts is as new as the overlay.
        final rowHasCounts =
            view.post.poll.resultsVisible && view.viewerPollChoice > 0;
        final source = fresh != null && !rowHasCounts ? fresh : view;
        return PollCard(
          display: PollDisplay.of(
            poll: source.post.poll,
            viewerChoice: source.viewerPollChoice,
            isAuthor: isAuthor,
            now: reference,
            canVote: engagementOn && !cubit.votingOff,
            pendingChoice: entry.pendingChoice,
            knownChoice: entry.knownChoice,
            forceClosed: entry.closed,
          ),
          now: reference,
          refreshing: entry.refreshing,
          onVote: (choice) => unawaited(cubit.vote(targetId, choice)),
          onSeeFinalResults: () => unawaited(cubit.refresh(targetId)),
        );
      },
    );
  }
}
