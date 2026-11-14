import 'package:dzeroth/features/messages/domain/message_search.dart';
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pbenum.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/messaging_fixtures.dart';

List<ConversationHits> _search(
  String query,
  List<pb.Conversation> conversations,
  Map<String, List<pb.Message>> messages,
) => searchMessages(
  conversations: conversations,
  messagesByConversation: messages,
  query: query,
);

void main() {
  group('matchRanges', () {
    test('is case-insensitive and returns ranges of the original text', () {
      expect(matchRanges('Hello HELLO hello', 'hElLo'), const [
        SearchRange(0, 5),
        SearchRange(6, 11),
        SearchRange(12, 17),
      ]);
    });

    test('blank query and empty text match nothing', () {
      expect(matchRanges('abc', '  '), isEmpty);
      expect(matchRanges('', 'a'), isEmpty);
    });

    test('ranges stay on the original when lower-casing changes length', () {
      // "İ".toLowerCase() is two code units; the range must still cover the
      // one original code point and later offsets must not shift.
      const text = 'İstanbul and Istanbul';
      final ranges = matchRanges(text, 'istanbul');
      expect(ranges, isNotEmpty);
      final last = ranges.last;
      expect(text.substring(last.start, last.end), 'Istanbul');
      for (final r in ranges) {
        expect(r.end, lessThanOrEqualTo(text.length));
      }
    });

    test('ranges are correct after emoji (surrogate pairs)', () {
      const text = '\u{1F600} hi \u{1F600} Hi';
      final ranges = matchRanges(text, 'hi');
      expect(ranges.map((r) => text.substring(r.start, r.end)), ['hi', 'Hi']);
      expect(ranges.first.start, 3);
    });

    test('a query that is an emoji matches whole code points', () {
      const text = 'a \u{1F600} b';
      final r = matchRanges(text, '\u{1F600}').single;
      expect(text.substring(r.start, r.end), '\u{1F600}');
    });
  });

  group('snippetAround', () {
    test('short text is unchanged', () {
      final s = snippetAround('hello', const [SearchRange(0, 5)]);
      expect(s.text, 'hello');
      expect(s.ranges, const [SearchRange(0, 5)]);
    });

    test('long text is windowed and ranges are moved into the window', () {
      final text = '${'x' * 300}needle${'y' * 300}';
      final ranges = matchRanges(text, 'needle');
      final s = snippetAround(text, ranges);
      expect(s.text.length, lessThan(200));
      final r = s.ranges.single;
      expect(s.text.substring(r.start, r.end), 'needle');
      expect(s.text.startsWith('\u2026'), isTrue);
      expect(s.text.endsWith('\u2026'), isTrue);
    });
  });

  group('searchMessages never matches', () {
    final c1 = conv('c1');

    test('a visible message in an open conversation matches', () {
      final groups = _search(
        'hello',
        [c1],
        {
          'c1': [msg(1, text: 'Hello there')],
        },
      );
      expect(groups.single.hits.single.ranges, const [SearchRange(0, 5)]);
    });

    test('deleted-account, removed and unspecified messages', () {
      for (final state in [
        MessageState.MESSAGE_STATE_DELETED_ACCOUNT,
        MessageState.MESSAGE_STATE_REMOVED,
        MessageState.MESSAGE_STATE_UNSPECIFIED,
      ]) {
        final m = msg(1, text: 'secret word')..state = state;
        expect(
          _search(
            'secret',
            [c1],
            {
              'c1': [m],
            },
          ),
          isEmpty,
          reason: '$state',
        );
      }
    });

    test('a tombstone that kept text (defence in depth) is not matched', () {
      final m = msg(1, text: 'secret')
        ..state = MessageState.MESSAGE_STATE_REMOVED;
      expect(
        _search(
          'secret',
          [c1],
          {
            'c1': [m],
          },
        ),
        isEmpty,
      );
    });

    test('a conversation whose peer is blocked either way (can_reply off)', () {
      final blocked = conv('c2')..canReply = false;
      expect(
        _search(
          'hello',
          [blocked],
          {
            'c2': [msg(1, conversationId: 'c2', text: 'hello')],
          },
        ),
        isEmpty,
      );
    });

    test('messages with no cached conversation header', () {
      expect(
        _search(
          'hello',
          [c1],
          {
            'orphan': [msg(1, conversationId: 'orphan', text: 'hello')],
          },
        ),
        isEmpty,
      );
    });

    test('a blank query', () {
      expect(
        _search(
          '   ',
          [c1],
          {
            'c1': [msg(1)],
          },
        ),
        isEmpty,
      );
    });
  });

  test('groups and hits are newest first, one group per conversation', () {
    final groups = _search(
      'hi',
      [conv('a'), conv('b')],
      {
        'a': [
          msg(1, conversationId: 'a', secondsAgo: 100, text: 'hi old'),
          msg(2, conversationId: 'a', secondsAgo: 50, text: 'hi newer'),
        ],
        'b': [msg(3, conversationId: 'b', secondsAgo: 10, text: 'hi newest')],
      },
    );
    expect(groups.map((g) => g.conversation.id), ['b', 'a']);
    expect(groups.last.hits.map((h) => h.message.text), ['hi newer', 'hi old']);
  });
}
