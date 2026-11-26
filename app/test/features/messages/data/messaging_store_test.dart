import 'package:drift/native.dart';
import 'package:dzeroth/core/storage/app_database.dart';
import 'package:dzeroth/features/messages/data/messaging_store.dart';
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pbenum.dart';
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as posts;
import 'package:fixnum/fixnum.dart';
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

  group('a thread cold open merges the header into the cached row (F-5)', () {
    // What ListMessages carries: identity, peer, state, folder, can_reply and,
    // on the first page, unread_count and silent. No last_message or
    // updated_at.
    pb.Conversation header(String id) => pb.Conversation(
      id: id,
      kind: ConversationKind.CONVERSATION_KIND_DIRECT,
      state: ConversationState.CONVERSATION_STATE_ACCEPTED,
      folder: Folder.FOLDER_INBOX,
      canReply: true,
    );

    Future<void> coldOpen(String id, pb.Conversation? conversation) =>
        store.applyThreadColdOpen(
          id,
          items: msgs(1, 3, conversationId: id),
          conversation: conversation,
          sinceToken: 's',
          nextPageToken: '',
          session: store.session,
        );

    test('takes the first-page unread count and mute (0 and false '
        'included), keeps preview and sort key', () async {
      final a = hexId(0xa1);
      final b = hexId(0xb2);
      await store.applyConversationsColdOpen(
        Folder.FOLDER_INBOX,
        items: [
          conv(b, minutesAgo: 1, unread: 2, snippet: 'newer'),
          conv(a, minutesAgo: 5, unread: 3, snippet: 'older', silent: true),
        ],
        sinceToken: 'x',
        nextPageToken: '',
        session: store.session,
      );
      final before = await db.select(db.conversationEntries).get();
      final sortKeyBefore = before
          .firstWhere((r) => r.conversationId == a)
          .sortKey;

      await coldOpen(a, header(a));

      final row = (await store.conversation(a))!;
      // The header is a first page with unread_count 0 / silent false: read
      // on another device, so the cached 3 and mute are replaced.
      expect(row.unreadCount.toInt(), 0);
      expect(row.silent, isFalse);
      expect(row.lastMessage.snippet, 'older');
      expect(row.hasUpdatedAt(), isTrue);
      expect(row.canReply, isTrue);
      final after = await db.select(db.conversationEntries).get();
      expect(
        after.firstWhere((r) => r.conversationId == a).sortKey,
        sortKeyBefore,
      );
      // Still second in the Inbox, not thrown to the end or the top.
      final inbox = await store.readConversations(Folder.FOLDER_INBOX);
      expect(inbox.conversations.map((c) => c.id), [b, a]);
      expect(inbox.conversations.last.unreadCount.toInt(), 0);
    });

    test('with nothing cached the header is stored as it is', () async {
      final a = hexId(0xa1);
      await coldOpen(a, header(a));
      final row = (await store.conversation(a))!;
      expect(row.id, a);
      expect(row.unreadCount.toInt(), 0);
      expect(row.canReply, isTrue);
    });

    test('what the header does carry wins over the cached row', () async {
      final a = hexId(0xa1);
      await store.applyConversationsColdOpen(
        Folder.FOLDER_INBOX,
        items: [conv(a, unread: 1)],
        sinceToken: 'x',
        nextPageToken: '',
        session: store.session,
      );
      final fresh = header(a)
        ..state = ConversationState.CONVERSATION_STATE_REQUEST
        ..canReply = false;
      await coldOpen(a, fresh);

      final row = (await store.conversation(a))!;
      expect(row.state, ConversationState.CONVERSATION_STATE_REQUEST);
      expect(row.canReply, isFalse);
      expect(row.unreadCount.toInt(), 0);
    });

    test('a first-page header unread_count wins (W7-27)', () async {
      final a = hexId(0xa1);
      await store.applyConversationsColdOpen(
        Folder.FOLDER_INBOX,
        items: [conv(a, unread: 1)],
        sinceToken: 'x',
        nextPageToken: '',
        session: store.session,
      );
      await coldOpen(a, header(a)..unreadCount = Int64(4));
      expect((await store.conversation(a))!.unreadCount.toInt(), 4);
    });

    test('a null header leaves the cached row alone', () async {
      final a = hexId(0xa1);
      await store.applyConversationsColdOpen(
        Folder.FOLDER_INBOX,
        items: [conv(a, unread: 2)],
        sinceToken: 'x',
        nextPageToken: '',
        session: store.session,
      );
      await coldOpen(a, null);
      expect((await store.conversation(a))!.unreadCount.toInt(), 2);
    });
  });

  group('mergeThreadHeader', () {
    test('no cached row: a copy of the header', () {
      final fresh = conv('c1', unread: 2);
      for (final first in [true, false]) {
        final merged = mergeThreadHeader(null, fresh, firstPage: first);
        expect(merged, fresh);
        expect(identical(merged, fresh), isFalse);
      }
    });

    test('keeps what the header leaves unspecified', () {
      final cached = conv('c1', unread: 2, snippet: 'hi', silent: true);
      final fresh = pb.Conversation(id: 'c1', canReply: true);
      for (final first in [true, false]) {
        final merged = mergeThreadHeader(cached, fresh, firstPage: first);
        expect(merged.kind, ConversationKind.CONVERSATION_KIND_DIRECT);
        expect(merged.state, ConversationState.CONVERSATION_STATE_ACCEPTED);
        expect(merged.folder, Folder.FOLDER_INBOX);
        expect(merged.lastMessage.snippet, 'hi');
        expect(merged.updatedAt, cached.updatedAt);
        expect(merged.canReply, isTrue);
      }
    });

    group('unread_count (W7-27)', () {
      final cached = conv('c1', unread: 3);

      test('first page: a count of 0 overrides the cached 3 (read on '
          'another device)', () {
        final merged = mergeThreadHeader(cached, conv('c1'), firstPage: true);
        expect(merged.unreadCount.toInt(), 0);
      });

      test('first page: a count of 5 is set', () {
        final merged = mergeThreadHeader(
          cached,
          conv('c1', unread: 5),
          firstPage: true,
        );
        expect(merged.unreadCount.toInt(), 5);
      });

      test('since page: the unset count keeps the cached 3', () {
        final merged = mergeThreadHeader(cached, conv('c1'), firstPage: false);
        expect(merged.unreadCount.toInt(), 3);
      });

      test('older page: the unset count keeps the cached 3 (same rule as a '
          'since page: firstPage false)', () {
        final merged = mergeThreadHeader(cached, conv('c1'), firstPage: false);
        expect(merged.unreadCount.toInt(), 3);
      });

      test('not a first page: a positive count still wins', () {
        final merged = mergeThreadHeader(
          cached,
          conv('c1', unread: 5),
          firstPage: false,
        );
        expect(merged.unreadCount.toInt(), 5);
      });
    });

    group('silent (W7-27)', () {
      final cached = conv('c1', silent: true);

      test('first page: false overrides the cached muted flag', () {
        final merged = mergeThreadHeader(cached, conv('c1'), firstPage: true);
        expect(merged.silent, isFalse);
      });

      test('first page: true is set over a cached unmuted row', () {
        final merged = mergeThreadHeader(
          conv('c1'),
          conv('c1', silent: true),
          firstPage: true,
        );
        expect(merged.silent, isTrue);
      });

      test('since or older page: the unset flag keeps the cached muted '
          'flag', () {
        final merged = mergeThreadHeader(cached, conv('c1'), firstPage: false);
        expect(merged.silent, isTrue);
      });
    });
  });

  group('text_removed rows (Plan 6 PR 6-5)', () {
    pb.Message purged(int n) => msg(n, secondsAgo: 10000 - n).deepCopy()
      ..text = ''
      ..textRemoved = true;

    Future<void> coldOpen(List<pb.Message> items) => store.applyThreadColdOpen(
      'c1',
      items: items,
      conversation: null,
      sinceToken: 's',
      nextPageToken: '',
      session: store.session,
    );

    Future<pb.Message> cached(int n) async =>
        (await store.readThread('c1')).messages
            .singleWhere((m) => m.id == hexId(n));

    test('a text_removed row keeps the cached text', () async {
      await coldOpen(msgs(1, 3));

      await store.applyThreadRefresh(
        'c1',
        items: [purged(2)],
        sinceToken: 's2',
        session: store.session,
      );
      var row = await cached(2);
      expect(row.text, 'hello');
      expect(row.textRemoved, isTrue);

      // A cold open replaces the thread; the cached text still survives.
      await coldOpen([purged(3), purged(2), purged(1)]);
      row = await cached(2);
      expect(row.text, 'hello');
      expect(row.textRemoved, isTrue);

      await store.applyThreadOlder(
        'c1',
        items: [purged(1)],
        nextPageToken: '',
        session: store.session,
      );
      expect((await cached(1)).text, 'hello');
    });

    test('a text_removed row keeps the cached shared post', () async {
      final shared = msg(1).deepCopy()
        ..sharedPost = (posts.EmbeddedPost()..postId = 'p1');
      await coldOpen([shared]);

      await coldOpen([purged(1)]);
      final row = await cached(1);
      expect(row.sharedPost.postId, 'p1');
      expect(row.text, 'hello');
    });

    test('with nothing cached the row is stored as sent', () async {
      await coldOpen([purged(1)]);
      final row = await cached(1);
      expect(row.text, isEmpty);
      expect(row.textRemoved, isTrue);
    });

    test('a tombstone never brings the cached text back', () async {
      await coldOpen(msgs(1, 1));
      final erased = purged(1)
        ..state = MessageState.MESSAGE_STATE_DELETED_ACCOUNT;

      await store.applyThreadRefresh(
        'c1',
        items: [erased],
        sinceToken: 's2',
        session: store.session,
      );
      expect((await cached(1)).text, isEmpty);
    });

    test('a row that is not text_removed replaces the cached text', () async {
      await coldOpen(msgs(1, 1));
      await coldOpen([msg(1, secondsAgo: 9999, text: 'edited')]);
      expect((await cached(1)).text, 'edited');
    });

    test('applySent of a text_removed row keeps the cached text and shared '
        'post', () async {
      final shared = msg(1, secondsAgo: 9999).deepCopy()
        ..sharedPost = (posts.EmbeddedPost()..postId = 'p1');
      await coldOpen([shared]);

      await store.applySent(purged(1), null, session: store.session);
      final row = await cached(1);
      expect(row.text, 'hello');
      expect(row.sharedPost.postId, 'p1');
      expect(row.textRemoved, isTrue);
    });
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
