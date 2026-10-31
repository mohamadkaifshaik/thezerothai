import '../../../gen/dzeroth/posts/v1/posts.pb.dart' as pb;

/// What a poll card shows (ADR-0029 D4, W6-13). The rules live here so the
/// widget only draws.
enum PollMode {
  /// Open, the viewer may vote: outlined choice buttons, no counts.
  vote,

  /// Open, the viewer cannot vote (the author, `engagement` off, voting
  /// refused) and the counts are hidden: the labels, read-only.
  readOnly,

  /// The viewer voted but the counts are not known yet (a vote in flight, or
  /// a refusal that told us the choice): the labels, the check on theirs.
  votedHidden,

  /// Closed, but this copy still has hidden counts (a cached row that passed
  /// `closes_at`): "See final results" asks the server once.
  finalPending,

  /// The server sent the counts: bars with percentages.
  results,
}

/// The card's view of one [pb.Poll] for one viewer. Immutable.
class PollDisplay {
  const PollDisplay._({
    required this.mode,
    required this.labels,
    required this.percents,
    required this.leading,
    required this.myChoice,
    required this.totalVotes,
    required this.closed,
    required this.pending,
    this.closesAt,
  });

  final PollMode mode;
  final List<String> labels;

  /// Whole percents that total 100 (largest remainder); all 0 when there is
  /// no vote; empty unless [mode] is [PollMode.results].
  final List<int> percents;

  /// Indexes drawn bold: every choice tied for the most votes (none at 0).
  final Set<int> leading;

  /// The viewer's own choice (0-based), or null.
  final int? myChoice;

  /// The real total, plus one while the viewer's own vote is in flight.
  final int totalVotes;
  final bool closed;

  /// The viewer's vote is on its way (optimistic).
  final bool pending;
  final DateTime? closesAt;

  bool get showsBars => mode == PollMode.results;

  /// Builds the display.
  ///
  /// - [viewerChoice]: `PostView.viewer_poll_choice` (index + 1, 0 = none).
  /// - [pendingChoice]: the 0-based choice being sent, if any.
  /// - [knownChoice]: a 0-based choice the server named in an ALREADY_VOTED
  ///   refusal, if any.
  /// - [forceClosed]: the server said POLL_CLOSED while this device's clock
  ///   still read open.
  /// - [canVote]: the viewer has `engagement` on and voting was not refused.
  factory PollDisplay.of({
    required pb.Poll poll,
    required int viewerChoice,
    required bool isAuthor,
    required DateTime now,
    required bool canVote,
    int? pendingChoice,
    int? knownChoice,
    bool forceClosed = false,
  }) {
    final labels = [for (final c in poll.choices) c.label];
    final closesAt = poll.hasClosesAt() ? poll.closesAt.toDateTime() : null;
    final closed =
        poll.closed ||
        forceClosed || (closesAt != null && !closesAt.isAfter(now));

    int? valid(int? index) =>
        index != null && index >= 0 && index < labels.length ? index : null;
    final fromServer = valid(viewerChoice > 0 ? viewerChoice - 1 : null);
    final mine = valid(pendingChoice) ?? fromServer ?? valid(knownChoice);
    final pending = pendingChoice != null && valid(pendingChoice) != null;

    final votes = [for (final c in poll.choices) c.votes.toInt()];
    final total = poll.totalVotes.toInt() + (pending ? 1 : 0);

    PollMode mode;
    if (poll.resultsVisible && !pending) {
      mode = PollMode.results;
    } else if (mine != null) {
      mode = PollMode.votedHidden;
    } else if (closed) {
      mode = PollMode.finalPending;
    } else if (isAuthor || !canVote) {
      mode = PollMode.readOnly;
    } else {
      mode = PollMode.vote;
    }

    final showBars = mode == PollMode.results;
    final percents = showBars ? largestRemainderPercents(votes) : <int>[];
    final most = votes.isEmpty ? 0 : votes.reduce((a, b) => a > b ? a : b);
    final leading = showBars && most > 0
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
      totalVotes: total,
      closed: closed,
      pending: pending,
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
