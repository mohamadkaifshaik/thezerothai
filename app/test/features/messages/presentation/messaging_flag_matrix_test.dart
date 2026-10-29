import 'dart:async';

import 'package:dzeroth/core/feature_flags/ui_shell_feature_flag.dart';
import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/features/messages/domain/messaging_feature_flag.dart';
import 'package:dzeroth/features/messages/domain/people_source.dart';
import 'package:dzeroth/features/messages/presentation/conversations_screen.dart';
import 'package:dzeroth/features/messages/presentation/recipient_picker_screen.dart';
import 'package:dzeroth/features/messages/presentation/thread_screen.dart';
import 'package:dzeroth/features/messages/presentation/widgets/message_bubble.dart';
import 'package:dzeroth/features/moderation/domain/reports_feature_flag.dart';
import 'package:dzeroth/features/notifications/domain/notifications_feature_flag.dart';
import 'package:dzeroth/gen/dzeroth/graph/v1/graph.connect.spec.dart';
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.connect.spec.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/messaging_flow_rig.dart';
import '../../../support/thread_test_support.dart';

/// W7-21: the five-flag matrix `messaging` x `ui_shell` x `search` x `reports`
/// x `notifications` (32 combinations) on the real router and the real
/// repositories. Each combination checks, in one session, what the flags
/// are documented to decide:
///
/// - `messaging`: the Inbox, a conversation and the picker open, or the route
///   redirects Home with not one messaging RPC (ADR-0027 D6).
/// - `ui_shell`: the Messages destination in the shell (W7-19, F10); it needs
///   `messaging` too. A conversation is never inside the shell.
/// - `reports`: the "Report message" action on a peer's bubble and the "Report
///   @handle" item of the conversation menu (W7-18).
/// - `notifications`: with push registered on Android the open thread polls
///   every 30 s, otherwise every 15 s (ADR-0027 D7, W7-19).
/// - `search`: today's only people source cannot search the server, so the
///   flag changes nothing in the picker: typing filters the loaded Following
///   rows and sends no request (W7-17; W4's source plugs in later).
void main() {
  const peerBubble = ValueKey('bubble-00000000000000000000000000000002');
  final combos = <Set<String>>[
    for (var bits = 0; bits < 32; bits++)
      {
        'graph',
        if (bits & 1 != 0) kFeatureMessaging,
        if (bits & 2 != 0) kFeatureUiShell,
        if (bits & 4 != 0) kPickerSearchFlag,
        if (bits & 8 != 0) kFeatureReports,
        if (bits & 16 != 0) kFeatureNotifications,
      },
  ];

  const messagingRpcs = '/${MessagingService.name}/';

  Finder inPicker(String text) => find.descendant(
    of: find.byType(RecipientPicker),
    matching: find.text(text),
  );

  for (final flags in combos) {
    final messaging = flags.contains(kFeatureMessaging);
    final uiShell = flags.contains(kFeatureUiShell);
    final search = flags.contains(kPickerSearchFlag);
    final reports = flags.contains(kFeatureReports);
    final notifications = flags.contains(kFeatureNotifications);
    final name =
        'messaging=$messaging ui_shell=$uiShell search=$search '
        'reports=$reports notifications=$notifications';

    testWidgets(name, (tester) async {
      final server = MessagingFlowRig.serverWithConversation();
      final rig = MessagingFlowRig(server: server, flags: flags);
      await rig.pump(tester);

      // --- the Inbox route -------------------------------------------------
      if (!messaging) {
        expect(rig.path, AppRouter.homePath, reason: 'Inbox redirects Home');
        expect(find.byType(ConversationsScreen), findsNothing);
        for (final location in [
          AppRouter.messageRequestsPath,
          AppRouter.messagePath(kThreadId),
          AppRouter.messageNewPath,
        ]) {
          rig.appRouter.router.go(location);
          await tester.pumpAndSettle();
          expect(rig.path, AppRouter.homePath, reason: '$location redirects');
        }
        expect(find.byIcon(Icons.mail), findsNothing);
        expect(find.byIcon(Icons.mail_outline), findsNothing);
        expect(
          server.calls.where((c) => c.startsWith(messagingRpcs)),
          isEmpty,
          reason: 'no messaging RPC without the flag',
        );
        return;
      }

      expect(rig.path, AppRouter.messagesPath);
      expect(find.byType(ConversationsScreen), findsOneWidget);
      expect(find.text('hello from sam'), findsOneWidget);
      // The Messages destination: selected (filled) in the new shell only.
      expect(
        find.byIcon(Icons.mail),
        uiShell ? findsOneWidget : findsNothing,
        reason: 'Messages destination needs messaging + ui_shell',
      );

      // --- a conversation (never inside the shell) -------------------------
      await rig.start(tester);
      await tester.tap(find.byKey(ValueKey('conversation-$kThreadId')));
      await tester.pumpAndSettle();
      expect(find.byType(ThreadScreen), findsOneWidget);
      expect(find.byIcon(Icons.mail), findsNothing);

      await tester.longPress(find.byKey(peerBubble));
      await tester.pumpAndSettle();
      expect(
        find.text(kReportMessageLabel),
        reports ? findsOneWidget : findsNothing,
        reason: 'the bubble menu needs reports',
      );
      if (reports) {
        await tester.tapAt(const Offset(2, 2));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.byTooltip('Conversation info'));
      await tester.pumpAndSettle();
      expect(
        find.text('Report @sam'),
        reports ? findsOneWidget : findsNothing,
        reason: 'the conversation menu needs reports',
      );
      expect(find.text('Block @sam'), findsOneWidget, reason: 'graph is on');
      await tester.tapAt(const Offset(2, 2));
      await tester.pumpAndSettle();

      // Push covers the thread only with the notifications flag (Android,
      // registered): 30 s, else 15 s. At 16 s the 15 s poller has polled once.
      final polled = server.messageListCalls;
      await tester.pump(const Duration(seconds: 16));
      expect(
        server.messageListCalls - polled,
        notifications ? 0 : 1,
        reason: notifications ? 'hot interval 30 s' : 'hot interval 15 s',
      );
      await tester.pump(const Duration(seconds: 16));
      expect(
        server.messageListCalls - polled,
        notifications ? 1 : 2,
        reason: 'by 32 s: polls at 30 s, or at 15 s and 30 s',
      );

      // --- the picker ------------------------------------------------------
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      unawaited(rig.appRouter.router.push(AppRouter.messageNewPath));
      await tester.pumpAndSettle();
      expect(find.byType(RecipientPicker), findsOneWidget);
      expect(inPicker('Sam Rivera'), findsOneWidget);
      await tester.enterText(find.byKey(kRecipientFieldKey), 'sa');
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(
        server.count('/${GraphService.name}/ListFollowing'),
        1,
        reason: 'filtering loaded rows asks nothing, search or not',
      );
      expect(inPicker('Sam Rivera'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
