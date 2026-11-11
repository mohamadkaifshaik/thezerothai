import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/features/messages/domain/messages_list_detail.dart';
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pbenum.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/messaging_fixtures.dart';

/// The location rules of Messages list–detail (tablet plan sections 3 and
/// 5.3).
void main() {
  final id = hexId(0xc1);

  group('messagesShellMasterFolder', () {
    test('the inbox and the Requests folder', () {
      expect(
        messagesShellMasterFolder(AppRouter.messagesPath),
        Folder.FOLDER_INBOX,
      );
      expect(
        messagesShellMasterFolder(AppRouter.messageRequestsPath),
        Folder.FOLDER_REQUESTS,
      );
    });

    test('ignores a query and a trailing slash', () {
      expect(messagesShellMasterFolder('/messages/'), Folder.FOLDER_INBOX);
      expect(messagesShellMasterFolder('/messages?x=1'), Folder.FOLDER_INBOX);
      expect(
        messagesShellMasterFolder('/messages/requests/'),
        Folder.FOLDER_REQUESTS,
      );
    });

    for (final location in [
      AppRouter.messagePath(id),
      AppRouter.messageNewPath,
      AppRouter.messageDraftPath,
      '/messagesx',
      '/home',
      '/settings',
      '/plans',
      '/',
    ]) {
      test('$location: none', () {
        expect(messagesShellMasterFolder(location), isNull);
      });
    }
  });

  group('messagesThreadIdOf and isMessagesThreadLocation', () {
    test('a conversation', () {
      expect(messagesThreadIdOf(AppRouter.messagePath(id)), id);
      expect(messagesThreadIdOf('${AppRouter.messagePath(id)}/'), id);
      expect(isMessagesThreadLocation(AppRouter.messagePath(id)), isTrue);
    });

    test('the draft is a thread location with no id', () {
      expect(messagesThreadIdOf(AppRouter.messageDraftPath), isNull);
      expect(isMessagesThreadLocation(AppRouter.messageDraftPath), isTrue);
    });

    for (final location in [
      AppRouter.messagesPath,
      AppRouter.messageRequestsPath,
      AppRouter.messageNewPath,
      '/messages/$id/extra',
      '/home',
    ]) {
      test('$location: no thread', () {
        expect(messagesThreadIdOf(location), isNull);
        expect(isMessagesThreadLocation(location), isFalse);
      });
    }
  });

  group('messagesSplitFolderOf', () {
    test('the Requests rows pass the Requests folder', () {
      expect(
        messagesSplitFolderOf(Folder.FOLDER_REQUESTS),
        Folder.FOLDER_REQUESTS,
      );
    });

    test('no extra, the inbox, or anything else is the inbox', () {
      for (final extra in <Object?>[null, Folder.FOLDER_INBOX, 'requests', 3]) {
        expect(messagesSplitFolderOf(extra), Folder.FOLDER_INBOX);
      }
    });
  });
}
