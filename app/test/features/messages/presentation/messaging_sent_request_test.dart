import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/features/messages/presentation/thread_screen.dart';
import 'package:dzeroth/features/messages/presentation/widgets/message_composer.dart';
import 'package:dzeroth/features/messages/presentation/widgets/request_banner.dart';
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pbenum.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/messaging_flow_rig.dart';
import '../../../support/thread_test_support.dart';

/// W7-25b (ADR-0027 note W7-25): the requester's own pending request reads
/// REQUEST in the Inbox row, so the thread shows the waiting note, and the
/// note goes when an Inbox refresh brings the accept. Real router, real
/// repository, store and cubits; only the wire is faked.
void main() {
  const noMessaging = {'graph', 'reports', 'ui_shell'};

  /// Awaits [work] (a drift call) by pumping the test zone (not `runAsync`).
  Future<void> pumped(WidgetTester tester, Future<void> work) async {
    var finished = false;
    final done = work.whenComplete(() => finished = true);
    for (var i = 0; i < 200 && !finished; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    await done;
  }

  testWidgets('the note shows for a pending request and goes when the Inbox '
      'refresh brings the accept; the composer stays', (tester) async {
    final server = MessagingFlowRig.serverWithConversation();
    server.conversations[kThreadId]!.state =
        ConversationState.CONVERSATION_STATE_REQUEST;
    final rig = MessagingFlowRig(server: server);
    await rig.pump(tester);

    // The Inbox row opens the thread; the cached row says REQUEST in INBOX.
    await tester.tap(find.byKey(ValueKey('conversation-$kThreadId')));
    await tester.pumpAndSettle();
    expect(find.byType(ThreadScreen), findsOneWidget);
    expect(find.text(kSentRequestText), findsOneWidget);
    expect(find.byKey(MessageComposer.fieldKey), findsOneWidget);
    expect(find.text('Accept'), findsNothing);

    // The peer accepts; the requester's next Inbox refresh brings the row.
    server.conversations[kThreadId]!.state =
        ConversationState.CONVERSATION_STATE_ACCEPTED;
    await pumped(
      tester,
      rig.messagingRepository.refreshConversations(Folder.FOLDER_INBOX),
    );
    await tester.pumpAndSettle();

    expect(find.text(kSentRequestText), findsNothing);
    expect(find.byKey(MessageComposer.fieldKey), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('read-only Messages never promise a send: no waiting note, no '
      'composer', (tester) async {
    final server = MessagingFlowRig.serverWithConversation();
    server.conversations[kThreadId]!.state =
        ConversationState.CONVERSATION_STATE_REQUEST;
    final rig = MessagingFlowRig(server: server, flags: noMessaging);
    await rig.primeReadOnly(tester);
    await rig.pump(tester, location: AppRouter.messagePath(kThreadId));
    await tester.pumpAndSettle();

    expect(find.byType(ThreadScreen), findsOneWidget);
    expect(find.text(kSentRequestText), findsNothing);
    expect(find.byKey(MessageComposer.fieldKey), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  test('a sent request needs can_reply (no waiting on a blocked or gone '
      'peer)', () {
    final pending = threadConv(
      state: ConversationState.CONVERSATION_STATE_REQUEST,
    );
    expect(isSentRequest(pending), isTrue);
    expect(
      isSentRequest(
        threadConv(
          state: ConversationState.CONVERSATION_STATE_REQUEST,
          canReply: false,
        ),
      ),
      isFalse,
    );
    expect(isSentRequest(threadConv()), isFalse);
  });
}
