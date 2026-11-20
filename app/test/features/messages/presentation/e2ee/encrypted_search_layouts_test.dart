import 'package:dzeroth/features/messages/domain/e2ee/encrypted_messaging.dart';
import 'package:dzeroth/features/messages/presentation/widgets/message_search_panel.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../support/encrypted_search_rig.dart';
import '../../../../support/messaging_fixtures.dart';

// The panel's three looks stay as they are with encrypted hits drawn beside
// the cache's: one group per conversation, at every width and text size.

const _sizes = <String, Size>{
  'phone': Size(390, 844),
  'tablet': Size(1024, 768),
  'desktop': Size(1440, 900),
};

Finder _row(String text) =>
    find.byWidgetPredicate((w) => w is HighlightedMatch && w.text == text);

EncryptedSearchRig _rig() {
  final rig = EncryptedSearchRig(
    conversations: [conv('c1'), conv('c2')],
    messages: {
      'c1': [msg(1, secondsAgo: 500, text: 'cache needle in the first chat')],
    },
  );
  rig.port.setSearchHits([
    EncryptedSearchHit(
      conversationId: 'c1',
      messageId: 'mv1',
      at: kMsgBase.subtract(const Duration(seconds: 10)),
      mine: true,
      text: 'a very long vault needle ${'and more words ' * 12}',
    ),
    EncryptedSearchHit(
      conversationId: 'c2',
      messageId: 'mv2',
      at: kMsgBase.subtract(const Duration(seconds: 20)),
      mine: false,
      text: 'vault needle elsewhere',
    ),
  ]);
  return rig;
}

void main() {
  for (final MapEntry(key: name, value: size) in _sizes.entries) {
    group('$name (${size.width.toInt()} dp)', () {
      for (final scale in [1.0, 2.0]) {
        testWidgets('list search with vault hits, ${scale}x text', (
          tester,
        ) async {
          final rig = _rig();
          await rig.pump(tester, size: size, textScale: scale);
          await rig.type(tester, 'needle');
          expect(find.text('Peer c1'), findsOneWidget);
          expect(find.text('Peer c2'), findsOneWidget);
          expect(_row('cache needle in the first chat'), findsOneWidget);
          expect(_row('vault needle elsewhere'), findsOneWidget);
          expect(tester.takeException(), isNull);
        });
      }

      testWidgets('list search with vault hits, right to left', (tester) async {
        final rig = _rig();
        await rig.pump(
          tester,
          size: size,
          textScale: 2,
          textDirection: TextDirection.rtl,
        );
        await rig.type(tester, 'needle');
        expect(_row('vault needle elsewhere'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('chat search with vault hits', (tester) async {
        final rig = _rig();
        await rig.pump(tester, size: size, conversationId: 'c1');
        await rig.type(tester, 'needle');
        expect(_row('vault needle elsewhere'), findsNothing);
        expect(find.byType(HighlightedMatch), findsNWidgets(2));
        expect(tester.takeException(), isNull);
      });
    });
  }
}
