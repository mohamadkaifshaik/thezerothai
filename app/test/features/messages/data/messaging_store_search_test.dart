import 'package:drift/native.dart';
import 'package:dzeroth/core/storage/app_database.dart';
import 'package:dzeroth/features/messages/data/messaging_store.dart';
import 'package:dzeroth/features/messages/domain/message_search.dart';
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

  Future<void> seed(String id, {List<String> texts = const ['hello']}) async {
    await store.applyThreadColdOpen(
      id,
      items: [
        for (var i = 0; i < texts.length; i++)
          msg(
            id.codeUnitAt(0) * 10 + i,
            conversationId: id,
            secondsAgo: i,
            text: texts[i],
          ),
      ],
      conversation: conv(id),
      sinceToken: 's',
      nextPageToken: 'older-$id',
      session: store.session,
    );
  }

  Future<List<ConversationHits>> search(String q, {String? only}) async {
    final corpus = await store.readSearchCorpus(conversationId: only);
    return searchMessages(
      conversations: corpus.conversations,
      messagesByConversation: corpus.messages,
      query: q,
    );
  }

  test('searches every cached conversation, or just one', () async {
    await seed('a', texts: ['hello a']);
    await seed('b', texts: ['hello b']);
    expect((await search('hello')).length, 2);
    expect((await search('hello', only: 'a')).single.conversation.id, 'a');
  });

  test('orphan messages (header removed) are never returned', () async {
    await seed('a');
    await store.removeConversationEntry('a');
    expect(await search('hello'), isEmpty);
  });

  test('a conversation the caller blocked stops matching at once', () async {
    await seed('a');
    expect(await search('hello'), isNotEmpty);
    await store.markConversationReadOnly('a', session: store.session);
    expect(await search('hello'), isEmpty);
  });

  test('a conversation removed with everything is not searched', () async {
    await seed('a');
    await store.removeConversation('a');
    expect(await search('hello'), isEmpty);
  });

  test('sign-out (clearAll) leaves nothing to search', () async {
    await seed('a');
    expect(await search('hello'), isNotEmpty);
    await db.clearAll();
    expect(await search('hello'), isEmpty);
  });

  test('the cache holds at most 200 messages per conversation', () async {
    await seed('a', texts: List.filled(1, 'x'));
    for (var i = 0; i < 6; i++) {
      await store.applyThreadRefresh(
        'a',
        items: msgs(1 + i * 50, 50 + i * 50, conversationId: 'a'),
        sinceToken: 's$i',
        session: store.session,
      );
    }
    final corpus = await store.readSearchCorpus(conversationId: 'a');
    expect(corpus.messages['a']!.length, lessThanOrEqualTo(200));
  });
}
