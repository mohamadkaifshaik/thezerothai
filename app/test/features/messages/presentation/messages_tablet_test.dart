import 'package:dzeroth/shared/widgets/primitives/app_pill_button.dart';
import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/router/main_shell.dart';
import 'package:dzeroth/core/feature_flags/ui_shell_feature_flag.dart';
import 'package:dzeroth/features/messages/domain/messaging_feature_gate.dart';
import 'package:dzeroth/features/messages/presentation/widgets/thread_info_sheet.dart';
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.connect.spec.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:dzeroth/core/widgets/app_nav_rail.dart';
import 'package:dzeroth/core/widgets/context_pane.dart';
import 'package:dzeroth/core/widgets/shell_geometry.dart';
import 'package:dzeroth/features/auth/presentation/widgets/auth_gate.dart';
import 'package:dzeroth/features/messages/presentation/bloc/conversations_cubit.dart';
import 'package:dzeroth/features/messages/presentation/bloc/message_composer_cubit.dart';
import 'package:dzeroth/features/messages/presentation/conversations_screen.dart';
import 'package:dzeroth/features/messages/presentation/draft_thread_screen.dart';
import 'package:dzeroth/features/messages/presentation/messages_list_detail.dart';
import 'package:dzeroth/features/messages/presentation/recipient_picker_screen.dart';
import 'package:dzeroth/features/messages/presentation/thread_route_page.dart';
import 'package:dzeroth/features/messages/presentation/thread_screen.dart';
import 'package:dzeroth/features/messages/presentation/widgets/message_composer.dart';
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pbenum.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/messages_tablet_fixtures.dart';
import '../../../support/messaging_flow_rig.dart';
import '../../../support/theme_harness.dart';

/// Tablet plan T6 (sections 3, 4.1 "Conversations" and "Chat", 5.2, 5.3):
/// Messages list–detail on the tablet layout. The shell's `/messages` and
/// `/messages/requests` get the list pane in band B; the root thread routes
/// draw the split page at 840-1199dp; the folders are hoisted, so neither
/// crossing 840dp nor switching conversations loads the list again. Phones,
/// band A and desktop keep today's pages. Real router, real repositories,
/// store and cubits; only the wire is faked.
void main() {
  MessagingFlowRig rigFor({Set<String> flags = kMessagesTabletFlags}) =>
      MessagingFlowRig(server: tabletServer(), flags: flags);

  Future<MessagingFlowRig> open(
    WidgetTester tester, {
    String location = AppRouter.messagesPath,
    double width = 1024,
    double height = 900,
    Set<String> flags = kMessagesTabletFlags,
    bool hoisted = true,
    TextDirection textDirection = TextDirection.ltr,
  }) async {
    final rig = rigFor(flags: flags);
    await rig.pump(
      tester,
      location: location,
      size: Size(width, height),
      hoisted: hoisted,
      textDirection: textDirection,
    );
    return rig;
  }

  Future<void> done(WidgetTester tester) => tester.pumpWidget(const SizedBox());

  group('flag modes x widths on /messages', () {
    const widths = [360.0, 599.0, 600.0, 839.0, 840.0, 1024.0, 1199.0, 1200.0];
    for (final MapEntry(key: mode, value: flags)
        in kMessagesFlagModes.entries) {
      for (final width in widths) {
        final paned =
            mode == 'ui_shell + ui_tablet' && width >= 840 && width < 1200;
        testWidgets('$mode at ${width.toInt()}: '
            '${paned ? 'list pane + placeholder' : 'the list page'}', (
          tester,
        ) async {
          final rig = await open(tester, width: width, flags: flags);

          expect(findMessagesPane(), paned ? findsOneWidget : findsNothing);
          expect(
            find.text(kSelectAConversation),
            paned ? findsOneWidget : findsNothing,
          );
          // The list once, wherever it is drawn.
          expect(find.text('Peer 0'), findsOneWidget);
          // One open: one INBOX refresh (no second for the pane).
          expect(rig.listCalls(Folder.FOLDER_INBOX), 1);
          expect(rig.listCalls(Folder.FOLDER_REQUESTS), 0);
          expect(find.byType(ContextPane), findsNothing);
          expect(tester.takeException(), isNull);
          await done(tester);
        });
      }
    }
  });

  group('band B: the shell inbox', () {
    for (final width in [840.0, 1024.0, 1199.0]) {
      testWidgets('geometry at ${width.toInt()}: rail | list | 1 | detail', (
        tester,
      ) async {
        await open(tester, width: width);
        final c = width - 80;
        final list = ShellGeometry.listPaneWidthFor(c);
        final pane = rectOf(tester, findMessagesPane());
        expect(pane.left, 80);
        expect(pane.width, list);
        final detail = rectOf(
          tester,
          find.byType(ConversationsDetailPlaceholder),
        );
        expect(detail.left, 80 + list + 1);
        expect(detail.right, width);
        await done(tester);
      });
    }

    testWidgets('RTL: the rail on the right, then the list, then the detail', (
      tester,
    ) async {
      await open(tester, textDirection: TextDirection.rtl);
      final list = ShellGeometry.listPaneWidthFor(1024 - 80);
      expect(rectOf(tester, find.byType(AppNavRail)).right, 1024);
      expect(rectOf(tester, findMessagesPane()).right, 1024 - 80);
      expect(
        rectOf(tester, find.byType(ConversationsDetailPlaceholder)).right,
        1024 - 80 - list - 1,
      );
      await done(tester);
    });

    testWidgets('the placeholder: icon, line and New message (the picker)', (
      tester,
    ) async {
      final rig = await open(tester);
      await tester.tap(find.widgetWithText(FilledButton, kNewMessageLabel));
      await tester.pumpAndSettle();
      expect(rig.path, AppRouter.messageNewPath);
      expect(find.byType(RecipientPickerDialog), findsOneWidget);
      await done(tester);
    });

    testWidgets('a row opens the split page: the thread beside the same list, '
        'the row selected, no second list call, one shell', (tester) async {
      final rig = await open(tester);
      final cubit = rig.session!.ifCreated(Folder.FOLDER_INBOX);
      await tester.tap(inMessagesPane(conversationRow(inboxId(2))));
      await tester.pumpAndSettle();

      expect(rig.path, AppRouter.messagePath(inboxId(2)));
      expect(rig.stack, [
        AppRouter.messagesPath,
        AppRouter.messagePath(inboxId(2)),
      ]);
      expect(rig.shellPages, 1);
      expect(find.byType(ThreadScreen), findsOneWidget);
      expect(find.text('newer in ${inboxId(2)}'), findsOneWidget);
      // The split page: a MainShell around the thread, inside the AuthGate.
      final split = find.ancestor(
        of: find.byType(ThreadScreen),
        matching: find.byType(MainShell),
      );
      expect(split, findsOneWidget);
      expect(
        find.ancestor(of: split, matching: find.byType(AuthGate)),
        findsWidgets,
      );
      // The list pane beside it, with the open row selected.
      expect(
        tester.getSemantics(inMessagesPane(conversationRow(inboxId(2)))),
        isSemantics(isSelected: true, isButton: true, hasTapAction: true),
      );
      expect(rig.session!.ifCreated(Folder.FOLDER_INBOX), same(cubit));
      expect(rig.listCalls(Folder.FOLDER_INBOX), 1);
      // The thread is the detail: after the rail and the list.
      final list = ShellGeometry.listPaneWidthFor(1024 - 80);
      expect(rectOf(tester, find.byType(ThreadScreen)).left, 80 + list + 1);
      await done(tester);
    });

    testWidgets('no transition at 1024: the thread is in place on the first '
        'frame, and back is instant', (tester) async {
      final rig = await open(tester);
      await tester.tap(inMessagesPane(conversationRow(inboxId(1))));
      await tester.pump();
      // The route's own animation: already complete (zero duration).
      expect(threadRouteStatus(tester), AnimationStatus.completed);
      final list = ShellGeometry.listPaneWidthFor(1024 - 80);
      expect(rectOf(tester, find.byType(ThreadScreen)).left, 80 + list + 1);
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Back'));
      await tester.pump();
      expect(find.byType(ThreadScreen), findsNothing);
      expect(rig.path, AppRouter.messagesPath);
      await done(tester);
    });

    testWidgets('switching in the split page replaces the thread: one page '
        'deep, the new conversation loaded, the selection moved', (
      tester,
    ) async {
      final rig = await open(tester);
      await tester.tap(inMessagesPane(conversationRow(inboxId(1))));
      await tester.pumpAndSettle();
      final first = threadCubitOf(tester);
      final before = rig.threadCalls(inboxId(3));

      await tester.tap(inMessagesPane(conversationRow(inboxId(3))));
      await tester.pumpAndSettle();

      expect(rig.stack, [
        AppRouter.messagesPath,
        AppRouter.messagePath(inboxId(3)),
      ]);
      expect(rig.threadCalls(inboxId(3)), greaterThan(before));
      expect(threadCubitOf(tester), isNot(same(first)));
      expect(threadCubitOf(tester).conversationId, inboxId(3));
      expect(find.text('newer in ${inboxId(3)}'), findsOneWidget);
      expect(find.text('newer in ${inboxId(1)}'), findsNothing);
      expect(
        tester.getSemantics(inMessagesPane(conversationRow(inboxId(3)))),
        isSemantics(isSelected: true, isButton: true, hasTapAction: true),
      );
      expect(rig.listCalls(Folder.FOLDER_INBOX), 1);

      // The open row does nothing.
      await tester.tap(inMessagesPane(conversationRow(inboxId(3))));
      await tester.pumpAndSettle();
      expect(rig.stack, [
        AppRouter.messagesPath,
        AppRouter.messagePath(inboxId(3)),
      ]);

      // Back pops to the shell's placeholder.
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(rig.path, AppRouter.messagesPath);
      expect(find.text(kSelectAConversation), findsOneWidget);
      await done(tester);
    });

    testWidgets("the split page's list keeps its scroll offset across "
        'switches', (tester) async {
      await open(tester, height: 700);
      await tester.tap(inMessagesPane(conversationRow(inboxId(0))));
      await tester.pumpAndSettle();
      final scrollable = find.descendant(
        of: findMessagesPane(),
        matching: find.byType(Scrollable),
      );
      await tester.drag(scrollable.first, const Offset(0, -300));
      await tester.pumpAndSettle();
      final offset = tester
          .state<ScrollableState>(scrollable.first)
          .position
          .pixels;
      expect(offset, greaterThan(0));
      final target = find
          .descendant(
            of: findMessagesPane(),
            matching: find.textContaining('Peer '),
          )
          .hitTestable()
          .first;
      await tester.tap(target);
      await tester.pumpAndSettle();
      expect(
        tester.state<ScrollableState>(scrollable.first).position.pixels,
        offset,
      );
      await done(tester);
    });

    testWidgets('the Requests folder: its list pane, its rows keep it in the '
        'split page, and back closes the folder', (tester) async {
      final rig = await open(tester);
      await tester.tap(inMessagesPane(find.text('Message requests')));
      await tester.pumpAndSettle();
      expect(rig.stack.last, AppRouter.messageRequestsPath);
      expect(inMessagesPane(find.text('Message requests')), findsOneWidget);
      expect(find.text(kSelectAConversation), findsOneWidget);
      expect(rig.listCalls(Folder.FOLDER_REQUESTS), 1);

      await tester.tap(inMessagesPane(conversationRow(kRequestId)));
      await tester.pumpAndSettle();
      expect(rig.path, AppRouter.messagePath(kRequestId));
      expect(find.text('Rex Request wants to message you'), findsOneWidget);
      // The Requests list stays beside the request.
      expect(inMessagesPane(find.text('Message requests')), findsOneWidget);
      expect(inMessagesPane(conversationRow(inboxId(0))), findsNothing);

      // Switching inside keeps the folder (the extra is passed again).
      await tester.tap(inMessagesPane(conversationRow(kRequestId2)));
      await tester.pumpAndSettle();
      expect(rig.path, AppRouter.messagePath(kRequestId2));
      expect(inMessagesPane(find.text('Message requests')), findsOneWidget);
      expect(rig.listCalls(Folder.FOLDER_REQUESTS), 1);

      // The folder's back goes to the shell inbox (never a shell page
      // pushed over the root thread).
      await tester.tap(inMessagesPane(find.byTooltip('Back')));
      await tester.pumpAndSettle();
      expect(rig.stack, [AppRouter.messagesPath]);
      expect(rig.shellPages, 1);
      expect(find.text(kSelectAConversation), findsOneWidget);
      await done(tester);
    });

    testWidgets("the split page inbox's Requests row goes to the shell "
        'folder', (tester) async {
      final rig = await open(tester);
      await tester.tap(inMessagesPane(conversationRow(inboxId(0))));
      await tester.pumpAndSettle();
      await tester.tap(inMessagesPane(find.text('Message requests')));
      await tester.pumpAndSettle();
      expect(rig.stack, [AppRouter.messageRequestsPath]);
      expect(rig.shellPages, 1);
      expect(find.byType(ThreadScreen), findsNothing);
      await done(tester);
    });

    testWidgets('the rail selects Messages in the split page', (tester) async {
      await open(tester, location: AppRouter.messagePath(inboxId(0)));
      final rail = tester.widget<AppNavRail>(find.byType(AppNavRail));
      expect(rail.destinations[rail.selectedIndex!].label, 'Messages');
      await done(tester);
    });
  });

  group('band A and phones: today\'s full-screen thread', () {
    for (final width in [360.0, 599.0, 600.0, 700.0, 839.0]) {
      testWidgets('at ${width.toInt()} a row pushes the thread with no shell', (
        tester,
      ) async {
        final rig = await open(tester, width: width);
        expect(findMessagesPane(), findsNothing);
        await tester.tap(conversationRow(inboxId(1)));
        await tester.pumpAndSettle();
        expect(rig.path, AppRouter.messagePath(inboxId(1)));
        expect(
          find.ancestor(
            of: find.byType(ThreadScreen),
            matching: find.byType(MainShell),
          ),
          findsNothing,
        );
        expect(rectOf(tester, find.byType(ThreadRoutePage)).width, width);
        await tester.tap(find.byTooltip('Back'));
        await tester.pumpAndSettle();
        expect(rig.path, AppRouter.messagesPath);
        await done(tester);
      });
    }

    testWidgets('desktop (1200) keeps the full-screen thread (R-1)', (
      tester,
    ) async {
      await open(
        tester,
        width: 1200,
        location: AppRouter.messagePath(inboxId(0)),
      );
      expect(
        find.ancestor(
          of: find.byType(ThreadScreen),
          matching: find.byType(MainShell),
        ),
        findsNothing,
      );
      expect(findMessagesPane(), findsNothing);
      await done(tester);
    });

    testWidgets('without the session (no AppWidget) 1024 keeps the '
        'full-screen thread', (tester) async {
      await open(
        tester,
        hoisted: false,
        location: AppRouter.messagePath(inboxId(0)),
      );
      expect(findMessagesPane(), findsNothing);
      expect(
        find.ancestor(
          of: find.byType(ThreadScreen),
          matching: find.byType(MainShell),
        ),
        findsNothing,
      );
      await done(tester);
    });
  });

  group('crossing 840 and 1200', () {
    testWidgets('/messages 839 -> 840 -> 839: the same cubit, one list call', (
      tester,
    ) async {
      final rig = await open(tester, width: 839);
      final cubit = rig.session!.ifCreated(Folder.FOLDER_INBOX);
      expect(cubit, isNotNull);
      await rig.resize(tester, 840);
      expect(findMessagesPane(), findsOneWidget);
      expect(find.text(kSelectAConversation), findsOneWidget);
      await rig.resize(tester, 839);
      expect(findMessagesPane(), findsNothing);
      expect(find.text('Peer 0'), findsOneWidget);
      expect(rig.session!.ifCreated(Folder.FOLDER_INBOX), same(cubit));
      expect(rig.listCalls(), 1);
      await done(tester);
    });

    testWidgets('a thread 839 -> 840 -> 839: re-parented (the same cubit and '
        'composer text), no reload', (tester) async {
      final rig = await open(
        tester,
        width: 839,
        location: AppRouter.messagePath(inboxId(4)),
      );
      final cubit = threadCubitOf(tester);
      await tester.enterText(
        find.byKey(MessageComposer.fieldKey),
        'half typed',
      );
      final calls = rig.threadCalls(inboxId(4));

      await rig.resize(tester, 840);
      expect(findMessagesPane(), findsOneWidget);
      expect(threadCubitOf(tester), same(cubit));
      expect(find.text('half typed'), findsOneWidget);
      expect(
        tester.getSemantics(inMessagesPane(conversationRow(inboxId(4)))),
        isSemantics(isSelected: true, isButton: true, hasTapAction: true),
      );

      await rig.resize(tester, 839);
      expect(findMessagesPane(), findsNothing);
      expect(threadCubitOf(tester), same(cubit));
      expect(find.text('half typed'), findsOneWidget);
      expect(rig.threadCalls(inboxId(4)), calls);
      await done(tester);
    });

    testWidgets('a thread 1199 -> 1200 -> 1199: the split page goes and comes '
        'back, the thread kept', (tester) async {
      await open(
        tester,
        width: 1199,
        location: AppRouter.messagePath(inboxId(4)),
      );
      final cubit = threadCubitOf(tester);
      await rig1200(tester);
      expect(findMessagesPane(), findsNothing);
      expect(threadCubitOf(tester), same(cubit));
      tester.view.physicalSize = const Size(1199, 900);
      await tester.pumpAndSettle();
      expect(findMessagesPane(), findsOneWidget);
      expect(threadCubitOf(tester), same(cubit));
      await done(tester);
    });

    testWidgets('the draft thread 839 -> 840: the same composer', (
      tester,
    ) async {
      final rig = await open(tester, width: 839);
      // The picker opens the draft for someone with no conversation.
      rig.appRouter.router.push(AppRouter.messageNewPath);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sam Rivera'));
      await tester.pumpAndSettle();
      expect(rig.path, AppRouter.messageDraftPath);
      expect(find.byType(DraftThreadScreen), findsOneWidget);
      await tester.enterText(find.byKey(MessageComposer.fieldKey), 'first');
      MessageComposerCubit composer() => BlocProvider.of<MessageComposerCubit>(
        tester.element(find.byType(MessageComposer)),
      );
      final before = composer();
      final field = tester.state(find.byKey(MessageComposer.fieldKey));
      await rig.resize(tester, 840);
      expect(findMessagesPane(), findsOneWidget);
      // Re-parented: the same composer cubit and the same field state.
      expect(composer(), same(before));
      expect(tester.state(find.byKey(MessageComposer.fieldKey)), same(field));
      expect(find.text('first'), findsOneWidget);
      await done(tester);
    });
  });

  // Tablet plan section 5.5: 5 widths x 2 text scales x 2 themes on a thread
  // and on the inbox. Band A: the full-screen thread / the list over the
  // whole content; band B: rail | list | 1 | detail = W.
  group('matrix cells (section 5.5)', () {
    for (final brightness in Brightness.values) {
      for (final width in kTabletMatrixWidths) {
        for (final scale in kTabletTextScales) {
          testWidgets('${brightness.name} ${width.toInt()}dp x$scale', (
            tester,
          ) async {
            final rig = rigFor();
            await rig.pump(
              tester,
              location: AppRouter.messagePath(inboxId(1)),
              size: Size(width, kTabletHeights[width]!),
              hoisted: true,
              brightness: brightness,
              textScale: scale,
            );
            expect(tester.takeException(), isNull);
            final thread = rectOf(tester, find.byType(ThreadScreen));
            if (width < AppBreakpoints.expanded) {
              expect(findMessagesPane(), findsNothing);
              expect(thread.left, 0);
              expect(thread.width, width);
            } else {
              expect(rectOf(tester, find.byType(AppNavRail)).left, 0);
              final content = width - AppSize.railCompact;
              final list = ShellGeometry.listPaneWidthFor(content);
              expect(rectOf(tester, findMessagesPane()).width, list);
              expect(thread.left, AppSize.railCompact + list + 1);
              expect(AppSize.railCompact + list + 1 + thread.width, width);
            }

            // The inbox at the same cell.
            await tester.tap(find.byTooltip('Back'));
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            expect(rectOf(tester, find.byType(AppNavRail)).left, 0);
            if (width >= AppBreakpoints.expanded) {
              expect(find.text(kSelectAConversation), findsOneWidget);
            } else {
              expect(
                rectOf(tester, findInboxRoute()).width,
                width - AppSize.railCompact,
              );
            }
            await done(tester);
          });
        }
      }
    }
  });

  group('the boundaries (section 5.5)', () {
    for (final width in kBoundaryWidths) {
      final split = width >= 840 && width < 1200;
      testWidgets('${width.toInt()}: a thread is '
          '${split ? 'the split page' : 'full screen'}', (tester) async {
        await open(
          tester,
          width: width,
          location: AppRouter.messagePath(inboxId(1)),
        );
        expect(findMessagesPane(), split ? findsOneWidget : findsNothing);
        expect(
          find.ancestor(
            of: find.byType(ThreadScreen),
            matching: find.byType(MainShell),
          ),
          split ? findsOneWidget : findsNothing,
        );
        expect(tester.takeException(), isNull);
        await done(tester);
      });
    }
  });

  group('below 840 the transition is the platform one', () {
    testWidgets('iOS at 700: the back swipe pops the thread', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        final rig = await open(tester, width: 700);
        await tester.tap(conversationRow(inboxId(1)));
        await tester.pumpAndSettle();
        expect(find.byType(ThreadScreen), findsOneWidget);

        final gesture = await tester.startGesture(const Offset(2, 450));
        await gesture.moveBy(const Offset(400, 0));
        await gesture.up();
        await tester.pumpAndSettle();

        expect(find.byType(ThreadScreen), findsNothing);
        expect(rig.stack, [AppRouter.messagesPath]);
        await done(tester);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('Android at 700: the thread animates in over the platform '
        'duration', (tester) async {
      await open(tester, width: 700);
      await tester.tap(conversationRow(inboxId(1)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      // Mid-transition: the route animates, the inbox under it is painted.
      expect(threadRouteStatus(tester), AnimationStatus.forward);
      expect(findInboxRoute(), findsOneWidget);
      expect(find.byType(ThreadScreen), findsOneWidget);
      await tester.pumpAndSettle();
      expect(threadRouteStatus(tester), AnimationStatus.completed);
      // Back animates out too.
      await tester.tap(find.byTooltip('Back'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(threadRouteStatus(tester), AnimationStatus.reverse);
      await tester.pumpAndSettle();
      await done(tester);
    });

    testWidgets('iOS at 1024: no swipe and no slide in the split page', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        final rig = await open(tester);
        await tester.tap(inMessagesPane(conversationRow(inboxId(1))));
        await tester.pump();
        await tester.pump();
        final list = ShellGeometry.listPaneWidthFor(1024 - 80);
        expect(rectOf(tester, find.byType(ThreadScreen)).left, 80 + list + 1);
        await tester.pumpAndSettle();

        // A swipe from the leading edge is the rail's, not a back swipe: the
        // split page stays (the list and the rail are beside the thread).
        final gesture = await tester.startGesture(const Offset(2, 450));
        await gesture.moveBy(const Offset(500, 0));
        await gesture.up();
        await tester.pumpAndSettle();
        expect(find.byType(ThreadScreen), findsOneWidget);
        expect(rig.stack, [
          AppRouter.messagesPath,
          AppRouter.messagePath(inboxId(1)),
        ]);
        await done(tester);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });

  testWidgets('text scale 2.0 at 1024 x 768: no overflow, rows 48dp+', (
    tester,
  ) async {
    final rig = rigFor();
    await rig.pump(
      tester,
      location: AppRouter.messagePath(inboxId(1)),
      size: const Size(1024, 768),
      hoisted: true,
      textScale: 2,
    );
    expect(tester.takeException(), isNull);
    expect(
      tester.getSize(inMessagesPane(conversationRow(inboxId(1)))).height,
      greaterThanOrEqualTo(48),
    );
    await done(tester);
  });

  group('read-only Messages (messaging off for the caller, the probe ok)', () {
    const readOnlyFlags = {
      'graph',
      'reports',
      kFeatureUiShell,
      kFeatureUiTablet,
    };

    testWidgets('1024: the list pane and the placeholder without New message; '
        'a row opens the split page with no composer', (tester) async {
      final rig = rigFor(flags: readOnlyFlags);
      await rig.primeReadOnly(tester);
      await rig.pump(tester, size: const Size(1024, 900), hoisted: true);
      expect(rig.messagingRepository.gate.access, MessagingAccess.readOnly);

      expect(findMessagesPane(), findsOneWidget);
      expect(find.text(kSelectAConversation), findsOneWidget);
      expect(find.widgetWithText(FilledButton, kNewMessageLabel), findsNothing);
      expect(find.byTooltip(kNewMessageLabel), findsNothing);
      // The rail has no Messages destination in this mode (ADR-0034).
      expect(find.text('Messages'), findsOneWidget);
      final rail = tester.widget<AppNavRail>(find.byType(AppNavRail));
      expect(
        rail.destinations.map((d) => d.label),
        isNot(contains('Messages')),
      );

      await tester.tap(inMessagesPane(conversationRow(inboxId(1))));
      await tester.pumpAndSettle();
      expect(find.byType(ThreadScreen), findsOneWidget);
      expect(findMessagesPane(), findsOneWidget);
      expect(find.text(kMessagingReadOnlyText), findsOneWidget);
      expect(find.byKey(MessageComposer.fieldKey), findsNothing);
      await done(tester);
    });

    testWidgets('700: today\'s list, and the thread full screen', (
      tester,
    ) async {
      final rig = rigFor(flags: readOnlyFlags);
      await rig.primeReadOnly(tester);
      await rig.pump(tester, size: const Size(700, 900), hoisted: true);
      expect(findMessagesPane(), findsNothing);
      await tester.tap(conversationRow(inboxId(1)));
      await tester.pumpAndSettle();
      expect(
        find.ancestor(
          of: find.byType(ThreadScreen),
          matching: find.byType(MainShell),
        ),
        findsNothing,
      );
      await done(tester);
    });
  });

  testWidgets('the info sheet in the split page (real stack): Delete confirms '
      'over the content area, deletes, lands on the placeholder, and the row '
      'leaves the list', (tester) async {
    final rig = await open(tester);
    await tester.tap(inMessagesPane(conversationRow(inboxId(2))));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip(kConversationInfoLabel));
    await tester.pumpAndSettle();
    expect(find.byType(ThreadInfoSheet), findsOneWidget);
    expect(tester.getRect(find.byType(ThreadInfoSheet)).right, 1024);
    await tester.tap(find.text('Delete conversation'));
    await tester.pumpAndSettle();
    expect(find.byType(ThreadInfoSheet), findsNothing);

    // The confirm is centred on the content area (after the 80dp rail).
    final dialog = tester.getRect(
      find
          .descendant(
            of: find.byType(AlertDialog),
            matching: find.byType(Material),
          )
          .first,
    );
    expect(dialog.center.dx, closeTo(80 + (1024 - 80) / 2, 1));
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(rig.server.count('/${MessagingService.name}/DeleteConversation'), 1);
    expect(rig.stack, [AppRouter.messagesPath]);
    expect(find.text(kSelectAConversation), findsOneWidget);
    expect(inMessagesPane(conversationRow(inboxId(2))), findsNothing);
    expect(inMessagesPane(conversationRow(inboxId(1))), findsOneWidget);
    await done(tester);
  });

  testWidgets('the info sheet in the split page: Block runs the graph flow', (
    tester,
  ) async {
    final rig = await open(tester);
    await tester.tap(inMessagesPane(conversationRow(inboxId(2))));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip(kConversationInfoLabel));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Block @peer2'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(AppPillButton, 'Block'));
    await tester.pumpAndSettle();
    expect(rig.server.blocks.single.userId, 'u-peer2');
    expect(find.text(kThreadReadOnlyText), findsOneWidget);
    await done(tester);
  });

  testWidgets('the hoisted inbox cubit is the one the route reads', (
    tester,
  ) async {
    final rig = await open(tester, width: 700);
    final cubit = rig.session!.ifCreated(Folder.FOLDER_INBOX)!;
    expect(cubit.started, isTrue);
    expect(
      tester.element(find.byType(ConversationsList)).read<ConversationsCubit>(),
      same(cubit),
    );
    await done(tester);
  });
}

/// The animation status of the open thread's route.
AnimationStatus threadRouteStatus(WidgetTester tester) =>
    ModalRoute.of(tester.element(find.byType(ThreadScreen)))!.animation!.status;

Future<void> rig1200(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1200, 900);
  await tester.pumpAndSettle();
}
