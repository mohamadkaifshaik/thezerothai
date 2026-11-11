import 'package:dzeroth/features/messages/data/messaging_repository.dart';
import 'package:dzeroth/features/messages/data/messaging_store.dart';
import 'package:dzeroth/features/messages/domain/messaging_feature_gate.dart';
import 'package:dzeroth/features/messages/presentation/bloc/conversations_session.dart';
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pbenum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/messaging_fixtures.dart';

class _MockMessaging extends Mock implements MessagingRepository {}

/// The hoisted inbox and Requests folders (tablet plan section 5.2): lazy,
/// one per folder, per account, dropped when Messages turns `hidden`.
void main() {
  late _MockMessaging repo;
  late List<(List<pb.Conversation>, bool)> synced;

  setUpAll(() => registerFallbackValue(Folder.FOLDER_INBOX));

  setUp(() {
    repo = _MockMessaging();
    synced = [];
    when(() => repo.rateLimitedFor()).thenReturn(null);
    when(() => repo.conversationsChanged)
        .thenAnswer((_) => const Stream<void>.empty());
    when(() => repo.cachedConversations(any()))
        .thenAnswer((_) async => const ConversationsSnapshot());
    when(() => repo.refreshConversations(any())).thenAnswer(
      (invocation) async => ConversationsResult(
        ConversationsSnapshot(
          conversations: [
            conv(
              invocation.positionalArguments.first == Folder.FOLDER_INBOX
                  ? 'inbox-row'
                  : 'request-row',
            ),
          ],
        ),
        requestCount: 1,
      ),
    );
  });

  ConversationsSession build() {
    final session = ConversationsSession(
      repository: repo,
      onInboxSynced: (rows, {required hasMore}) => synced.add((rows, hasMore)),
    );
    addTearDown(session.dispose);
    return session;
  }

  test('nothing is created or sent until a placement reads a folder', () {
    final session = build();
    expect(session.ifCreated(Folder.FOLDER_INBOX), isNull);
    expect(session.ifCreated(Folder.FOLDER_REQUESTS), isNull);
    verifyNever(() => repo.cachedConversations(any()));
    verifyNever(() => repo.refreshConversations(any()));
  });

  test('one cubit per folder, the same on every read; reading sends '
      'nothing', () {
    final session = build();
    final inbox = session.cubitFor(Folder.FOLDER_INBOX);
    final requests = session.cubitFor(Folder.FOLDER_REQUESTS);
    expect(session.cubitFor(Folder.FOLDER_INBOX), same(inbox));
    expect(session.cubitFor(Folder.FOLDER_REQUESTS), same(requests));
    expect(inbox, isNot(same(requests)));
    expect(inbox.folder, Folder.FOLDER_INBOX);
    expect(requests.folder, Folder.FOLDER_REQUESTS);
    // An unspecified folder is the inbox.
    expect(session.cubitFor(Folder.FOLDER_UNSPECIFIED), same(inbox));
    verifyNever(() => repo.refreshConversations(any()));
  });

  test('the inbox re-syncs the Messages badge; the Requests folder does '
      'not', () async {
    final session = build();
    await session.cubitFor(Folder.FOLDER_INBOX).open();
    await session.cubitFor(Folder.FOLDER_REQUESTS).open();
    expect(synced, hasLength(1));
    expect(synced.single.$1.single.id, 'inbox-row');
  });

  test('reset closes and drops both folders and the scroll memory, and '
      'ticks once', () async {
    final session = build();
    final inbox = session.cubitFor(Folder.FOLDER_INBOX);
    final requests = session.cubitFor(Folder.FOLDER_REQUESTS);
    final bucket = session.bucketFor(Folder.FOLDER_INBOX);
    var ticks = 0;
    session.changes.addListener(() => ticks++);

    session.reset();
    await pumpEventQueue();

    expect(inbox.isClosed, isTrue);
    expect(requests.isClosed, isTrue);
    expect(session.ifCreated(Folder.FOLDER_INBOX), isNull);
    expect(session.ifCreated(Folder.FOLDER_REQUESTS), isNull);
    expect(ticks, 1);
    // Nothing to drop: no tick.
    session.reset();
    expect(ticks, 1);
    // The scroll memory went too.
    expect(session.bucketFor(Folder.FOLDER_INBOX), isNot(same(bucket)));
    // The next account reads a fresh cubit.
    expect(session.cubitFor(Folder.FOLDER_INBOX), isNot(same(inbox)));
  });

  test('access hidden drops both; full and read-only keep them', () async {
    final session = build();
    final inbox = session.cubitFor(Folder.FOLDER_INBOX);
    session.accessChanged(MessagingAccess.full);
    session.accessChanged(MessagingAccess.readOnly);
    expect(session.ifCreated(Folder.FOLDER_INBOX), same(inbox));
    expect(inbox.isClosed, isFalse);

    session.accessChanged(MessagingAccess.hidden);
    await pumpEventQueue();
    expect(inbox.isClosed, isTrue);
    expect(session.ifCreated(Folder.FOLDER_INBOX), isNull);
  });

  test('one scroll bucket per folder, kept until a drop', () {
    final session = build();
    final inbox = session.bucketFor(Folder.FOLDER_INBOX);
    expect(session.bucketFor(Folder.FOLDER_INBOX), same(inbox));
    expect(session.bucketFor(Folder.FOLDER_REQUESTS), isNot(same(inbox)));
  });

  test('dispose closes the folders; later resets are no-ops', () async {
    final session = ConversationsSession(repository: repo);
    final inbox = session.cubitFor(Folder.FOLDER_INBOX);
    session.dispose();
    await pumpEventQueue();
    expect(inbox.isClosed, isTrue);
    session
      ..reset()
      ..accessChanged(MessagingAccess.hidden)
      ..dispose();
  });
}
