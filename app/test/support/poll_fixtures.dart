import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protobuf/well_known_types/google/protobuf/timestamp.pb.dart'
    as ts;

import 'posts_fixtures.dart';

/// "Now" for poll tests: the real clock, truncated to the second, taken once
/// (a fixed date would go stale, see the fixed-date guard).
final DateTime kPollNow = () {
  final n = DateTime.now().toUtc();
  return DateTime.utc(n.year, n.month, n.day, n.hour, n.minute, n.second);
}();

/// A poll with [labels]; [votes] are the counts the server sent (all 0 when
/// hidden). [closesIn] is relative to [kPollNow] (negative: already closed).
pb.Poll pollOf({
  List<String> labels = const ['Red', 'Green', 'Blue'],
  List<int>? votes,
  int total = 0,
  bool visible = false,
  Duration closesIn = const Duration(days: 2),
  bool closed = false,
}) {
  return pb.Poll(
    choices: [
      for (var i = 0; i < labels.length; i++)
        pb.PollChoice(
          label: labels[i],
          votes: Int64(votes == null ? 0 : votes[i]),
        ),
    ],
    closesAt: ts.Timestamp.fromDateTime(kPollNow.add(closesIn)),
    totalVotes: Int64(total),
    resultsVisible: visible,
    closed: closed,
  );
}

/// A post view carrying [poll]; [choice] is `viewer_poll_choice` (index + 1).
pb.PostView pollPostView(
  int n, {
  required pb.Poll poll,
  int choice = 0,
  String authorId = 'u1',
}) {
  final base = postView(n, authorId: authorId, text: 'Pick one');
  base.post.poll = poll;
  base.viewerPollChoice = choice;
  return base;
}

/// The tapped choice of a vote request, for assertions.
int choiceOf(Object request) => (request as dynamic).choiceIndex as int;

void expectPercentsTotal100(List<int> percents) =>
    expect(percents.fold<int>(0, (a, b) => a + b), 100);
