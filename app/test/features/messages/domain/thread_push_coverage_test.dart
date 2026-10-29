import 'package:dzeroth/features/messages/domain/conversation_id.dart';
import 'package:dzeroth/features/messages/domain/thread_push_coverage.dart';
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pbenum.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/messaging_fixtures.dart';
import '../../../support/thread_test_support.dart';

void main() {
  bool covers({
    bool registered = true,
    bool notifications = true,
    bool known = true,
    bool silent = false,
    Folder folder = Folder.FOLDER_INBOX,
    ConversationState state = ConversationState.CONVERSATION_STATE_ACCEPTED,
  }) => pushCoversThread(
    deviceRegistered: registered,
    notificationsEnabled: notifications,
    conversation: known
        ? threadConv(silent: silent, folder: folder, state: state)
        : null,
  );

  group('pushCoversThread', () {
    test('an accepted, unmuted conversation with push registered', () {
      expect(covers(), isTrue);
    });

    test('not when the device is not (or no longer) registered', () {
      expect(covers(registered: false), isFalse);
    });

    test('not with the notifications flag off', () {
      expect(covers(notifications: false), isFalse);
    });

    test('not when the conversation is muted (silent)', () {
      expect(covers(silent: true), isFalse);
    });

    test('not for a request, on either side of it', () {
      expect(covers(folder: Folder.FOLDER_REQUESTS), isFalse);
      expect(
        covers(state: ConversationState.CONVERSATION_STATE_REQUEST),
        isFalse,
      );
    });

    test('not while the header is unknown', () {
      expect(covers(known: false), isFalse);
    });
  });

  group('isConversationId (the one 32-hex pattern)', () {
    test('accepts exactly 32 lower-case hex characters', () {
      expect(isConversationId(hexId(0xab)), isTrue);
      expect(isConversationId('ab12' * 8), isTrue);
    });

    test('rejects everything else', () {
      for (final bad in [
        '',
        'ABC',
        'AB12' * 8,
        'ab12' * 7,
        '${'ab12' * 8}0',
        '${'ab12' * 8}\n',
        '%61${'a' * 31}',
        '${'ab12' * 7}ab1g',
        'new',
      ]) {
        expect(isConversationId(bad), isFalse, reason: bad);
      }
      expect(kConversationIdPattern, '[0-9a-f]{32}');
    });
  });
}
