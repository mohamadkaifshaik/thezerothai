import 'dart:async';

import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/core/vault/vault_status.dart';
import 'package:dzeroth/features/messages/domain/e2ee/encrypted_messaging.dart';
import 'package:dzeroth/features/messages/domain/e2ee/encryption_access.dart';
import 'package:dzeroth/features/messages/domain/e2ee/encryption_device.dart';
import 'package:dzeroth/features/messages/presentation/e2ee/encryption_error_messages.dart';
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

/// A port whose `securityCode` answers wait for a gate (the answer is read
/// when the call is made, as the real port reads the vault).
class _HeldMessaging extends FakeEncryptedMessaging {
  final List<Completer<void>> gates = [];

  @override
  Future<SecurityCode> securityCode(String conversationId) async {
    final answer = await super.securityCode(conversationId);
    if (gates.isNotEmpty) await gates.removeAt(0).future;
    return answer;
  }
}

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
      FakeEncryptedMessaging? using,
      EncryptionDevice? device,
      Stream<ConversationSecurity?>? changes,
      Stream<List<ThreadEntry>>? entries,
    }) async {
      final port = using ?? FakeEncryptedMessaging();
      addTearDown(port.dispose);
      port.setSecurityCode(_id, code);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.reset);
      final never = StreamController<ConversationSecurity?>.broadcast();
      addTearDown(never.close);
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (context, _) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => unawaited(
                    showModalBottomSheet<void>(
                      context: context,
                      isScrollControlled: true,
                      builder: (_) => ConversationEncryptionHost(
                        messaging: port,
                        conversationId: _id,
                        peerName: peerName,
                        access: access,
                        device: device,
                        securityChanges: changes ?? never.stream,
                        entryChanges: entries,
                        isWeb: isWeb,
                      ),
                    ),
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
          // Non-zero counts wherever the port's rules allow them, so a count
          // line that must stay hidden would show.
          SecurityCode(
            reason: reason,
            myDevices: reason == NoCodeReason.unavailable ? 0 : 1,
            theirDevices: reason == NoCodeReason.unavailable ? 0 : 4,
          ),
        );
        expect(find.text(kSecurityCodeHeader), findsOneWidget);
        expect(find.text(text), findsOneWidget);
        expect(hasDigitText(tester), isFalse);
        expect(find.text(securityCodeIntro('Sam Rivera')), findsNothing);
        expect(find.text(kSecurityCodeMeaning), findsNothing);
        expect(
          find.text(securityCodeMine(1)),
          counts ? findsOneWidget : findsNothing,
        );
        expect(
          find.text(securityCodeTheirs(4)),
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
        // The panel opened, and shows this reason's line.
        expect(find.text(kSecurityCodeHeader), findsOneWidget);
        expect(
          find.text(
            reason == NoCodeReason.sentRequest
                ? kNoCodeSentRequest
                : kNoCodeNotAMember,
          ),
          findsOneWidget,
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

    Future<FakeEncryptedMessaging> pumpHost(
      WidgetTester tester,
      Object failure,
    ) async {
      final port = FakeEncryptedMessaging();
      addTearDown(port.dispose);
      final never = StreamController<ConversationSecurity?>.broadcast();
      addTearDown(never.close);
      port.failNextOn('securityCode', failure);
      await tester.pumpWidget(
        MaterialApp(
          theme: appLightTheme,
          home: Scaffold(
            body: ConversationEncryptionHost(
              messaging: port,
              conversationId: _id,
              peerName: 'Sam',
              access: EncryptionAccess.full,
              securityChanges: never.stream,
              isWeb: false,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return port;
    }

    testWidgets('a failure shows the line with Retry', (tester) async {
      final port = await pumpHost(tester, StateError('x'));
      expect(find.text(kSecurityCodeFailed), findsOneWidget);
      port.setSecurityCode(_id, const SecurityCode(digits: _digits));
      await tester.tap(find.text(kStatusTryAgain));
      await tester.pumpAndSettle();
      expect(find.text(kSecurityCodeFailed), findsNothing);
      expect(find.text('11111'), findsOneWidget);
    });

    testWidgets('offline says why and offers Try again', (tester) async {
      final port = await pumpHost(tester, const NetworkException('offline'));
      expect(find.text(kSecurityCodeFailed), findsNothing);
      expect(
        find.text(encryptionErrorMessage(const NetworkException('offline'))),
        findsOneWidget,
      );
      expect(find.textContaining('No connection'), findsOneWidget);
      expect(find.text(kStatusTryAgain), findsOneWidget);
      port.setSecurityCode(_id, const SecurityCode(digits: _digits));
      await tester.tap(find.text(kStatusTryAgain));
      await tester.pumpAndSettle();
      expect(find.text('11111'), findsOneWidget);
    });

    testWidgets('loading shows the skeleton with its label and no digit', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final port = _HeldMessaging();
      final gate = Completer<void>();
      port.gates.add(gate);
      await pumpPanel(tester, const SecurityCode(digits: _digits), using: port);
      expect(find.bySemanticsLabel(kSecurityCodeLoading), findsOneWidget);
      expect(find.text(kSecurityCodeHeader), findsOneWidget);
      expect(hasDigitText(tester), isFalse);
      gate.complete();
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel(kSecurityCodeLoading), findsNothing);
      expect(find.text('11111'), findsOneWidget);
      handle.dispose();
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

    group('a stale code never stays', () {
      final other = '0987654321' * 6;

      ConversationSecurity security({int my = 1, int theirs = 1}) =>
          // Deliberately not const: a distinct object each time.
          ConversationSecurity(
            state: ConversationEncryptionState.ready,
            myDevices: my,
            theirDevices: theirs,
          );

      int loads(FakeEncryptedMessaging p) =>
          p.calls.where((c) => c == 'securityCode').length;

      testWidgets('a device swap that keeps both counts reloads the code and '
          'never shows the old digits meanwhile', (tester) async {
        final port = _HeldMessaging();
        final changes = StreamController<ConversationSecurity?>.broadcast();
        addTearDown(changes.close);
        await pumpPanel(
          tester,
          const SecurityCode(digits: _digits, myDevices: 1, theirDevices: 1),
          using: port,
          changes: changes.stream,
        );
        changes.add(security());
        await tester.pumpAndSettle();
        expect(find.text('11111'), findsOneWidget);
        final before = loads(port);

        // One device removed and one added: the counts are the same.
        port.setSecurityCode(
          _id,
          SecurityCode(digits: other, myDevices: 1, theirDevices: 1),
        );
        final gate = Completer<void>();
        port.gates.add(gate);
        changes.add(security());
        // The cubit's emission reaches the widget before the next frame.
        await tester.idle();
        await tester.pump();
        expect(loads(port), before + 1);
        expect(find.text('11111'), findsNothing);
        expect(hasDigitText(tester), isFalse);
        expect(find.text(kSecurityCodeLoading), findsNothing);
        gate.complete();
        await tester.pumpAndSettle();
        expect(find.text('11111'), findsNothing);
        expect(find.text('09876'), findsWidgets);
      });

      testWidgets('the identical security object does not reload', (
        tester,
      ) async {
        final port = FakeEncryptedMessaging();
        final changes = StreamController<ConversationSecurity?>.broadcast();
        addTearDown(changes.close);
        await pumpPanel(
          tester,
          const SecurityCode(digits: _digits, myDevices: 1, theirDevices: 1),
          using: port,
          changes: changes.stream,
        );
        final same = security();
        changes.add(same);
        await tester.pumpAndSettle();
        final before = loads(port);
        changes.add(same);
        await tester.pumpAndSettle();
        expect(loads(port), before);
      });

      testWidgets('a request sent or accepted reloads the code', (
        tester,
      ) async {
        final port = FakeEncryptedMessaging();
        final changes = StreamController<ConversationSecurity?>.broadcast();
        addTearDown(changes.close);
        await pumpPanel(
          tester,
          const SecurityCode(digits: _digits),
          using: port,
          changes: changes.stream,
        );
        changes.add(security());
        await tester.pumpAndSettle();
        final before = loads(port);
        changes.add(
          ConversationSecurity(
            state: ConversationEncryptionState.ready,
            sentRequest: true,
            myDevices: 1,
            theirDevices: 1,
          ),
        );
        await tester.pumpAndSettle();
        expect(loads(port), before + 1);
      });

      for (final (name, kind) in [
        ('an encryption reset line', SystemLineKind.encryptionReset),
        ('a new unknown-device line', SystemLineKind.unknownDevice),
        ('a device-added line', SystemLineKind.deviceAdded),
        ('a device-removed line', SystemLineKind.deviceRemoved),
      ]) {
        testWidgets('$name reloads the code', (tester) async {
          final port = _HeldMessaging();
          final entries = StreamController<List<ThreadEntry>>.broadcast();
          addTearDown(entries.close);
          await pumpPanel(
            tester,
            const SecurityCode(digits: _digits, myDevices: 1, theirDevices: 1),
            using: port,
            entries: entries.stream,
          );
          expect(find.text('11111'), findsOneWidget);
          final before = loads(port);
          port.setSecurityCode(
            _id,
            SecurityCode(digits: other, myDevices: 1, theirDevices: 1),
          );
          final gate = Completer<void>();
          port.gates.add(gate);
          final line = SystemLineEntry(
            id: 's1',
            at: base,
            kind: kind,
            side: LineSide.theirs,
          );
          entries.add([line]);
          await tester.idle();
          await tester.pump();
          expect(loads(port), before + 1);
          expect(hasDigitText(tester), isFalse);
          gate.complete();
          await tester.pumpAndSettle();
          expect(find.text('09876'), findsWidgets);

          // The same line again, and a message, change nothing.
          entries.add([
            line,
            DecryptedMessage(id: 'm1', at: base, mine: false, text: 'hi'),
          ]);
          await tester.pumpAndSettle();
          expect(loads(port), before + 1);
        });
      }
    });

    group('access or the thread is lost', () {
      testWidgets('the panel closes when the thread goes away', (tester) async {
        final changes = StreamController<ConversationSecurity?>.broadcast();
        await pumpPanel(
          tester,
          const SecurityCode(digits: _digits, myDevices: 1, theirDevices: 1),
          changes: changes.stream,
        );
        expect(find.text('11111'), findsOneWidget);
        await changes.close();
        await tester.pump();
        expect(hasDigitText(tester), isFalse, reason: 'cleared, then popped');
        await tester.pumpAndSettle();
        expect(find.text(kSecurityCodeHeader), findsNothing);
        expect(find.text('open'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('the panel closes and shows no code when the vault stops '
          'being ready', (tester) async {
        final device = FakeEncryptionDevice();
        await pumpPanel(
          tester,
          const SecurityCode(digits: _digits, myDevices: 1, theirDevices: 1),
          device: device,
        );
        expect(find.text('11111'), findsOneWidget);
        device.vaultStatus.value = VaultStatus.heldElsewhere;
        await tester.pump();
        expect(hasDigitText(tester), isFalse);
        await tester.pumpAndSettle();
        expect(find.text(kSecurityCodeHeader), findsNothing);
        expect(find.text('open'), findsOneWidget);
      });

      testWidgets('the panel closes when this device is removed elsewhere', (
        tester,
      ) async {
        final port = FakeEncryptedMessaging();
        await pumpPanel(
          tester,
          const SecurityCode(digits: _digits, myDevices: 1, theirDevices: 1),
          using: port,
        );
        expect(find.text('11111'), findsOneWidget);
        port.removedElsewhere.value = true;
        await tester.pump();
        expect(hasDigitText(tester), isFalse);
        await tester.pumpAndSettle();
        expect(find.text(kSecurityCodeHeader), findsNothing);
        expect(find.text('open'), findsOneWidget);
      });

      testWidgets('the panel closes when the access rule turns hidden', (
        tester,
      ) async {
        final device = FakeEncryptionDevice(vaultKnown: true);
        await pumpPanel(
          tester,
          const SecurityCode(digits: _digits, myDevices: 1, theirDevices: 1),
          access: EncryptionAccess.manage,
          device: device,
        );
        expect(find.text('11111'), findsOneWidget);
        device.vaultKnown = false;
        device.vaultStatus.value = VaultStatus.opening;
        await tester.pump();
        expect(hasDigitText(tester), isFalse);
        await tester.pumpAndSettle();
        expect(find.text(kSecurityCodeHeader), findsNothing);
      });

      testWidgets('several losses at once pop once', (tester) async {
        final port = FakeEncryptedMessaging();
        final device = FakeEncryptionDevice();
        final changes = StreamController<ConversationSecurity?>.broadcast();
        await pumpPanel(
          tester,
          const SecurityCode(digits: _digits, myDevices: 1, theirDevices: 1),
          using: port,
          device: device,
          changes: changes.stream,
        );
        port.removedElsewhere.value = true;
        device.vaultStatus.value = VaultStatus.keyLost;
        await changes.close();
        await tester.pumpAndSettle();
        expect(find.text(kSecurityCodeHeader), findsNothing);
        expect(find.text('open'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    });
  });

  group('the entry', () {
    void expectEntryAbove(WidgetTester tester) {
      final entry = tester.getTopLeft(find.text(kEncryptionEntryLabel)).dy;
      expect(
        entry,
        lessThan(tester.getTopLeft(find.text('Delete conversation')).dy),
      );
      expect(entry, lessThan(tester.getTopLeft(find.text('Block @sam')).dy));
    }

    Future<FakeEncryptedMessaging> pumpThread(
      WidgetTester tester,
      double width, {
      bool encrypted = true,
      bool request = false,
      Set<String> flags = _plain,
      String? displayName,
      EncryptionDevice? device,
    }) async {
      final server = MessagingFlowRig.serverWithConversation();
      if (encrypted) {
        server.conversations[kThreadId]!.encryption =
            ConversationEncryption.CONVERSATION_ENCRYPTION_MLS;
      }
      if (displayName != null) {
        server.conversations[kThreadId]!.peer.displayName = displayName;
      }
      final port = FakeEncryptedMessaging();
      addTearDown(port.dispose);
      port.setSecurityCode(
        kThreadId,
        const SecurityCode(digits: _digits, myDevices: 1, theirDevices: 1),
      );
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
        device: device ?? FakeEncryptionDevice(),
      );
      return port;
    }

    final tablet = {..._plain, 'ui_tablet'};

    testWidgets('the Encryption entry exists in an encrypted thread on phone '
        '(menu)', (tester) async {
      await pumpThread(tester, 390);
      await tester.tap(find.byTooltip(kConversationInfoLabel));
      await tester.pumpAndSettle();
      expect(find.text(kEncryptionEntryLabel), findsOneWidget);
      expect(find.byIcon(Icons.lock_outline), findsWidgets);
      expectEntryAbove(tester);
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
      expectEntryAbove(tester);
      await tester.tap(find.text(kEncryptionEntryLabel));
      await tester.pumpAndSettle();
      expect(find.text(kSecurityCodeHeader), findsOneWidget);
      // The default decision at 834 dp with the tablet flags: the side sheet.
      expect(find.byType(BottomSheet), findsNothing);
    });

    testWidgets('... desktop (menu and side box)', (tester) async {
      await pumpThread(tester, 1300, flags: tablet);
      // The side box's action.
      expect(find.text(kEncryptionEntryLabel), findsOneWidget);
      await tester.tap(find.byTooltip(kConversationInfoLabel));
      await tester.pumpAndSettle();
      expect(find.text(kEncryptionEntryLabel), findsNWidgets(2));
      // The menu's entry, last in the tree order of the popup (the overlay).
      final entry = tester.getTopLeft(find.text(kEncryptionEntryLabel).last).dy;
      expect(
        entry,
        lessThan(tester.getTopLeft(find.text('Block @sam').last).dy),
      );
      expect(
        entry,
        lessThan(tester.getTopLeft(find.text('Delete conversation').last).dy),
      );
    });

    testWidgets('the panel names a peer without a display name by @handle', (
      tester,
    ) async {
      await pumpThread(tester, 390, displayName: '');
      await tester.tap(find.byTooltip(kConversationInfoLabel));
      await tester.pumpAndSettle();
      await tester.tap(find.text(kEncryptionEntryLabel));
      await tester.pumpAndSettle();
      expect(find.text(securityCodeIntro('@sam')), findsOneWidget);
    });

    testWidgets('the panel names the peer by display name', (tester) async {
      await pumpThread(tester, 390);
      await tester.tap(find.byTooltip(kConversationInfoLabel));
      await tester.pumpAndSettle();
      await tester.tap(find.text(kEncryptionEntryLabel));
      await tester.pumpAndSettle();
      expect(find.text(securityCodeIntro('Sam Rivera')), findsOneWidget);
    });

    testWidgets('flag off with a vault on the device (manage): the entry '
        'opens the panel', (tester) async {
      await pumpThread(
        tester,
        390,
        flags: {..._plain}..remove(kFeatureE2eeDm),
        device: FakeEncryptionDevice(),
      );
      await tester.tap(find.byTooltip(kConversationInfoLabel));
      await tester.pumpAndSettle();
      expect(find.text(kEncryptionEntryLabel), findsOneWidget);
      await tester.tap(find.text(kEncryptionEntryLabel));
      await tester.pumpAndSettle();
      expect(find.text(kSecurityCodeHeader), findsOneWidget);
      expect(find.text(kOwnDeviceAlertAction), findsOneWidget);
    });

    testWidgets('access hidden with a port present: no entry and no port '
        'call', (tester) async {
      // Flag off and no vault known on the device.
      final port = await pumpThread(
        tester,
        390,
        flags: {..._plain}..remove(kFeatureE2eeDm),
        device: FakeEncryptionDevice(vaultKnown: false),
      );
      await tester.tap(find.byTooltip(kConversationInfoLabel));
      await tester.pumpAndSettle();
      expect(find.text(kEncryptionEntryLabel), findsNothing);
      expect(port.calls, isNot(contains('securityCode')));
      expect(port.calls, isNot(contains('watchThread')));
    });

    for (final width in [700.0, 1000.0]) {
      testWidgets('the default decision at $width dp with the tablet flags: '
          'the side sheet', (tester) async {
        await pumpThread(tester, width, flags: tablet);
        await tester.tap(find.byTooltip(kConversationInfoLabel));
        await tester.pumpAndSettle();
        expectEntryAbove(tester);
        await tester.tap(find.text(kEncryptionEntryLabel));
        await tester.pumpAndSettle();
        expect(find.text(kSecurityCodeHeader), findsOneWidget);
        expect(find.byType(BottomSheet), findsNothing);
      });
    }

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
