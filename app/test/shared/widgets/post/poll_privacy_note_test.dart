import 'dart:io';

import 'package:dzeroth/features/engagement/domain/poll_display.dart';
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:dzeroth/shared/widgets/post/poll_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/poll_fixtures.dart';
import '../../../support/theme_harness.dart';

const _line = 'Individual choices are hidden from other users';

PollDisplay _display(pb.Poll poll, {int viewerChoice = 0}) => PollDisplay.of(
  poll: poll,
  viewerChoice: viewerChoice,
  isAuthor: false,
  now: kPollNow,
  canVote: true,
);

// Shown in the results state only: that is where counts are on screen and a
// small poll can give a choice away. The vote and hidden states show no counts.
void main() {
  pb.Poll results() => pollOf(
    labels: ['A choice label of exactly 25', 'B', 'C'],
    votes: [5, 4, 3],
    total: 12,
    visible: true,
  );

  testWidgets('results state shows the privacy line', (tester) async {
    await pumpThemed(
      tester,
      PollCard(display: _display(results(), viewerChoice: 1), now: kPollNow),
    );
    expect(find.text(_line), findsOneWidget);
    expect(find.byKey(const ValueKey('poll-privacy-note')), findsOneWidget);
  });

  testWidgets('vote and counts-hidden states do not show it', (tester) async {
    await pumpThemed(
      tester,
      PollCard(
        display: _display(pollOf(total: 3)),
        now: kPollNow,
        onVote: (_) {},
      ),
    );
    expect(find.text(_line), findsNothing);
    await pumpThemed(
      tester,
      PollCard(
        display: _display(pollOf(total: 3), viewerChoice: 1),
        now: kPollNow,
      ),
    );
    expect(find.text(_line), findsNothing);
  });

  testWidgets('no anonymous wording in the rendered card', (tester) async {
    await pumpThemed(
      tester,
      PollCard(display: _display(results()), now: kPollNow),
    );
    final texts = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data ?? '')
        .join(' ');
    expect(texts.toLowerCase(), isNot(contains('anonym')));
    expect(kPollPrivacyNote.toLowerCase(), isNot(contains('anonym')));
  });

  test('no poll source says anonymous', () {
    for (final path in [
      'lib/shared/widgets/post/poll_card.dart',
      'lib/features/engagement/presentation/widgets/post_poll.dart',
    ]) {
      expect(
        File(path).readAsStringSync().toLowerCase(),
        isNot(contains('anonym')),
        reason: path,
      );
    }
  });

  forEachThemeAndWidth('results with the line fits at 360 dp and 2.0 scale', (
    tester,
    env,
  ) async {
    await pumpThemed(
      tester,
      SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: PollCard(display: _display(results()), now: kPollNow),
        ),
      ),
      brightness: env.brightness,
      size: env.size,
      textScale: env.textScale,
    );
    expect(tester.takeException(), isNull);
    expect(find.text(_line), findsOneWidget);
  }, textScales: kMatrixTextScalesLarge);
}
