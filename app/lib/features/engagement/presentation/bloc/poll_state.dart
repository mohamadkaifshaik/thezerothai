import 'package:flutter/foundation.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../gen/dzeroth/posts/v1/posts.pb.dart' as pb;

/// Which step failed (picks the wording of the snackbar).
enum PollAction { vote, change, refresh }

/// One failed vote or refresh, shown once by the card of [postId].
@immutable
class PollFailure {
  const PollFailure({
    required this.postId,
    required this.action,
    required this.error,
    required this.serial,
  });

  final String postId;
  final PollAction action;
  final AppException error;

  /// Distinguishes two consecutive identical failures.
  final int serial;
}

/// What the session knows about one poll beyond the row a card was given.
@immutable
class PollEntry {
  const PollEntry({
    this.pendingChoice,
    this.fresh,
    this.knownChoice,
    this.refreshing = false,
    this.closed = false,
    this.changing = false,
    this.limitReached = false,
    this.blocked = false,
    this.freshWins = false,
  });

  /// The 0-based choice being sent (optimistic), or null.
  final int? pendingChoice;

  /// The server's latest `PostView` of the original (the `VotePoll` response
  /// or a `GetPost`): its poll carries the counts the viewer may see.
  final pb.PostView? fresh;

  /// The viewer's 0-based choice named by an ALREADY_VOTED refusal, used
  /// while `GetPost` has not (or could not) bring the counts.
  final int? knownChoice;

  /// A `GetPost` for this poll is in flight.
  final bool refreshing;

  /// The server said POLL_CLOSED (the clock of this device was behind).
  final bool closed;

  /// "Change vote" was tapped: the card shows the choice pills again.
  final bool changing;

  /// The server refused another change (LIMIT_REACHED `poll_vote_changes`):
  /// the control is gone for this poll.
  final bool limitReached;

  /// The server said TARGET_BLOCKED (the viewer blocks the author) before the
  /// row said so.
  final bool blocked;

  /// [fresh] came from a vote change or a refusal of one: it beats a row that
  /// already carried counts.
  final bool freshWins;

  PollEntry copyWith({
    int? pendingChoice,
    bool clearPending = false,
    pb.PostView? fresh,
    int? knownChoice,
    bool? refreshing,
    bool? closed,
    bool? changing,
    bool? limitReached,
    bool? blocked,
    bool? freshWins,
    bool clearKnown = false,
  }) => PollEntry(
    pendingChoice: clearPending ? null : (pendingChoice ?? this.pendingChoice),
    fresh: fresh ?? this.fresh,
    knownChoice: clearKnown ? null : (knownChoice ?? this.knownChoice),
    refreshing: refreshing ?? this.refreshing,
    closed: closed ?? this.closed,
    changing: changing ?? this.changing,
    limitReached: limitReached ?? this.limitReached,
    blocked: blocked ?? this.blocked,
    freshWins: freshWins ?? this.freshWins,
  );
}

/// The session's poll overlay: per original post id. Plain immutable class
/// (no codegen), like `EngagementState`.
@immutable
class PollState {
  const PollState({
    this.entries = const {},
    this.failure,
    this.votingOff = false,
  });

  final Map<String, PollEntry> entries;
  final PollFailure? failure;

  /// The server refused voting (FEATURE_DISABLED / UNIMPLEMENTED): no card
  /// offers vote buttons until the next `GetMe` or sign-in.
  final bool votingOff;

  PollState copyWith({
    Map<String, PollEntry>? entries,
    PollFailure? failure,
    bool clearFailure = false,
    bool? votingOff,
  }) => PollState(
    entries: entries ?? this.entries,
    failure: clearFailure ? null : (failure ?? this.failure),
    votingOff: votingOff ?? this.votingOff,
  );
}
