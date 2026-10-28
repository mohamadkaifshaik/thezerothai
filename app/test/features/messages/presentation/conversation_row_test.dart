import 'package:dzeroth/features/messages/presentation/widgets/conversation_row.dart';
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pbenum.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/messaging_fixtures.dart';
import '../../../support/theme_harness.dart';

void main() {
  final now = kMsgBase.add(const Duration(minutes: 5));

  Future<void> pumpRow(
    WidgetTester tester,
    ConversationRow row, {
    Brightness brightness = Brightness.light,
    double textScale = 1,
    double width = 400,
  }) => pumpThemed(
    tester,
    row,
    brightness: brightness,
    textScale: textScale,
    size: Size(width, 800),
  );

  group('conversationSnippet', () {
    test('a peer message is shown as is', () {
      expect(conversationSnippet(conv('a', snippet: 'hi there')), 'hi there');
    });

    test('own messages get the "You: " prefix', () {
      expect(
        conversationSnippet(conv('a', snippet: 'on my way', fromSelf: true)),
        'You: on my way',
      );
    });

    test('tombstones read as text, never the empty snippet', () {
      expect(
        conversationSnippet(
          conv(
            'a',
            snippet: '',
            lastState: MessageState.MESSAGE_STATE_DELETED_ACCOUNT,
          ),
        ),
        kConversationDeletedSnippet,
      );
      expect(
        conversationSnippet(
          conv('a', snippet: '', lastState: MessageState.MESSAGE_STATE_REMOVED),
        ),
        kConversationRemovedSnippet,
      );
    });

    test('no preview yet is empty', () {
      expect(conversationSnippet(conv('a')), '');
    });
  });

  testWidgets('shows bold name, muted handle, relative time and snippet', (
    tester,
  ) async {
    await pumpRow(
      tester,
      ConversationRow(
        conversation: conv('a', snippet: 'hello', fromSelf: true),
        now: now,
      ),
    );

    expect(find.text('Peer a'), findsOneWidget);
    expect(find.text('@peera'), findsOneWidget);
    expect(find.text('5m'), findsOneWidget);
    expect(find.text('You: hello'), findsOneWidget);
    expect(find.byKey(ConversationRow.unreadDotKey), findsNothing);
    expect(find.byKey(ConversationRow.silentMarkerKey), findsNothing);
    final name = tester.widget<Text>(find.text('Peer a'));
    expect(name.style?.fontWeight, FontWeight.w700);
  });

  testWidgets('the row is 72dp high with a 48dp avatar and no divider', (
    tester,
  ) async {
    await pumpRow(
      tester,
      ConversationRow(
        conversation: conv('a', snippet: 'hello'),
        now: now,
      ),
    );

    expect(tester.getSize(find.byType(ConversationRow)).height, 72);
    expect(find.byType(Divider), findsNothing);
    expect(tester.getSize(find.byType(CircleAvatar).first), const Size(48, 48));
  });

  testWidgets('unread: bold snippet, accent dot and "unread" when spoken', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await pumpRow(
      tester,
      ConversationRow(
        conversation: conv('a', snippet: 'hello', unread: 2),
        now: now,
      ),
    );

    final snippet = tester.widget<Text>(find.text('hello'));
    expect(snippet.style?.fontWeight, FontWeight.w700);
    expect(find.byKey(ConversationRow.unreadDotKey), findsOneWidget);
    expect(
      tester.getSemantics(find.byType(ConversationRow)),
      matchesSemantics(
        label: 'Peer a, @peera, hello, 5 minutes ago, unread',
        isButton: false,
        hasTapAction: false,
      ),
    );
    handle.dispose();
  });

  testWidgets('a read row is not bold and says nothing of unread', (
    tester,
  ) async {
    await pumpRow(
      tester,
      ConversationRow(
        conversation: conv('a', snippet: 'hello'),
        now: now,
      ),
    );

    final snippet = tester.widget<Text>(find.text('hello'));
    expect(snippet.style?.fontWeight, FontWeight.w400);
    expect(find.byKey(ConversationRow.unreadDotKey), findsNothing);
  });

  testWidgets('silent: a muted marker, spoken as "muted"', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpRow(
      tester,
      ConversationRow(
        conversation: conv('a', snippet: 'hello', silent: true),
        now: now,
      ),
    );

    expect(find.byKey(ConversationRow.silentMarkerKey), findsOneWidget);
    expect(
      tester.getSemantics(find.byType(ConversationRow)).label,
      endsWith(', muted'),
    );
    handle.dispose();
  });

  testWidgets('with onTap the row is a button that calls it', (tester) async {
    var taps = 0;
    final handle = tester.ensureSemantics();
    await pumpRow(
      tester,
      ConversationRow(
        conversation: conv('a', snippet: 'hello'),
        now: now,
        onTap: () => taps++,
      ),
    );

    expect(
      tester.getSemantics(find.byType(ConversationRow)),
      isSemantics(isButton: true, hasTapAction: true),
    );
    await tester.tap(find.byType(ConversationRow));
    expect(taps, 1);
    handle.dispose();
  });

  forEachThemeAndWidth('a long name, handle and snippet never overflow', (
    tester,
    env,
  ) async {
    final long = conv('a', snippet: 'word ' * 60, unread: 1, silent: true);
    long.peer
      ..displayName = 'A very long display name that cannot possibly fit'
      ..handle = 'a_very_long_handle_that_cannot_fit_either';
    await pumpThemed(
      tester,
      ConversationRow(conversation: long, now: now),
      brightness: env.brightness,
      size: env.size,
      textScale: env.textScale,
    );

    expect(tester.takeException(), isNull);
    expect(
      tester.getSize(find.byType(ConversationRow)).height,
      greaterThanOrEqualTo(72),
    );
  }, textScales: kMatrixTextScalesLarge);
}
