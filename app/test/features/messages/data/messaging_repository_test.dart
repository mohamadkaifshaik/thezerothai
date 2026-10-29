import 'package:connectrpc/connect.dart' as connect;
import 'package:drift/native.dart';
import 'package:fixnum/fixnum.dart' show Int64;
import 'package:dzeroth/core/network/api_client.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/network/rate_limit_hold.dart';
import 'package:dzeroth/core/storage/app_database.dart';
import 'package:dzeroth/features/messages/data/messaging_repository.dart';
import 'package:dzeroth/features/messages/data/messaging_store.dart';
import 'package:dzeroth/features/messages/data/timer_thread_poller.dart';
import 'package:dzeroth/features/messages/domain/messaging_feature_gate.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pbenum.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_transport.dart';
import '../../../support/messaging_fixtures.dart';

const _svc = '/dzeroth.messaging.v1.MessagingService';
const _listConvs = '$_svc/ListConversations';
const _listMsgs = '$_svc/ListMessages';
const _send = '$_svc/SendMessage';
const _read = '$_svc/MarkConversationRead';
const _accept = '$_svc/AcceptMessageRequest';
const _delete = '$_svc/DeleteConversation';

void main() {
  late AppDatabase db;
  late MessagingStore store;
  late FakeTransport transport;
  late MessagingRepository repo;
  late MessagingFeatureGate gate;
  late RateLimitHold hold;
  late Duration clock;
  var flagOn = true;
  var disabledAsked = 0;

  late List<pb.ListConversationsRequest> convRequests;
  late List<pb.ListMessagesRequest> msgRequests;
  late List<Object> convAnswers;
  late List<Object> msgAnswers;
  Object? sendAnswer;
  Object? readAnswer;

  setUp(() {
    flagOn = true;
    disabledAsked = 0;
    clock = Duration.zero;
    convRequests = [];
    msgRequests = [];
    convAnswers = [];
    msgAnswers = [];
    sendAnswer = null;
    readAnswer = null;
    db = AppDatabase.forTesting(NativeDatabase.memory());
    store = MessagingStore(db);
    gate = MessagingFeatureGate(
      isMessagingEnabled: () => flagOn,
      onDisabledByServer: () => disabledAsked++,
    );
    hold = RateLimitHold(monotonic: () => clock);
    transport = FakeTransport((procedure, input) async {
      Object answer(List<Object> from) {
        final next = from.removeAt(0);
        if (next is Exception) throw next;
        return next;
      }

      switch (procedure) {
        case _listConvs:
          convRequests.add(input as pb.ListConversationsRequest);
          return answer(convAnswers);
        case _listMsgs:
          msgRequests.add(input as pb.ListMessagesRequest);
          return answer(msgAnswers);
        case _send:
          final a = sendAnswer;
          if (a is Exception) throw a;
          return a!;
        case _read:
          final a = readAnswer;
          if (a is Exception) throw a;
          return pb.MarkConversationReadResponse();
        case _accept:
          final a = readAnswer;
          if (a is Exception) throw a;
          return pb.AcceptMessageRequestResponse();
        case _delete:
          final a = readAnswer;
          if (a is Exception) throw a;
          return pb.DeleteConversationResponse();
      }
      throw StateError('unexpected $procedure');
    });
    repo = MessagingRepository(
      apiClient: ApiClient.withTransport(transport),
      store: store,
      gate: gate,
      rateLimitHold: hold,
    );
  });
  tearDown(() => db.close());

  pb.ListMessagesResponse thread(
    List<pb.Message> messages, {
    String since = 's1',
    String next = '',
    String gap = '',
    bool withConversation = true,
  }) {
    final r = pb.ListMessagesResponse(
      messages: messages,
      sinceToken: since,
      nextPageToken: next,
      gapPageToken: gap,
    );
    if (withConversation) r.conversation = conv('c1');
    return r;
  }

  group('threads', () {
    test(
      'first open sends no token and caches rows, header and tokens',
      () async {
        msgAnswers.add(thread(msgs(1, 3), next: 'older'));

        final snap = await repo.refreshThread('c1');

        expect(msgRequests.single.sinceToken, isEmpty);
        expect(msgRequests.single.pageToken, isEmpty);
        expect(snap.messages.map((m) => m.id), [hexId(3), hexId(2), hexId(1)]);
        expect(snap.conversation?.id, 'c1');
        expect(snap.sinceToken, 's1');
        expect(snap.olderPageToken, 'older');
        final cached = await repo.cachedThread('c1');
        expect(cached.messages, hasLength(3));
        expect(msgRequests, hasLength(1));
      },
    );

    test(
      'W7-27: a cold open is marked first-page and takes the header count '
      '(0 over a cached 3); a since refresh is not and keeps the cache',
      () async {
        await store.applyConversationsColdOpen(
          Folder.FOLDER_INBOX,
          items: [conv('c1', unread: 3)],
          sinceToken: 'x',
          nextPageToken: '',
          session: store.session,
        );
        msgAnswers.add(thread(msgs(1, 2)));

        final first = await repo.refreshThread('c1');

        expect(first.firstPageHeader, isTrue);
        expect(first.conversation?.unreadCount.toInt(), 0);

        // A since page has no header: nothing marks it, the cache is returned.
        await store.applyConversationsColdOpen(
          Folder.FOLDER_INBOX,
          items: [conv('c1', unread: 3)],
          sinceToken: 'x',
          nextPageToken: '',
          session: store.session,
        );
        msgAnswers.add(thread([msg(3)], since: 's2', withConversation: false));
        final since = await repo.refreshThread('c1');

        expect(since.firstPageHeader, isFalse);
        expect(since.conversation?.unreadCount.toInt(), 3);
        expect((await repo.cachedThread('c1')).firstPageHeader, isFalse);
      },
    );

    test(
      'W7-30: only the cold-open header sets the cached peer; a header on '
      'a since or older page ("Deleted account") never overwrites it',
      () async {
        final frozen = conv('c1')
          ..peer = common.AuthorSnapshot(
            userId: 'u-c1',
            handle: 'frozenhandle',
            displayName: 'Frozen Name',
            avatarUrl: 'https://example.test/frozen.png',
          );
        final placeholder = pb.Conversation(
          id: 'c1',
          peer: common.AuthorSnapshot(displayName: 'Deleted account'),
        );
        msgAnswers.add(
          pb.ListMessagesResponse(
            messages: msgs(1, 3),
            sinceToken: 's1',
            nextPageToken: 'older',
            conversation: frozen,
          ),
        );
        await repo.refreshThread('c1');

        msgAnswers.add(
          pb.ListMessagesResponse(
            messages: [msg(0, secondsAgo: 99)],
            conversation: placeholder,
          ),
        );
        await repo.loadOlderMessages('c1');
        msgAnswers.add(
          pb.ListMessagesResponse(
            messages: [msg(4, secondsAgo: 0)],
            sinceToken: 's2',
            conversation: placeholder,
          ),
        );
        final snap = await repo.refreshThread('c1');

        expect(snap.conversation?.peer.handle, 'frozenhandle');
        expect(snap.conversation?.peer.displayName, 'Frozen Name');
        expect(
          snap.conversation?.peer.avatarUrl,
          'https://example.test/frozen.png',
        );
      },
    );

    test('a since response with a duplicate id leaves one row', () async {
      msgAnswers.add(thread(msgs(1, 3)));
      await repo.refreshThread('c1');
      // The 5 s settle window returns 3 again, edited, plus a new 4.
      msgAnswers.add(
        thread(
          [msg(4, secondsAgo: 0), msg(3, secondsAgo: 5, text: 'edited')],
          since: 's2',
          withConversation: false,
        ),
      );

      final snap = await repo.refreshThread('c1');

      expect(msgRequests.last.sinceToken, 's1');
      expect(msgRequests.last.pageToken, isEmpty);
      expect(snap.messages.map((m) => m.id), [
        hexId(4),
        hexId(3),
        hexId(2),
        hexId(1),
      ]);
      expect(snap.messages.where((m) => m.id == hexId(3)), hasLength(1));
      expect(snap.sinceToken, 's2');
      // A since answer has no conversation: the cached header is kept.
      expect(snap.conversation?.id, 'c1');
    });

    test('a duplicate id inside one response is stored once', () async {
      msgAnswers.add(thread([msg(2), msg(2), msg(1, secondsAgo: 9)]));
      final snap = await repo.refreshThread('c1');
      expect(snap.messages, hasLength(2));
    });

    test('pollThread reports new messages only for ids not held', () async {
      msgAnswers.add(thread(msgs(1, 2)));
      expect((await repo.pollThread('c1')).newMessages, isTrue);
      msgAnswers.add(thread([msg(2)], since: 's2', withConversation: false));
      expect((await repo.pollThread('c1')).newMessages, isFalse);
      msgAnswers.add(thread([msg(3)], since: 's3', withConversation: false));
      expect((await repo.pollThread('c1')).newMessages, isTrue);
    });

    test('a full since page follows gap_page_token and writes once', () async {
      msgAnswers.add(thread(msgs(1, 2)));
      await repo.refreshThread('c1');
      msgAnswers
        ..add(
          thread(msgs(7, 8), since: 's2', gap: 'gap1', withConversation: false),
        )
        ..add(thread(msgs(5, 6), next: 'gap2', withConversation: false))
        ..add(thread(msgs(3, 4), withConversation: false));

      final snap = await repo.refreshThread('c1');

      expect(msgRequests.skip(1).map((r) => (r.sinceToken, r.pageToken)), [
        ('s1', ''),
        ('', 'gap1'),
        ('', 'gap2'),
      ]);
      expect(snap.messages, hasLength(8));
      expect(snap.sinceToken, 's2');
    });

    test(
      'a failure while filling the gap keeps the cache and since_token',
      () async {
        msgAnswers.add(thread(msgs(1, 2)));
        await repo.refreshThread('c1');
        msgAnswers
          ..add(
            thread(
              msgs(5, 6),
              since: 's2',
              gap: 'gap1',
              withConversation: false,
            ),
          )
          ..add(connect.ConnectException(connect.Code.unavailable, 'x'));

        await expectLater(
          repo.refreshThread('c1'),
          throwsA(isA<NetworkException>()),
        );

        final snap = await repo.cachedThread('c1');
        expect(snap.messages, hasLength(2));
        expect(snap.sinceToken, 's1');
      },
    );

    test('a gap too deep reloads the first page', () async {
      msgAnswers.add(thread(msgs(1, 2)));
      await repo.refreshThread('c1');
      msgAnswers.add(
        thread(msgs(50, 51), since: 's2', gap: 'g0', withConversation: false),
      );
      for (var i = 1; i <= kMaxGapPages; i++) {
        msgAnswers.add(thread(msgs(40 - i, 41 - i), next: 'g$i'));
      }
      msgAnswers.add(thread(msgs(60, 61), since: 'fresh'));

      final snap = await repo.refreshThread('c1');

      expect(snap.sinceToken, 'fresh');
      expect(snap.messages.map((m) => m.id), [hexId(61), hexId(60)]);
    });

    test(
      'a rejected since_token is dropped and one first open is sent',
      () async {
        msgAnswers.add(thread(msgs(1, 2)));
        await repo.refreshThread('c1');
        msgAnswers
          ..add(
            withDetail(
              connect.Code.invalidArgument,
              common.ErrorReason.ERROR_REASON_VALIDATION,
              metadata: {'field': 'since_token'},
            ),
          )
          ..add(thread(msgs(1, 3), since: 'new'));

        final snap = await repo.refreshThread('c1');

        expect(msgRequests.last.sinceToken, isEmpty);
        expect(msgRequests, hasLength(3));
        expect(snap.sinceToken, 'new');
      },
    );

    test(
      'older pages append below with their token; none when exhausted',
      () async {
        msgAnswers.add(thread(msgs(5, 6), next: 'p2'));
        await repo.refreshThread('c1');
        msgAnswers.add(thread(msgs(3, 4), next: '', withConversation: false));

        final snap = await repo.loadOlderMessages('c1');

        expect(msgRequests.last.pageToken, 'p2');
        expect(msgRequests.last.sinceToken, isEmpty);
        expect(snap.messages, hasLength(4));
        expect(snap.hasMore, isFalse);
        await repo.loadOlderMessages('c1');
        expect(msgRequests, hasLength(2));
      },
    );

    test('identical refreshes in flight share one call', () async {
      msgAnswers.add(thread(msgs(1, 2)));
      await Future.wait([repo.refreshThread('c1'), repo.refreshThread('c1')]);
      expect(msgRequests, hasLength(1));
    });
  });

  group('conversations', () {
    pb.ListConversationsResponse list(
      List<pb.Conversation> items, {
      String since = 's1',
      String next = '',
      int requests = 0,
    }) => pb.ListConversationsResponse(
      conversations: items,
      sinceToken: since,
      nextPageToken: next,
    )..requestCount = Int64(requests);

    test('first open caches the folder and returns request_count', () async {
      convAnswers.add(list([conv('a'), conv('b', minutesAgo: 5)], requests: 3));

      final result = await repo.refreshConversations(Folder.FOLDER_INBOX);

      expect(convRequests.single.folder, Folder.FOLDER_INBOX);
      expect(result.requestCount, 3);
      expect(result.snapshot.conversations.map((c) => c.id), ['a', 'b']);
      expect(
        (await repo.cachedConversations(Folder.FOLDER_REQUESTS)).conversations,
        isEmpty,
      );
    });

    test('a since refresh merges by id and has no request_count', () async {
      convAnswers.add(
        list([conv('a', minutesAgo: 5), conv('b', minutesAgo: 9)]),
      );
      await repo.refreshConversations(Folder.FOLDER_INBOX);
      convAnswers.add(list([conv('b', unread: 2)], since: 's2'));

      final result = await repo.refreshConversations(Folder.FOLDER_INBOX);

      expect(convRequests.last.sinceToken, 's1');
      expect(result.requestCount, isNull);
      expect(result.snapshot.conversations.map((c) => c.id), ['b', 'a']);
      expect(result.snapshot.conversations.first.unreadCount.toInt(), 2);
      expect(result.snapshot.sinceToken, 's2');
    });

    test(
      'a full since page reloads the first page (no gap token exists)',
      () async {
        convAnswers.add(list([conv('a')]));
        await repo.refreshConversations(Folder.FOLDER_INBOX);
        convAnswers
          ..add(
            list([
              for (var i = 0; i < 20; i++) conv('n$i', minutesAgo: i),
            ], since: 's2'),
          )
          ..add(list([conv('z')], since: 'fresh'));

        final result = await repo.refreshConversations(Folder.FOLDER_INBOX);

        expect(convRequests.map((r) => r.sinceToken), ['', 's1', '']);
        expect(result.snapshot.conversations.map((c) => c.id), ['z']);
        expect(result.snapshot.sinceToken, 'fresh');
      },
    );

    test('keeps following next_page_token over empty pages', () async {
      convAnswers
        ..add(list([], next: 'n1'))
        ..add(list([], next: 'n2'))
        ..add(list([conv('r', folder: Folder.FOLDER_REQUESTS)]));

      final result = await repo.refreshConversations(Folder.FOLDER_REQUESTS);

      expect(convRequests.map((r) => r.pageToken), ['', 'n1', 'n2']);
      expect(result.snapshot.conversations.map((c) => c.id), ['r']);
    });
  });

  group('mutations', () {
    test(
      'send caches the message and the conversation; key is passed',
      () async {
        sendAnswer = pb.SendMessageResponse(
          message: msg(1, conversationId: 'c9', fromSelf: true),
          conversation: conv('c9'),
        );

        await repo.sendMessage(
          idempotencyKey: 'key-1',
          text: 'hi',
          recipientUserId: 'u-9',
        );

        expect(
          (await repo.cachedThread('c9')).messages.single.fromSelf,
          isTrue,
        );
        expect(
          (await repo.cachedConversations(Folder.FOLDER_INBOX))
              .conversations
              .single
              .id,
          'c9',
        );
      },
    );

    test('send and accept send no RPC while the caller flag is off', () async {
      flagOn = false;
      await expectLater(
        repo.sendMessage(idempotencyKey: 'k', text: 't', conversationId: 'c1'),
        throwsA(isA<FeatureDisabledException>()),
      );
      await expectLater(
        repo.acceptMessageRequest(idempotencyKey: 'k', conversationId: 'c1'),
        throwsA(isA<FeatureDisabledException>()),
      );
      expect(transport.calledProcedures, isEmpty);
    });

    test(
      'reads and clean-up still work for a caller with the flag off',
      () async {
        flagOn = false;
        msgAnswers.add(thread(msgs(1, 1)));
        await repo.refreshThread('c1');
        await repo.markConversationRead(
          idempotencyKey: 'k',
          conversationId: 'c1',
        );
        await repo.deleteConversation(
          idempotencyKey: 'k2',
          conversationId: 'c1',
        );
        expect(transport.calledProcedures, [_listMsgs, _read, _delete]);
        expect((await repo.cachedThread('c1')).messages, isEmpty);
      },
    );

    test('accept moves the cached conversation to the inbox', () async {
      convAnswers.add(
        pb.ListConversationsResponse(
          conversations: [
            conv(
              'q',
              folder: Folder.FOLDER_REQUESTS,
              state: ConversationState.CONVERSATION_STATE_REQUEST,
            ),
          ],
          sinceToken: 's',
        ),
      );
      await repo.refreshConversations(Folder.FOLDER_REQUESTS);

      await repo.acceptMessageRequest(idempotencyKey: 'k', conversationId: 'q');

      expect(
        (await repo.cachedConversations(Folder.FOLDER_REQUESTS)).conversations,
        isEmpty,
      );
      final inbox = await repo.cachedConversations(Folder.FOLDER_INBOX);
      expect(
        inbox.conversations.single.state,
        ConversationState.CONVERSATION_STATE_ACCEPTED,
      );
    });

    group('persisted request count', () {
      pb.ListConversationsResponse list(
        List<pb.Conversation> items, {
        String since = 's1',
        int requests = 0,
      }) => pb.ListConversationsResponse(
        conversations: items,
        sinceToken: since,
        requestCount: Int64(requests),
      );

      pb.Conversation request(String id) => conv(
        id,
        folder: Folder.FOLDER_REQUESTS,
        state: ConversationState.CONVERSATION_STATE_REQUEST,
      );

      Future<void> seed({required int requests}) async {
        convAnswers.add(
          pb.ListConversationsResponse(
            conversations: [request('q1'), request('q2')],
            sinceToken: 'r',
          ),
        );
        await repo.refreshConversations(Folder.FOLDER_REQUESTS);
        convAnswers.add(
          pb.ListConversationsResponse(
            conversations: [conv('a')],
            sinceToken: 'i',
            requestCount: Int64(requests),
          ),
        );
        await repo.refreshConversations(Folder.FOLDER_INBOX);
        convRequests.clear();
      }

      test('a warm start reads the count from disk with no network', () async {
        convAnswers.add(list([conv('a')], requests: 3));
        await repo.refreshConversations(Folder.FOLDER_INBOX);
        convRequests.clear();

        final restarted = MessagingRepository(
          apiClient: ApiClient.withTransport(transport),
          store: MessagingStore(db),
          gate: gate,
          rateLimitHold: hold,
        );
        final cached = await restarted.cachedConversations(Folder.FOLDER_INBOX);

        expect(cached.requestCount, 3);
        expect(convRequests, isEmpty);
        expect(
          (await restarted.cachedConversations(Folder.FOLDER_REQUESTS))
              .requestCount,
          isNull,
        );
      });

      test('is unknown (null) before any first INBOX page', () async {
        expect(
          (await repo.cachedConversations(Folder.FOLDER_INBOX)).requestCount,
          isNull,
        );
      });

      test(
        'a fresh first INBOX page overwrites it; a since keeps it',
        () async {
          convAnswers.add(list([conv('a')], requests: 3));
          await repo.refreshConversations(Folder.FOLDER_INBOX);
          convAnswers.add(list([conv('a')], since: 's2'));
          final since = await repo.refreshConversations(Folder.FOLDER_INBOX);
          expect(since.requestCount, isNull);
          expect(since.snapshot.requestCount, 3);

          // A cold reopen (rejected since token) carries a fresh count.
          await store.clearConversationsSince(
            Folder.FOLDER_INBOX,
            session: store.session,
          );
          convAnswers.add(list([conv('a')], requests: 0));
          await repo.refreshConversations(Folder.FOLDER_INBOX);

          expect(
            (await repo.cachedConversations(Folder.FOLDER_INBOX)).requestCount,
            0,
          );
        },
      );

      test('accepting a request lowers it by one', () async {
        await seed(requests: 2);

        await repo.acceptMessageRequest(
          idempotencyKey: 'k',
          conversationId: 'q1',
        );

        expect(
          (await repo.cachedConversations(Folder.FOLDER_INBOX)).requestCount,
          1,
        );
      });

      test('deleting a request lowers it, never below 0', () async {
        await seed(requests: 1);

        await repo.deleteConversation(
          idempotencyKey: 'k1',
          conversationId: 'q1',
        );
        await repo.deleteConversation(
          idempotencyKey: 'k2',
          conversationId: 'q2',
        );

        expect(
          (await repo.cachedConversations(Folder.FOLDER_INBOX)).requestCount,
          0,
        );
      });

      test('deleting an inbox conversation leaves it alone', () async {
        await seed(requests: 2);

        await repo.deleteConversation(idempotencyKey: 'k', conversationId: 'a');

        expect(
          (await repo.cachedConversations(Folder.FOLDER_INBOX)).requestCount,
          2,
        );
      });

      test('accept answered NOT_FOUND still throws, but the cache is cleaned, '
          'the count lowered and the lists told', () async {
        await seed(requests: 2);
        var changes = 0;
        final sub = repo.conversationsChanged.listen((_) => changes++);
        addTearDown(sub.cancel);
        readAnswer = const NotFoundException('raw-not-found');
        transport.calledProcedures.clear();

        await expectLater(
          repo.acceptMessageRequest(idempotencyKey: 'k', conversationId: 'q1'),
          throwsA(isA<NotFoundException>()),
        );
        await pumpEventQueue();

        expect(transport.calledProcedures, [_accept]);
        final requests = await repo.cachedConversations(Folder.FOLDER_REQUESTS);
        expect(requests.conversations.map((c) => c.id), ['q2']);
        expect(
          (await repo.cachedConversations(Folder.FOLDER_INBOX)).requestCount,
          1,
        );
        expect(changes, 1);
      });

      test('delete answered NOT_FOUND counts as done: the cache is cleaned, '
          'the count lowered and the lists told', () async {
        await seed(requests: 2);
        var changes = 0;
        final sub = repo.conversationsChanged.listen((_) => changes++);
        addTearDown(sub.cancel);
        readAnswer = const NotFoundException('raw-not-found');
        transport.calledProcedures.clear();

        await repo.deleteConversation(
          idempotencyKey: 'k',
          conversationId: 'q1',
        );
        await pumpEventQueue();

        expect(transport.calledProcedures, [_delete]);
        final requests = await repo.cachedConversations(Folder.FOLDER_REQUESTS);
        expect(requests.conversations.map((c) => c.id), ['q2']);
        expect(
          (await repo.cachedConversations(Folder.FOLDER_INBOX)).requestCount,
          1,
        );
        expect(changes, 1);
      });

      test('a delete that fails otherwise leaves the cache and the lists '
          'alone', () async {
        await seed(requests: 2);
        var changes = 0;
        final sub = repo.conversationsChanged.listen((_) => changes++);
        addTearDown(sub.cancel);
        readAnswer = const NetworkException('raw-socket');

        await expectLater(
          repo.deleteConversation(idempotencyKey: 'k', conversationId: 'q1'),
          throwsA(isA<NetworkException>()),
        );
        await pumpEventQueue();

        expect(
          (await repo.cachedConversations(Folder.FOLDER_REQUESTS)).conversations
              .map((c) => c.id),
          unorderedEquals(['q1', 'q2']),
        );
        expect(
          (await repo.cachedConversations(Folder.FOLDER_INBOX)).requestCount,
          2,
        );
        expect(changes, 0);
      });

      group('dropBlockedRequest (W7-18)', () {
        test('removes only the list row: no call, the count and the thread '
            'stay, the lists are told', () async {
          await seed(requests: 2);
          msgAnswers.add(
            thread([
              msg(2, conversationId: 'q1'),
              msg(1, conversationId: 'q1'),
            ], withConversation: false),
          );
          await repo.refreshThread('q1');
          transport.calledProcedures.clear();
          var changes = 0;
          final sub = repo.conversationsChanged.listen((_) => changes++);
          addTearDown(sub.cancel);

          await repo.dropBlockedRequest('q1');
          await pumpEventQueue();

          expect(transport.calledProcedures, isEmpty);
          expect(
            (await repo.cachedConversations(Folder.FOLDER_REQUESTS))
                .conversations
                .map((c) => c.id),
            ['q2'],
          );
          expect(
            (await repo.cachedConversations(Folder.FOLDER_INBOX)).requestCount,
            2,
            reason: 'the next first Inbox page corrects the count',
          );
          expect((await repo.cachedThread('q1')).messages, hasLength(2));
          expect(changes, 1);
        });

        test(
          'an inbox conversation and an unknown id are left alone',
          () async {
            await seed(requests: 2);
            var changes = 0;
            final sub = repo.conversationsChanged.listen((_) => changes++);
            addTearDown(sub.cancel);

            await repo.dropBlockedRequest('a');
            await repo.dropBlockedRequest('nope');
            await pumpEventQueue();

            expect(
              (await repo.cachedConversations(Folder.FOLDER_INBOX))
                  .conversations
                  .map((c) => c.id),
              ['a'],
            );
            expect(changes, 0);
          },
        );
      });

      test('a failed accept leaves it alone', () async {
        await seed(requests: 2);
        readAnswer = const UnknownApiException('boom');

        await expectLater(
          repo.acceptMessageRequest(idempotencyKey: 'k', conversationId: 'q1'),
          throwsA(isA<AppException>()),
        );

        expect(
          (await repo.cachedConversations(Folder.FOLDER_INBOX)).requestCount,
          2,
        );
      });
    });

    test(
      'accept and delete announce a cache change; a failure does not',
      () async {
        convAnswers.add(
          pb.ListConversationsResponse(
            conversations: [
              conv(
                'q',
                folder: Folder.FOLDER_REQUESTS,
                state: ConversationState.CONVERSATION_STATE_REQUEST,
              ),
              conv(
                'r',
                folder: Folder.FOLDER_REQUESTS,
                state: ConversationState.CONVERSATION_STATE_REQUEST,
              ),
            ],
            sinceToken: 's',
          ),
        );
        await repo.refreshConversations(Folder.FOLDER_REQUESTS);
        var changes = 0;
        final sub = repo.conversationsChanged.listen((_) => changes++);
        addTearDown(sub.cancel);

        await repo.acceptMessageRequest(
          idempotencyKey: 'k',
          conversationId: 'q',
        );
        await pumpEventQueue();
        expect(changes, 1);

        await repo.deleteConversation(
          idempotencyKey: 'k2',
          conversationId: 'r',
        );
        await pumpEventQueue();
        expect(changes, 2);

        readAnswer = const UnknownApiException('boom');
        await expectLater(
          repo.acceptMessageRequest(idempotencyKey: 'k3', conversationId: 'z'),
          throwsA(isA<AppException>()),
        );
        await pumpEventQueue();
        expect(changes, 2);
      },
    );

    test('mark read zeroes the cached unread count', () async {
      convAnswers.add(
        pb.ListConversationsResponse(conversations: [conv('a', unread: 4)]),
      );
      await repo.refreshConversations(Folder.FOLDER_INBOX);
      await repo.markConversationRead(idempotencyKey: 'k', conversationId: 'a');
      final inbox = await repo.cachedConversations(Folder.FOLDER_INBOX);
      expect(inbox.conversations.single.unreadCount.toInt(), 0);
    });

    test('a send that finishes after sign-out writes nothing', () async {
      sendAnswer = pb.SendMessageResponse(
        message: msg(1, conversationId: 'c9'),
        conversation: conv('c9'),
      );
      final pending = repo.sendMessage(
        idempotencyKey: 'k',
        text: 't',
        conversationId: 'c9',
      );
      db.sessionEpoch.end();
      await pending;
      await db.clearAll();
      expect((await repo.cachedThread('c9')).messages, isEmpty);
    });
  });

  group('sign-out', () {
    test('clearAll leaves no message, conversation or token row', () async {
      convAnswers.add(
        pb.ListConversationsResponse(
          conversations: [conv('c1')],
          sinceToken: 's',
        ),
      );
      await repo.refreshConversations(Folder.FOLDER_INBOX);
      msgAnswers.add(thread(msgs(1, 3), next: 'n'));
      await repo.refreshThread('c1');

      db.sessionEpoch.end();
      await db.clearAll();

      expect(await db.select(db.conversationEntries).get(), isEmpty);
      expect(await db.select(db.messageEntries).get(), isEmpty);
      expect(await db.select(db.messagingStateEntries).get(), isEmpty);
    });

    test('a response in flight at sign-out is dropped, not written', () async {
      msgAnswers.add(thread(msgs(1, 3)));
      final pending = repo.refreshThread('c1');
      db.sessionEpoch.end();
      await pending;
      await db.clearAll();
      expect(await db.select(db.messageEntries).get(), isEmpty);
      expect(await db.select(db.messagingStateEntries).get(), isEmpty);
    });
  });

  group('RATE_LIMITED', () {
    final limited = withDetail(
      connect.Code.resourceExhausted,
      common.ErrorReason.ERROR_REASON_RATE_LIMITED,
      metadata: {'limit': 'read_budget_daily'},
    );

    test(
      'is held in the shared RateLimitHold; reads send no RPC until it clears',
      () async {
        msgAnswers.add(limited);
        await expectLater(
          repo.pollThread('c1'),
          throwsA(isA<RateLimitedException>()),
        );
        expect(hold.check(), isNotNull);

        await expectLater(
          repo.pollThread('c1'),
          throwsA(isA<RateLimitedException>()),
        );
        await expectLater(
          repo.refreshConversations(Folder.FOLDER_INBOX),
          throwsA(isA<RateLimitedException>()),
        );
        expect(transport.calledProcedures, [_listMsgs]);

        clock += const Duration(minutes: 6);
        msgAnswers.add(thread(msgs(1, 1)));
        await repo.pollThread('c1');
        expect(transport.calledProcedures, [_listMsgs, _listMsgs]);
      },
    );

    test('holds the ThreadPoller until the hold clears', () async {
      final poller = TimerThreadPoller(
        pull: () => repo.pollThread('c1'),
        rateLimitHold: hold,
        monotonic: () => clock,
      )..start();
      addTearDown(poller.dispose);

      msgAnswers.add(limited);
      poller.onPush();
      await pumpEventQueue();
      expect(transport.calledProcedures, [_listMsgs]);

      // A push while held does not pull.
      poller.onPush();
      await pumpEventQueue();
      expect(transport.calledProcedures, [_listMsgs]);

      clock += const Duration(minutes: 6);
      msgAnswers.add(thread(msgs(1, 1)));
      poller.onPush();
      await pumpEventQueue();
      expect(transport.calledProcedures, [_listMsgs, _listMsgs]);
    });

    test('a send RATE_LIMITED answer does not hold reads', () async {
      sendAnswer = limited;
      await expectLater(
        repo.sendMessage(idempotencyKey: 'k', text: 't', conversationId: 'c1'),
        throwsA(isA<RateLimitedException>()),
      );
      expect(hold.check(), isNull);
    });
  });

  group('errors', () {
    test(
      'CANNOT_MESSAGE, LIMIT_REACHED and DEGRADED_MODE reach the caller typed',
      () async {
        sendAnswer = withDetail(
          connect.Code.failedPrecondition,
          common.ErrorReason.ERROR_REASON_CANNOT_MESSAGE,
        );
        await expectLater(
          repo.sendMessage(
            idempotencyKey: 'k',
            text: 't',
            recipientUserId: 'u',
          ),
          throwsA(isA<CannotMessageException>()),
        );
        sendAnswer = withDetail(
          connect.Code.failedPrecondition,
          common.ErrorReason.ERROR_REASON_LIMIT_REACHED,
          metadata: {'limit': 'dm_new_daily'},
        );
        await expectLater(
          repo.sendMessage(
            idempotencyKey: 'k',
            text: 't',
            recipientUserId: 'u',
          ),
          throwsA(
            isA<LimitReachedException>().having(
              (e) => e.quota,
              'quota',
              'dm_new_daily',
            ),
          ),
        );
        sendAnswer = withDetail(
          connect.Code.unavailable,
          common.ErrorReason.ERROR_REASON_DEGRADED_MODE,
        );
        await expectLater(
          repo.sendMessage(
            idempotencyKey: 'k',
            text: 't',
            recipientUserId: 'u',
          ),
          throwsA(isA<DegradedModeException>()),
        );
      },
    );

    test(
      'FEATURE_DISABLED on a read asks GetMe once and stops all calls',
      () async {
        msgAnswers.add(
          withDetail(
            connect.Code.failedPrecondition,
            common.ErrorReason.ERROR_REASON_FEATURE_DISABLED,
            metadata: {'feature': 'messaging'},
          ),
        );
        await expectLater(
          repo.refreshThread('c1'),
          throwsA(isA<FeatureDisabledException>()),
        );
        expect(disabledAsked, 1);
        await expectLater(
          repo.refreshThread('c1'),
          throwsA(isA<FeatureDisabledException>()),
        );
        expect(transport.calledProcedures, [_listMsgs]);
      },
    );
  });
}
