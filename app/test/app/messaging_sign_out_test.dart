import 'dart:async';

import 'package:dzeroth/app/session_wiring.dart';
import 'package:dzeroth/features/timeline/data/timeline_repository.dart';
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pbenum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../support/messaging_flow_rig.dart';
import '../support/thread_test_support.dart';

class _MockTimeline extends Mock implements TimelineRepository {}

/// W7-21: sign-out wipes the three messaging drift tables through the real
/// `wipeSessionData` (the function `bootstrap` calls), with the messaging
/// repository passed in. The repository-level tests call `clearAll` directly;
/// these prove the wiring.
void main() {
  late FakeMessagingServer server;
  late MessagingFlowRig rig;

  setUp(() {
    server = MessagingFlowRig.serverWithRequest();
    rig = MessagingFlowRig(server: server);
  });

  Future<void> fillAllThreeTables() async {
    await rig.messagingRepository.refreshConversations(Folder.FOLDER_REQUESTS);
    await rig.messagingRepository.refreshThread(kThreadId);
    final counts = await rig.messagingRowCounts();
    expect(counts.conversations, greaterThan(0));
    expect(counts.messages, greaterThan(0));
    expect(counts.state, greaterThan(0));
  }

  Future<void> signOut() => wipeSessionData(
    database: rig.database,
    timelineRepository: _MockTimeline(),
    messagingRepository: rig.messagingRepository,
  );

  test(
    'wipeSessionData leaves no conversation, message or token row',
    () async {
      await fillAllThreeTables();

      await signOut();

      final counts = await rig.messagingRowCounts();
      expect(counts.conversations, 0);
      expect(counts.messages, 0);
      expect(counts.state, 0);
      // And nothing readable is left to the next user on the device.
      final thread = await rig.messagingRepository.cachedThread(kThreadId);
      expect(thread.messages, isEmpty);
      expect(thread.conversation, isNull);
    },
  );

  test('a ListMessages answer in flight at sign-out is not written, and the '
      'next session still caches', () async {
    await fillAllThreeTables();
    server.listMessagesGate = Completer<void>();
    final inFlight = rig.messagingRepository.refreshThread(kThreadId);
    // Let the request reach the (held) server.
    await Future<void>.delayed(Duration.zero);
    expect(server.messageListCalls, 2);

    await signOut();
    server.listMessagesGate!.complete();
    await inFlight;

    final counts = await rig.messagingRowCounts();
    expect(counts.messages, 0, reason: 'the late answer must be dropped');
    expect(counts.conversations, 0);
    expect(counts.state, 0);

    // The next user's first load is a new session and does cache.
    server.listMessagesGate = null;
    await rig.messagingRepository.refreshThread(kThreadId);
    expect((await rig.messagingRowCounts()).messages, greaterThan(0));
  });
}
