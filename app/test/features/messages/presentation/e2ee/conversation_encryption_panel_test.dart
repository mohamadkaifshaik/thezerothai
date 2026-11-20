import 'dart:async';

import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/messages/domain/e2ee/encrypted_messaging.dart';
import 'package:dzeroth/features/messages/domain/e2ee/encryption_access.dart';
import 'package:dzeroth/features/messages/domain/messaging_feature_flag.dart';
import 'package:dzeroth/features/messages/presentation/e2ee/conversation_encryption_panel.dart';
import 'package:dzeroth/features/messages/presentation/e2ee/encryption_copy.dart';
import 'package:dzeroth/features/messages/presentation/widgets/thread_info_sheet.dart';
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pbenum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../../support/fake_encrypted_messaging.dart';
import '../../../../support/fake_encryption_device.dart';
import '../../../../support/messaging_flow_rig.dart';
import '../../../../support/thread_test_support.dart';

const _id = 'c1';
// Twelve distinct groups of five digits.
const _digits =
    '11111222223333344444555556666677777888889999900000'
    '1234567890';
const _plain = {'messaging', 'graph', 'reports', 'ui_shell', kFeatureE2eeDm};

void main() {
  final base = DateTime.now().toUtc().subtract(const Duration(minutes: 30));

  group('the panel', () {
    Future<FakeEncryptedMessaging> pumpPanel(
      WidgetTester tester,
      SecurityCode code, {
      EncryptionAccess access = EncryptionAccess.full,
      bool isWeb = false,
      String peerName = 'Sam Rivera',
      Size size = const Size(390, 2400),
      List<String>? pushed,
    }) async {
      final port = FakeEncryptedMessaging();
      addTearDown(port.dispose);
      port.setSecurityCode(_id, code);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.reset);
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (context, _) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => showConversationEncryption(
                    context,
                    messaging: port,
                    conversationId: _id,
                    peerName: peerName,
                    access: access,
                    securityChanges: const Stream.empty(),
                    isWeb: isWeb,
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
          GoRoute(
            path: AppRouter.encryptionSettingsPath,
            builder: (context, _) => const Scaffold(body: Text('settings')),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        MaterialApp.router(theme: appLightTheme, routerConfig: router),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return port;
    }

    bool hasDigitText(WidgetTester tester) => tester
        .widgetList<Text>(find.byType(Text))
        .any((t) => RegExp(r'\d{5}').hasMatch(t.data ?? ''));

    test('securityCodeGroups splits 60 digits into 12 groups of 5', () {
      final groups = securityCodeGroups(_digits);
      expect(groups, hasLength(12));
      expect(groups.every((g) => g.length == 5), isTrue);
      expect(groups.first, '11111');
      expect(groups.last, '67890');
      expect(groups.join(), _digits);
    });

    testWidgets('the code shows 12 groups, the intro with the peer name, '
        'the meaning and the moment lines, and both device counts', (
      tester,
    ) async {
      await pumpPanel(
        tester,
        const SecurityCode(digits: _digits, myDevices: 2, theirDevices: 3),
      );
      for (final g in securityCodeGroups(_digits)) {
        expect(find.text(g), findsWidgets);
      }
      expect(find.text(kSecurityCodeHeader), findsOneWidget);
      expect(find.text(securityCodeIntro('Sam Rivera')), findsOneWidget);
      expect(find.text(kSecurityCodeMeaning), findsOneWidget);
      expect(find.text(kSecurityCodeMoment), findsOneWidget);
      expect(find.text(securityCodeMine(2)), findsOneWidget);
      expect(find.text(securityCodeTheirs(3)), findsOneWidget);
      expect(find.text(kEncryptedNoteText), findsOneWidget);
      expect(find.text(kEncryptionHowItWorksLabel), findsOneWidget);
      expect(find.text(kEncryptionHelp1), findsOneWidget);
      expect(find.text(kEncryptionHelp10), findsOneWidget);
      expect(find.byType(SelectableText), findsNothing);
      expect(find.byType(SelectionArea), findsNothing);
    });

    final noCode = <(NoCodeReason, String, bool)>[
      (NoCodeReason.sentRequest, kNoCodeSentRequest, false),
      (NoCodeReason.notAMember, kNoCodeNotAMember, false),
      (NoCodeReason.unknownDevice, kNoCodeUnknownDevice, true),
      (NoCodeReason.listUnverifiable, kNoCodeUnverifiable, true),
      (NoCodeReason.unavailable, kNoCodeUnavailable, false),
    ];
    for (final (reason, text, counts) in noCode) {
      testWidgets('no code: ${reason.name} says its line and draws no '
          'digit', (tester) async {
        await pumpPanel(
          tester,
          SecurityCode(
            reason: reason,
            myDevices: counts ? 1 : 0,
            theirDevices: counts ? 4 : 0,
          ),
        );
        expect(find.text(text), findsOneWidget);
        expect(hasDigitText(tester), isFalse);
        expect(find.text(securityCodeIntro('Sam Rivera')), findsNothing);
        expect(find.text(kSecurityCodeMeaning), findsNothing);
        expect(
          find.text(securityCodeMine(1)),
          counts ? findsOneWidget : findsNothing,
        );
      });
    }

    testWidgets('sentRequest and notAMember hide the device counts', (
      tester,
    ) async {
      for (final reason in [
        NoCodeReason.sentRequest,
        NoCodeReason.notAMember,
      ]) {
        await pumpPanel(
          tester,
          SecurityCode(reason: reason, myDevices: 2, theirDevices: 2),
        );
        expect(find.text(securityCodeMine(2)), findsNothing);
        expect(find.text(securityCodeTheirs(2)), findsNothing);
        await tester.pumpWidget(const SizedBox());
      }
    });

    testWidgets('pendingRequest shows only the note and the help', (
      tester,
    ) async {
      await pumpPanel(
        tester,
        const SecurityCode(reason: NoCodeReason.pendingRequest),
      );
      expect(find.text(kEncryptedNoteText), findsOneWidget);
      expect(find.text(kEncryptionHelp1), findsOneWidget);
      expect(find.text(kSecurityCodeHeader), findsNothing);
      expect(find.textContaining('No security code'), findsNothing);
    });

    testWidgets('a failure shows the line with Retry, and offline says why', (
      tester,
    ) async {
      final port = FakeEncryptedMessaging();
      addTearDown(port.dispose);
      port.failNextOn('securityCode', StateError('x'));
      await tester.pumpWidget(
        MaterialApp(
          theme: appLightTheme,
          home: Scaffold(
            body: ConversationEncryptionHost(
              messaging: port,
              conversationId: _id,
              peerName: 'Sam',
              access: EncryptionAccess.full,
              securityChanges: const Stream.empty(),
              isWeb: false,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(kSecurityCodeFailed), findsOneWidget);
      port.setSecurityCode(_id, const SecurityCode(digits: _digits));
      await tester.tap(find.text(kStatusTryAgain));
      await tester.pumpAndSettle();
      expect(find.text(kSecurityCodeFailed), findsNothing);
      expect(find.text('11111'), findsOneWidget);
    });

    testWidgets('there is no button or text containing "verified", "QR" or '
        '"Copy"', (tester) async {
      await pumpPanel(
        tester,
        const SecurityCode(digits: _digits, myDevices: 1, theirDevices: 1),
      );
      for (final t in tester.widgetList<Text>(find.byType(Text))) {
        final s = (t.data ?? '').toLowerCase();
        expect(s.contains('verified'), isFalse, reason: s);
        expect(s.contains('qr'), isFalse, reason: s);
        expect(s.contains('copy'), isFalse, reason: s);
      }
      expect(find.byTooltip('Copy'), findsNothing);
      expect(find.byIcon(Icons.copy), findsNothing);
      expect(find.byIcon(Icons.qr_code), findsNothing);
    });

    for (final isWeb in [false, true]) {
      testWidgets('the help shows the web lines only on web (isWeb: $isWeb)', (
        tester,
      ) async {
        await pumpPanel(
          tester,
          const SecurityCode(reason: NoCodeReason.unavailable),
          isWeb: isWeb,
        );
        expect(
          find.text(kEncryptionHelpWeb),
          isWeb ? findsOneWidget : findsNothing,
        );
        expect(
          find.text(kWebStorageNote),
          isWeb ? findsOneWidget : findsNothing,
        );
        expect(find.text(kEncryptionHelp4), findsOneWidget);
      });
    }

    testWidgets('Check your devices closes the panel and opens the settings '
        'path', (tester) async {
      await pumpPanel(
        tester,
        const SecurityCode(digits: _digits, myDevices: 1, theirDevices: 1),
      );
      await tester.tap(find.text(kOwnDeviceAlertAction));
      await tester.pumpAndSettle();
      expect(find.text(kSecurityCodeHeader), findsNothing);
      expect(find.text('settings'), findsOneWidget);
    });

    testWidgets('access unsupported hides Check your devices', (tester) async {
      await pumpPanel(
        tester,
        const SecurityCode(digits: _digits, myDevices: 1, theirDevices: 1),
        access: EncryptionAccess.unsupported,
      );
      expect(find.text(kOwnDeviceAlertAction), findsNothing);
      expect(find.text(kSecurityCodeHeader), findsOneWidget);
    });

    testWidgets('each group has the digit-by-digit label', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpPanel(
        tester,
        const SecurityCode(digits: _digits, myDevices: 1, theirDevices: 1),
      );
      final groups = securityCodeGroups(_digits);
      for (var i = 0; i < 12; i++) {
        expect(
          find.bySemanticsLabel(securityCodeGroupLabel(i + 1, groups[i])),
          findsOneWidget,
          reason: 'group ${i + 1}',
        );
      }
      handle.dispose();
    });
  });

  group('the entry', () {
    Future<MessagingFlowRig> pumpThread(
      WidgetTester tester,
      double width, {
      bool encrypted = true,
      bool request = false,
      Set<String> flags = _plain,
    }) async {
      final server = MessagingFlowRig.serverWithConversation();
      if (encrypted) {
        server.conversations[kThreadId]!.encryption =
            ConversationEncryption.CONVERSATION_ENCRYPTION_MLS;
      }
      final port = FakeEncryptedMessaging();
      addTearDown(port.dispose);
      port.setThread(
        ThreadRef.conversation(kThreadId),
        EncryptedThread(
          conversationId: kThreadId,
          entries: [
            DecryptedMessage(id: 'e1', at: base, mine: false, text: 'hello'),
          ],
          security: ConversationSecurity(
            state: request
                ? ConversationEncryptionState.pendingRequest
                : ConversationEncryptionState.ready,
          ),
        ),
      );
      final rig = MessagingFlowRig(server: server, flags: flags);
      await rig.pump(
        tester,
        location: AppRouter.messagePath(kThreadId),
        size: Size(width, 900),
        hoisted: width >= 1200,
        encrypted: port,
        device: FakeEncryptionDevice(),
      );
      return rig;
    }

    final tablet = {..._plain, 'ui_tablet'};

    testWidgets('the Encryption entry exists in an encrypted thread on phone '
        '(menu)', (tester) async {
      await pumpThread(tester, 390);
      await tester.tap(find.byTooltip(kConversationInfoLabel));
      await tester.pumpAndSettle();
      expect(find.text(kEncryptionEntryLabel), findsOneWidget);
      expect(find.byIcon(Icons.lock_outline), findsWidgets);
      final entry = tester.getTopLeft(find.text(kEncryptionEntryLabel)).dy;
      expect(
        entry,
        lessThan(tester.getTopLeft(find.text('Delete conversation')).dy),
      );
      if (find.text('Block @sam').evaluate().isNotEmpty) {
        expect(entry, lessThan(tester.getTopLeft(find.text('Block @sam')).dy));
      }
      await tester.tap(find.text(kEncryptionEntryLabel));
      await tester.pumpAndSettle();
      expect(find.text(kSecurityCodeHeader), findsOneWidget);
    });

    testWidgets('... tablet (info sheet)', (tester) async {
      await pumpThread(tester, 834, flags: tablet);
      await tester.tap(find.byTooltip(kConversationInfoLabel));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(ThreadInfoSheet),
          matching: find.text(kEncryptionEntryLabel),
        ),
        findsOneWidget,
      );
      await tester.tap(find.text(kEncryptionEntryLabel));
      await tester.pumpAndSettle();
      expect(find.text(kSecurityCodeHeader), findsOneWidget);
    });

    testWidgets('... desktop (menu and side box)', (tester) async {
      await pumpThread(tester, 1300, flags: tablet);
      // The side box's action.
      expect(find.text(kEncryptionEntryLabel), findsOneWidget);
      await tester.tap(find.byTooltip(kConversationInfoLabel));
      await tester.pumpAndSettle();
      expect(find.text(kEncryptionEntryLabel), findsNWidgets(2));
    });

    for (final width in [390.0, 834.0, 1300.0]) {
      testWidgets('no entry in a plaintext thread at $width', (tester) async {
        await pumpThread(tester, width, encrypted: false, flags: tablet);
        await tester.tap(find.byTooltip(kConversationInfoLabel));
        await tester.pumpAndSettle();
        expect(find.text(kEncryptionEntryLabel), findsNothing);
      });

      testWidgets('no entry in an incoming request at $width', (tester) async {
        await pumpThread(tester, width, request: true, flags: tablet);
        await tester.tap(find.byTooltip(kConversationInfoLabel));
        await tester.pumpAndSettle();
        expect(find.text(kEncryptionEntryLabel), findsNothing);
      });
    }
  });
}
