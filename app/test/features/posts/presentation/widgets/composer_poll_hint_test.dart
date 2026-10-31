import 'package:dzeroth/features/posts/domain/composer_draft.dart';
import 'package:dzeroth/features/posts/presentation/widgets/composer_poll_builder.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const poll = DraftPoll(choices: ['', ''], durationMinutes: 1440);

  Widget host({required bool open, required VoidCallback onRules}) {
    return MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: open
              ? ComposerPollBuilder(
                  poll: poll,
                  durationClamped: false,
                  enabled: true,
                  onChoiceChanged: (_, _) {},
                  onChoiceAdded: () {},
                  onChoiceRemoved: (_) {},
                  onLengthChanged: (_) {},
                  onRemove: () {},
                  openRules: (_) => onRules(),
                )
              : const SizedBox.shrink(),
        ),
      ),
    );
  }

  testWidgets('shows the sensitive-info hint with the builder and opens the '
      'rules on tap', (tester) async {
    var opened = 0;
    await tester.pumpWidget(host(open: true, onRules: () => opened++));

    final hint = find.byKey(const ValueKey('poll-sensitive-hint'));
    expect(hint, findsOneWidget);
    expect(find.textContaining(kPollSensitiveHint), findsOneWidget);
    expect(tester.getSize(hint).height, greaterThanOrEqualTo(48));

    await tester.tap(hint);
    expect(opened, 1);
  });

  testWidgets('is hidden when no poll builder is open', (tester) async {
    await tester.pumpWidget(host(open: false, onRules: () {}));
    expect(find.byKey(const ValueKey('poll-sensitive-hint')), findsNothing);
  });

  testWidgets('wraps without overflow at text scale 2.0 on a narrow screen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(
          size: Size(320, 900),
          textScaler: TextScaler.linear(2),
        ),
        child: host(open: true, onRules: () {}),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('poll-sensitive-hint')), findsOneWidget);
  });
}
