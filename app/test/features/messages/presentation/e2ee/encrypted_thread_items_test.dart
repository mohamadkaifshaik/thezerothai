import 'package:dzeroth/features/messages/domain/e2ee/encrypted_messaging.dart';
import 'package:dzeroth/features/messages/domain/e2ee/message_content_codec.dart';
import 'package:dzeroth/features/messages/presentation/e2ee/encrypted_thread_items.dart';
import 'package:dzeroth/features/messages/presentation/e2ee/encryption_copy.dart';
import 'package:dzeroth/features/messages/presentation/thread_items.dart';
import 'package:dzeroth/features/messages/presentation/widgets/message_bubble.dart'
    show kMessageDeletedText, kMessageRemovedText;
import 'package:flutter_test/flutter_test.dart';

// Local noon of today, so the tests hold in any time zone and never use a
// fixed date.
DateTime _noon([int daysAgo = 0]) {
  final n = DateTime.now();
  return DateTime(n.year, n.month, n.day - daysAgo, 12);
}

DateTime _at(int minutesAfterNoon, [int daysAgo = 0]) =>
    _noon(daysAgo).add(Duration(minutes: minutesAfterNoon)).toUtc();

DecryptedMessage _m(
  int n, {
  required bool mine,
  int minute = 0,
  int daysAgo = 0,
  EncryptedMessageState state = EncryptedMessageState.visible,
}) => DecryptedMessage(
  id: 'm$n',
  at: _at(minute, daysAgo),
  mine: mine,
  state: state,
  text: state == EncryptedMessageState.visible ? 'text $n' : '',
);

SystemLineEntry _line(
  int n,
  SystemLineKind kind, {
  LineSide? side,
  int minute = 0,
  int daysAgo = 0,
}) => SystemLineEntry(
  id: 'l$n',
  at: _at(minute, daysAgo),
  kind: kind,
  side: side,
);

String _shape(List<ThreadItem> items) => [
  for (final item in items)
    switch (item) {
      EncryptedMessageItem(
        :final message,
        :final firstOfGroup,
        :final lastOfGroup,
      ) =>
        '${message.state == EncryptedMessageState.undecryptable
                ? 'undec'
                : message.mine
                ? 'me'
                : 'peer'}'
            '${firstOfGroup ? ' first' : ''}${lastOfGroup ? ' last' : ''}',
      SystemLineItem() => 'line',
      OwnDeviceAlertItem() => 'alert',
      DaySeparatorItem() => 'day',
      MessageItem() => 'plain',
    },
].join(', ');

void main() {
  test(
    'groups by mine within a day and adds day separators like buildThreadItems',
    () {
      final items = buildEncryptedThreadItems([
        _m(4, mine: true, minute: 3),
        _m(3, mine: false, minute: 2),
        _m(2, mine: false, minute: 1),
        _m(1, mine: false, minute: 0),
        _m(0, mine: true, minute: 5, daysAgo: 1),
      ]);

      expect(
        _shape(items),
        'me first last, peer last, peer, peer first, day, me first last, day',
      );
      expect((items.first as EncryptedMessageItem).message.id, 'm4');
    },
  );

  test('no entries, no rows', () {
    expect(buildEncryptedThreadItems(const []), isEmpty);
  });

  test('a system line breaks a group', () {
    final items = buildEncryptedThreadItems([
      _m(3, mine: false, minute: 3),
      _line(1, SystemLineKind.deviceRemoved, side: LineSide.theirs, minute: 2),
      _m(2, mine: false, minute: 1),
    ]);

    expect(_shape(items), 'peer first last, line, peer first last, day');
  });

  for (final mine in [true, false]) {
    test('an undecryptable row is its own item and breaks the group before and '
        'after it, whether mine is true or false ($mine)', () {
      final items = buildEncryptedThreadItems([
        _m(3, mine: mine, minute: 3),
        _m(
          2,
          mine: mine,
          minute: 2,
          state: EncryptedMessageState.undecryptable,
        ),
        _m(1, mine: mine, minute: 1),
      ]);

      expect(
        _shape(items),
        '${mine ? 'me' : 'peer'} first last, undec first last, '
        '${mine ? 'me' : 'peer'} first last, day',
      );
    });
  }

  test('two undecryptable rows in a row are each their own item', () {
    final items = buildEncryptedThreadItems([
      _m(2, mine: false, minute: 2, state: EncryptedMessageState.undecryptable),
      _m(1, mine: false, minute: 1, state: EncryptedMessageState.undecryptable),
    ]);

    expect(_shape(items), 'undec first last, undec first last, day');
  });

  test('deviceAdded mine is an alert, theirs is a line', () {
    final items = buildEncryptedThreadItems([
      _line(3, SystemLineKind.deviceAdded, side: LineSide.theirs, minute: 3),
      _line(2, SystemLineKind.deviceAdded, side: LineSide.mine, minute: 2),
      _line(1, SystemLineKind.deviceAdded, minute: 1),
    ]);

    expect(_shape(items), 'line, alert, line, day');
    expect(items[1].key, 'alert-l2');
    expect(items[0].key, 'line-l3');
  });

  test('two reset lines on one local day keep only the newest; a third on the '
      'next day stays', () {
    final items = buildEncryptedThreadItems([
      _line(3, SystemLineKind.encryptionReset, minute: 30),
      _line(2, SystemLineKind.encryptionReset, minute: 10),
      _line(1, SystemLineKind.encryptionReset, minute: 10, daysAgo: 1),
    ]);

    expect(_shape(items), 'line, day, line, day');
    expect(
      [
        for (final i in items)
          if (i is SystemLineItem) i.line.id,
      ],
      ['l3', 'l1'],
    );
  });

  test('a dropped reset line leaves no phantom group break', () {
    final items = buildEncryptedThreadItems([
      _m(3, mine: false, minute: 3),
      _line(2, SystemLineKind.encryptionReset, minute: 2),
      _line(1, SystemLineKind.encryptionReset, minute: 1),
      _m(0, mine: false, minute: 0),
    ]);

    expect(_shape(items), 'peer first last, line, peer first last, day');
  });

  test('showLines false drops lines and alerts but keeps messages', () {
    final items = buildEncryptedThreadItems([
      _m(3, mine: false, minute: 3),
      _line(2, SystemLineKind.deviceAdded, side: LineSide.mine, minute: 2),
      _line(1, SystemLineKind.unknownDevice, minute: 1),
      _m(0, mine: false, minute: 0),
    ], showLines: false);

    expect(_shape(items), 'peer last, peer first, day');
  });

  test('an unsent own row sorts where the pipeline put it', () {
    final unsent = DecryptedMessage(
      id: 'local-1',
      at: _at(1),
      mine: true,
      text: 'typed',
      progress: SendProgress.sending,
    );
    final items = buildEncryptedThreadItems([
      _m(2, mine: false, minute: 5),
      unsent,
      _m(1, mine: true, minute: 9),
    ]);

    expect(
      [
        for (final i in items)
          if (i is EncryptedMessageItem) i.message.id,
      ],
      ['m2', 'local-1', 'm1'],
    );
  });

  group('encryptedDisplayText', () {
    DecryptedMessage m({
      EncryptedMessageState state = EncryptedMessageState.visible,
      MessageCheck check = MessageCheck.ok,
      String text = '',
    }) => DecryptedMessage(
      id: 'x',
      at: _at(0),
      mine: false,
      state: state,
      check: check,
      text: text,
    );

    test('visible and ok shows the text and is not a placeholder', () {
      final x = m(text: 'hello');
      expect(encryptedDisplayText(x), 'hello');
      expect(encryptedIsPlaceholder(x), isFalse);
    });

    test('the other five cases show their fixed placeholder', () {
      final cases = <DecryptedMessage, String>{
        m(check: MessageCheck.unverified): kCouldNotVerifyText,
        m(check: MessageCheck.undecodable): kCannotDisplayText,
        m(state: EncryptedMessageState.undecryptable): kCouldNotDecryptText,
        m(state: EncryptedMessageState.removed): kMessageRemovedText,
        m(state: EncryptedMessageState.deletedAccount): kMessageDeletedText,
      };
      cases.forEach((message, text) {
        expect(encryptedDisplayText(message), text);
        expect(encryptedIsPlaceholder(message), isTrue);
      });
    });

    test('text of an unverified message is never used even if set', () {
      final x = m(check: MessageCheck.unverified, text: 'secret');
      expect(encryptedDisplayText(x), kCouldNotVerifyText);
      final y = m(state: EncryptedMessageState.removed, text: 'secret');
      expect(encryptedDisplayText(y), isNot('secret'));
    });
  });
}
