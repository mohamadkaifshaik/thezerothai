import 'dart:async';
import 'dart:typed_data';

import 'package:connectrpc/connect.dart' as connect;
import 'package:dzeroth/core/crypto/mls_pair.dart';
import 'package:dzeroth/core/network/api_client.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/network/rate_limit_hold.dart';
import 'package:dzeroth/core/storage/app_database.dart';
import 'package:dzeroth/features/messages/data/messaging_repository.dart';
import 'package:dzeroth/features/messages/data/messaging_store.dart';
import 'package:dzeroth/features/messages/domain/messaging_feature_flag.dart';
import 'package:dzeroth/features/messages/domain/messaging_feature_gate.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pbenum.dart';
import 'package:drift/drift.dart'
    show ApplyInterceptor, QueryExecutor, QueryInterceptor;
import 'package:drift/native.dart';
import 'package:fake_async/fake_async.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_transport.dart';
import '../../../support/messaging_fixtures.dart';
import '../../../support/posts_fixtures.dart';

const _svc = '/dzeroth.messaging.v1.MessagingService';
const _conv = '0123456789abcdef0123456789abcdef';
const _key = '11111111-1111-4111-8111-111111111111';

Uint8List _b(List<int> v) => Uint8List.fromList(v);

/// Counts the SELECT statements the cache database runs.
class _CountSelects extends QueryInterceptor {
  int selects = 0;

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    selects++;
    return super.runSelect(executor, statement, args);
  }
}

void main() {
  late AppDatabase db;
  late MessagingStore store;
  late FakeTransport transport;
  late MessagingRepository repo;
  late MessagingFeatureGate gate;
  late bool flagOn;
  late List<Object> requests;
  Completer<Object>? hang;
  Object? Function(String procedure)? override;

  setUp(() {
    flagOn = true;
    requests = [];
    hang = null;
    override = null;
    db = AppDatabase.forTesting(NativeDatabase.memory());
    store = MessagingStore(db);
    transport = FakeTransport((procedure, input) async {
      requests.add(input);
      final h = hang;
      if (h != null) return h.future;
      final o = override?.call(procedure);
      if (o != null) return o;
      switch (procedure) {
        case '$_svc/SendMessage':
          return pb.SendMessageResponse();
        case '$_svc/CommitConversation':
          return pb.CommitConversationResponse(
            mlsGeneration: Int64(2),
            mlsEpoch: Int64(5),
          );
        case '$_svc/ListConversationCommits':
          return pb.ListConversationCommitsResponse();
        case '$_svc/ListEpochMessages':
          return pb.ListEpochMessagesResponse();
        case '$_svc/ListWelcomes':
          return pb.ListWelcomesResponse();
        case '$_svc/AckWelcomes':
          return pb.AckWelcomesResponse();
      }
      throw StateError('unexpected $procedure');
    });
    repo = MessagingRepository(
      apiClient: ApiClient.withTransport(transport),
      store: store,
      gate: gate = MessagingFeatureGate(isMessagingEnabled: () => flagOn),
      rateLimitHold: RateLimitHold(monotonic: () => Duration.zero),
    );
  });
  tearDown(() => db.close());

  test('sendEncrypted to a conversation sends the exact fields, text empty, '
      'no mls_init', () async {
    await repo.sendEncrypted(
      idempotencyKey: _key,
      conversationId: _conv,
      ciphertext: _b([1, 2, 3]),
      pair: const MlsPair(2, 5),
      reportCommitment: _b([9, 9]),
    );
    final r = requests.single as pb.SendMessageRequest;
    expect(r.idempotencyKey, _key);
    expect(r.conversationId, _conv);
    expect(r.hasRecipientUserId(), isFalse);
    expect(r.text, isEmpty);
    expect(r.sharedPostId, isEmpty);
    expect(r.ciphertext, [1, 2, 3]);
    expect(r.mlsGeneration, Int64(2));
    expect(r.mlsEpoch, Int64(5));
    expect(r.reportCommitment, [9, 9]);
    expect(r.hasMlsInit(), isFalse);
  });

  test('sendEncrypted to a recipient with mlsInit sets mls_init', () async {
    final init = pb.MlsInit(
      commit: [1],
      welcome: [2],
      welcomeDeviceIds: ['d1'],
    );
    await repo.sendEncrypted(
      idempotencyKey: _key,
      recipientUserId: 'u-peer',
      ciphertext: _b([1]),
      pair: const MlsPair(1, 1),
      reportCommitment: _b([3]),
      mlsInit: init.writeToBuffer(),
    );
    final r = requests.single as pb.SendMessageRequest;
    expect(r.recipientUserId, 'u-peer');
    expect(r.hasConversationId(), isFalse);
    expect(r.text, isEmpty);
    expect(r.mlsInit.commit, [1]);
    expect(r.mlsInit.welcome, [2]);
    expect(r.mlsInit.welcomeDeviceIds, ['d1']);
  });

  test('sendEncrypted with both or neither target asserts', () async {
    await expectLater(
      repo.sendEncrypted(
        idempotencyKey: _key,
        ciphertext: _b([1]),
        pair: const MlsPair(1, 1),
        reportCommitment: _b([3]),
      ),
      throwsA(isA<AssertionError>()),
    );
  });

  test(
    'a malformed mlsInit fails the returned Future, sends nothing',
    () async {
      await expectLater(
        repo.sendEncrypted(
          idempotencyKey: _key,
          recipientUserId: 'u-peer',
          ciphertext: _b([1]),
          pair: const MlsPair(1, 1),
          reportCommitment: _b([3]),
          mlsInit: _b([0xff]),
        ),
        throwsA(isA<Exception>()),
      );
      expect(requests, isEmpty);
    },
  );

  test('nothing is written to the cache by sendEncrypted', () async {
    override = (p) => p == '$_svc/SendMessage'
        ? pb.SendMessageResponse(
            message: pb.Message(id: 'm1', conversationId: _conv),
            conversation: pb.Conversation(id: _conv),
          )
        : null;
    await repo.sendEncrypted(
      idempotencyKey: _key,
      conversationId: _conv,
      ciphertext: _b([1]),
      pair: const MlsPair(1, 1),
      reportCommitment: _b([3]),
    );
    final cached = await repo.cachedThread(_conv);
    expect(cached.messages, isEmpty);
    expect(cached.conversation, isNull);
    expect(transport.calledProcedures, ['$_svc/SendMessage']);
  });

  test(
    'commitConversation sends the exact fields and returns the pair',
    () async {
      final pair = await repo.commitConversation(
        idempotencyKey: _key,
        conversationId: _conv,
        builtOn: const MlsPair(2, 4),
        commit: _b([7]),
        welcome: _b([8]),
        welcomeDeviceIds: ['d1', 'd2'],
        reset: true,
      );
      expect(pair, const MlsPair(2, 5));
      final r = requests.single as pb.CommitConversationRequest;
      expect(r.idempotencyKey, _key);
      expect(r.conversationId, _conv);
      expect(r.mlsGeneration, Int64(2));
      expect(r.mlsEpoch, Int64(4));
      expect(r.commit, [7]);
      expect(r.welcome, [8]);
      expect(r.welcomeDeviceIds, ['d1', 'd2']);
      expect(r.reset, isTrue);
    },
  );

  test('commitConversation without welcome leaves it empty', () async {
    await repo.commitConversation(
      idempotencyKey: _key,
      conversationId: _conv,
      builtOn: const MlsPair(1, 1),
      commit: _b([7]),
    );
    final r = requests.single as pb.CommitConversationRequest;
    expect(r.welcome, isEmpty);
    expect(r.welcomeDeviceIds, isEmpty);
    expect(r.reset, isFalse);
  });

  test(
    'a response pair the client cannot hold is UnknownApiException',
    () async {
      override = (p) => p == '$_svc/CommitConversation'
          ? pb.CommitConversationResponse(
              mlsGeneration: Int64(-1),
              mlsEpoch: Int64(1),
            )
          : null;
      await expectLater(
        repo.commitConversation(
          idempotencyKey: _key,
          conversationId: _conv,
          builtOn: const MlsPair(1, 1),
          commit: _b([7]),
        ),
        throwsA(isA<UnknownApiException>()),
      );
    },
  );

  test(
    'listConversationCommits sends after (null is 0, 0) and page size',
    () async {
      await repo.listConversationCommits(conversationId: _conv, after: null);
      await repo.listConversationCommits(
        conversationId: _conv,
        after: const MlsPair(3, 4),
        pageSize: 50,
      );
      final a = requests[0] as pb.ListConversationCommitsRequest;
      final b = requests[1] as pb.ListConversationCommitsRequest;
      expect(a.conversationId, _conv);
      expect(a.afterGeneration, Int64.ZERO);
      expect(a.afterEpoch, Int64.ZERO);
      expect(a.pageSize, 0);
      expect(b.afterGeneration, Int64(3));
      expect(b.afterEpoch, Int64(4));
      expect(b.pageSize, 50);
    },
  );

  test('listEpochMessages sends the pair, page size and token', () async {
    await repo.listEpochMessages(
      conversationId: _conv,
      pair: const MlsPair(2, 6),
      pageSize: 20,
      pageToken: 'tok',
    );
    final r = requests.single as pb.ListEpochMessagesRequest;
    expect(r.conversationId, _conv);
    expect(r.mlsGeneration, Int64(2));
    expect(r.mlsEpoch, Int64(6));
    expect(r.pageSize, 20);
    expect(r.pageToken, 'tok');
    expect(r.order, EpochMessageOrder.EPOCH_MESSAGE_ORDER_UNSPECIFIED);
  });

  test('listEpochMessages sends the created_at order when asked', () async {
    await repo.listEpochMessages(
      conversationId: _conv,
      pair: const MlsPair(2, 6),
      pageSize: 50,
      order: EpochMessageOrder.EPOCH_MESSAGE_ORDER_CREATED_AT,
    );
    final r = requests.single as pb.ListEpochMessagesRequest;
    expect(r.order, EpochMessageOrder.EPOCH_MESSAGE_ORDER_CREATED_AT);
  });

  test('listWelcomes sends the device', () async {
    await repo.listWelcomes(deviceId: 'dev-1');
    expect((requests.single as pb.ListWelcomesRequest).deviceId, 'dev-1');
  });

  test('ackWelcomes sends the key, device and ids', () async {
    await repo.ackWelcomes(
      idempotencyKey: _key,
      deviceId: 'dev-1',
      ids: ['w1', 'w2'],
    );
    final ack = requests.single as pb.AckWelcomesRequest;
    expect(ack.idempotencyKey, _key);
    expect(ack.deviceId, 'dev-1');
    expect(ack.ids, ['w1', 'w2']);
  });

  test('with messaging off for the caller: send and commit are refused '
      'without an RPC; lists and ack are allowed', () async {
    flagOn = false;
    await expectLater(
      repo.sendEncrypted(
        idempotencyKey: _key,
        conversationId: _conv,
        ciphertext: _b([1]),
        pair: const MlsPair(1, 1),
        reportCommitment: _b([3]),
      ),
      throwsA(isA<FeatureDisabledException>()),
    );
    await expectLater(
      repo.commitConversation(
        idempotencyKey: _key,
        conversationId: _conv,
        builtOn: const MlsPair(1, 1),
        commit: _b([7]),
      ),
      throwsA(isA<FeatureDisabledException>()),
    );
    expect(requests, isEmpty);
    await repo.listConversationCommits(conversationId: _conv, after: null);
    await repo.listEpochMessages(
      conversationId: _conv,
      pair: const MlsPair(1, 1),
    );
    await repo.listWelcomes(deviceId: 'dev-1');
    await repo.ackWelcomes(idempotencyKey: _key, deviceId: 'dev-1', ids: []);
    expect(requests, hasLength(4));
  });

  group('checkPostShare', () {
    const postId = '1234567890123456789';

    test('sends the post id and returns the shared post id', () async {
      override = (p) => p == '$_svc/CheckPostShare'
          ? pb.CheckPostShareResponse(sharedPostId: '9999999999999999999')
          : null;
      expect(await repo.checkPostShare(postId), '9999999999999999999');
      expect(transport.calledProcedures, ['$_svc/CheckPostShare']);
      expect((requests.single as pb.CheckPostShareRequest).postId, postId);
    });

    test('FEATURE_DISABLED for dm_share_check is re-thrown as dm_post_share '
        'and turns nothing off', () async {
      override = (p) => throw serverError(
        connect.Code.failedPrecondition,
        common.ErrorReason.ERROR_REASON_FEATURE_DISABLED,
        metadata: {'feature': kFeatureDmShareCheck},
      );
      await expectLater(
        repo.checkPostShare(postId),
        throwsA(
          isA<FeatureDisabledException>().having(
            (e) => e.feature,
            'feature',
            kFeatureDmPostShare,
          ),
        ),
      );
      expect(gate.canSend, isTrue);
      expect(gate.canRead, isTrue);
    });

    test('FEATURE_DISABLED for dm_post_share keeps its feature', () async {
      override = (p) => throw serverError(
        connect.Code.failedPrecondition,
        common.ErrorReason.ERROR_REASON_FEATURE_DISABLED,
        metadata: {'feature': kFeatureDmPostShare},
      );
      await expectLater(
        repo.checkPostShare(postId),
        throwsA(
          isA<FeatureDisabledException>().having(
            (e) => e.feature,
            'feature',
            kFeatureDmPostShare,
          ),
        ),
      );
      expect(gate.canSend, isTrue);
    });

    test('a posts-off answer to the share check turns nothing off and reads '
        'as post sharing unavailable', () async {
      override = (p) => throw serverError(
        connect.Code.failedPrecondition,
        common.ErrorReason.ERROR_REASON_FEATURE_DISABLED,
        metadata: {'feature': 'posts'},
      );
      await expectLater(
        repo.checkPostShare(postId),
        throwsA(
          isA<FeatureDisabledException>().having(
            (e) => e.feature,
            'feature',
            kFeatureDmPostShare,
          ),
        ),
      );
      expect(gate.canSend, isTrue);
      expect(gate.canRead, isTrue);
    });

    test('a messaging-off answer still turns messaging off', () async {
      override = (p) => throw serverError(
        connect.Code.failedPrecondition,
        common.ErrorReason.ERROR_REASON_FEATURE_DISABLED,
        metadata: {'feature': 'messaging'},
      );
      await expectLater(
        repo.checkPostShare(postId),
        throwsA(
          isA<FeatureDisabledException>().having(
            (e) => e.feature,
            'feature',
            'messaging',
          ),
        ),
      );
      expect(gate.canSend, isFalse);
    });

    test('PROTECTED_ACCOUNT is a ProtectedAccountException', () async {
      override = (p) => throw serverError(
        connect.Code.failedPrecondition,
        common.ErrorReason.ERROR_REASON_PROTECTED_ACCOUNT,
      );
      await expectLater(
        repo.checkPostShare(postId),
        throwsA(isA<ProtectedAccountException>()),
      );
      expect(gate.canSend, isTrue);
    });

    test('UNAVAILABLE is a NetworkException', () async {
      override = (p) => throw connect.ConnectException(
        connect.Code.unavailable,
        'temporarily busy, please retry',
      );
      await expectLater(
        repo.checkPostShare(postId),
        throwsA(isA<NetworkException>()),
      );
    });

    test('a share check that never answers ends as a connection failure '
        'after the timeout', () {
      fakeAsync((async) {
        hang = Completer<Object>();
        Object? error;
        repo
            .checkPostShare(postId)
            .then<void>((_) {}, onError: (Object e) => error = e);
        async.flushMicrotasks();
        async.elapse(kMlsRpcTimeout - const Duration(seconds: 1));
        expect(error, isNull);
        async.elapse(const Duration(seconds: 2));
        expect(error, isA<NetworkException>());
      });
    });

    test('NOT_FOUND is a NotFoundException', () async {
      override = (p) => throw connect.ConnectException(
        connect.Code.notFound,
        'post not found',
      );
      await expectLater(
        repo.checkPostShare(postId),
        throwsA(isA<NotFoundException>()),
      );
    });

    test('with messaging off for the caller no RPC is sent', () async {
      flagOn = false;
      await expectLater(
        repo.checkPostShare(postId),
        throwsA(isA<FeatureDisabledException>()),
      );
      expect(requests, isEmpty);
    });
  });

  test('sendEncrypted answered FEATURE_DISABLED for e2ee_dm throws and plain '
      'sending stays on', () async {
    var refused = false;
    override = (p) {
      if (p == '$_svc/SendMessage' && !refused) {
        refused = true;
        throw serverError(
          connect.Code.failedPrecondition,
          common.ErrorReason.ERROR_REASON_FEATURE_DISABLED,
          metadata: {'feature': kFeatureE2eeDm},
        );
      }
      return null;
    };
    await expectLater(
      repo.sendEncrypted(
        idempotencyKey: _key,
        recipientUserId: 'u-peer',
        ciphertext: _b([1]),
        pair: const MlsPair(1, 1),
        reportCommitment: _b([3]),
        mlsInit: pb.MlsInit(commit: [1]).writeToBuffer(),
      ),
      throwsA(
        isA<FeatureDisabledException>().having(
          (e) => e.feature,
          'feature',
          kFeatureE2eeDm,
        ),
      ),
    );
    expect(gate.canSend, isTrue);
    await repo.sendMessage(
      idempotencyKey: '22222222-2222-4222-8222-222222222222',
      text: 'plain',
      conversationId: _conv,
    );
    expect(transport.calledProcedures, [
      '$_svc/SendMessage',
      '$_svc/SendMessage',
    ]);
    expect(gate.canSend, isTrue);
  });

  test('a call that never answers throws NetworkException at 30 s', () {
    fakeAsync((async) {
      hang = Completer<Object>();
      Object? error;
      repo
          .listWelcomes(deviceId: 'dev-1')
          .then<void>((_) {}, onError: (Object e) => error = e);
      async.flushMicrotasks();
      async.elapse(kMlsRpcTimeout - const Duration(seconds: 1));
      expect(error, isNull);
      async.elapse(const Duration(seconds: 2));
      expect(error, isA<NetworkException>());
      expect((error! as NetworkException).message, 'timed out');
    });
  });

  test('every MLS method times out the same way', () {
    fakeAsync((async) {
      hang = Completer<Object>();
      final errors = <Object>[];
      void watch(Future<Object?> f) =>
          f.then<void>((_) {}, onError: (Object e) => errors.add(e));
      watch(
        repo.sendEncrypted(
          idempotencyKey: _key,
          conversationId: _conv,
          ciphertext: _b([1]),
          pair: const MlsPair(1, 1),
          reportCommitment: _b([3]),
        ),
      );
      watch(
        repo.commitConversation(
          idempotencyKey: _key,
          conversationId: _conv,
          builtOn: const MlsPair(1, 1),
          commit: _b([7]),
        ),
      );
      watch(repo.listConversationCommits(conversationId: _conv, after: null));
      watch(
        repo.listEpochMessages(
          conversationId: _conv,
          pair: const MlsPair(1, 1),
        ),
      );
      watch(repo.ackWelcomes(idempotencyKey: _key, deviceId: 'd', ids: []));
      async.flushMicrotasks();
      async.elapse(kMlsRpcTimeout + const Duration(seconds: 1));
      expect(errors, hasLength(5));
      expect(errors, everyElement(isA<NetworkException>()));
    });
  });

  test('a server error is mapped, not swallowed', () async {
    override = (p) =>
        throw connect.ConnectException(connect.Code.unavailable, 'down');
    await expectLater(
      repo.listWelcomes(deviceId: 'dev-1'),
      throwsA(isA<NetworkException>()),
    );
  });

  group('encrypted message lists and the cache (R14)', () {
    final answers = <pb.ListMessagesResponse>[];
    final encrypted = <String>[];
    final accepted = <String>[];
    final deleted = <String>[];

    pb.Message enc(int n) => msg(n, conversationId: _conv, text: '')
      ..ciphertext = [7, 7, 7]
      ..mlsGeneration = Int64(1);

    pb.Conversation mlsHeader() => conv(_conv)
      ..encryption = ConversationEncryption.CONVERSATION_ENCRYPTION_MLS
      ..mlsGeneration = Int64(1)
      ..mlsEpoch = Int64(2);

    pb.ListMessagesResponse listAnswer(
      List<pb.Message> messages, {
      pb.Conversation? conversation,
      String since = '',
      String next = '',
      String gap = '',
    }) => pb.ListMessagesResponse(
      messages: messages,
      conversation: conversation,
      sinceToken: since,
      nextPageToken: next,
      gapPageToken: gap,
    );

    Future<List<Object?>> tables() async => [
      await db.select(db.messageEntries).get(),
      await db.select(db.conversationEntries).get(),
      await db.select(db.messagingStateEntries).get(),
    ];

    Future<void> expectEmptyTables() async {
      expect(await db.select(db.messageEntries).get(), isEmpty);
      expect(await db.select(db.conversationEntries).get(), isEmpty);
      expect(await db.select(db.messagingStateEntries).get(), isEmpty);
    }

    setUp(() async {
      await db.claimCacheFor('a');
      answers.clear();
      encrypted.clear();
      accepted.clear();
      deleted.clear();
      repo
        ..onEncryptedConversation = encrypted.add
        ..onRequestAccepted = accepted.add
        ..onConversationDeleted = deleted.add;
      override = (p) {
        switch (p) {
          case '$_svc/ListMessages':
            return answers.removeAt(0);
          case '$_svc/ListConversations':
            return pb.ListConversationsResponse(requestCount: Int64(0));
          case '$_svc/AcceptMessageRequest':
            return pb.AcceptMessageRequestResponse();
          case '$_svc/DeleteConversation':
            return pb.DeleteConversationResponse();
        }
        return null;
      };
    });

    test('listMlsMessages sends the since token and page size 50', () async {
      answers
        ..add(listAnswer([]))
        ..add(listAnswer([]));
      await repo.listMlsMessages(conversationId: _conv, sinceToken: 's1');
      await repo.listMlsMessages(conversationId: _conv, pageToken: 'p1');
      final a = requests[0] as pb.ListMessagesRequest;
      final b = requests[1] as pb.ListMessagesRequest;
      expect(a.conversationId, _conv);
      expect(a.sinceToken, 's1');
      expect(a.pageToken, isEmpty);
      expect(a.pageSize, 50);
      expect(b.sinceToken, isEmpty);
      expect(b.pageToken, 'p1');
      expect(b.pageSize, 50);
      await expectEmptyTables();
    });

    test('listMlsMessages with both tokens throws ArgumentError and sends '
        'nothing', () async {
      await expectLater(
        repo.listMlsMessages(
          conversationId: _conv,
          sinceToken: 's1',
          pageToken: 'p1',
        ),
        throwsA(isA<ArgumentError>()),
      );
      expect(requests, isEmpty);
    });

    test('listMlsMessages writes nothing to the cache', () async {
      answers.add(
        listAnswer(
          [enc(1), enc(2)],
          conversation: mlsHeader(),
          since: 's9',
          next: 'older',
        ),
      );
      final page = await repo.listMlsMessages(conversationId: _conv);
      expect(page.messages, hasLength(2));
      expect(page.messages.first.ciphertext, isNotEmpty);
      await expectEmptyTables();
      expect(encrypted, isEmpty);
      expect(transport.calledProcedures, ['$_svc/ListMessages']);
    });

    test('listMlsMessages writes nothing on an error either', () async {
      override = (p) =>
          throw connect.ConnectException(connect.Code.unavailable, 'down');
      await expectLater(
        repo.listMlsMessages(conversationId: _conv),
        throwsA(isA<NetworkException>()),
      );
      await expectEmptyTables();
    });

    test('listMlsMessages times out at 30 s and writes nothing', () async {
      Object? error;
      fakeAsync((async) {
        hang = Completer<Object>();
        repo
            .listMlsMessages(conversationId: _conv)
            .then<void>((_) {}, onError: (Object e) => error = e);
        async.flushMicrotasks();
        async.elapse(kMlsRpcTimeout - const Duration(seconds: 1));
        expect(error, isNull);
        async.elapse(const Duration(seconds: 2));
        expect(error, isA<NetworkException>());
      });
      await expectEmptyTables();
    });

    test('a rejected since token surfaces as ValidationException '
        'since_token and the cached thread, if any, is untouched', () async {
      answers.add(
        listAnswer(
          [msg(1, conversationId: _conv), msg(2, conversationId: _conv)],
          conversation: conv(_conv),
          since: 's1',
        ),
      );
      await repo.refreshThread(_conv);
      final before = await tables();
      expect((before[0]! as List).length, 2);
      override = (p) => throw serverError(
        connect.Code.invalidArgument,
        common.ErrorReason.ERROR_REASON_VALIDATION,
        metadata: {'field': 'since_token'},
      );
      await expectLater(
        repo.listMlsMessages(conversationId: _conv, sinceToken: 's1'),
        throwsA(
          isA<ValidationException>().having(
            (e) => e.field,
            'field',
            'since_token',
          ),
        ),
      );
      expect(await tables(), before);
    });

    test('RATE_LIMITED sets the read hold as the other reads do', () async {
      override = (p) => throw serverError(
        connect.Code.resourceExhausted,
        common.ErrorReason.ERROR_REASON_RATE_LIMITED,
        metadata: {'limit': 'search_daily'},
      );
      await expectLater(
        repo.listMlsMessages(conversationId: _conv),
        throwsA(isA<RateLimitedException>()),
      );
      expect(repo.rateLimitedFor(), isNotNull);
      requests.clear();
      await expectLater(
        repo.listMlsMessages(conversationId: _conv),
        throwsA(isA<RateLimitedException>()),
      );
      expect(requests, isEmpty);
      await expectEmptyTables();
    });

    test('it is allowed when messaging is off for the caller and refused '
        'when globally off', () async {
      flagOn = false;
      answers.add(listAnswer([]));
      await repo.listMlsMessages(conversationId: _conv);
      expect(requests, hasLength(1));
      override = (p) => throw serverError(
        connect.Code.failedPrecondition,
        common.ErrorReason.ERROR_REASON_FEATURE_DISABLED,
        metadata: {'feature': 'messaging'},
      );
      await expectLater(
        repo.listMlsMessages(conversationId: _conv),
        throwsA(isA<FeatureDisabledException>()),
      );
      requests.clear();
      await expectLater(
        repo.listMlsMessages(conversationId: _conv),
        throwsA(isA<FeatureDisabledException>()),
      );
      expect(requests, isEmpty);
      await expectEmptyTables();
    });

    test('an e2ee_dm FEATURE_DISABLED on listMlsMessages leaves messaging '
        'reads on', () async {
      override = (p) => throw serverError(
        connect.Code.failedPrecondition,
        common.ErrorReason.ERROR_REASON_FEATURE_DISABLED,
        metadata: {'feature': kFeatureE2eeDm},
      );
      await expectLater(
        repo.listMlsMessages(conversationId: _conv),
        throwsA(isA<FeatureDisabledException>()),
      );
      expect(gate.canRead, isTrue);
      requests.clear();
      answers.add(listAnswer([]));
      override = (p) => p == '$_svc/ListMessages' ? answers.removeAt(0) : null;
      await repo.listMlsMessages(conversationId: _conv);
      expect(requests, hasLength(1));
      await expectEmptyTables();
    });

    test('refreshThread on an MLS conversation stores no message and calls '
        'onEncryptedConversation once', () async {
      answers.add(
        listAnswer(
          [enc(1), enc(2)],
          conversation: mlsHeader(),
          since: 's1',
          next: 'older',
        ),
      );
      await repo.refreshThread(_conv);
      expect(await db.select(db.messageEntries).get(), isEmpty);
      expect(encrypted, [_conv]);
      // A since refresh that spans a gap page is still one call.
      answers
        ..add(
          listAnswer(
            [enc(3)],
            conversation: mlsHeader(),
            since: 's2',
            gap: 'g',
          ),
        )
        ..add(listAnswer([enc(4)]));
      await repo.refreshThread(_conv);
      expect(await db.select(db.messageEntries).get(), isEmpty);
      expect(encrypted, [_conv, _conv]);
    });

    test('what counts as encrypted-shaped is dropped, plaintext is kept '
        '(a backdated plaintext message is a stated limit)', () async {
      final removed = msg(3, conversationId: _conv, text: '')
        ..ciphertextRemoved = true;
      final generation = msg(2, conversationId: _conv, text: '')
        ..mlsGeneration = Int64(3);
      answers.add(
        listAnswer(
          [msg(5, conversationId: _conv), removed, generation, enc(1)],
          conversation: mlsHeader(),
          since: 's1',
        ),
      );
      final snap = await repo.refreshThread(_conv);
      expect([for (final m in snap.messages) m.id], [hexId(5)]);
      expect(encrypted, [_conv]);
    });

    test('a plaintext thread is cached exactly as before', () async {
      final header = conv(_conv, snippet: 'hi');
      answers.add(
        listAnswer(
          [msg(1, conversationId: _conv), msg(2, conversationId: _conv)],
          conversation: header,
          since: 's1',
        ),
      );
      final snap = await repo.refreshThread(_conv);
      expect(snap.messages, hasLength(2));
      expect(snap.messages.first.text, 'hello');
      expect(snap.conversation!.lastMessage.snippet, 'hi');
      expect(snap.conversation!.lastMessage.encrypted, isFalse);
      expect(snap.conversation!.writeToBuffer(), header.writeToBuffer());
      expect(snap.sinceToken, 's1');
      expect(encrypted, isEmpty);
    });

    test('refreshThread on an MLS conversation still returns the '
        'conversation header', () async {
      answers.add(listAnswer([enc(1)], conversation: mlsHeader(), since: 's1'));
      final snap = await repo.refreshThread(_conv);
      expect(snap.messages, isEmpty);
      expect(snap.conversation!.id, _conv);
      expect(
        snap.conversation!.encryption,
        ConversationEncryption.CONVERSATION_ENCRYPTION_MLS,
      );
      expect(snap.conversation!.lastMessage.encrypted, isTrue);
      expect(await repo.cachedEverEncrypted(_conv), isTrue);
    });

    test('loadOlderMessages and fetchOlderForSearch drop encrypted '
        'messages too', () async {
      answers.add(
        listAnswer(
          [msg(5, conversationId: _conv)],
          conversation: conv(_conv),
          since: 's1',
          next: 'older',
        ),
      );
      await repo.refreshThread(_conv);
      answers.add(listAnswer([enc(4), msg(3, conversationId: _conv)]));
      final older = await repo.loadOlderMessages(_conv);
      expect([for (final m in older.messages) m.id], [hexId(5), hexId(3)]);
      expect(encrypted, [_conv]);
      answers.add(listAnswer([enc(2), msg(1, conversationId: _conv)]));
      final page = await repo.fetchOlderForSearch(_conv, 'tok');
      expect([for (final m in page.messages) m.id], [hexId(1)]);
      expect(encrypted, [_conv, _conv]);
      expect(await db.select(db.messageEntries).get(), hasLength(2));
    });

    test('sendMessage with an encrypted answer caches no message and '
        'reports it', () async {
      override = (p) => p == '$_svc/SendMessage'
          ? pb.SendMessageResponse(message: enc(1), conversation: mlsHeader())
          : null;
      final response = await repo.sendMessage(
        idempotencyKey: _key,
        text: 'x',
        conversationId: _conv,
      );
      expect(response.message.ciphertext, [7, 7, 7]);
      expect(await db.select(db.messageEntries).get(), isEmpty);
      expect(await db.select(db.conversationEntries).get(), isEmpty);
      expect(encrypted, [_conv]);
      expect(await repo.cachedEverEncrypted(_conv), isTrue);
    });

    test('onRequestAccepted fires after a successful accept and not after '
        'a failed one', () async {
      await repo.acceptMessageRequest(
        idempotencyKey: _key,
        conversationId: _conv,
      );
      expect(accepted, [_conv]);
      override = (p) =>
          throw connect.ConnectException(connect.Code.unavailable, 'down');
      await expectLater(
        repo.acceptMessageRequest(idempotencyKey: _key, conversationId: _conv),
        throwsA(isA<NetworkException>()),
      );
      override = (p) =>
          throw connect.ConnectException(connect.Code.notFound, 'gone');
      await expectLater(
        repo.acceptMessageRequest(idempotencyKey: _key, conversationId: _conv),
        throwsA(isA<NotFoundException>()),
      );
      expect(accepted, [_conv]);
    });

    test('onConversationDeleted fires after a successful delete', () async {
      await repo.deleteConversation(
        idempotencyKey: _key,
        conversationId: _conv,
      );
      expect(deleted, [_conv]);
    });

    test('a NONE header never clears a cached encrypted marker', () async {
      pb.Conversation encryptedRow() => conv(_conv)
        ..encryption = ConversationEncryption.CONVERSATION_ENCRYPTION_MLS
        ..lastMessage = pb.MessagePreview(encrypted: true);
      pb.Conversation noneRow() => conv(_conv, snippet: 'plain words');
      override = (p) {
        switch (p) {
          case '$_svc/ListConversations':
            return pb.ListConversationsResponse(
              conversations: [encryptedRow()],
              sinceToken: 't1',
              requestCount: Int64(0),
            );
        }
        return null;
      };
      await repo.refreshConversations(Folder.FOLDER_INBOX);
      expect(await repo.cachedEverEncrypted(_conv), isTrue);
      expect(encrypted, isEmpty);

      // A since refresh answering NONE with a snippet and encrypted false.
      override = (p) => pb.ListConversationsResponse(
        conversations: [noneRow()],
        sinceToken: 't2',
        requestCount: Int64(0),
      );
      await repo.refreshConversations(Folder.FOLDER_INBOX);
      var row = (await repo.cachedConversation(_conv))!;
      expect(row.lastMessage.encrypted, isTrue);
      expect(row.lastMessage.snippet, isEmpty);
      expect(encrypted, [_conv]);

      // A NONE thread header on a cold open does the same.
      answers.add(
        listAnswer(
          [],
          conversation: conv(_conv, snippet: 'plain words'),
          since: 's1',
        ),
      );
      override = (p) => p == '$_svc/ListMessages' ? answers.removeAt(0) : null;
      await repo.refreshThread(_conv);
      row = (await repo.cachedConversation(_conv))!;
      expect(row.lastMessage.encrypted, isTrue);
      expect(row.lastMessage.snippet, isEmpty);
      expect(encrypted, [_conv, _conv]);
      expect(await repo.cachedEverEncrypted(_conv), isTrue);
    });

    test(
      'cachedEverEncrypted is false for an unknown or plaintext row',
      () async {
        expect(await repo.cachedEverEncrypted('nope'), isFalse);
        override = (p) => pb.ListConversationsResponse(
          conversations: [conv(_conv, snippet: 'hi')],
          sinceToken: 't1',
          requestCount: Int64(0),
        );
        await repo.refreshConversations(Folder.FOLDER_INBOX);
        expect(await repo.cachedEverEncrypted(_conv), isFalse);
        expect(encrypted, isEmpty);
      },
    );

    group('the ever-encrypted set', () {
      void script(String procedure, List<Object> items) {
        override = (p) {
          if (p != procedure) return null;
          final next = items.removeAt(0);
          if (next is connect.ConnectException) throw next;
          return next;
        };
      }

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

      Future<void> mark() =>
          store.markEverEncrypted({_conv}, session: store.session);

      Future<List<Object?>> storedPayloads() async => [
        for (final r in await db.select(db.messageEntries).get()) r.payload,
      ];

      Future<void> expectNoCiphertextStored() async {
        for (final r in await db.select(db.messageEntries).get()) {
          expect(pb.Message.fromBuffer(r.payload).ciphertext, isEmpty);
          expect(pb.Message.fromBuffer(r.payload).mlsGeneration, Int64.ZERO);
        }
      }

      test('a since page that drops an encrypted message records the '
          'conversation as ever encrypted (cachedEverEncrypted true, '
          'snapshot header encrypted)', () async {
        answers.add(
          listAnswer(
            [msg(1, conversationId: _conv)],
            conversation: conv(_conv, snippet: 'hi'),
            since: 's1',
          ),
        );
        await repo.refreshThread(_conv);
        expect(await repo.cachedEverEncrypted(_conv), isFalse);
        answers.add(listAnswer([enc(2)], since: 's2'));
        final snap = await repo.refreshThread(_conv);
        expect(await repo.cachedEverEncrypted(_conv), isTrue);
        expect(snap.conversation!.lastMessage.encrypted, isTrue);
        expect(snap.conversation!.lastMessage.snippet, isEmpty);
        expect(snap.messages, hasLength(1));
        expect(encrypted, [_conv]);
        await expectNoCiphertextStored();
      });

      test(
        'the marker survives a new repository over the same store',
        () async {
          answers.add(listAnswer([enc(1)], since: 's1'));
          await repo.refreshThread(_conv);
          final again = MessagingRepository(
            apiClient: ApiClient.withTransport(transport),
            store: MessagingStore(db),
            gate: MessagingFeatureGate(isMessagingEnabled: () => true),
          );
          expect(await again.cachedEverEncrypted(_conv), isTrue);
        },
      );

      test('the ever-encrypted set holds ids only', () async {
        answers.add(
          listAnswer([enc(1)], conversation: mlsHeader(), since: 's1'),
        );
        await repo.refreshThread(_conv);
        final rows = [
          for (final r in await db.select(db.messagingStateEntries).get())
            if (r.stateKey.startsWith(kEverEncryptedStatePrefix)) r,
        ];
        expect(rows, hasLength(1));
        expect(rows.single.stateKey, '$kEverEncryptedStatePrefix$_conv');
        expect(rows.single.sinceToken, isEmpty);
        expect(rows.single.olderPageToken, isEmpty);
        expect(rows.single.requestCount, isNull);
        expect(await storedPayloads(), isEmpty);
      });

      test('an inbox cold open that omits a marked conversation, then a NONE '
          'row, keeps cachedEverEncrypted true', () async {
        script('$_svc/ListConversations', [
          inbox([conv(_conv, snippet: 'old')], since: 't1'),
          rejectedToken('since_token'),
          inbox([], since: 't2'),
          inbox([conv(_conv, snippet: 'plain words')], since: 't3'),
        ]);
        await repo.refreshConversations(Folder.FOLDER_INBOX);
        await mark();
        await repo.refreshConversations(Folder.FOLDER_INBOX);
        expect(await repo.cachedConversation(_conv), isNull);
        expect(await repo.cachedEverEncrypted(_conv), isTrue);
        await repo.refreshConversations(Folder.FOLDER_INBOX);
        final row = (await repo.cachedConversation(_conv))!;
        expect(row.lastMessage.encrypted, isTrue);
        expect(row.lastMessage.snippet, isEmpty);
        expect(await repo.cachedEverEncrypted(_conv), isTrue);
        expect(encrypted, [_conv]);
      });

      test('accept NOT_FOUND on a marked request keeps cachedEverEncrypted '
          'true', () async {
        await mark();
        override = (p) =>
            throw connect.ConnectException(connect.Code.notFound, 'gone');
        await expectLater(
          repo.acceptMessageRequest(
            idempotencyKey: _key,
            conversationId: _conv,
          ),
          throwsA(isA<NotFoundException>()),
        );
        expect(await repo.cachedEverEncrypted(_conv), isTrue);
      });

      test('a NONE sendMessage answer never clears the marker', () async {
        await mark();
        override = (p) => p == '$_svc/SendMessage'
            ? pb.SendMessageResponse(
                message: msg(1, conversationId: _conv),
                conversation: conv(_conv, snippet: 'plain'),
              )
            : null;
        await repo.sendMessage(
          idempotencyKey: _key,
          text: 'x',
          conversationId: _conv,
        );
        final row = (await repo.cachedConversation(_conv))!;
        expect(row.lastMessage.encrypted, isTrue);
        expect(row.lastMessage.snippet, isEmpty);
        expect(await repo.cachedEverEncrypted(_conv), isTrue);
        expect(encrypted, [_conv]);
      });

      test('keep-paging older conversations never clears the marker', () async {
        await mark();
        script('$_svc/ListConversations', [
          inbox([], since: 't1', next: 'older'),
          inbox([conv(_conv, snippet: 'plain')]),
        ]);
        await repo.refreshConversations(Folder.FOLDER_INBOX);
        final row = (await repo.cachedConversation(_conv))!;
        expect(row.lastMessage.encrypted, isTrue);
        expect(row.lastMessage.snippet, isEmpty);
        expect(await repo.cachedEverEncrypted(_conv), isTrue);
      });

      // D2, owner approved 2026-11-20: delete-for-me used to clear the mark;
      // it now keeps it (only sign-out clears it).
      test('delete-for-me keeps the ever-encrypted mark and a later NONE '
          'header stays encrypted', () async {
        await mark();
        await repo.deleteConversation(
          idempotencyKey: _key,
          conversationId: _conv,
        );
        expect(await repo.cachedEverEncrypted(_conv), isTrue);
        override = (p) =>
            throw connect.ConnectException(connect.Code.notFound, 'gone');
        await repo.deleteConversation(
          idempotencyKey: _key,
          conversationId: _conv,
        );
        expect(await repo.cachedEverEncrypted(_conv), isTrue);
        // The server later answers NONE for the same (fixed) conversation id.
        script('$_svc/ListMessages', [
          listAnswer(
            [msg(1, conversationId: _conv)],
            conversation: conv(_conv, snippet: 'plain words'),
            since: 's1',
          ),
        ]);
        final snap = await repo.refreshThread(_conv);
        expect(snap.conversation!.lastMessage.encrypted, isTrue);
        expect(snap.conversation!.lastMessage.snippet, isEmpty);
        expect(await repo.cachedEverEncrypted(_conv), isTrue);
      });

      test('a successful sendEncrypted records the conversation as ever '
          'encrypted', () async {
        override = (p) => p == '$_svc/SendMessage'
            ? pb.SendMessageResponse(
                message: pb.Message(id: hexId(1), conversationId: _conv),
              )
            : null;
        expect(await repo.cachedEverEncrypted(_conv), isFalse);
        await repo.sendEncrypted(
          idempotencyKey: _key,
          recipientUserId: 'u-peer',
          ciphertext: _b([1]),
          pair: const MlsPair(1, 1),
          reportCommitment: _b([3]),
        );
        expect(await repo.cachedEverEncrypted(_conv), isTrue);
        expect(await db.select(db.messageEntries).get(), isEmpty);
        expect(await db.select(db.conversationEntries).get(), isEmpty);
        // A failed send records nothing.
        const other = 'fedcba9876543210fedcba9876543210';
        override = (p) =>
            throw connect.ConnectException(connect.Code.unavailable, 'down');
        await expectLater(
          repo.sendEncrypted(
            idempotencyKey: _key,
            conversationId: other,
            ciphertext: _b([1]),
            pair: const MlsPair(1, 1),
            reportCommitment: _b([3]),
          ),
          throwsA(isA<NetworkException>()),
        );
        expect(await repo.cachedEverEncrypted(other), isFalse);
      });

      test('noteEverEncrypted records a valid id once and ignores an invalid '
          'one', () async {
        Future<List<String>> marks() async => [
          for (final r in await db.select(db.messagingStateEntries).get())
            if (r.stateKey.startsWith(kEverEncryptedStatePrefix)) r.stateKey,
        ];
        final session = repo.cacheSession;
        await repo.noteEverEncrypted(_conv, session: session);
        await repo.noteEverEncrypted(_conv, session: session);
        await repo.noteEverEncrypted('not-a-conversation-id', session: session);
        await repo.noteEverEncrypted('', session: session);
        await repo.noteEverEncrypted(_conv.toUpperCase(), session: session);
        expect(await marks(), ['$kEverEncryptedStatePrefix$_conv']);
        expect(await repo.cachedEverEncrypted(_conv), isTrue);
        // Bound to the session it was given: nothing lands once that
        // session ended (a sign-out while the write was queued).
        const other = 'fedcba9876543210fedcba9876543210';
        final pending = repo.noteEverEncrypted(other, session: session);
        db.sessionEpoch.end();
        await pending;
        expect(await marks(), ['$kEverEncryptedStatePrefix$_conv']);
      });

      test('a mark noted with a session that ended is dropped', () async {
        // Captured by user a's work before its call.
        final session = repo.cacheSession;
        // User b claims the cache before the stale call runs.
        await db.claimCacheFor('b');
        await repo.noteEverEncrypted(_conv, session: session);
        expect(await store.isEverEncrypted(_conv), isFalse);
        expect([
          for (final r in await db.select(db.messagingStateEntries).get())
            if (r.stateKey.startsWith(kEverEncryptedStatePrefix)) r,
        ], isEmpty);
        // The same call with b's session lands.
        await repo.noteEverEncrypted(_conv, session: repo.cacheSession);
        expect(await store.isEverEncrypted(_conv), isTrue);
      });

      test('an MLS since page followed by a failing gap page still records '
          'the mark', () async {
        script('$_svc/ListMessages', [
          listAnswer(
            [msg(1, conversationId: _conv)],
            conversation: conv(_conv, snippet: 'hi'),
            since: 's1',
          ),
          listAnswer(
            [enc(2)],
            conversation: mlsHeader(),
            since: 's2',
            gap: 'g1',
          ),
          connect.ConnectException(connect.Code.unavailable, 'down'),
        ]);
        await repo.refreshThread(_conv);
        expect(await repo.cachedEverEncrypted(_conv), isFalse);
        await expectLater(
          repo.refreshThread(_conv),
          throwsA(isA<NetworkException>()),
        );
        expect(await repo.cachedEverEncrypted(_conv), isTrue);
        expect(encrypted, [_conv]);
        await expectNoCiphertextStored();
      });

      test('a message carrying only a report commitment or an epoch is not '
          'cached', () async {
        final epochOnly = msg(2, conversationId: _conv, text: '')
          ..mlsEpoch = Int64(3);
        final commitmentOnly = msg(3, conversationId: _conv, text: '')
          ..reportCommitment = [5, 5];
        answers.add(
          listAnswer(
            [msg(1, conversationId: _conv), epochOnly, commitmentOnly],
            conversation: conv(_conv, snippet: 'hi'),
            since: 's1',
          ),
        );
        final snap = await repo.refreshThread(_conv);
        expect([for (final m in snap.messages) m.id], [hexId(1)]);
        for (final r in await db.select(db.messageEntries).get()) {
          final m = pb.Message.fromBuffer(r.payload);
          expect(m.mlsEpoch, Int64.ZERO);
          expect(m.reportCommitment, isEmpty);
        }
        expect(await repo.cachedEverEncrypted(_conv), isTrue);
      });

      test('an invalid conversation id is not recorded as ever '
          'encrypted', () async {
        await store.markEverEncrypted({
          'c1',
          'not-hex',
          '',
          _conv.toUpperCase(),
          '$_conv%',
          _conv,
        }, session: store.session);
        final keys = [
          for (final r in await db.select(db.messagingStateEntries).get())
            r.stateKey,
        ];
        expect(keys, ['$kEverEncryptedStatePrefix$_conv']);
        // Through a read too: a server-chosen id that is not one is dropped.
        answers.add(listAnswer([enc(1)..conversationId = 'c1'], since: 's1'));
        await repo.refreshThread('c1');
        expect(await store.isEverEncrypted('c1'), isFalse);
        expect(await db.select(db.messageEntries).get(), isEmpty);
      });

      test('a refresh that learns nothing new about a marked conversation '
          'makes no report', () async {
        pb.Conversation shownEncrypted() =>
            conv(_conv)..lastMessage = pb.MessagePreview(encrypted: true);
        await mark();
        script('$_svc/ListConversations', [
          inbox([shownEncrypted()], since: 't1'),
          inbox([shownEncrypted()], since: 't2'),
          inbox([
            shownEncrypted()
              ..encryption = ConversationEncryption.CONVERSATION_ENCRYPTION_MLS,
          ], since: 't3'),
        ]);
        await repo.refreshConversations(Folder.FOLDER_INBOX);
        await repo.refreshConversations(Folder.FOLDER_INBOX);
        await repo.refreshConversations(Folder.FOLDER_INBOX);
        expect(encrypted, isEmpty);
        expect(await repo.cachedEverEncrypted(_conv), isTrue);
      });

      test('conversationWithPeer shows a marked conversation as '
          'encrypted', () async {
        await store.applyConversationsColdOpen(
          Folder.FOLDER_INBOX,
          items: [conv(_conv, snippet: 'plain words')],
          sinceToken: 't1',
          nextPageToken: '',
          session: store.session,
        );
        var row = (await repo.cachedConversationWith('u-$_conv'))!;
        expect(row.lastMessage.snippet, 'plain words');
        await mark();
        row = (await repo.cachedConversationWith('u-$_conv'))!;
        expect(row.lastMessage.encrypted, isTrue);
        expect(row.lastMessage.snippet, isEmpty);
        // The stored row is not rewritten by the read.
        final stored = pb.Conversation.fromBuffer(
          (await db.select(db.conversationEntries).get()).single.payload,
        );
        expect(stored.lastMessage.snippet, 'plain words');
      });

      test('dropBlockedRequest keeps the mark', () async {
        await store.applyConversationsColdOpen(
          Folder.FOLDER_REQUESTS,
          items: [
            conv(
              _conv,
              folder: Folder.FOLDER_REQUESTS,
              state: ConversationState.CONVERSATION_STATE_REQUEST,
            ),
          ],
          sinceToken: 't1',
          nextPageToken: '',
          session: store.session,
        );
        await mark();
        await repo.dropBlockedRequest(_conv);
        expect(await repo.cachedConversation(_conv), isNull);
        expect(await repo.cachedEverEncrypted(_conv), isTrue);
      });

      test('a dm_post_share FEATURE_DISABLED on a read leaves messaging '
          'reads on', () async {
        script('$_svc/ListMessages', [
          serverError(
            connect.Code.failedPrecondition,
            common.ErrorReason.ERROR_REASON_FEATURE_DISABLED,
            metadata: {'feature': kFeatureDmPostShare},
          ),
          listAnswer(
            [msg(1, conversationId: _conv)],
            conversation: conv(_conv, snippet: 'hi'),
            since: 's1',
          ),
        ]);
        await expectLater(
          repo.refreshThread(_conv),
          throwsA(isA<FeatureDisabledException>()),
        );
        expect(gate.canRead, isTrue);
        requests.clear();
        final snap = await repo.refreshThread(_conv);
        expect(requests, hasLength(1));
        expect(snap.messages, hasLength(1));
      });

      test('accept and delete with an ended session make no report', () async {
        // The session ends while each call is in flight.
        override = (p) {
          switch (p) {
            case '$_svc/AcceptMessageRequest':
              db.sessionEpoch.end();
              return pb.AcceptMessageRequestResponse();
            case '$_svc/DeleteConversation':
              db.sessionEpoch.end();
              return pb.DeleteConversationResponse();
          }
          return null;
        };
        await repo.acceptMessageRequest(
          idempotencyKey: _key,
          conversationId: _conv,
        );
        await repo.deleteConversation(
          idempotencyKey: _key,
          conversationId: _conv,
        );
        expect(accepted, isEmpty);
        expect(deleted, isEmpty);
      });

      test('sign-out clears the marker', () async {
        await mark();
        await db.clearAll();
        expect(await repo.cachedEverEncrypted(_conv), isFalse);
      });

      test('an id-bearing cache wipe keeps the marker', () async {
        await mark();
        await db.clearIdBearingCache();
        expect(await repo.cachedEverEncrypted(_conv), isTrue);
      });

      test('a throwing callback neither fails nor masks a call that '
          'succeeded', () async {
        repo.onEncryptedConversation = (_) => throw StateError('boom');
        repo.onRequestAccepted = (_) => throw StateError('boom');
        answers.add(listAnswer([enc(1)], since: 's1'));
        await repo.refreshThread(_conv);
        await repo.acceptMessageRequest(
          idempotencyKey: _key,
          conversationId: _conv,
        );
        expect(await repo.cachedEverEncrypted(_conv), isTrue);
      });

      test(
        'callbacks are skipped when the session ended during the call',
        () async {
          override = (p) async {
            db.sessionEpoch.end();
            return listAnswer([enc(1)], since: 's1');
          };
          await repo.refreshThread(_conv);
          expect(encrypted, isEmpty);
        },
      );

      test('the gap-overflow fallback caches no encrypted message', () async {
        script('$_svc/ListMessages', [
          listAnswer(
            [msg(1, conversationId: _conv)],
            conversation: conv(_conv, snippet: 'hi'),
            since: 's1',
          ),
          listAnswer([enc(2)], since: 's2', gap: 'g0'),
          for (var i = 0; i < kMaxGapPages; i++)
            listAnswer([enc(3 + i)], next: 'g${i + 1}'),
          listAnswer(
            [enc(20), msg(21, conversationId: _conv)],
            conversation: mlsHeader(),
            since: 's3',
          ),
        ]);
        await repo.refreshThread(_conv);
        await repo.refreshThread(_conv);
        await expectNoCiphertextStored();
        expect(await db.select(db.messageEntries).get(), hasLength(1));
        expect(encrypted, [_conv]);
        expect(await repo.cachedEverEncrypted(_conv), isTrue);
      });

      test('the rejected-since fallback caches no encrypted message', () async {
        script('$_svc/ListMessages', [
          listAnswer(
            [msg(1, conversationId: _conv)],
            conversation: conv(_conv, snippet: 'hi'),
            since: 's1',
          ),
          rejectedToken('since_token'),
          listAnswer(
            [enc(2), msg(3, conversationId: _conv)],
            conversation: mlsHeader(),
            since: 's2',
          ),
        ]);
        await repo.refreshThread(_conv);
        await repo.refreshThread(_conv);
        await expectNoCiphertextStored();
        expect(await db.select(db.messageEntries).get(), hasLength(1));
        expect(encrypted, [_conv]);
        expect(await repo.cachedEverEncrypted(_conv), isTrue);
      });

      test('the loadOlderMessages rejected-token fallback caches no '
          'encrypted message', () async {
        script('$_svc/ListMessages', [
          listAnswer(
            [msg(5, conversationId: _conv)],
            conversation: conv(_conv, snippet: 'hi'),
            since: 's1',
            next: 'older',
          ),
          rejectedToken('page_token'),
          listAnswer(
            [enc(4), msg(3, conversationId: _conv)],
            conversation: mlsHeader(),
            since: 's2',
          ),
        ]);
        await repo.refreshThread(_conv);
        await repo.loadOlderMessages(_conv);
        await expectNoCiphertextStored();
        expect(await db.select(db.messageEntries).get(), hasLength(1));
        expect(await repo.cachedEverEncrypted(_conv), isTrue);
      });
    });
  });

  test('the marker logic of a conversations page costs a constant number of '
      'reads, whatever the page size', () async {
    Future<int> selectsFor(int rows) async {
      final counter = _CountSelects();
      final counted = AppDatabase.forTesting(
        NativeDatabase.memory().interceptWith(counter),
      );
      addTearDown(counted.close);
      await counted.claimCacheFor('a');
      final countedStore = MessagingStore(counted);
      final ids = [for (var i = 0; i < rows; i++) hexId(100 + i)];
      var calls = 0;
      final r = MessagingRepository(
        apiClient: ApiClient.withTransport(
          FakeTransport((procedure, input) async {
            calls++;
            return pb.ListConversationsResponse(
              conversations: [for (final id in ids) conv(id, snippet: 'hi')],
              sinceToken: 't$calls',
              requestCount: Int64(0),
            );
          }),
        ),
        store: countedStore,
        gate: MessagingFeatureGate(isMessagingEnabled: () => true),
        pageSize: 50,
        rateLimitHold: RateLimitHold(monotonic: () => Duration.zero),
      );
      // A cold open caches the rows; one of them is marked.
      await r.refreshConversations(Folder.FOLDER_INBOX);
      await countedStore.markEverEncrypted({
        ids.first,
      }, session: countedStore.session);
      counter.selects = 0;
      // The since refresh every poll makes.
      await r.refreshConversations(Folder.FOLDER_INBOX);
      expect(calls, 2);
      return counter.selects;
    }

    final small = await selectsFor(2);
    final large = await selectsFor(20);
    expect(small, greaterThan(0));
    expect(large, small);
  });
}
