import 'dart:io';
import 'dart:ui' as ui;

import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/features/messages/presentation/conversations_screen.dart';
import 'package:dzeroth/features/messages/presentation/draft_thread_screen.dart';
import 'package:dzeroth/features/messages/presentation/widgets/message_composer.dart';
import 'package:dzeroth/features/messages/presentation/widgets/messages_side_card.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/shared/widgets/primitives/app_back_header.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protobuf/well_known_types/google/protobuf/timestamp.pb.dart'
    as ts;

import '../../../support/app_fonts.dart';
import '../../../support/messages_tablet_fixtures.dart';
import '../../../support/messaging_fixtures.dart' show kMsgBase;
import '../../../support/messaging_flow_rig.dart';

// Messages from the dzeroth-mobile, tablet and desktop mocks: the inbox, the
// first message and the conversation. One model and one set of actions; the
// phone has the gradient New message button, the tablet and desktop the
// raised one in the header, and only the desktop has the side column card.

const _screenshots = bool.fromEnvironment('MESSAGES_SCREENSHOTS');

Future<void> _capture(WidgetTester tester, String name) async {
  if (!_screenshots) return;
  await tester.runAsync(() async {
    final image = await captureImage(tester.element(find.byType(MaterialApp)));
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('build/artifacts/messages/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

const _sizes = <String, Size>{
  'phone': Size(390, 844),
  'tablet': Size(1024, 768),
  'desktop': Size(1440, 900),
};

enum _Screen { inbox, draft, chat }

final _peer = common.AuthorSnapshot(
  userId: 'u-sam',
  handle: 'sam',
  displayName: 'Sam Rivera',
);

Future<MessagingFlowRig> _open(
  WidgetTester tester,
  Size size,
  _Screen screen, {
  Brightness brightness = Brightness.light,
  double textScale = 1,
}) async {
  final rig = MessagingFlowRig(
    server: tabletServer(),
    flags: kMessagesTabletFlags,
  );
  await rig.pump(
    tester,
    size: size,
    brightness: brightness,
    textScale: textScale,
    hoisted: true,
    location: screen == _Screen.chat
        ? AppRouter.messagePath(inboxId(0))
        : AppRouter.messagesPath,
  );
  if (screen == _Screen.draft) {
    rig.appRouter.router.push(AppRouter.messageDraftPath, extra: _peer);
  }
  await tester.pumpAndSettle();
  return rig;
}

void main() {
  setUpAll(() async {
    if (_screenshots) await loadAppFonts();
  });

  for (final MapEntry(key: name, value: size) in _sizes.entries) {
    final phone = size.width < 600;
    final desktop = size.width >= 1200;

    group('$name (${size.width.toInt()} dp)', () {
      testWidgets('inbox: the look', (tester) async {
        await _open(tester, size, _Screen.inbox);
        // The title leads from the left; the requests card says who wants
        // to say hello; a row has no handle, a 50 dp avatar and a right-hand
        // time.
        expect(find.text('2 people want to say hello'), findsOneWidget);
        final list = find.byType(ConversationsList);
        final title = tester.getRect(
          find.descendant(of: list, matching: find.text('Messages')),
        );
        expect(title.center.dx, lessThan(tester.getRect(list).center.dx));
        final row = conversationRow(inboxId(1));
        expect(
          find.descendant(of: row, matching: find.text('@peer1')),
          findsNothing,
        );
        final avatar = tester.getRect(
          find.descendant(of: row, matching: find.byType(CircleAvatar)).first,
        );
        expect(avatar.width, 50);
        final time = tester.getRect(
          find.descendant(of: row, matching: find.text('1m')),
        );
        expect(time.right, greaterThan(tester.getRect(row).right - 24));
        // New message: the gradient button on a phone, the header action on
        // the wider layouts.
        expect(find.byTooltip('New message'), findsOneWidget);
        expect(
          find.ancestor(
            of: find.byTooltip('New message'),
            matching: find.byType(FloatingActionButton),
          ),
          phone ? findsOneWidget : findsNothing,
        );
        // "Select a conversation": the tablet's detail pane, the desktop's
        // side column card; the phone has none.
        expect(
          find.byType(MessagesSideCard),
          desktop ? findsOneWidget : findsNothing,
        );
        expect(
          find.text('Select a conversation'),
          size.width >= 840 && !desktop ? findsOneWidget : findsNothing,
        );
        expect(tester.takeException(), isNull);
      });

      testWidgets('inbox: New message, a row and the requests do the same', (
        tester,
      ) async {
        final rig = await _open(tester, size, _Screen.inbox);
        await tester.tap(find.byTooltip('New message').first);
        await tester.pumpAndSettle();
        expect(rig.stack.last, AppRouter.messageNewPath);
        rig.appRouter.router.pop();
        await tester.pumpAndSettle();

        await tester.tap(find.text('Message requests').first);
        await tester.pumpAndSettle();
        expect(
          find.widgetWithText(AppBackHeader, 'Message requests'),
          findsOneWidget,
        );
        rig.appRouter.router.go(AppRouter.messagesPath);
        await tester.pumpAndSettle();

        await tester.tap(conversationRow(inboxId(1)));
        await tester.pumpAndSettle();
        expect(rig.stack.last, AppRouter.messagePath(inboxId(1)));
      });

      testWidgets('first message: Say hello, and the first send', (
        tester,
      ) async {
        final rig = await _open(tester, size, _Screen.draft);
        expect(find.byType(DraftThreadScreen), findsOneWidget);
        expect(find.text('Say hello.'), findsOneWidget);
        expect(find.text('Write your first message below.'), findsOneWidget);
        // The phone's orbit becomes the person's avatar on the wider layouts.
        expect(
          find.descendant(
            of: find.byType(DraftThreadScreen),
            matching: find.text('SR'),
          ),
          phone ? findsOneWidget : findsNWidgets(2),
        );
        await tester.enterText(find.byKey(MessageComposer.fieldKey), 'hi Sam');
        await tester.pump();
        await tester.tap(find.byKey(MessageComposer.sendKey));
        await tester.pumpAndSettle();
        expect(rig.server.sends.single.text, 'hi Sam');
        expect(rig.stack.last, startsWith('/messages/'));
      });

      testWidgets('conversation: the brand bubble, the pill and Send', (
        tester,
      ) async {
        final rig = await _open(tester, size, _Screen.chat);
        final mine = find.byKey(
          ValueKey(
            'bubble-${rig.server.messages[inboxId(0)]!.firstWhere((m) => m.fromSelf).id}',
          ),
        );
        final bubble = tester.widget<DecoratedBox>(mine);
        expect(
          (bubble.decoration as BoxDecoration).gradient,
          isNotNull,
          reason: 'the caller\'s bubble is on the brand gradient',
        );
        final field = tester.getRect(find.byKey(MessageComposer.fieldKey));
        expect(field.height, greaterThan(0));
        await tester.enterText(
          find.byKey(MessageComposer.fieldKey),
          'on my way',
        );
        await tester.pump();
        await tester.tap(find.byKey(MessageComposer.sendKey));
        await tester.pumpAndSettle();
        expect(rig.server.sends.single.text, 'on my way');
        expect(tester.takeException(), isNull);
      });
    });
  }

  testWidgets('conversation: Seen under the newest own message the peer read', (
    tester,
  ) async {
    final server = tabletServer();
    server.conversations[inboxId(0)]!.peerReadAt = ts.Timestamp.fromDateTime(
      kMsgBase,
    );
    final rig = MessagingFlowRig(server: server, flags: kMessagesTabletFlags);
    await rig.pump(
      tester,
      hoisted: true,
      location: AppRouter.messagePath(inboxId(0)),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Seen '), findsOneWidget);
  });

  for (final screen in _Screen.values) {
    testWidgets('${screen.name} at text scale 2.0 on a phone: no overflow', (
      tester,
    ) async {
      await _open(tester, _sizes['phone']!, screen, textScale: 2);
      expect(tester.takeException(), isNull);
      expect(
        screen == _Screen.inbox
            ? find.byType(ConversationsScreen)
            : find.byKey(MessageComposer.fieldKey),
        findsOneWidget,
      );
    });
  }

  group('screenshots', () {
    for (final screen in _Screen.values) {
      for (final brightness in Brightness.values) {
        for (final MapEntry(key: name, value: size) in _sizes.entries) {
          testWidgets('${screen.name} $name ${brightness.name}', (
            tester,
          ) async {
            await _open(tester, size, screen, brightness: brightness);
            await _capture(tester, '${screen.name}-$name-${brightness.name}');
          }, skip: !_screenshots);
        }
      }
    }
  });
}
