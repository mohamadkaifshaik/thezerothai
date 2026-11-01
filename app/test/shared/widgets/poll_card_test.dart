import 'package:dzeroth/features/engagement/domain/poll_display.dart';
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:dzeroth/shared/widgets/poll_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/poll_fixtures.dart';
import '../../support/theme_harness.dart';

const _long = 'A choice label of exactly 25';

PollDisplay _display(
  pb.Poll poll, {
  int viewerChoice = 0,
  int? pending,
  Duration shift = Duration.zero,
}) => PollDisplay.of(
  poll: poll,
  viewerChoice: viewerChoice,
  isAuthor: false,
  now: kPollNow.add(shift),
  canVote: true,
  pendingChoice: pending,
);

void main() {
  final cases = <String, PollDisplay Function()>{
    'vote': () => _display(pollOf(labels: [_long, 'B', 'C', 'D'], total: 12)),
    'results': () => _display(
      pollOf(
        labels: [_long, 'B', 'C'],
        votes: [5, 4, 3],
        total: 12,
        visible: true,
      ),
      viewerChoice: 2,
    ),
    'voted, counts hidden': () => _display(pollOf(total: 3), viewerChoice: 1),
    'sending': () => _display(pollOf(total: 3), pending: 0),
    'final pending': () =>
        _display(pollOf(total: 3), shift: const Duration(days: 3)),
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
              onSeeFinalResults: () {},
            ),
          ),
        ),
        brightness: env.brightness,
        size: env.size,
        textScale: env.textScale,
      );
      expect(tester.takeException(), isNull);
      for (var i = 0; i < 2; i++) {
        final size = tester.getSize(find.byKey(ValueKey('poll-choice-$i')));
        expect(size.height, greaterThanOrEqualTo(48));
      }
    }, textScales: kMatrixTextScalesLarge);
  }

  group('copy and semantics', () {
    Future<void> pump(
      WidgetTester tester,
      PollDisplay d, {
      ValueChanged<int>? onVote,
      VoidCallback? onSee,
      VoidCallback? onChange,
    }) => pumpThemed(
      tester,
      PollCard(
        display: d,
        now: kPollNow,
        onVote: onVote,
        onSeeFinalResults: onSee,
        onChangeVote: onChange,
      ),
    );

    testWidgets('open and not voted: buttons and "N votes · 2 days left"', (
      tester,
    ) async {
      final taps = <int>[];
      await pump(tester, _display(pollOf(total: 1234)), onVote: taps.add);
      expect(find.text('1.23K votes · 2 days left'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('poll-choice-1')));
      expect(taps, [1]);
      expect(find.bySemanticsLabel('Vote for Green'), findsOneWidget);
    });

    testWidgets('results: percents total 100, check and bold on the leader', (
      tester,
    ) async {
      await pump(
        tester,
        _display(
          pollOf(
            votes: [1, 1, 1],
            total: 3,
            visible: true,
            closesIn: const Duration(days: 2),
          ),
          viewerChoice: 3,
        ),
        onChange: () {},
      );
      expect(find.text('34%'), findsOneWidget);
      expect(find.text('33%'), findsNWidgets(2));
      expect(find.byIcon(Icons.check_circle), findsOneWidget);
      expect(
        find.bySemanticsLabel('Blue, 33 percent, your vote'),
        findsOneWidget,
      );
      // A vote is no longer final (ADR-0029 Amendment 1): the card offers Change vote.
      expect(find.text('Change vote'), findsOneWidget);
      expect(find.bySemanticsLabel('Change your vote'), findsOneWidget);
    });

    testWidgets('closed with counts reads "Final results"', (tester) async {
      await pump(
        tester,
        _display(
          pollOf(votes: [2, 0, 0], total: 2, visible: true, closed: true),
        ),
      );
      expect(find.text('2 votes · Final results'), findsOneWidget);
      expect(find.text('See final results'), findsNothing);
    });

    testWidgets('final pending: the button asks once', (tester) async {
      var asked = 0;
      await pump(
        tester,
        _display(pollOf(total: 3), shift: const Duration(days: 3)),
        onSee: () => asked++,
      );
      await tester.tap(find.byKey(const ValueKey('poll-see-final')));
      expect(asked, 1);
      expect(find.byKey(const ValueKey('poll-choice-0')), findsOneWidget);
    });

    testWidgets('no buttons without onVote (author, engagement off)', (
      tester,
    ) async {
      await pump(tester, _display(pollOf(total: 1)));
      await tester.tap(find.byKey(const ValueKey('poll-choice-0')));
      expect(tester.takeException(), isNull);
    });
  });

  group('PollEmbedSummary', () {
    testWidgets('compact line and read-only options open the original', (
      tester,
    ) async {
      var opened = 0;
      await pumpThemed(
        tester,
        PollEmbedSummary(
          poll: pollOf(),
          now: kPollNow,
          showOptions: true,
          onOpen: () => opened++,
        ),
      );
      expect(find.text('Poll · 3 choices · ends in 2 days'), findsOneWidget);
      expect(find.text('Red'), findsOneWidget);
      await tester.tap(find.text('Red'));
      expect(opened, 1);
    });

    test('summary says ended once closed', () {
      expect(
        PollEmbedSummary.summary(
          pollOf(closesIn: const Duration(hours: -1)),
          kPollNow,
        ),
        'Poll · 3 choices · ended',
      );
    });
  });
}
