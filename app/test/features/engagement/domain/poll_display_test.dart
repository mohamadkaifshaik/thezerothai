import 'package:dzeroth/features/engagement/domain/poll_display.dart';
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:flutter_test/flutter_test.dart';

import '../../../support/poll_fixtures.dart';

PollDisplay _display(
  pb.Poll poll, {
  int viewerChoice = 0,
  bool isAuthor = false,
  bool canVote = true,
  int? pending,
  int? known,
  bool forceClosed = false,
  bool blocked = false,
  bool changing = false,
  bool limit = false,
  Duration shift = Duration.zero,
}) => PollDisplay.of(
  poll: poll,
  viewerChoice: viewerChoice,
  isAuthor: isAuthor,
  now: kPollNow.add(shift),
  canVote: canVote,
  pendingChoice: pending,
  knownChoice: known,
  forceClosed: forceClosed,
  blocked: blocked,
  changing: changing,
  changeLimitReached: limit,
);

void main() {
  group('largestRemainderPercents', () {
    test('always totals 100', () {
      for (final votes in [
        [1, 1, 1],
        [1, 2, 4],
        [33, 33, 34],
        [1, 0, 0, 0],
        [7, 7, 7, 7],
        [5, 1],
      ]) {
        expectPercentsTotal100(largestRemainderPercents(votes));
      }
      expect(largestRemainderPercents([1, 1, 1]), [34, 33, 33]);
    });

    test('no votes is zeros, never a division', () {
      expect(largestRemainderPercents([0, 0, 0]), [0, 0, 0]);
      expect(largestRemainderPercents([]), isEmpty);
    });
  });

  group('mode', () {
    test('open, not voted, may vote: buttons', () {
      final d = _display(pollOf(total: 4));
      expect(d.mode, PollMode.vote);
      expect(d.showsBars, isFalse);
      expect(d.percents, isEmpty);
      expect(d.totalVotes, 4);
    });

    test('hidden counts are zeros: no bar is drawn from them', () {
      final d = _display(pollOf(total: 9), viewerChoice: 2);
      expect(d.mode, PollMode.votedHidden);
      expect(d.myChoice, 1);
      expect(d.percents, isEmpty);
    });

    test('results: bars, ties bold all, check on mine', () {
      final d = _display(
        pollOf(votes: [3, 3, 1], total: 7, visible: true),
        viewerChoice: 3,
      );
      expect(d.mode, PollMode.results);
      expectPercentsTotal100(d.percents);
      expect(d.leading, {0, 1});
      expect(d.myChoice, 2);
    });

    test('results with no votes: no choice is bold', () {
      final d = _display(pollOf(votes: [0, 0, 0], visible: true));
      expect(d.leading, isEmpty);
      expect(d.percents, [0, 0, 0]);
    });

    test('the author gets no buttons', () {
      expect(_display(pollOf(), isAuthor: true).mode, PollMode.readOnly);
    });

    test('engagement off or voting refused: no buttons', () {
      expect(_display(pollOf(), canVote: false).mode, PollMode.readOnly);
    });

    test('a cached row past closes_at with hidden counts: final results', () {
      final d = _display(pollOf(), shift: const Duration(days: 3));
      expect(d.closed, isTrue);
      expect(d.mode, PollMode.finalPending);
    });

    test('closed by the server or by POLL_CLOSED', () {
      expect(_display(pollOf(closed: true)).mode, PollMode.finalPending);
      expect(_display(pollOf(), forceClosed: true).mode, PollMode.finalPending);
      final closedWithCounts = pollOf(
        visible: true,
        votes: [1, 0, 0],
        total: 1,
        closed: true,
      );
      expect(_display(closedWithCounts).mode, PollMode.results);
    });

    test('a vote in flight: check, one more vote, no bars', () {
      final d = _display(pollOf(total: 4), pending: 1);
      expect(d.mode, PollMode.votedHidden);
      expect(d.pending, isTrue);
      expect(d.myChoice, 1);
      expect(d.totalVotes, 5);
      expect(d.percents, isEmpty);
    });

    test('a choice the server named (ALREADY_VOTED) before the re-read', () {
      final d = _display(pollOf(total: 4), known: 2);
      expect(d.mode, PollMode.votedHidden);
      expect(d.myChoice, 2);
    });

    test('a choice the server named beats a stale row (a refused change)', () {
      final poll = pollOf(votes: [5, 4, 3], total: 12, visible: true);
      final d = _display(poll, viewerChoice: 1, known: 2);
      expect(d.myChoice, 2);
      expect(d.committedChoice, 2);
      expect(d.mode, PollMode.results);
    });

    test('Change vote needs an open poll, a vote, counts and no block', () {
      final poll = pollOf(votes: [5, 4, 3], total: 12, visible: true);
      expect(_display(poll, viewerChoice: 1).canChange, isTrue);
      expect(_display(poll).canChange, isFalse, reason: 'never voted');
      expect(_display(poll, viewerChoice: 1, blocked: true).canChange, isFalse);
      expect(_display(poll, viewerChoice: 1, limit: true).canChange, isFalse);
      expect(
        _display(poll, viewerChoice: 1, isAuthor: true).canChange,
        isFalse,
      );
      expect(
        _display(poll, viewerChoice: 1, canVote: false).canChange,
        isFalse,
      );
      expect(
        _display(pollOf(total: 3), viewerChoice: 1).canChange,
        isFalse,
        reason: 'counts hidden',
      );
      final closed = pollOf(
        votes: [1, 0, 0],
        total: 1,
        visible: true,
        closesIn: const Duration(hours: -1),
      );
      expect(_display(closed, viewerChoice: 1).canChange, isFalse);
    });

    test(
      'tapping Change vote shows the pills with the check and the percents',
      () {
        final poll = pollOf(votes: [5, 4, 3], total: 12, visible: true);
        final d = _display(poll, viewerChoice: 1, changing: true);
        expect(d.mode, PollMode.change);
        expect(d.myChoice, 0);
        expect(d.percents, isNotEmpty);
      },
    );

    test('a change in flight moves one vote and leaves the total', () {
      final poll = pollOf(votes: [5, 4, 3], total: 12, visible: true);
      final d = _display(poll, viewerChoice: 1, pending: 2);
      expect(d.pendingChange, isTrue);
      expect(d.mode, PollMode.results);
      expect(d.totalVotes, 12);
      expect(d.myChoice, 2);
      expect(d.committedChoice, 0);
      expect(d.percents, [34, 33, 33]); // 4 / 4 / 4 of 12
      expectPercentsTotal100(d.percents);
    });

    test('blocked and never voted: labels only, counts stay hidden', () {
      final d = _display(pollOf(total: 3), blocked: true);
      expect(d.mode, PollMode.readOnly);
      expect(d.blocked, isTrue);
      expect(d.percents, isEmpty);
    });

    test('blocked and voted: the check and the results, no control', () {
      final poll = pollOf(votes: [5, 4, 3], total: 12, visible: true);
      final d = _display(poll, viewerChoice: 2, blocked: true);
      expect(d.mode, PollMode.results);
      expect(d.myChoice, 1);
      expect(d.canChange, isFalse);
    });

    test('an out-of-range viewer choice is ignored', () {
      final d = _display(pollOf(), viewerChoice: 9);
      expect(d.myChoice, isNull);
      expect(d.mode, PollMode.vote);
    });
  });
}
