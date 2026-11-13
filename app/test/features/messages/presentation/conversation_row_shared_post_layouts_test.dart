import 'package:dzeroth/features/messages/presentation/widgets/conversation_row.dart';
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/messaging_fixtures.dart';
import '../../../support/theme_harness.dart';

const _url = 'https://dzeroth.com/post/1234567890123456789';

/// The inbox row of a conversation whose last message shares a post: the
/// preview reads "Shared a post" (never the link, never the post's text) at
/// every width, in both themes and at large text.
void main() {
  pb.Conversation shared({
    String snippet = _url,
    bool fromSelf = false,
    bool unread = false,
  }) {
    final c = conv(
      'a',
      snippet: snippet,
      fromSelf: fromSelf,
      unread: unread ? 2 : 0,
    );
    c.lastMessage.sharedPost = true;
    return c;
  }

  Widget row(pb.Conversation c) => ConversationRow(
    conversation: c,
    now: kMsgBase.add(const Duration(minutes: 5)),
    onTap: () {},
  );

  forEachThemeAndWidth(
    '"Shared a post" in the inbox row, no overflow',
    (tester, env) async {
      final handle = tester.ensureSemantics();
      await pumpThemed(
        tester,
        row(shared(unread: true)),
        size: env.size,
        brightness: env.brightness,
        textScale: env.textScale,
      );

      expect(tester.takeException(), isNull);
      expect(find.text('Shared a post'), findsOneWidget);
      expect(find.textContaining('dzeroth.com'), findsNothing);
      expect(
        find.bySemanticsLabel(RegExp('Shared a post.*unread')),
        findsOneWidget,
      );
      handle.dispose();
    },
    widths: const [390, 1024, 1440],
    textScales: const [1.0, 2.0],
  );

  testWidgets('the caller\'s own share reads "You: Shared a post"', (
    tester,
  ) async {
    await pumpThemed(tester, row(shared(fromSelf: true)));
    expect(find.text('You: Shared a post'), findsOneWidget);
  });

  testWidgets('a caption is the preview and the link is not', (tester) async {
    await pumpThemed(tester, row(shared(snippet: 'you will like this')));
    expect(find.text('you will like this'), findsOneWidget);
    expect(find.text('Shared a post'), findsNothing);
  });

  testWidgets('a plain message that is only a link stays a link', (
    tester,
  ) async {
    await pumpThemed(tester, row(conv('a', snippet: _url)));
    expect(find.text(_url), findsOneWidget);
    expect(find.text('Shared a post'), findsNothing);
  });
}
