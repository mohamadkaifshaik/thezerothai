import 'dart:async';

import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/router/main_shell.dart';
import 'package:dzeroth/features/auth/presentation/widgets/auth_gate.dart';
import 'package:dzeroth/features/beacons/data/beacons_repository.dart';
import 'package:dzeroth/features/beacons/domain/beacons_feature_flag.dart';
import 'package:dzeroth/features/beacons/presentation/beacon_screen.dart';
import 'package:dzeroth/features/beacons/presentation/bloc/plans_session.dart';
import 'package:dzeroth/features/beacons/presentation/plans_list_detail.dart';
import 'package:dzeroth/features/messages/presentation/conversations_screen.dart';
import 'package:dzeroth/features/messages/presentation/draft_thread_screen.dart';
import 'package:dzeroth/features/messages/presentation/messages_list_detail.dart';
import 'package:dzeroth/features/messages/presentation/open_conversation.dart';
import 'package:dzeroth/features/messages/presentation/recipient_picker_screen.dart';
import 'package:dzeroth/features/messages/presentation/thread_screen.dart';
import 'package:dzeroth/features/messages/presentation/widgets/message_composer.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/features/posts/presentation/bloc/pending_posts_cubit.dart';
import 'package:dzeroth/features/posts/presentation/composer_screen.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.connect.spec.dart';
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pbenum.dart';
import 'package:dzeroth/shared/widgets/primitives/app_pill_button.dart';
import 'package:dzeroth/shared/widgets/primitives/app_back_header.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/beacons_fixtures.dart';
import '../../../support/fake_beacons_server.dart';
import '../../../support/messages_tablet_fixtures.dart';
import '../../../support/messaging_fixtures.dart';
import '../../../support/messaging_flow_rig.dart';
import '../../../support/thread_test_support.dart';

class _MockPosts extends Mock implements PostsRepository {}

/// Every way into a conversation (tablet plan section 5.3, step 5), on the
/// real router, at 1024 (band B: the split page) and at a full-screen width
/// (600 or 700: band A; 390: a phone). Each checks the page that opens, the
/// list beside it in band B, the back target, and that only one
/// `ShellRoute` page is ever on the stack.
///
/// The ways in: an inbox row; a Requests row; a cold deep link (the hop
/// through sign-in that keeps it is width-independent and covered by
/// `app_router_deep_link_test`); a tapped push (`PushCubit.onOpen` is
/// `router.push(location)` in `AppWidget`) from a shell page, over another
/// thread, over the people picker and over the composer; the profile's
/// Message button and the plan's "Message organiser" (both
/// `openConversationWith`); the people picker (`pushReplacement`); and the
/// draft's first send (`pushReplacement` of the new conversation). The app
/// has no "share to DM".
void main() {
  Future<MessagingFlowRig> open(
    WidgetTester tester, {
    String location = AppRouter.messagesPath,
    double width = 1024,
    Set<String> flags = kMessagesTabletFlags,
    List<RepositoryProvider<dynamic>> extraProviders = const [],
    List<BlocProvider<dynamic>> extraBlocs = const [],
  }) async {
    final rig = MessagingFlowRig(server: tabletServer(), flags: flags);
    await rig.pump(
      tester,
      location: location,
      size: Size(width, 900),
      hoisted: true,
      extraProviders: extraProviders,
      extraBlocs: extraBlocs,
    );
    return rig;
  }

  Future<void> done(WidgetTester tester) => tester.pumpWidget(const SizedBox());

  Finder splitPage() => find.ancestor(
    of: find.byType(ThreadScreen),
    matching: find.byType(MainShell),
  );

  void expectSplit(String id, {bool requests = false}) {
    expect(find.byType(ThreadScreen), findsOneWidget);
    expect(splitPage(), findsOneWidget);
    expect(inMessagesPane(conversationRow(id)), findsOneWidget);
    expect(
      inMessagesPane(find.widgetWithText(AppBackHeader, 'Message requests')),
      requests ? findsOneWidget : findsNothing,
    );
  }

  void expectFullScreen() {
    expect(find.byType(ThreadScreen), findsOneWidget);
    expect(splitPage(), findsNothing);
    expect(findMessagesPane(), findsNothing);
  }

  group('an inbox row', () {
    testWidgets('1024: the shell list pane pushes the split page', (
      tester,
    ) async {
      final rig = await open(tester);
      await tester.tap(inMessagesPane(conversationRow(inboxId(0))));
      await tester.pumpAndSettle();
      expect(rig.stack, [
        AppRouter.messagesPath,
        AppRouter.messagePath(inboxId(0)),
      ]);
      expectSplit(inboxId(0));
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(rig.stack, [AppRouter.messagesPath]);
      await done(tester);
    });

    testWidgets('700: the list pushes the full-screen thread', (tester) async {
      final rig = await open(tester, width: 700);
      await tester.tap(conversationRow(inboxId(0)));
      await tester.pumpAndSettle();
      expectFullScreen();
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(rig.stack, [AppRouter.messagesPath]);
      await done(tester);
    });
  });

  group('a Requests row', () {
    for (final width in [1024.0, 700.0]) {
      testWidgets('${width.toInt()}: opens the request '
          '${width >= 840 ? 'beside the Requests list' : 'full screen'}', (
        tester,
      ) async {
        final rig = await open(
          tester,
          width: width,
          location: AppRouter.messageRequestsPath,
        );
        final row = width >= 840
            ? inMessagesPane(conversationRow(kRequestId))
            : conversationRow(kRequestId);
        await tester.tap(row);
        await tester.pumpAndSettle();
        expect(rig.stack.last, AppRouter.messagePath(kRequestId));
        if (width >= 840) {
          expectSplit(kRequestId, requests: true);
        } else {
          expectFullScreen();
        }
        expect(find.text('Rex Request wants to message you'), findsOneWidget);
        await tester.tap(find.byTooltip('Back').last);
        await tester.pumpAndSettle();
        expect(rig.stack.last, AppRouter.messageRequestsPath);
        await done(tester);
      });
    }
  });

  group('a cold deep link', () {
    testWidgets('1024: the split page with the inbox, the row selected; up '
        'with nothing to pop goes to the inbox', (tester) async {
      final rig = await open(
        tester,
        location: AppRouter.messagePath(inboxId(5)),
      );
      expect(rig.stack, [AppRouter.messagePath(inboxId(5))]);
      expect(rig.shellPages, 0);
      expectSplit(inboxId(5));
      expect(
        tester.getSemantics(inMessagesPane(conversationRow(inboxId(5)))),
        isSemantics(isSelected: true, isButton: true, hasTapAction: true),
      );
      // The route keeps its AuthGate outermost.
      expect(
        find.ancestor(of: splitPage(), matching: find.byType(AuthGate)),
        findsOneWidget,
      );
      // One INBOX load for the pane; the thread's own read.
      expect(rig.listCalls(Folder.FOLDER_INBOX), 1);
      expect(rig.threadCalls(inboxId(5)), greaterThan(0));

      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(rig.stack, [AppRouter.messagesPath]);
      expect(find.text(kSelectAConversation), findsOneWidget);
      // The shell inbox opens its folder once more (a new visit).
      expect(rig.shellPages, 1);
      await done(tester);
    });

    testWidgets('600: the full-screen thread; up goes to the inbox list', (
      tester,
    ) async {
      final rig = await open(
        tester,
        width: 600,
        location: AppRouter.messagePath(inboxId(5)),
      );
      expectFullScreen();
      expect(rig.listCalls(), 0);
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(rig.stack, [AppRouter.messagesPath]);
      expect(findInboxRoute(), findsOneWidget);
      expect(find.text(kSelectAConversation), findsNothing);
      await done(tester);
    });

    testWidgets('a Requests thread by link shows the inbox (no extra)', (
      tester,
    ) async {
      await open(tester, location: AppRouter.messagePath(kRequestId));
      expect(find.byType(ThreadScreen), findsOneWidget);
      expect(
        inMessagesPane(find.widgetWithText(AppBackHeader, 'Message requests')),
        findsNothing,
      );
      expect(inMessagesPane(conversationRow(inboxId(0))), findsOneWidget);
      await done(tester);
    });
  });

  group('a tapped push (router.push)', () {
    for (final width in [1024.0, 600.0]) {
      final split = width >= 840;
      testWidgets('${width.toInt()}: from the inbox', (tester) async {
        final rig = await open(tester, width: width);
        rig.appRouter.router.push(AppRouter.messagePath(inboxId(2)));
        await tester.pumpAndSettle();
        expect(rig.stack, [
          AppRouter.messagesPath,
          AppRouter.messagePath(inboxId(2)),
        ]);
        expect(rig.shellPages, 1);
        split ? expectSplit(inboxId(2)) : expectFullScreen();
        await tester.tap(find.byTooltip('Back'));
        await tester.pumpAndSettle();
        expect(rig.stack, [AppRouter.messagesPath]);
        await done(tester);
      });

      testWidgets('${width.toInt()}: over another open thread', (tester) async {
        final rig = await open(
          tester,
          width: width,
          location: AppRouter.messagePath(inboxId(1)),
        );
        rig.appRouter.router.push(AppRouter.messagePath(inboxId(2)));
        await tester.pumpAndSettle();
        expect(rig.stack, [
          AppRouter.messagePath(inboxId(1)),
          AppRouter.messagePath(inboxId(2)),
        ]);
        expect(rig.shellPages, 0);
        expect(find.text('newer in ${inboxId(2)}'), findsOneWidget);
        if (split) {
          expect(
            tester.getSemantics(inMessagesPane(conversationRow(inboxId(2)))),
            isSemantics(isSelected: true, isButton: true, hasTapAction: true),
          );
        } else {
          expectFullScreen();
        }
        await tester.tap(find.byTooltip('Back'));
        await tester.pumpAndSettle();
        expect(rig.stack, [AppRouter.messagePath(inboxId(1))]);
        expect(find.text('newer in ${inboxId(1)}'), findsOneWidget);
        await done(tester);
      });

      testWidgets('${width.toInt()}: over the people picker', (tester) async {
        final rig = await open(tester, width: width);
        rig.appRouter.router.push(AppRouter.messageNewPath);
        await tester.pumpAndSettle();
        expect(find.byType(RecipientPickerDialog), findsOneWidget);
        rig.appRouter.router.push(AppRouter.messagePath(inboxId(3)));
        await tester.pumpAndSettle();
        expect(rig.stack, [
          AppRouter.messagesPath,
          AppRouter.messageNewPath,
          AppRouter.messagePath(inboxId(3)),
        ]);
        expect(rig.shellPages, 1);
        split ? expectSplit(inboxId(3)) : expectFullScreen();
        await tester.tap(find.byTooltip('Back'));
        await tester.pumpAndSettle();
        expect(rig.stack.last, AppRouter.messageNewPath);
        await done(tester);
      });

      testWidgets('${width.toInt()}: over the composer', (tester) async {
        final posts = _MockPosts();
        when(() => posts.subFeatureEnabled(any())).thenReturn(false);
        final pending = PendingPostsCubit();
        addTearDown(pending.close);
        final rig = await open(
          tester,
          width: width,
          flags: {...kMessagesTabletFlags, 'posts'},
          extraProviders: [
            RepositoryProvider<PostsRepository>.value(value: posts),
          ],
          extraBlocs: [BlocProvider<PendingPostsCubit>.value(value: pending)],
        );
        rig.appRouter.router.push(AppRouter.composePath);
        await tester.pumpAndSettle();
        expect(find.byType(ComposerScreen), findsOneWidget);

        rig.appRouter.router.push(AppRouter.messagePath(inboxId(4)));
        await tester.pumpAndSettle();
        expect(rig.stack, [
          AppRouter.messagesPath,
          AppRouter.composePath,
          AppRouter.messagePath(inboxId(4)),
        ]);
        expect(rig.shellPages, 1);
        split ? expectSplit(inboxId(4)) : expectFullScreen();
        await tester.tap(find.byTooltip('Back'));
        await tester.pumpAndSettle();
        expect(rig.stack.last, AppRouter.composePath);
        expect(find.byType(ComposerScreen), findsOneWidget);
        await done(tester);
      });
    }
  });

  group("the profile's Message button (openConversationWith)", () {
    for (final width in [1024.0, 700.0]) {
      testWidgets('${width.toInt()}: an existing conversation opens it', (
        tester,
      ) async {
        // The inbox was loaded once this session (so the cache knows the
        // conversation), then the profile's button is pressed.
        final rig = await open(tester, width: width);
        final peer = common.AuthorSnapshot(
          userId: 'u-peer3',
          handle: 'peer3',
          displayName: 'Peer 3',
        );
        // The call the profile header's envelope makes, from a shell page.
        // Not awaited: it completes when the pushed thread is popped.
        unawaited(openConversationWith(tester.element(findInboxRoute()), peer));
        await tester.pumpAndSettle();
        expect(rig.stack, [
          AppRouter.messagesPath,
          AppRouter.messagePath(inboxId(3)),
        ]);
        width >= 840 ? expectSplit(inboxId(3)) : expectFullScreen();
        await done(tester);
      });
    }
  });

  group('the plan\'s "Message organiser"', () {
    testWidgets('1024: the draft opens in the split page with the Messages '
        'list, never the Plans list; back returns to the plan', (tester) async {
      final beacons = FakeBeaconsServer()
        ..public.add(
          beaconView(
            startAt: DateTime.now().add(const Duration(hours: 2)),
            organiserId: 'u-sam',
            organiserHandle: 'sam',
            organiserName: 'Sam Rivera',
          ),
        );
      final plans = PlansSession(repository: beacons);
      addTearDown(plans.dispose);
      final rig = await open(
        tester,
        location: AppRouter.planPath(kBeaconIdA),
        flags: {...kMessagesTabletFlags, kFeatureBeacons},
        extraProviders: [
          RepositoryProvider<BeaconsRepository>.value(value: beacons),
          RepositoryProvider<PlansSession>.value(value: plans),
        ],
      );
      expect(find.byType(BeaconScreen), findsOneWidget);
      expect(find.byType(PlansListPane), findsOneWidget);

      await tester.tap(find.widgetWithText(AppPillButton, 'Message organiser'));
      await tester.pumpAndSettle();

      expect(rig.stack, [
        AppRouter.planPath(kBeaconIdA),
        AppRouter.messageDraftPath,
      ]);
      expect(rig.shellPages, 1);
      expect(find.byType(DraftThreadScreen), findsOneWidget);
      expect(findMessagesPane(), findsOneWidget);
      // The shell under the split page is on a plan: its Plans list pane
      // must not leak into the split page.
      expect(
        find.descendant(
          of: find.ancestor(
            of: find.byType(DraftThreadScreen),
            matching: find.byType(MainShell),
          ),
          matching: find.byType(PlansListPane),
        ),
        findsNothing,
      );

      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(rig.stack, [AppRouter.planPath(kBeaconIdA)]);
      expect(find.byType(PlansListPane), findsOneWidget);
      await done(tester);
    });
  });

  group('the people picker', () {
    testWidgets('1024: someone with no conversation opens the draft in the '
        'split page (pushReplacement); the first send replaces it with '
        'the conversation', (tester) async {
      final rig = await open(tester);
      await tester.tap(find.widgetWithText(FilledButton, kNewMessageLabel));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sam Rivera'));
      await tester.pumpAndSettle();
      expect(rig.stack, [AppRouter.messagesPath, AppRouter.messageDraftPath]);
      expect(find.byType(DraftThreadScreen), findsOneWidget);
      expect(findMessagesPane(), findsOneWidget);

      await tester.enterText(find.byKey(MessageComposer.fieldKey), 'hi Sam');
      await tester.pump();
      await tester.tap(find.byKey(MessageComposer.sendKey));
      await tester.pumpAndSettle();
      expect(rig.server.sends.single.recipientUserId, 'u-sam');
      final created = rig.server.conversations.values
          .firstWhere((c) => c.peer.userId == 'u-sam')
          .id;
      expect(rig.stack, [
        AppRouter.messagesPath,
        AppRouter.messagePath(created),
      ]);
      expect(find.byType(ThreadScreen), findsOneWidget);
      expect(splitPage(), findsOneWidget);
      expect(rig.server.count('/${MessagingService.name}/SendMessage'), 1);
      await done(tester);
    });

    for (final width in [1024.0, 600.0]) {
      testWidgets('${width.toInt()}: an existing conversation replaces the '
          'picker with the thread', (tester) async {
        final server = tabletServer();
        final sam = threadConv().deepCopy()
          ..updatedAt = server.conversations[inboxId(0)]!.updatedAt
          ..lastMessage = server.conversations[inboxId(0)]!.lastMessage;
        server.conversations[kThreadId] = sam;
        server.messages[kThreadId] = [
          msg(900, conversationId: kThreadId, text: 'sam says hi'),
        ];
        final rig = MessagingFlowRig(
          server: server,
          flags: kMessagesTabletFlags,
        );
        await rig.pump(tester, size: Size(width, 900), hoisted: true);
        rig.appRouter.router.push(AppRouter.messageNewPath);
        await tester.pumpAndSettle();
        await tester.tap(
          find.descendant(
            of: find.byType(RecipientPickerDialog),
            matching: find.text('Sam Rivera'),
          ),
        );
        await tester.pumpAndSettle();
        expect(rig.stack, [
          AppRouter.messagesPath,
          AppRouter.messagePath(kThreadId),
        ]);
        expect(find.text('sam says hi'), findsOneWidget);
        width >= 840 ? expectSplit(kThreadId) : expectFullScreen();
        await done(tester);
      });
    }
  });

  testWidgets('the inbox route is the shell child and the threads are root '
      'at every width', (tester) async {
    final rig = await open(tester, width: 1024);
    expect(
      find.ancestor(of: findInboxRoute(), matching: find.byType(MainShell)),
      findsOneWidget,
    );
    expect(find.byType(ConversationsScreen), findsOneWidget);
    expect(rig.shellPages, 1);
    await done(tester);
  });

  // T7: the composer dialog over a thread. The split page draws the rail
  // (band B), so the dialog centres on the content area beside it; the
  // full-screen thread (band A) has none, so it centres on the window.
  group('the composer over a thread (T7)', () {
    for (final width in [1024.0, 700.0]) {
      testWidgets('${width.toInt()}: centred on the '
          '${width >= 840 ? 'content area beside the rail' : 'window'}', (
        tester,
      ) async {
        final posts = _MockPosts();
        when(() => posts.subFeatureEnabled(any())).thenReturn(false);
        final pending = PendingPostsCubit();
        addTearDown(pending.close);
        final rig = await open(
          tester,
          width: width,
          flags: {...kMessagesTabletFlags, 'posts'},
          extraProviders: [
            RepositoryProvider<PostsRepository>.value(value: posts),
          ],
          extraBlocs: [BlocProvider<PendingPostsCubit>.value(value: pending)],
        );
        await tester.tap(
          width >= 840
              ? inMessagesPane(conversationRow(inboxId(0)))
              : conversationRow(inboxId(0)),
        );
        await tester.pumpAndSettle();
        width >= 840 ? expectSplit(inboxId(0)) : expectFullScreen();
        // Messages has no New post control (`canComposeAt`): a pushed
        // location (a notification tap) opens the composer over the thread.
        unawaited(rig.appRouter.router.push(AppRouter.composePath));
        await tester.pumpAndSettle();
        expect(rig.stack.last, AppRouter.composePath);
        final composer = find.byType(ComposerScreen);
        expect(
          find.ancestor(of: composer, matching: find.byType(Dialog)),
          findsOneWidget,
        );
        final centre = tester.getRect(composer).center.dx;
        expect(
          centre,
          moreOrLessEquals(width >= 840 ? 80 + (width - 80) / 2 : width / 2),
        );
        expect(rig.shellPages, 1);
        await done(tester);
      });
    }
  });
}
