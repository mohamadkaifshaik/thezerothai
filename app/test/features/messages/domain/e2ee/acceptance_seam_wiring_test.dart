import 'package:drift/native.dart';
import 'package:dzeroth/core/network/api_client.dart';
import 'package:dzeroth/core/storage/app_database.dart';
import 'package:dzeroth/features/messages/data/messaging_repository.dart';
import 'package:dzeroth/features/messages/data/messaging_store.dart';
import 'package:dzeroth/features/messages/domain/messaging_feature_gate.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pbenum.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../support/e2ee_pipeline_harness.dart';
import '../../../../support/e2ee_pipeline_rig.dart';
import '../../../../support/fake_transport.dart';

// The repository -> pipeline link as bootstrap wires it
// (`repo.onServerConversationRow = pipeline.noteServerRow`), end to end: a REAL
// repository over a fake transport answers the inbox or a thread's first page,
// and the pipeline (its parts built over a rig vault) settles the acceptance
// of a conversation it joined before a restart, with no extra RPC.

const _svc = '/dzeroth.messaging.v1.MessagingService';
const _listConvs = '$_svc/ListConversations';
const _listMsgs = '$_svc/ListMessages';
const _send = '$_svc/SendMessage';

String _id(int n) => n.toRadixString(16).padLeft(32, '0');
final String _c1 = _id(1);

pb.Conversation _row({
  Folder folder = Folder.FOLDER_INBOX,
  ConversationState state = ConversationState.CONVERSATION_STATE_ACCEPTED,
}) => pb.Conversation(
  id: _c1,
  peer: common.AuthorSnapshot(userId: 'ref-bob'),
  folder: folder,
  state: state,
  canReply: true,
);

void main() {
  late AppDatabase db;
  late PipelineHarness h;
  late MessagingRepository repo;
  late FakeTransport transport;
  pb.Conversation answerRow = _row();
  final msgRequests = <pb.ListMessagesRequest>[];

  Future<bool> accepted() async =>
      (await h.rig.device.vault.conversation(_c1))?.sync.requestAccepted ??
      false;

  setUp(() async {
    answerRow = _row();
    db = AppDatabase.forTesting(NativeDatabase.memory());
    transport = FakeTransport((procedure, input) async {
      switch (procedure) {
        case _listConvs:
          return pb.ListConversationsResponse(
            conversations: [answerRow],
            sinceToken: 's1',
          );
        case _listMsgs:
          msgRequests.add(input as pb.ListMessagesRequest);
          return pb.ListMessagesResponse(
            conversation: answerRow,
            sinceToken: 's1',
          );
        case _send:
          return pb.SendMessageResponse(
            message: pb.Message(
              id: _id(900),
              conversationId: _c1,
              fromSelf: true,
              text: 'hi',
            ),
            conversation: answerRow,
          );
      }
      throw StateError('unexpected $procedure');
    });
    repo = MessagingRepository(
      apiClient: ApiClient.withTransport(transport),
      store: MessagingStore(db),
      gate: MessagingFeatureGate(
        isMessagingEnabled: () => true,
        onDisabledByServer: () {},
      ),
    );

    h = await PipelineHarness.create();
    final bob = await RigPeer.create('bob');
    h.rig.keys.peers['ref-bob'] = [rigKeyDevice(bob.idString, bob.key)];
    await h.offer(_c1, bob, accepted: false);
    await h.ready();
    expect(await accepted(), isFalse);
    // A restart: no memory of any sighting; the server's own rows (in the
    // rig) are gone, so a first-page read of the pipeline finds no header.
    h.rig.server.rows.remove(_c1);
    h.pipeline.contexts.clear();
    h.rig.server.calls.clear();
    repo
      ..onServerConversationRow = h.pipeline.noteServerRow
      ..wantsFirstPage = h.pipeline.wantsFirstPage;
    msgRequests.clear();
  });

  tearDown(() async {
    await h.dispose();
    await db.close();
  });

  test('(a) the next server inbox sync that lists the conversation ACCEPTED '
      'settles it, with no extra RPC', () async {
    await repo.refreshConversations(Folder.FOLDER_INBOX);
    await h.settle();

    expect(await accepted(), isTrue);
    expect(transport.calledProcedures, [_listConvs]);
    expect(h.rig.server.calls.where((c) => c == 'listMlsMessages'), isEmpty);
  });

  test('(b) opening the thread (the repository\'s first-page read) settles '
      'it', () async {
    await repo.refreshThread(_c1);
    await h.settle();

    expect(await accepted(), isTrue);
    expect(transport.calledProcedures, [_listMsgs]);
    expect(h.rig.server.calls.where((c) => c == 'listMlsMessages'), isEmpty);
  });

  test('(c) a request row of the Requests folder never accepts', () async {
    answerRow = _row(
      folder: Folder.FOLDER_REQUESTS,
      state: ConversationState.CONVERSATION_STATE_REQUEST,
    );

    await repo.refreshConversations(Folder.FOLDER_REQUESTS);
    await repo.refreshThread(_c1);
    await h.settle();

    expect(await accepted(), isFalse);
    expect(h.pipeline.contexts.of(_c1).requestSeenInHeader, isTrue);
  });

  test('(e) a send answer and a cached row do not settle it', () async {
    // A send answer can carry an ACCEPTED-looking row; a cached row may be
    // from an earlier run. Neither is reported, so neither is a sight.
    await repo.sendMessage(
      idempotencyKey: 'key-1',
      text: 'hi',
      conversationId: _c1,
    );
    await repo.cachedConversations(Folder.FOLDER_INBOX);
    await repo.cachedConversation(_c1);
    await h.settle();

    expect(transport.calledProcedures, [_send]);
    expect(await accepted(), isFalse);
    expect(h.pipeline.contexts.of(_c1).acceptedSightingHeld, isFalse);
  });

  group('(7) a restarted thread gets its header', () {
    /// The thread was opened once while the server said REQUEST (a since
    /// token is cached), then the app restarted (no memory) and the server
    /// now says ACCEPTED; a since page carries no header.
    Future<void> restartedWithCachedThread() async {
      answerRow = _row(
        folder: Folder.FOLDER_REQUESTS,
        state: ConversationState.CONVERSATION_STATE_REQUEST,
      );
      await repo.refreshThread(_c1);
      await h.settle();
      expect(await accepted(), isFalse);
      h.pipeline.contexts.clear();
      // The thread screen's state build of this run (it makes the
      // conversation's state known to `wantsFirstPage`).
      await h.pipeline.crypto.describeState(_c1);
      answerRow = _row();
      msgRequests.clear();
      transport.calledProcedures.clear();
    }

    test('the next refresh is a first page and settles it, with the same '
        'number of RPCs; the second is a since poll again', () async {
      await restartedWithCachedThread();

      await repo.refreshThread(_c1);
      await h.settle();

      expect(msgRequests, hasLength(1));
      expect(msgRequests.single.sinceToken, isEmpty);
      expect(transport.calledProcedures, [_listMsgs]);
      expect(await accepted(), isTrue);

      await repo.refreshThread(_c1);
      expect(msgRequests, hasLength(2));
      expect(msgRequests.last.sinceToken, 's1');
    });

    test('the since poll is kept for a conversation that was sighted this '
        'run, and for a plaintext one', () async {
      await restartedWithCachedThread();
      // A server row of this run (the inbox) came first.
      h.pipeline.contexts.note(_row(), fromList: true);

      await repo.refreshThread(_c1);
      expect(msgRequests.single.sinceToken, 's1');
      expect(h.pipeline.wantsFirstPage(_id(77)), isFalse);
    });
  });
}
