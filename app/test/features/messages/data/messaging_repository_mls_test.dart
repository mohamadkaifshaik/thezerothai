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
import 'package:drift/native.dart';
import 'package:fake_async/fake_async.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_transport.dart';
import '../../../support/posts_fixtures.dart';

const _svc = '/dzeroth.messaging.v1.MessagingService';
const _conv = '0123456789abcdef0123456789abcdef';
const _key = '11111111-1111-4111-8111-111111111111';

Uint8List _b(List<int> v) => Uint8List.fromList(v);

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
}
