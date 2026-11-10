import 'package:dzeroth/app/session_wiring.dart';
import 'package:dzeroth/core/network/api_client.dart';
import 'package:dzeroth/core/storage/app_database.dart';
import 'package:dzeroth/features/messages/data/messaging_repository.dart';
import 'package:dzeroth/features/messages/data/messaging_store.dart';
import 'package:dzeroth/features/messages/domain/messaging_feature_gate.dart';
import 'package:dzeroth/features/messages/presentation/bloc/conversations_cubit.dart';
import 'package:dzeroth/features/messages/presentation/bloc/thread_cubit.dart';
import 'package:dzeroth/features/posts/domain/posts_feature_flag.dart';
import 'package:dzeroth/features/timeline/data/timeline_repository.dart';
import 'package:dzeroth/features/timeline/data/timeline_store.dart';
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pbenum.dart';
import 'package:fixnum/fixnum.dart' show Int64;
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_transport.dart';
import '../../../support/messaging_fixtures.dart';
import '../../../support/thread_test_support.dart';

const _svc = '/dzeroth.messaging.v1.MessagingService';
const _listConvs = '$_svc/ListConversations';
const _listMsgs = '$_svc/ListMessages';

/// The inbox and a thread on the start-up fallback with no sqlite at all
/// (`AppDatabase.keepingNothing`, e.g. the web without `sqlite3.wasm`): the
/// rows the server returned stay in memory for the session and render. Real
/// repository and store, fake transport.
void main() {
  late AppDatabase db;
  late List<pb.ListConversationsRequest> convRequests;
  late List<pb.ListMessagesRequest> msgRequests;
  late List<pb.ListConversationsResponse> convAnswers;
  late List<pb.ListMessagesResponse> msgAnswers;
  late FakeTransport transport;
  late MessagingRepository repo;
  final closers = <Future<void> Function()>[];

  pb.ListConversationsResponse inbox(
    List<pb.Conversation> rows, {
    String since = '',
    String next = '',
  }) => pb.ListConversationsResponse(
    conversations: rows,
    sinceToken: since,
    nextPageToken: next,
    requestCount: Int64(0),
  );

  pb.ListMessagesResponse page(
    List<pb.Message> messages, {
    String since = '',
    String next = '',
  }) => pb.ListMessagesResponse(
    messages: messages,
    conversation: threadConv(),
    sinceToken: since,
    nextPageToken: next,
  );

  List<String> convIds(ConversationsCubit c) => [
    for (final row in c.state.conversations) row.id,
  ];
  List<String> msgIds(ThreadCubit c) => [
    for (final m in c.state.messages) m.id,
  ];
  List<String> hexIds(Iterable<int> n) => [for (final i in n) hexId(i)];

  ConversationsCubit inboxCubit() {
    final c = ConversationsCubit(repository: repo);
    closers.add(c.close);
    return c;
  }

  ThreadCubit threadCubit() {
    final c = ThreadCubit(
      repository: repo,
      poller: FakeThreadPoller(),
      conversationId: kThreadId,
    );
    closers.add(c.close);
    return c;
  }

  List<pb.Message> thread(int from, int to) =>
      msgs(from, to, conversationId: kThreadId);

  setUp(() {
    db = AppDatabase.keepingNothing();
    convRequests = [];
    msgRequests = [];
    convAnswers = [];
    msgAnswers = [];
    transport = FakeTransport((procedure, input) async {
      switch (procedure) {
        case _listConvs:
          convRequests.add(input as pb.ListConversationsRequest);
          if (convAnswers.isEmpty) throw StateError('unscripted $procedure');
          return convAnswers.removeAt(0);
        case _listMsgs:
          msgRequests.add(input as pb.ListMessagesRequest);
          if (msgAnswers.isEmpty) throw StateError('unscripted $procedure');
          return msgAnswers.removeAt(0);
      }
      throw StateError('unexpected $procedure');
    });
    repo = MessagingRepository(
      apiClient: ApiClient.withTransport(transport),
      store: MessagingStore(db),
      gate: MessagingFeatureGate(isMessagingEnabled: () => true),
    );
  });

  tearDown(() async {
    for (final close in closers.reversed) {
      await close();
    }
    closers.clear();
    await db.close();
  });

  group('inbox', () {
    test('the first page the server returned renders', () async {
      await db.claimCacheFor('a');
      convAnswers.add(
        inbox(
          [conv('c3', minutesAgo: 1), conv('c2', minutesAgo: 2)],
          since: 's1',
          next: 'older',
        ),
      );
      final list = inboxCubit();

      await list.load();

      expect(convRequests, hasLength(1));
      expect(list.state.status, ConversationsStatus.ready);
      expect(convIds(list), ['c3', 'c2']);
      expect(list.state.hasMore, isTrue);
      expect(list.state.requestCount, 0);
    });

    test('paging appends the older page', () async {
      convAnswers
        ..add(
          inbox(
            [conv('c3', minutesAgo: 1), conv('c2', minutesAgo: 2)],
            since: 's1',
            next: 'older',
          ),
        )
        ..add(inbox([conv('c1', minutesAgo: 3)]));
      final list = inboxCubit();
      await list.load();

      await list.loadMore();

      expect(convRequests.last.pageToken, 'older');
      expect(convIds(list), ['c3', 'c2', 'c1']);
      expect(list.state.hasMore, isFalse);
    });

    test('a refresh sends the kept since_token and moves the updated row to '
        'the top', () async {
      convAnswers
        ..add(
          inbox([
            conv('c3', minutesAgo: 1),
            conv('c2', minutesAgo: 2),
          ], since: 's1'),
        )
        ..add(inbox([conv('c2', minutesAgo: 0)], since: 's2'));
      final list = inboxCubit();
      await list.load();

      await list.refresh();

      expect(convRequests.last.sinceToken, 's1');
      expect(convIds(list), ['c2', 'c3']);
    });
  });

  group('thread', () {
    test('the messages the server returned render', () async {
      msgAnswers.add(page(thread(4, 6), since: 's1', next: 'older'));
      final chat = threadCubit();

      await chat.load();

      expect(msgRequests, hasLength(1));
      expect(chat.state.status, ThreadStatus.ready);
      expect(msgIds(chat), hexIds([6, 5, 4]));
      expect(chat.state.conversation?.id, kThreadId);
      expect(chat.state.hasMore, isTrue);
    });

    test('paging appends older messages', () async {
      msgAnswers
        ..add(page(thread(4, 6), since: 's1', next: 'older'))
        ..add(page(thread(1, 3)));
      final chat = threadCubit();
      await chat.load();

      await chat.loadMore();

      expect(msgRequests.last.pageToken, 'older');
      expect(msgIds(chat), hexIds([6, 5, 4, 3, 2, 1]));
      expect(chat.state.hasMore, isFalse);
    });

    test('a refresh sends the kept since_token and adds the new '
        'messages', () async {
      msgAnswers
        ..add(page(thread(4, 6), since: 's1'))
        ..add(page(thread(7, 8), since: 's2'));
      final chat = threadCubit();
      await chat.load();

      await chat.refresh();

      expect(msgRequests.last.sinceToken, 's1');
      expect(msgIds(chat), hexIds([8, 7, 6, 5, 4]));
    });
  });

  test('an account switch clears the inbox and the threads: the next account '
      'never sees them', () async {
    await db.claimCacheFor('a');
    convAnswers.add(inbox([conv('c-a')], since: 's1'));
    msgAnswers.add(page(thread(1, 2), since: 't1'));
    await inboxCubit().load();
    await threadCubit().load();
    // The inbox row, and the thread's header cached as a row of its own.
    expect(
      [
        for (final c in (await repo.cachedConversations(
          Folder.FOLDER_INBOX,
        )).conversations)
          c.id,
      ],
      containsAll(['c-a', kThreadId]),
      reason: 'kept',
    );
    expect((await repo.cachedThread(kThreadId)).messages, hasLength(2));

    // What `wireAuthSession` runs for a switch from a to b.
    await wipeSessionData(
      database: db,
      timelineRepository: TimelineRepository(
        apiClient: ApiClient.withTransport(transport),
        store: TimelineStore(db),
        gate: PostsFeatureGate(isPostsEnabled: () => true),
      ),
      messagingRepository: repo,
    );
    await db.claimCacheFor('b');

    expect(
      (await repo.cachedConversations(Folder.FOLDER_INBOX)).conversations,
      isEmpty,
    );
    expect((await repo.cachedThread(kThreadId)).messages, isEmpty);
    convAnswers.add(inbox([conv('c-b')], since: 'b1'));
    final list = inboxCubit();
    await list.load();
    expect(convRequests.last.sinceToken, isEmpty, reason: "a's token is gone");
    expect(convIds(list), ['c-b']);
  });
}
