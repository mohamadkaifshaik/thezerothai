import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/router/main_shell.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/core/widgets/app_nav_rail.dart';
import 'package:dzeroth/core/widgets/shell_geometry.dart';
import 'package:dzeroth/features/messages/presentation/messages_list_detail.dart';
import 'package:dzeroth/features/messages/presentation/recipient_picker_screen.dart';
import 'package:dzeroth/features/messages/presentation/thread_screen.dart';
import 'package:dzeroth/features/messages/presentation/widgets/message_composer.dart';
import 'package:dzeroth/shared/widgets/primitives/app_back_header.dart';
import 'package:dzeroth/shared/widgets/primitives/app_main_column.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/messages_tablet_fixtures.dart';
import '../../../support/messaging_flow_rig.dart';
import '../../../support/tablet_modal_harness.dart' show openDialogRect;
import '../../../support/geometry.dart';

/// T8e for Messages (tablet plan sections 3, 4.1 "Chat" and
/// "RecipientPicker", 5.3, 5.4):
/// - the people picker (`/messages/new`, a root dialog page) is
///   `min(600, C - 48)` x `min(H - 48, 640)`, centred on the content area,
///   with the barrier over the rail; it still opens the thread with
///   `pushReplacement` of the root route, full screen in band A and the
///   split page in band B;
/// - the thread's reading column (the messages and the composer under them)
///   is at most 680 and centred in its pane, its header's divider spanning
///   the pane.
void main() {
  Future<MessagingFlowRig> open(
    WidgetTester tester, {
    double width = 1024,
    double height = 900,
    TextDirection textDirection = TextDirection.ltr,
    double textScale = 1,
    String location = AppRouter.messagesPath,
  }) async {
    final rig = MessagingFlowRig(
      server: tabletServer(),
      flags: kMessagesTabletFlags,
    );
    await rig.pump(
      tester,
      location: location,
      size: Size(width, height),
      hoisted: true,
      textDirection: textDirection,
      textScale: textScale,
    );
    return rig;
  }

  Future<void> openPicker(MessagingFlowRig rig, WidgetTester tester) async {
    rig.appRouter.router.push(AppRouter.messageNewPath);
    await tester.pumpAndSettle();
    expect(find.byType(RecipientPickerDialog), findsOneWidget);
  }

  Future<void> done(WidgetTester tester) => tester.pumpWidget(const SizedBox());

  Rect content(double width, double height, {bool rtl = false}) =>
      Rect.fromLTWH(rtl ? 0 : 80, 0, width - 80, height);

  group('the picker on the tablet layout', () {
    for (final width in [600.0, 839.0, 840.0, 1024.0, 1199.0]) {
      testWidgets('${width.toInt()}: min(600, C - 48) x min(H - 48, 640), '
          'centred on the content area', (tester) async {
        final rig = await open(tester, width: width);
        await openPicker(rig, tester);
        final area = content(width, 900);
        final dialog = openDialogRect(tester);
        final w = area.width - 48 < 600 ? area.width - 48 : 600.0;
        expect(dialog.width, moreOrLessEquals(w, epsilon: 0.5));
        expect(dialog.height, moreOrLessEquals(640, epsilon: 0.5));
        expect(dialog.center.dx, moreOrLessEquals(area.center.dx));
        expect(dialog.center.dy, moreOrLessEquals(450));
        expectNoOverflow(tester);
        await done(tester);
      });
    }

    testWidgets('a short window: H - 48 tall', (tester) async {
      final rig = await open(tester, width: 1024, height: 600);
      await openPicker(rig, tester);
      expect(openDialogRect(tester).height, moreOrLessEquals(600 - 48));
      await done(tester);
    });

    testWidgets('the barrier covers the rail: a tap there closes the picker '
        'and selects nothing', (tester) async {
      final rig = await open(tester, width: 840);
      await openPicker(rig, tester);
      final rail = tester.getRect(find.byType(AppNavRail));
      await tester.tapAt(Offset(rail.center.dx, 300));
      await tester.pumpAndSettle();
      expect(find.byType(RecipientPickerDialog), findsNothing);
      expect(rig.stack, [AppRouter.messagesPath]);
      await done(tester);
    });

    testWidgets('RTL at 1024: centred on the content area left of the rail', (
      tester,
    ) async {
      final rig = await open(tester, textDirection: TextDirection.rtl);
      await openPicker(rig, tester);
      final dialog = openDialogRect(tester);
      expect(dialog.width, 600);
      expect(
        dialog.center.dx,
        moreOrLessEquals(content(1024, 900, rtl: true).center.dx),
      );
      await done(tester);
    });

    for (final width in [600.0, 1024.0]) {
      testWidgets('text scale 2.0 at ${width.toInt()}: no overflow, the To: '
          'field in the dialog', (tester) async {
        final rig = await open(tester, width: width, textScale: 2);
        await openPicker(rig, tester);
        expectNoOverflow(tester);
        final dialog = openDialogRect(tester);
        final field = tester.getRect(find.byKey(kRecipientFieldKey));
        expect(dialog.contains(field.center), isTrue);
        await done(tester);
      });
    }

    testWidgets('the keyboard up (half the height): the To: field stays above '
        'it', (tester) async {
      final rig = await open(tester, width: 1024, height: 768);
      await openPicker(rig, tester);
      tester.view.viewInsets = const FakeViewPadding(bottom: 384);
      await tester.pumpAndSettle();
      final field = tester.getRect(find.byKey(kRecipientFieldKey));
      expect(field.bottom, lessThanOrEqualTo(768 - 384));
      expect(openDialogRect(tester).bottom, lessThanOrEqualTo(768 - 384));
      expectNoOverflow(tester);
      await done(tester);
    });

    for (final width in [700.0, 1024.0]) {
      testWidgets('${width.toInt()}: from the New message control, picking '
          'someone replaces the picker with the thread '
          '(${width >= 840 ? 'the split page' : 'full screen'})', (
        tester,
      ) async {
        final rig = await open(tester, width: width);
        // Band A: the inbox bar's action; band B: the placeholder's button.
        await tester.tap(
          width >= 840
              ? find.widgetWithText(FilledButton, kNewMessageLabel)
              : find.byTooltip(kNewMessageLabel),
        );
        await tester.pumpAndSettle();
        expect(find.byType(RecipientPickerDialog), findsOneWidget);
        expect(
          openDialogRect(tester).center.dx,
          moreOrLessEquals(content(width, 900).center.dx),
        );
        await tester.tap(
          find.descendant(
            of: find.byType(RecipientPickerDialog),
            matching: find.text('Sam Rivera'),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(RecipientPickerDialog), findsNothing);
        // `pushReplacement`: one page over the inbox.
        expect(rig.stack.length, 2);
        expect(rig.stack.first, AppRouter.messagesPath);
        expect(rig.shellPages, 1);
        // Sam has no conversation yet: the draft thread, in the split page
        // in band B, full screen in band A.
        expect(rig.stack.last, AppRouter.messageDraftPath);
        final split = find.ancestor(
          of: find.byType(MessageComposer),
          matching: find.byType(MainShell),
        );
        expect(split, width >= 840 ? findsOneWidget : findsNothing);
        expect(find.byType(MessageComposer), findsOneWidget);
        await done(tester);
      });
    }

    testWidgets('a resize keeps what was typed, and the dialog follows the '
        'content area (1024 -> 839 -> 1200 -> 1024)', (tester) async {
      final rig = await open(tester);
      await openPicker(rig, tester);
      await tester.enterText(find.byKey(kRecipientFieldKey), 'pe');
      await tester.pumpAndSettle();
      for (final (width, centre) in [
        (839.0, content(839, 900).center.dx),
        // Desktop: today's card, centred on the window.
        (1200.0, 600.0),
        (1024.0, content(1024, 900).center.dx),
      ]) {
        await rig.resize(tester, width);
        expect(find.byType(RecipientPickerDialog), findsOneWidget);
        expect(
          find.descendant(
            of: find.byKey(kRecipientFieldKey),
            matching: find.text('pe'),
          ),
          findsOneWidget,
          reason: '$width',
        );
        expect(
          openDialogRect(tester).center.dx,
          moreOrLessEquals(centre),
          reason: '$width',
        );
      }
      await done(tester);
    });

    testWidgets('over the split page (band B): centred beside the rail', (
      tester,
    ) async {
      final rig = await open(tester, width: 1199);
      await tester.tap(inMessagesPane(conversationRow(inboxId(1))));
      await tester.pumpAndSettle();
      await openPicker(rig, tester);
      expect(
        openDialogRect(tester).center.dx,
        moreOrLessEquals(content(1199, 900).center.dx),
      );
      await done(tester);
    });
  });

  group('the picker on phones and desktop: today\'s', () {
    for (final width in [360.0, 599.0]) {
      testWidgets('${width.toInt()}: full screen', (tester) async {
        final rig = await open(tester, width: width);
        await openPicker(rig, tester);
        expect(tester.getSize(find.byType(Dialog)).width, width);
        await done(tester);
      });
    }
    for (final width in [1200.0, 1440.0]) {
      testWidgets('${width.toInt()}: a 600 card centred on the window', (
        tester,
      ) async {
        final rig = await open(tester, width: width);
        await openPicker(rig, tester);
        final dialog = openDialogRect(tester);
        expect(dialog.width, 600);
        expect(dialog.center.dx, moreOrLessEquals(width / 2));
        await done(tester);
      });
    }
  });

  group('the thread: the reading column', () {
    Rect column(WidgetTester tester) => tester.getRect(
      find.descendant(
        of: find.byType(ThreadScreen),
        matching: find.byType(AppMainColumnBleed),
      ),
    );

    Rect headerDivider(WidgetTester tester) => tester.getRect(
      find
          .descendant(
            of: find.descendant(
              of: find.byType(ThreadScreen),
              matching: find.byType(AppBackHeader),
            ),
            matching: find.byType(Divider),
          )
          .first,
    );

    for (final (width, rtl) in [
      (840.0, false),
      (1024.0, false),
      (1199.0, false),
      (1199.0, true),
    ]) {
      testWidgets('the split page at ${width.toInt()}${rtl ? ' RTL' : ''}: '
          'the detail\'s column, the composer under it', (tester) async {
        await open(
          tester,
          width: width,
          textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
        );
        await tester.tap(inMessagesPane(conversationRow(inboxId(1))));
        await tester.pumpAndSettle();
        final c = width - 80;
        final list = ShellGeometry.listPaneWidthFor(c);
        final detailWidth = c - list - 1;
        final detailLeft = rtl ? 0.0 : 80 + list + 1;
        final detail = Rect.fromLTWH(detailLeft, 0, detailWidth, 900);
        final col = column(tester);
        final expected = detailWidth < AppSize.readableMax
            ? detailWidth
            : AppSize.readableMax;
        expect(col.width, moreOrLessEquals(expected));
        expect(col.center.dx, moreOrLessEquals(detail.center.dx));
        // The composer is aligned with the messages above it.
        final composer = tester.getRect(find.byType(MessageComposer));
        expect(composer.left, moreOrLessEquals(col.left));
        expect(composer.right, moreOrLessEquals(col.right));
        // The header's divider spans the detail.
        final divider = headerDivider(tester);
        expect(divider.left, moreOrLessEquals(detail.left));
        expect(divider.right, moreOrLessEquals(detail.right));
        expectNoOverflow(tester);
        await done(tester);
      });
    }

    for (final width in [600.0, 839.0]) {
      testWidgets('band A at ${width.toInt()}: full screen, 680 centred on '
          'the window', (tester) async {
        await open(
          tester,
          width: width,
          location: AppRouter.messagePath(inboxId(1)),
        );
        final col = column(tester);
        final expected = width < AppSize.readableMax
            ? width
            : AppSize.readableMax;
        expect(col.width, moreOrLessEquals(expected));
        expect(col.center.dx, moreOrLessEquals(width / 2));
        final composer = tester.getRect(find.byType(MessageComposer));
        expect(composer.left, moreOrLessEquals(col.left));
        expect(composer.right, moreOrLessEquals(col.right));
        final divider = headerDivider(tester);
        expect(divider.left, 0);
        expect(divider.right, width);
        await done(tester);
      });
    }

    for (final width in [390.0, 1440.0]) {
      testWidgets('${width.toInt()}: today\'s column (at most 600)', (
        tester,
      ) async {
        await open(
          tester,
          width: width,
          location: AppRouter.messagePath(inboxId(1)),
        );
        final col = column(tester);
        expect(col.width, width < 600 ? width : 600);
        expect(headerDivider(tester).width, col.width);
        await done(tester);
      });
    }
  });

  // UX review: the Requests folder's header (a back header in the reading
  // column) spans the pane, as the Inbox's top bar does.
  group('the Requests header in band A', () {
    for (final width in [600.0, 834.0, 839.0]) {
      testWidgets('${width.toInt()}: its divider spans the pane', (
        tester,
      ) async {
        await open(
          tester,
          width: width,
          location: AppRouter.messageRequestsPath,
        );
        final header = find.ancestor(
          of: find.text('Message requests'),
          matching: find.byType(AppBackHeader),
        );
        expect(header, findsOneWidget);
        final divider = tester.getRect(
          find.descendant(of: header, matching: find.byType(Divider)),
        );
        expect(divider.left, moreOrLessEquals(80));
        expect(divider.right, moreOrLessEquals(width));
        // T8f, one header rule: Back leads the pane (outside the reading
        // column at 761-839) and takes a real tap there.
        final back = tester.getRect(find.byTooltip('Back'));
        expect(back.left, moreOrLessEquals(80 + AppSpacing.xs));
        await tester.tapAt(back.center);
        await tester.pumpAndSettle();
        expect(find.text('Message requests'), findsNothing);
        await done(tester);
      });
    }
  });
}
