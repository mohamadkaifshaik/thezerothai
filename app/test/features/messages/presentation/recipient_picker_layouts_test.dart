import 'dart:io';
import 'dart:ui' as ui;

import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.connect.spec.dart';
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pbenum.dart';
import 'package:dzeroth/features/graph/presentation/widgets/user_list_row.dart';
import 'package:dzeroth/features/messages/presentation/recipient_picker_screen.dart';
import 'package:dzeroth/shared/widgets/primitives/app_pill_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/app_fonts.dart';
import '../../../support/messages_tablet_fixtures.dart';
import '../../../support/messaging_flow_rig.dart';

// RecipientPicker from the dzeroth-mobile, tablet and desktop mocks: one
// picker, the same rows and actions. The phone is full screen with the
// raised pill and the "Suggested" title; the tablet and desktop card has the
// flat "To:" pill, the uppercase label and divided rows. Every row carries
// the outlined Message pill.

const _screenshots = bool.fromEnvironment('PICKER_SCREENSHOTS');

Future<void> _capture(WidgetTester tester, String name) async {
  if (!_screenshots) return;
  await tester.runAsync(() async {
    final image = await captureImage(tester.element(find.byType(MaterialApp)));
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('build/artifacts/picker/$name.png');
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

Future<MessagingFlowRig> _open(
  WidgetTester tester,
  Size size, {
  Brightness brightness = Brightness.light,
}) async {
  final rig = MessagingFlowRig(
    server: tabletServer(),
    flags: kMessagesTabletFlags,
  );
  await rig.pump(tester, size: size, brightness: brightness, hoisted: true);
  rig.appRouter.router.push(AppRouter.messageNewPath);
  await tester.pumpAndSettle();
  expect(find.byType(RecipientPickerDialog), findsOneWidget);
  return rig;
}

Finder get _samRow => find.byType(UserListRow);

Finder get _message => find.widgetWithText(AppPillButton, 'Message');

void main() {
  setUpAll(() async {
    if (_screenshots) await loadAppFonts();
  });

  for (final MapEntry(key: name, value: size) in _sizes.entries) {
    final phone = size.width < 600;

    group('$name (${size.width.toInt()} dp)', () {
      testWidgets('the look', (tester) async {
        await _open(tester, size);
        expect(
          tester.widget<RecipientPicker>(find.byType(RecipientPicker)).dialog,
          !phone,
        );
        expect(find.text(phone ? 'Suggested' : 'SUGGESTED'), findsOneWidget);
        expect(find.text('To:'), phone ? findsNothing : findsOneWidget);
        expect(find.text('Sam Rivera'), findsOneWidget);
        expect(_message, findsOneWidget);
        // Divided rows in the dialog (dz.css `.row`), open on a phone.
        expect(
          find.descendant(of: _samRow, matching: find.byType(Divider)),
          phone ? findsNothing : findsOneWidget,
        );
        // The row's 44 dp avatar and the mocks' gutters (20 / 16).
        final avatar = tester.getRect(
          find.descendant(of: _samRow, matching: find.byType(CircleAvatar)),
        );
        expect(avatar.width, 44);
        final picker = tester.getRect(find.byType(RecipientPicker));
        expect(avatar.left - picker.left, phone ? 20 : 16);
        // The section title sits between the pill and the first row.
        final field = tester.getRect(find.byKey(kRecipientFieldKey));
        final title = tester.getRect(
          find.text(phone ? 'Suggested' : 'SUGGESTED'),
        );
        expect(title.top, greaterThan(field.bottom));
        expect(title.bottom, lessThanOrEqualTo(avatar.top));
        expect(tester.takeException(), isNull);
      });

      testWidgets('Message opens the conversation, as the row does', (
        tester,
      ) async {
        final rig = await _open(tester, size);
        await tester.tap(_message);
        await tester.pumpAndSettle();
        expect(find.byType(RecipientPickerDialog), findsNothing);
        expect(rig.stack.last, startsWith('/messages/'));
        expect(rig.stack.last, isNot(AppRouter.messageNewPath));
      });

      testWidgets('typing filters; a handle offers "Message @handle"', (
        tester,
      ) async {
        await _open(tester, size);
        await tester.enterText(find.byKey(kRecipientFieldKey), 'sam');
        await tester.pump();
        expect(find.text('Sam Rivera'), findsOneWidget);
        expect(find.byTooltip('Clear'), findsOneWidget);
        await tester.enterText(find.byKey(kRecipientFieldKey), 'nobody1');
        await tester.pump();
        expect(find.text(kRecipientNoMatchText), findsOneWidget);
        expect(find.byKey(kRecipientHandleRowKey), findsOneWidget);
        // No section title over an empty answer.
        expect(find.text(phone ? 'Suggested' : 'SUGGESTED'), findsNothing);
        await tester.tap(find.byTooltip('Clear'));
        await tester.pump();
        expect(find.text('Sam Rivera'), findsOneWidget);
      });

      testWidgets('text scale 2.0: nothing overflows', (tester) async {
        final rig = MessagingFlowRig(
          server: tabletServer(),
          flags: kMessagesTabletFlags,
        );
        await rig.pump(tester, size: size, textScale: 2, hoisted: true);
        rig.appRouter.router.push(AppRouter.messageNewPath);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(_message, findsOneWidget);
      });
    });
  }

  group('screenshots', () {
    for (final brightness in Brightness.values) {
      for (final MapEntry(key: name, value: size) in _sizes.entries) {
        testWidgets('$name ${brightness.name}', (tester) async {
          await _open(tester, size, brightness: brightness);
          await _capture(tester, '$name-${brightness.name}');
        }, skip: !_screenshots);
      }
    }
  });

  // `dm_suggestions`: the server's "Suggested" section in the real shells
  // and the 600 dp dialog card.
  group('suggestions through the shell rig', () {
    for (final MapEntry(key: name, value: size) in _sizes.entries) {
      for (final brightness in Brightness.values) {
        for (final scale in const [1.0, 2.0]) {
          testWidgets('$name ${brightness.name} x$scale', (tester) async {
            final server = tabletServer()
              ..suggestions.addAll([
                pb.MessageSuggestion(
                  user: common.AuthorSnapshot(
                    userId: 'u-zed',
                    handle: 'zed',
                    displayName: 'Zed Person',
                  ),
                  reason: MessageSuggestionReason
                      .MESSAGE_SUGGESTION_REASON_COMMUNITY_MEMBER,
                  communityName: 'A community with a rather long name',
                ),
              ]);
            final rig = MessagingFlowRig(
              server: server,
              flags: {...kMessagesTabletFlags, 'dm_suggestions'},
            );
            await rig.pump(
              tester,
              size: size,
              brightness: brightness,
              textScale: scale,
              hoisted: true,
            );
            rig.appRouter.router.push(AppRouter.messageNewPath);
            await tester.pumpAndSettle();
            expect(find.text('Zed Person'), findsOneWidget);
            expect(
              find.text('In A community with a rather long name'),
              findsOneWidget,
            );
            expect(find.text('Sam Rivera'), findsOneWidget);
            expect(
              server.count('/${MessagingService.name}/ListMessageSuggestions'),
              1,
            );
            expect(tester.takeException(), isNull);
          });
        }
      }
    }
  });
}
