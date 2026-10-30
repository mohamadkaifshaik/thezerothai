import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pbenum.dart';
import 'package:dzeroth/features/messages/presentation/widgets/message_bubble.dart';
import 'package:dzeroth/features/messages/presentation/widgets/request_banner.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/messaging_fixtures.dart';
import '../../../support/theme_harness.dart';

void main() {
  Widget bubble(
    pb.Message message, {
    bool first = true,
    bool last = true,
    void Function(Uri)? onOpenLink,
  }) => MessageBubble(
    message: message,
    peerName: 'Sam Rivera',
    now: kMsgBase.add(const Duration(minutes: 5)),
    firstOfGroup: first,
    lastOfGroup: last,
    onOpenLink: onOpenLink ?? (_) {},
  );

  group('semantics', () {
    testWidgets('own: "You said ..."', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpThemed(
        tester,
        bubble(msg(1, fromSelf: true, text: 'on my way')),
      );

      expect(find.bySemanticsLabel('You said on my way'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('peer: "<name> said ..., <time>"', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpThemed(tester, bubble(msg(1, text: 'see you')));

      expect(
        find.bySemanticsLabel('Sam Rivera said see you, 5 minutes ago'),
        findsOneWidget,
      );
      handle.dispose();
    });

    testWidgets('the peer time under the bubble is not read twice', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpThemed(tester, bubble(msg(1, text: 'see you')));

      expect(find.byKey(MessageBubble.timeKey), findsOneWidget);
      expect(
        tester.getSemantics(find.byKey(MessageBubble.timeKey)).label,
        isNot(contains(':')),
        reason: 'the clock text is excluded; the bubble label has the time',
      );
      handle.dispose();
    });

    testWidgets('each link is an "Open link" action on the bubble', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      Uri? opened;
      await pumpThemed(
        tester,
        bubble(
          msg(1, text: 'read https://example.com/a and https://dzeroth.app'),
          onOpenLink: (u) => opened = u,
        ),
      );

      final data = tester
          .getSemantics(find.bySemanticsLabel(RegExp('Sam Rivera said')))
          .getSemanticsData();
      expect(data.customSemanticsActionIds, hasLength(2));
      expect(opened, isNull);
      handle.dispose();
    });

    testWidgets('tombstones read as their words', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpThemed(
        tester,
        Column(
          children: [
            bubble(
              msg(1).deepCopy()
                ..state = MessageState.MESSAGE_STATE_DELETED_ACCOUNT
                ..text = '',
            ),
            bubble(
              msg(2).deepCopy()
                ..state = MessageState.MESSAGE_STATE_REMOVED
                ..text = '',
            ),
          ],
        ),
      );

      expect(
        find.bySemanticsLabel('Message deleted, 5 minutes ago'),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel('This message was removed, 5 minutes ago'),
        findsOneWidget,
      );
      handle.dispose();
    });
  });

  group('look', () {
    testWidgets('own is accent with white text; the peer\'s is raised', (
      tester,
    ) async {
      await pumpThemed(
        tester,
        Column(
          children: [
            bubble(msg(1, fromSelf: true, text: 'mine')),
            bubble(msg(2, text: 'theirs')),
          ],
        ),
      );
      final colors = Theme.of(tester.element(find.text('mine'))).colorScheme;

      Color fill(int n) =>
          (tester
                      .widget<DecoratedBox>(
                        find.byKey(ValueKey('bubble-${hexId(n)}')),
                      )
                      .decoration
                  as BoxDecoration)
              .color!;
      expect(fill(1), const Color(0xFF1D9BF0));
      expect(fill(1), colors.primary);
      expect(fill(2), colors.surfaceContainerHigh);
      final mine = tester.widget<Text>(
        find.descendant(
          of: find.byKey(ValueKey('bubble-${hexId(1)}')),
          matching: find.byType(Text),
        ),
      );
      expect(mine.textSpan!.style?.color, const Color(0xFFFFFFFF));
    });

    testWidgets('tombstones are italic and muted', (tester) async {
      await pumpThemed(
        tester,
        bubble(
          msg(1).deepCopy()
            ..state = MessageState.MESSAGE_STATE_REMOVED
            ..text = '',
        ),
      );

      final text = tester.widget<Text>(find.text('This message was removed'));
      expect(text.style?.fontStyle, FontStyle.italic);
      expect(
        text.style?.color,
        Theme.of(tester.element(find.byType(MessageBubble)))
            .colorScheme
            .onSurfaceVariant,
      );
    });

    testWidgets('the time shows under the last bubble of a group only', (
      tester,
    ) async {
      await pumpThemed(
        tester,
        Column(
          children: [bubble(msg(1), last: false), bubble(msg(2), first: false)],
        ),
      );

      expect(find.byKey(MessageBubble.timeKey), findsOneWidget);
    });

    testWidgets('the bubble is at most 80% of the row', (tester) async {
      await pumpThemed(
        tester,
        bubble(msg(1, text: 'word ' * 80)),
        size: const Size(400, 800),
      );

      final width = tester
          .getSize(find.byKey(ValueKey('bubble-${hexId(1)}')))
          .width;
      expect(width, lessThanOrEqualTo((400 - 2 * AppSpacing.md) * 0.8 + 0.01));
    });
  });

  group('links', () {
    testWidgets(
      'only link spans are tappable; mentions and hashtags are plain',
      (tester) async {
        Uri? opened;
        await pumpThemed(
          tester,
          bubble(
            msg(1, text: 'hi @sam #tag https://example.com/x'),
            onOpenLink: (u) => opened = u,
          ),
        );

        final spans = <TextSpan>[];
        tester
            .widget<RichText>(
              find
                  .descendant(
                    of: find.byType(MessageText),
                    matching: find.byType(RichText),
                  )
                  .first,
            )
            .text
            .visitChildren((s) {
              if (s is TextSpan) spans.add(s);
              return true;
            });
        final tappable = spans.where((s) => s.recognizer != null).toList();
        expect(tappable, hasLength(1));
        expect(tappable.single.text, 'https://example.com/x');

        (tappable.single.recognizer! as TapGestureRecognizer).onTap!();
        expect(opened, Uri.parse('https://example.com/x'));
      },
    );

    testWidgets('linksEnabled false (W7-35 L-9): plain text, no tap, no '
        '"Open link" action', (tester) async {
      final handle = tester.ensureSemantics();
      var opened = 0;
      await pumpThemed(
        tester,
        MessageBubble(
          message: msg(1, text: 'see https://example.com/x'),
          peerName: 'Sam Rivera',
          now: kMsgBase.add(const Duration(minutes: 5)),
          firstOfGroup: true,
          lastOfGroup: true,
          onOpenLink: (_) => opened++,
          linksEnabled: false,
        ),
      );

      expect(find.textContaining('https://example.com/x'), findsOneWidget);
      final spans = <TextSpan>[];
      tester
          .widget<RichText>(
            find
                .descendant(
                  of: find.byType(MessageText),
                  matching: find.byType(RichText),
                )
                .first,
          )
          .text
          .visitChildren((s) {
            if (s is TextSpan && (s.recognizer != null || s.style != null)) {
              spans.add(s);
            }
            return true;
          });
      expect(spans.where((s) => s.recognizer != null), isEmpty);
      final data = tester
          .getSemantics(find.bySemanticsLabel(RegExp('Sam Rivera said')))
          .getSemanticsData();
      expect(data.customSemanticsActionIds, isEmpty);
      expect(opened, 0);
      handle.dispose();
    });

    test('messageLinksEnabled: a REQUEST holds the peer\'s links back, and so '
        'does a missing header', () {
      final request = conv(
        'c1',
        state: ConversationState.CONVERSATION_STATE_REQUEST,
      );
      final accepted = conv(
        'c1',
        state: ConversationState.CONVERSATION_STATE_ACCEPTED,
      );
      expect(messageLinksEnabled(request, msg(1)), isFalse);
      expect(messageLinksEnabled(null, msg(1)), isFalse);
      expect(messageLinksEnabled(accepted, msg(1)), isTrue);
      expect(messageLinksEnabled(request, msg(1, fromSelf: true)), isTrue);
    });

    testWidgets('a javascript: link is plain text', (tester) async {
      await pumpThemed(tester, bubble(msg(1, text: 'javascript:alert(1)')));

      final spans = <TextSpan>[];
      tester
          .widget<RichText>(
            find
                .descendant(
                  of: find.byType(MessageText),
                  matching: find.byType(RichText),
                )
                .first,
          )
          .text
          .visitChildren((s) {
            if (s is TextSpan) spans.add(s);
            return true;
          });
      expect(spans.where((s) => s.recognizer != null), isEmpty);
    });
  });

  forEachThemeAndWidth('bubbles fit at every width, theme and text scale', (
    tester,
    env,
  ) async {
    await pumpThemed(
      tester,
      ListView(
        children: [
          bubble(msg(1, text: 'a long message ' * 20), last: false),
          bubble(msg(2, text: 'https://example.com/${'x' * 80}'), first: false),
          bubble(msg(3, fromSelf: true, text: 'reply ' * 30)),
        ],
      ),
      brightness: env.brightness,
      size: env.size,
      textScale: env.textScale,
    );

    expect(tester.takeException(), isNull);
  }, textScales: kMatrixTextScalesLarge);
}
