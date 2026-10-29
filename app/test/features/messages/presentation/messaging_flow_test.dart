import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/features/messages/presentation/conversations_screen.dart';
import 'package:dzeroth/features/messages/presentation/report_conversation.dart';
import 'package:dzeroth/features/messages/presentation/thread_screen.dart';
import 'package:dzeroth/features/messages/presentation/widgets/message_bubble.dart';
import 'package:dzeroth/features/messages/presentation/widgets/message_composer.dart';
import 'package:dzeroth/features/messages/presentation/widgets/request_banner.dart';
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.connect.spec.dart';
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pbenum.dart';
import 'package:dzeroth/gen/dzeroth/moderation/v1/moderation.pbenum.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/messaging_fixtures.dart';
import '../../../support/messaging_flow_rig.dart';
import '../../../support/thread_test_support.dart';

/// W7-21: the cross-screen flows, on the real router, the real repositories,
/// store and cubits, with only the wire faked ([FakeMessagingServer]).
void main() {
  Future<void> openRequestThread(
    WidgetTester tester,
    MessagingFlowRig rig,
  ) async {
    await rig.pump(tester);
    expect(find.byType(ConversationsScreen), findsOneWidget);
    expect(find.text('Message requests (1)'), findsOneWidget);

    await tester.tap(find.text('Message requests (1)'));
    await tester.pumpAndSettle();
    // The folder is a pushed page inside the shell: it has Back.
    expect(find.byTooltip('Back'), findsOneWidget);
    expect(find.text('Message requests'), findsOneWidget);

    await tester.tap(find.byKey(ValueKey('conversation-$kThreadId')));
    await tester.pumpAndSettle();
    expect(rig.path, AppRouter.messagePath(kThreadId));
    expect(find.byType(ThreadScreen), findsOneWidget);
  }

  testWidgets('inbox, request, accept, send, report a message, block: one '
      'session through the real stack', (tester) async {
    final server = MessagingFlowRig.serverWithRequest();
    final rig = MessagingFlowRig(server: server);

    // Inbox -> Message requests -> the request.
    await openRequestThread(tester, rig);
    expect(find.text('Sam Rivera wants to message you'), findsOneWidget);
    expect(find.byKey(RequestBanner.acceptKey), findsOneWidget);
    expect(find.byKey(MessageComposer.fieldKey), findsNothing);
    expect(find.text('m2'), findsOneWidget);

    // Accept: the banner goes, the composer comes, one RPC.
    await tester.tap(find.byKey(RequestBanner.acceptKey));
    await tester.pumpAndSettle();
    expect(server.count('/${MessagingService.name}/AcceptMessageRequest'), 1);
    expect(find.textContaining('wants to message you'), findsNothing);
    expect(find.byKey(MessageComposer.fieldKey), findsOneWidget);
    expect(
      server.conversations[kThreadId]!.state,
      ConversationState.CONVERSATION_STATE_ACCEPTED,
    );

    // Compose and send.
    await tester.enterText(find.byKey(MessageComposer.fieldKey), 'hi Sam');
    await tester.pump();
    await tester.tap(find.byKey(MessageComposer.sendKey));
    await tester.pumpAndSettle();
    expect(server.sends, hasLength(1));
    expect(server.sends.single.text, 'hi Sam');
    expect(server.sends.single.conversationId, kThreadId);
    expect(find.text('hi Sam'), findsOneWidget);

    // Report the peer's message (long press -> menu -> sheet -> thanks).
    await tester.longPress(find.byKey(ValueKey('bubble-${hexId(2)}')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(kReportMessageLabel));
    await tester.pumpAndSettle();
    await tester.tap(find.text("It's spam"));
    await tester.pump();
    final send = find.widgetWithText(FilledButton, 'Send report');
    await tester.ensureVisible(send);
    await tester.pumpAndSettle();
    await tester.tap(send);
    await tester.pumpAndSettle();
    expect(find.text('Thanks for reporting'), findsOneWidget);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.text(kReportSentText), findsOneWidget);
    expect(server.reports, hasLength(1));
    expect(
      server.reports.single.targetType,
      ReportTargetType.REPORT_TARGET_TYPE_MESSAGE,
    );
    expect(server.reports.single.targetId, '$kThreadId:${hexId(2)}');
    // The report touched nothing else: the thread is still there, writable.
    expect(find.byKey(MessageComposer.fieldKey), findsOneWidget);
    expect(find.byType(MessageBubble), findsNWidgets(3));

    // Block from the conversation menu: confirm, then read-only.
    await tester.tap(find.byTooltip('Conversation info'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Block @sam'));
    await tester.pumpAndSettle();
    expect(find.text('Block this account?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Block'));
    await tester.pumpAndSettle();
    expect(server.blocks.single.userId, 'u-sam');
    expect(find.text(kThreadReadOnlyText), findsOneWidget);
    expect(find.byKey(MessageComposer.fieldKey), findsNothing);

    // The cached conversation is consistent when the user goes back.
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(rig.path, isNot(AppRouter.messagePath(kThreadId)));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the request path ends at Delete: the row leaves the folder', (
    tester,
  ) async {
    final server = MessagingFlowRig.serverWithRequest();
    final rig = MessagingFlowRig(server: server);
    await openRequestThread(tester, rig);

    await tester.tap(find.byKey(RequestBanner.deleteKey));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(server.count('/${MessagingService.name}/DeleteConversation'), 1);
    expect(find.byType(ThreadScreen), findsNothing);
    expect(find.byKey(ValueKey('conversation-$kThreadId')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('sign-out after the whole flow leaves no private row on the '
      'device and no poll behind', (tester) async {
    final server = MessagingFlowRig.serverWithRequest();
    final rig = MessagingFlowRig(server: server);
    await openRequestThread(tester, rig);
    await tester.tap(find.byKey(RequestBanner.acceptKey));
    await tester.pumpAndSettle();

    final before = await tester.runAsync(rig.messagingRowCounts);
    expect(before!.conversations, greaterThan(0));
    expect(before.messages, greaterThan(0));
    expect(before.state, greaterThan(0));

    // Control: while the thread is open it does poll.
    final opened = server.messageListCalls;
    await tester.pump(const Duration(seconds: 31));
    expect(server.messageListCalls, greaterThan(opened));

    // The thread is open; sign out. The router leaves it for sign-in.
    await rig.signOut(tester);

    expect(rig.path, AppRouter.signInPath);
    expect(find.byType(ThreadScreen), findsNothing);
    final after = await tester.runAsync(rig.messagingRowCounts);
    expect(after!.conversations, 0);
    expect(after.messages, 0);
    expect(after.state, 0);

    // Ten minutes later nothing polls, and nothing is written back.
    final calls = server.messageListCalls;
    await tester.pump(const Duration(minutes: 10));
    expect(server.messageListCalls, calls);
    final late = await tester.runAsync(rig.messagingRowCounts);
    expect(late!.messages, 0);
    await tester.pumpWidget(const SizedBox());
  });
}
