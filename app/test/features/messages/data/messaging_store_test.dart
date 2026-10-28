import 'package:drift/native.dart';
import 'package:dzeroth/core/storage/app_database.dart';
import 'package:dzeroth/features/messages/data/messaging_store.dart';
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pbenum.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/messaging_fixtures.dart';

void main() {
  late AppDatabase db;
  late MessagingStore store;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    store = MessagingStore(db);
  });
  tearDown(() => db.close());

  Future<void> older(int from, int to, String next) => store.applyThreadOlder(
    'c1',
    items: msgs(from, to),
    nextPageToken: next,
    session: store.session,
  );

  test(
    'keeps the newest 200 messages per conversation, with a valid older token',
    () async {
      // Four pages of 50, each page's token known: exactly 200.
      await store.applyThreadColdOpen(
        'c1',
        items: msgs(151, 200),
        conversation: null,
        sinceToken: 's',
        nextPageToken: 't150',
        session: store.session,
      );
      await older(101, 150, 't100');
      await older(51, 100, 't50');
      await older(1, 50, 't0');
      expect((await store.readThread('c1')).messages, hasLength(200));

      // 30 new messages arrive by since refresh: over the cap.
      await store.applyThreadRefresh(
        'c1',
        items: msgs(201, 230),
        sinceToken: 's2',
        session: store.session,
      );

      final snap = await store.readThread('c1');
      expect(snap.messages.length, lessThanOrEqualTo(kMessagesPerConversation));
      expect(snap.messages.first.id, hexId(230));
      // The cut is at a page boundary: the oldest kept row is the last of the
      // 51..100 page, and the token continues right below it.
      expect(snap.messages.last.id, hexId(51));
      expect(snap.olderPageToken, 't50');
      expect(snap.sinceToken, 's2');
    },
  );

  test(
    'with no page boundary in the window, exactly the newest 200 are kept',
    () async {
      await store.applyThreadColdOpen(
        'c1',
        items: msgs(1, 50),
        conversation: null,
        sinceToken: 's',
        nextPageToken: 'deep',
        session: store.session,
      );
      for (var i = 0; i < 5; i++) {
        await store.applyThreadRefresh(
          'c1',
          items: msgs(51 + i * 50, 100 + i * 50),
          sinceToken: 's$i',
          session: store.session,
        );
      }

      final snap = await store.readThread('c1');
      expect(snap.messages, hasLength(kMessagesPerConversation));
      expect(snap.messages.first.id, hexId(300));
      expect(snap.messages.last.id, hexId(101));
      expect(snap.olderPageToken, isEmpty);
    },
  );

  test('the cap is per conversation', () async {
    await store.applyThreadRefresh(
      'a',
      items: msgs(1, 50, conversationId: 'a'),
      sinceToken: 's',
      session: store.session,
    );
    await store.applyThreadRefresh(
      'b',
      items: msgs(1, 5, conversationId: 'b'),
      sinceToken: 's',
      session: store.session,
    );
    expect((await store.readThread('a')).messages, hasLength(50));
    expect((await store.readThread('b')).messages, hasLength(5));
  });

  test('a write that started before sign-out is dropped', () async {
    final session = store.session;
    db.sessionEpoch.end();
    await store.applyThreadRefresh(
      'c1',
      items: msgs(1, 2),
      sinceToken: 's',
      session: session,
    );
    await store.applyConversationsRefresh(
      Folder.FOLDER_INBOX,
      items: [conv('c1')],
      sinceToken: 's',
      session: session,
    );
    expect(await db.select(db.messageEntries).get(), isEmpty);
    expect(await db.select(db.conversationEntries).get(), isEmpty);
    expect(await db.select(db.messagingStateEntries).get(), isEmpty);
  });

  test(
    'removeConversation clears the row, the messages and the thread state',
    () async {
      await store.applyThreadColdOpen(
        'c1',
        items: msgs(1, 3),
        conversation: conv('c1'),
        sinceToken: 's',
        nextPageToken: 'n',
        session: store.session,
      );
      await store.removeConversation('c1');
      expect(await db.select(db.messageEntries).get(), isEmpty);
      expect(await db.select(db.conversationEntries).get(), isEmpty);
      expect(await db.select(db.messagingStateEntries).get(), isEmpty);
    },
  );
}
