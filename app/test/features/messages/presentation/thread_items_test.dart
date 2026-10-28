import 'package:dzeroth/features/messages/presentation/thread_items.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/messaging_fixtures.dart';

void main() {
  List<String> shape(List<ThreadItem> items) => [
    for (final item in items)
      switch (item) {
        MessageItem(:final firstOfGroup, :final lastOfGroup, :final message) =>
          '${message.fromSelf ? 'me' : 'peer'}'
              '${firstOfGroup ? ' first' : ''}${lastOfGroup ? ' last' : ''}',
        DaySeparatorItem() => 'day',
      },
  ];

  test('no messages, no rows', () {
    expect(buildThreadItems(const []), isEmpty);
  });

  test(
    'rows are newest first; a day separator sits above its first message',
    () {
      final items = buildThreadItems([
        msg(2, secondsAgo: 0),
        msg(1, secondsAgo: 10),
      ]);

      // Reversed list: index 0 is the newest, the separator is the last row.
      expect((items.first as MessageItem).message.id, hexId(2));
      expect(items.last, isA<DaySeparatorItem>());
      expect(items, hasLength(3));
    },
  );

  test('grouped by sender; the newest of a group shows the time', () {
    final items = buildThreadItems([
      msg(4, fromSelf: true, secondsAgo: 0),
      msg(3, secondsAgo: 5),
      msg(2, secondsAgo: 10),
      msg(1, secondsAgo: 15),
    ]);

    expect(shape(items), [
      'me first last',
      'peer last',
      'peer',
      'peer first',
      'day',
    ]);
  });

  test('a new day starts a new group and a separator, even for one sender', () {
    const twoDays = 2 * 24 * 3600;
    final items = buildThreadItems([
      msg(2, secondsAgo: 0),
      msg(1, secondsAgo: twoDays),
    ]);

    expect(shape(items), ['peer first last', 'day', 'peer first last', 'day']);
  });

  test('keys are stable and unique', () {
    final items = buildThreadItems(msgs(1, 30));

    expect({for (final i in items) i.key}, hasLength(items.length));
    expect(items.first.key, 'message-${hexId(30)}');
    expect(buildThreadItems(msgs(1, 30)).first.key, items.first.key);
  });

  group('formatDaySeparator', () {
    test('Today, Yesterday, then a date', () {
      final now = DateTime(
        kMsgBase.toLocal().year,
        kMsgBase.toLocal().month,
        kMsgBase.toLocal().day,
        12,
      );
      DateTime day(int back) => DateTime(now.year, now.month, now.day - back);

      expect(formatDaySeparator(day(0), now), 'Today');
      expect(formatDaySeparator(day(1), now), 'Yesterday');
      expect(formatDaySeparator(day(2), now), isNot('Yesterday'));
      expect(formatDaySeparator(day(2), now), isNot('Today'));
    });

    test('another year spells the year, the same year does not', () {
      final year = kMsgBase.toLocal().year;
      final now = DateTime(year, 6, 15, 12);

      expect(
        formatDaySeparator(DateTime(year - 1, 3, 4), now),
        contains('${year - 1}'),
      );
      expect(
        formatDaySeparator(DateTime(year, 3, 4), now),
        isNot(contains('$year')),
      );
    });
  });
}
