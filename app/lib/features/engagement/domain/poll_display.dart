import '../../../gen/dzeroth/posts/v1/posts.pb.dart' as pb;

/// What a poll card shows (ADR-0029 D4, W6-13). The rules live here so the
/// widget only draws.
enum PollMode {
  /// Open, the viewer may vote: outlined choice buttons, no counts.
  vote,

  /// Open, the viewer cannot vote (the author, `engagement` off, voting
  /// refused, blocks the author) and the counts are hidden: the labels,
  /// read-only.
  readOnly,

  /// The viewer voted but the counts are not known yet (a vote in flight, or
  /// a refusal that told us the choice): the labels, the check on theirs.
  votedHidden,

  /// Closed, but this copy still has hidden counts (a cached row that passed
  /// `closes_at`): "See final results" asks the server once.
  finalPending,

  /// The server sent the counts: bars with percentages.
  results,

  /// The viewer voted and tapped "Change vote" (ADR-0029 Amendment 1 A2.8):
  /// the choice pills again, the check on the current one, the percents kept.
  change,
}

/// The card's view of one [pb.Poll] for one viewer. Immutable.
class PollDisplay {
  const PollDisplay._({
    required this.mode,
    required this.labels,
    required this.percents,
    required this.leading,
    required this.myChoice,
    required this.committedChoice,
    required this.totalVotes,
    required this.closed,
    required this.pending,
    required this.pendingChange,
    required this.blocked,
    required this.canChange,
    this.closesAt,
  });

  final PollMode mode;
  final List<String> labels;

  /// Whole percents that total 100 (largest remainder); all 0 when there is
  /// no vote; empty unless the counts are visible ([PollMode.results] or
  /// [PollMode.change]).
  final List<int> percents;

  /// Indexes drawn bold: every choice tied for the most votes (none at 0).
  final Set<int> leading;

  /// The viewer's own choice (0-based), or null; the pending one while a vote
  /// is in flight.
  final int? myChoice;

  /// The vote the server holds for the viewer (0-based), or null: the
  /// `expected_choice` of a change is this plus one.
  final int? committedChoice;

  /// The real total, plus one while the viewer's own first vote is in flight
  /// (a change moves a vote and leaves the total alone).
  final int totalVotes;
  final bool closed;

  /// The viewer's vote is on its way (optimistic).
  final bool pending;

  /// The vote on its way moves an existing vote (counts shift -1/+1).
  final bool pendingChange;

  /// The viewer blocks the author: no buttons, "Unblock to vote".
  final bool blocked;

  /// "Change vote" may be offered: open, voted, not the author, not blocked,
  /// not at the change cap, no vote in flight.
  final bool canChange;
  final DateTime? closesAt;

  bool get showsBars => mode == PollMode.results;

  /// Builds the display.
  ///
  /// - [viewerChoice]: `PostView.viewer_poll_choice` (index + 1, 0 = none).
  /// - [pendingChoice]: the 0-based choice being sent, if any.
  /// - [knownChoice]: a 0-based choice the server named in a refusal
  ///   (ALREADY_VOTED, LIMIT_REACHED), if any; it beats a stale row.
  /// - [forceClosed]: the server said POLL_CLOSED while this device's clock
  ///   still read open.
  /// - [canVote]: the viewer has `engagement` on and voting was not refused.
  /// - [blocked]: `viewer_poll_vote_blocked` (or TARGET_BLOCKED).
  /// - [changing]: "Change vote" was tapped.
  /// - [changeLimitReached]: the server refused another change.
  factory PollDisplay.of({
    required pb.Poll poll,
    required int viewerChoice,
    required bool isAuthor,
    required DateTime now,
    required bool canVote,
    int? pendingChoice,
    int? knownChoice,
    bool forceClosed = false,
    bool blocked = false,
    bool changing = false,
    bool changeLimitReached = false,
  }) {
    final labels = [for (final c in poll.choices) c.label];
    final closesAt = poll.hasClosesAt() ? poll.closesAt.toDateTime() : null;
    final closed =
        poll.closed ||
        forceClosed ||
        (closesAt != null && !closesAt.isAfter(now));

    int? valid(int? index) =>
        index != null && index >= 0 && index < labels.length ? index : null;
    final fromServer = valid(viewerChoice > 0 ? viewerChoice - 1 : null);
    final committed = valid(knownChoice) ?? fromServer;
    final pendingIndex = valid(pendingChoice);
    final mine = pendingIndex ?? committed;
    final pending = pendingIndex != null;
    // A change moves a vote the viewer already has, with the counts known.
    final pendingChange =
        pending &&
        committed != null &&
        poll.resultsVisible &&
        committed != pendingIndex;

    var votes = [for (final c in poll.choices) c.votes.toInt()];
    if (pendingChange) {
      votes = [
        for (var i = 0; i < votes.length; i++)
          i == committed
              ? (votes[i] > 0 ? votes[i] - 1 : 0)
              : i == pendingIndex
              ? votes[i] + 1
              : votes[i],
      ];
    }
    final total =
        poll.totalVotes.toInt() + (pending && committed == null ? 1 : 0);

    final canChange =
        !closed &&
        !isAuthor &&
        !blocked &&
        !changeLimitReached &&
        canVote &&
        !pending &&
        committed != null &&
        poll.resultsVisible;

    PollMode mode;
    if (changing && canChange) {
      mode = PollMode.change;
    } else if (poll.resultsVisible && (!pending || pendingChange)) {
      mode = PollMode.results;
    } else if (mine != null) {
      mode = PollMode.votedHidden;
    } else if (closed) {
      mode = PollMode.finalPending;
    } else if (isAuthor || !canVote || blocked) {
      mode = PollMode.readOnly;
    } else {
      mode = PollMode.vote;
    }

    final showCounts = mode == PollMode.results || mode == PollMode.change;
    final percents = showCounts ? largestRemainderPercents(votes) : <int>[];
    final most = votes.isEmpty ? 0 : votes.reduce((a, b) => a > b ? a : b);
    final leading = showCounts && most > 0
        ? {
            for (var i = 0; i < votes.length; i++)
              if (votes[i] == most) i,
          }
        : <int>{};
    return PollDisplay._(
      mode: mode,
      labels: labels,
      percents: percents,
      leading: leading,
      myChoice: mine,
      committedChoice: committed,
      totalVotes: total,
      closed: closed,
      pending: pending,
      pendingChange: pendingChange,
      blocked: blocked && !closed,
      canChange: canChange,
      closesAt: closesAt,
    );
  }
}

/// Whole percents of [votes] that always total 100 (largest remainder; ties
/// go to the lower index). No votes at all gives zeros, never a division.
List<int> largestRemainderPercents(List<int> votes) {
  final total = votes.fold<int>(0, (a, b) => a + b);
  if (total <= 0) return List<int>.filled(votes.length, 0);
  final floors = [for (final v in votes) v * 100 ~/ total];
  var left = 100 - floors.fold<int>(0, (a, b) => a + b);
  final order = List<int>.generate(votes.length, (i) => i)
    ..sort((a, b) {
      final ra = votes[a] * 100 % total;
      final rb = votes[b] * 100 % total;
      return ra != rb ? rb.compareTo(ra) : a.compareTo(b);
    });
  for (final i in order) {
    if (left <= 0) break;
    floors[i]++;
    left--;
  }
  return floors;
}

/// `LimitReachedException.quota` of a refused vote change (the server's
/// `limit=poll_vote_changes`, `POLL_VOTE_CHANGES_MAX` = 5, ADR-0029 A1).
const kPollVoteChangesLimit = 'poll_vote_changes';
