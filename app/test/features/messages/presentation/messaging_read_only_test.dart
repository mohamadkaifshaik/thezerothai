import 'package:connectrpc/connect.dart' as connect;
import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/features/messages/domain/messaging_feature_gate.dart';
import 'package:dzeroth/features/messages/presentation/conversations_screen.dart';
import 'package:dzeroth/features/messages/presentation/thread_screen.dart';
import 'package:dzeroth/features/messages/presentation/widgets/message_bubble.dart';
import 'package:dzeroth/features/messages/presentation/widgets/message_composer.dart';
import 'package:dzeroth/features/messages/presentation/widgets/request_banner.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.connect.spec.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/messaging_fixtures.dart';
import '../../../support/messaging_flow_rig.dart';
import '../../../support/thread_test_support.dart';

/// W7-26 (ADR-0027 F6(a)): `messaging` off for this caller only. The device
/// cache holds a conversation and the session probe succeeded, so Messages
/// opens read-only: list, read, delete, report and block, but no composer, no
/// Accept, no New message, and `/messages/new` lands on `/messages`.
void main() {
  const noMessaging = {'graph', 'reports', 'ui_shell'};
  const peerBubble = ValueKey('bubble-00000000000000000000000000000002');
  const rpc = '/${MessagingService.name}/';

  /// Awaits [work] (a drift call) by pumping the test zone.
  Future<void> pumped(WidgetTester tester, Future<void> work) async {
    var finished = false;
    final done = work.whenComplete(() => finished = true);
    for (var i = 0; i < 200 && !finished; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    await done;
  }

  Future<MessagingFlowRig> readOnlyRig(
    WidgetTester tester,
    FakeMessagingServer server, {
    String location = AppRouter.messagesPath,
    Size size = const Size(390, 844),
    Brightness brightness = Brightness.light,
    double textScale = 1,
  }) async {
    final rig = MessagingFlowRig(server: server, flags: noMessaging);
    await rig.primeReadOnly(tester);
    await rig.pump(
      tester,
      location: location,
      size: size,
      brightness: brightness,
      textScale: textScale,
    );
    return rig;
  }

  testWidgets('the Inbox opens with no New message action', (tester) async {
    final server = MessagingFlowRig.serverWithConversation();
    final rig = await readOnlyRig(tester, server);

    expect(rig.messagingRepository.gate.access, MessagingAccess.readOnly);
    expect(rig.path, AppRouter.messagesPath);
    expect(find.byType(ConversationsScreen), findsOneWidget);
    expect(find.text('hello from sam'), findsOneWidget);
    expect(find.byTooltip('New message'), findsNothing);
    // The bar destination stays for people who can send.
    expect(find.byIcon(Icons.mail), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('/messages/new and /messages/new/draft land on /messages', (
    tester,
  ) async {
    final server = MessagingFlowRig.serverWithConversation();
    final rig = await readOnlyRig(tester, server);

    for (final location in [
      AppRouter.messageNewPath,
      AppRouter.messageDraftPath,
    ]) {
      rig.appRouter.router.go(location);
      await tester.pumpAndSettle();
      expect(rig.path, AppRouter.messagesPath, reason: location);
    }
    // The requests folder and a thread pass.
    rig.appRouter.router.go(AppRouter.messageRequestsPath);
    await tester.pumpAndSettle();
    expect(rig.path, AppRouter.messageRequestsPath);
    rig.appRouter.router.go(AppRouter.messagePath(kThreadId));
    await tester.pumpAndSettle();
    expect(find.byType(ThreadScreen), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a thread: read, report, block and delete work; no composer', (
    tester,
  ) async {
    final server = MessagingFlowRig.serverWithConversation();
    final rig = await readOnlyRig(tester, server);

    await tester.tap(find.byKey(ValueKey('conversation-$kThreadId')));
    await tester.pumpAndSettle();
    expect(find.byType(ThreadScreen), findsOneWidget);
    expect(find.text('m2'), findsOneWidget);
    expect(find.byKey(MessageComposer.fieldKey), findsNothing);
    expect(find.byKey(MessageComposer.sendKey), findsNothing);
    expect(find.text(kMessagingReadOnlyText), findsOneWidget);

    await tester.longPress(find.byKey(peerBubble));
    await tester.pumpAndSettle();
    expect(find.text(kReportMessageLabel), findsOneWidget);
    await tester.tapAt(const Offset(2, 2));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Conversation info'));
    await tester.pumpAndSettle();
    expect(find.text('Block @sam'), findsOneWidget);
    expect(find.text('Report @sam'), findsOneWidget);
    await tester.tap(find.text('Delete conversation'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(server.count('${rpc}DeleteConversation'), 1);
    expect(server.sends, isEmpty);
    expect(find.byType(ThreadScreen), findsNothing);
    expect(rig.path, AppRouter.messagesPath);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a received request: Delete and Block stay, Accept goes', (
    tester,
  ) async {
    final server = MessagingFlowRig.serverWithRequest();
    await readOnlyRig(
      tester,
      server,
      location: AppRouter.messagePath(kThreadId),
    );

    expect(find.text('Sam Rivera wants to message you'), findsOneWidget);
    expect(find.byKey(RequestBanner.acceptKey), findsNothing);
    expect(find.byKey(RequestBanner.deleteKey), findsOneWidget);
    expect(find.byKey(RequestBanner.blockKey), findsOneWidget);
    expect(find.byKey(MessageComposer.fieldKey), findsNothing);

    await tester.tap(find.byKey(RequestBanner.deleteKey));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(server.count('${rpc}DeleteConversation'), 1);
    expect(server.count('${rpc}AcceptMessageRequest'), 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('globally off: a FEATURE_DISABLED read hides Messages at once', (
    tester,
  ) async {
    final server = MessagingFlowRig.serverWithConversation();
    final rig = await readOnlyRig(tester, server);
    expect(rig.path, AppRouter.messagesPath);

    server.failures['${rpc}ListConversations'] = withDetail(
      connect.Code.failedPrecondition,
      common.ErrorReason.ERROR_REASON_FEATURE_DISABLED,
      metadata: {'feature': 'messaging'},
    );
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 400));
    await tester.pumpAndSettle();

    expect(rig.messagingRepository.gate.access, MessagingAccess.hidden);
    expect(rig.path, AppRouter.homePath);
    expect(find.byType(ConversationsScreen), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('before the probe answers, and with no cache, it is hidden and '
      'sends nothing', (tester) async {
    final server = MessagingFlowRig.serverWithConversation();
    final rig = MessagingFlowRig(server: server, flags: noMessaging);
    // No probe yet: hidden, so a deep link goes Home.
    await rig.pump(tester);
    expect(rig.path, AppRouter.homePath);
    expect(server.calls, isEmpty);

    // A probe with an empty cache: still hidden, 0 requests.
    await rig.primeReadOnly(tester, seedCache: false);
    await tester.pumpAndSettle();
    expect(rig.messagingRepository.gate.access, MessagingAccess.hidden);
    expect(server.calls, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets("user B on user A's device gets no readOnly from A's cache "
      "(W7-35 L-4)", (tester) async {
    final server = MessagingFlowRig.serverWithConversation();
    final rig = MessagingFlowRig(server: server, flags: noMessaging);
    // A signs in and fills the cache; B signs in on the same device.
    await pumped(tester, rig.database.claimCacheFor("uid-a"));
    await rig.primeReadOnly(tester);
    expect(rig.messagingRepository.gate.access, MessagingAccess.readOnly);
    await pumped(tester, rig.database.claimCacheFor("uid-b"));
    rig.messagingRepository.clearSession();
    server.calls.clear();

    await pumped(tester, rig.messagingRepository.probeAccess());

    expect(rig.messagingRepository.gate.access, MessagingAccess.hidden);
    expect(server.calls, isEmpty, reason: "B has no cache: 0 requests");
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('sign-out ends read-only mode', (tester) async {
    final server = MessagingFlowRig.serverWithConversation();
    final rig = await readOnlyRig(tester, server);
    expect(rig.path, AppRouter.messagesPath);

    await rig.signOut(tester);

    expect(rig.messagingRepository.gate.access, MessagingAccess.hidden);
    expect(rig.path, AppRouter.signInPath);
    await tester.pumpWidget(const SizedBox());
  });

  // The read-only composer notice and the banner without Accept, across the
  // widths, themes and text scales the repo checks.
  for (final size in const [Size(360, 740), Size(600, 900), Size(1200, 900)]) {
    for (final brightness in Brightness.values) {
      for (final scale in const [1.0, 1.3, 2.0]) {
        final name = '${size.width.toInt()}dp ${brightness.name} x$scale: ';
        testWidgets('${name}notice under the thread', (tester) async {
          final server = MessagingFlowRig.serverWithConversation();
          await readOnlyRig(
            tester,
            server,
            location: AppRouter.messagePath(kThreadId),
            size: size,
            brightness: brightness,
            textScale: scale,
          );
          expect(find.text(kMessagingReadOnlyText), findsOneWidget);
          expect(find.byKey(MessageComposer.fieldKey), findsNothing);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        });
        testWidgets('${name}request banner without Accept', (tester) async {
          final server = MessagingFlowRig.serverWithRequest();
          await readOnlyRig(
            tester,
            server,
            location: AppRouter.messagePath(kThreadId),
            size: size,
            brightness: brightness,
            textScale: scale,
          );
          expect(find.byKey(RequestBanner.acceptKey), findsNothing);
          expect(find.byKey(RequestBanner.deleteKey), findsOneWidget);
          expect(find.byKey(RequestBanner.blockKey), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        });
      }
    }
  }
}
