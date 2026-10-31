import 'package:dzeroth/features/engagement/domain/poll_display.dart';
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:dzeroth/shared/widgets/poll_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/poll_fixtures.dart';
import '../../support/theme_harness.dart';

const _long = 'A choice label of exactly 25';

pb.Poll _results() => pollOf(
  labels: [_long, 'B', 'C'],
  votes: [5, 4, 3],
  total: 12,
  visible: true,
);

PollDisplay _display(
  pb.Poll poll, {
  int viewerChoice = 0,
  int? pending,
  bool blocked = false,
  bool changing = false,
  bool limit = false,
}) => PollDisplay.of(
  poll: poll,
  viewerChoice: viewerChoice,
  isAuthor: false,
  now: kPollNow,
  canVote: true,
  pendingChoice: pending,
  blocked: blocked,
  changing: changing,
  changeLimitReached: limit,
);

/// W6-37 (ADR-0029 Amendment 1 A2.8): the poll card after a vote.
void main() {
  final cases = <String, PollDisplay Function()>{
    'voted, Change vote offered': () => _display(_results(), viewerChoice: 1),
    'changing: pills with the check and Cancel': () =>
        _display(_results(), viewerChoice: 1, changing: true),
    'change in flight': () => _display(_results(), viewerChoice: 1, pending: 2),
    'blocked, never voted': () => _display(pollOf(total: 3), blocked: true),
    'blocked, voted': () =>
        _display(_results(), viewerChoice: 1, blocked: true),
  };

  for (final entry in cases.entries) {
    forEachThemeAndWidth('poll card ${entry.key} fits', (tester, env) async {
      await pumpThemed(
        tester,
        SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: PollCard(
              display: entry.value(),
              now: kPollNow,
              onVote: (_) {},
              onChangeVote: () {},
              onCancelChange: () {},
            ),
          ),
        ),
        brightness: env.brightness,
        size: env.size,
        textScale: env.textScale,
      );
      expect(tester.takeException(), isNull);
    }, textScales: kMatrixTextScalesLarge);
  }

  group('copy and semantics', () {
    Future<void> pump(
      WidgetTester tester,
      PollDisplay d, {
      VoidCallback? onChange,
      VoidCallback? onCancel,
      ValueChanged<int>? onVote,
      String? reason,
    }) => pumpThemed(
      tester,
      PollCard(
        display: d,
        now: kPollNow,
        onVote: onVote,
        onChangeVote: onChange,
        onCancelChange: onCancel,
        blockedReason: reason,
      ),
    );

    testWidgets('the footer ends with Change vote, spoken "Change your vote"', (
      tester,
    ) async {
      var taps = 0;
      await pump(
        tester,
        _display(_results(), viewerChoice: 1),
        onChange: () => taps++,
      );
      expect(find.textContaining('12 votes'), findsOneWidget);
      expect(find.text('Change vote'), findsOneWidget);
      expect(find.bySemanticsLabel('Change your vote'), findsOneWidget);
      final size = tester.getSize(
        find.byKey(const ValueKey('poll-change-vote')),
      );
      expect(size.height, greaterThanOrEqualTo(48));
      await tester.tap(find.byKey(const ValueKey('poll-change-vote')));
      expect(taps, 1);
    });

    testWidgets('no onChangeVote: no control', (tester) async {
      await pump(tester, _display(_results(), viewerChoice: 1));
      expect(find.byKey(const ValueKey('poll-change-vote')), findsNothing);
    });

    testWidgets('changing: pills, the check on the current, Cancel', (
      tester,
    ) async {
      final votes = <int>[];
      var cancels = 0;
      await pump(
        tester,
        _display(_results(), viewerChoice: 2, changing: true),
        onVote: votes.add,
        onCancel: () => cancels++,
        onChange: () {},
      );
      expect(find.byIcon(Icons.check_circle), findsOneWidget);
      expect(find.byKey(const ValueKey('poll-change-vote')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('poll-choice-2')));
      expect(votes, [2]);
      await tester.tap(find.byKey(const ValueKey('poll-cancel-change')));
      expect(cancels, 1);
    });

    testWidgets('blocked: the reason shows and the choices do not vote', (
      tester,
    ) async {
      final votes = <int>[];
      await pump(
        tester,
        _display(pollOf(total: 3), blocked: true),
        onVote: votes.add,
        reason: 'You blocked @ava. Unblock to vote.',
      );
      expect(find.text('You blocked @ava. Unblock to vote.'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('poll-choice-0')));
      expect(votes, isEmpty);
    });
  });
}
