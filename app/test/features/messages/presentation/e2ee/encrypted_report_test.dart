import 'dart:typed_data';

import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/vault/vault_status.dart';
import 'package:dzeroth/features/messages/domain/e2ee/encrypted_messaging.dart';
import 'package:dzeroth/features/messages/domain/e2ee/message_content_codec.dart';
import 'package:dzeroth/features/messages/domain/messaging_feature_flag.dart';
import 'package:dzeroth/features/messages/presentation/e2ee/encryption_copy.dart';
import 'package:dzeroth/features/messages/presentation/report_conversation.dart';
import 'package:dzeroth/features/messages/presentation/widgets/message_bubble.dart';
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pbenum.dart';
import 'package:dzeroth/gen/dzeroth/moderation/v1/moderation.pbenum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../../../support/fake_encrypted_messaging.dart';
import '../../../../support/fake_encryption_device.dart';
import '../../../../support/messaging_flow_rig.dart';
import '../../../../support/thread_test_support.dart';

const _peerMsg = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _peerMsg2 = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const _ownMsg = 'cccccccccccccccccccccccccccccccc';
const _lostMsg = 'dddddddddddddddddddddddddddddddd';
const _goneMsg = 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee';
const _lineId = 'ffffffffffffffffffffffffffffffff';

void main() {
  final ref = ThreadRef.conversation(kThreadId);
  final base = DateTime.now().toUtc().add(const Duration(hours: 1));

  DecryptedMessage entry(
    String id, {
    bool mine = false,
    int minutes = 0,
    EncryptedMessageState state = EncryptedMessageState.visible,
    MessageCheck check = MessageCheck.ok,
    bool canReport = true,
  }) => DecryptedMessage(
    id: id,
    at: base.add(Duration(minutes: minutes)),
    mine: mine,
    state: state,
    check: check,
    text: state == EncryptedMessageState.visible && check == MessageCheck.ok
        ? 'secret $id'
        : '',
    canReport: canReport,
  );

  Future<({FakeEncryptedMessaging port, MessagingFlowRig rig})> open(
    WidgetTester tester, {
    List<ThreadEntry>? entries,
    Set<String> flags = const {'messaging', 'graph', 'reports', 'ui_shell'},
    Uint8List? payload,
  }) async {
    final server = MessagingFlowRig.serverWithConversation();
    server.conversations[kThreadId]!.encryption =
        ConversationEncryption.CONVERSATION_ENCRYPTION_MLS;
    final port = FakeEncryptedMessaging();
    addTearDown(port.dispose);
    port.setThread(
      ref,
      EncryptedThread(
        conversationId: kThreadId,
        entries:
            entries ??
            [
              entry(_peerMsg),
              entry(_peerMsg2, minutes: 1, check: MessageCheck.unverified),
              entry(_ownMsg, mine: true, minutes: 2, canReport: false),
            ],
        hasMore: false,
        security: const ConversationSecurity(
          state: ConversationEncryptionState.ready,
        ),
      ),
    );
    port.setReportPayload(kThreadId, _peerMsg, payload);
    port.setReportPayload(kThreadId, _peerMsg2, payload);
    final rig = MessagingFlowRig(
      server: server,
      flags: {...flags, kFeatureE2eeDm},
    );
    await rig.pump(
      tester,
      location: AppRouter.messagePath(kThreadId),
      size: const Size(390, 844),
      encrypted: port,
      device: FakeEncryptionDevice(status: VaultStatus.ready, vaultKnown: true),
    );
    return (port: port, rig: rig);
  }

  Finder bubble(String id) => find.byKey(ValueKey('bubble-$id'));

  Future<void> choose(WidgetTester tester, String id) async {
    await tester.longPress(bubble(id));
    await tester.pumpAndSettle();
    await tester.tap(find.text(kReportMessageLabel));
    await tester.pumpAndSettle();
  }

  Uint8List bytes(int n) => Uint8List.fromList(List.filled(n, 7));

  group('encrypted message reports', () {
    testWidgets('Report on a peer message reads the payload once and opens '
        'the sheet with the encrypted detail', (tester) async {
      final r = await open(tester, payload: bytes(40));

      await tester.longPress(bubble(_peerMsg));
      await tester.pumpAndSettle();
      expect(
        r.port.calls.where((c) => c == 'reportPayload'),
        isEmpty,
        reason: 'the payload is read only after Report message is chosen',
      );
      await tester.tap(find.text(kReportMessageLabel));
      await tester.pumpAndSettle();

      expect(r.port.calls.where((c) => c == 'reportPayload'), hasLength(1));
      expect(find.textContaining(kReportEncryptedDetail), findsOneWidget);
      expect(find.textContaining(kReportUnverifiedDetail), findsNothing);
      expect(r.rig.server.reports, isEmpty, reason: 'nothing sent yet');

      await tester.tap(find.text("It's spam"));
      await tester.pump();
      final send = find.widgetWithText(FilledButton, 'Send report');
      await tester.ensureVisible(send);
      await tester.tap(send);
      await tester.pumpAndSettle();

      expect(r.rig.server.reports, hasLength(1));
      final sent = r.rig.server.reports.single;
      expect(sent.targetType, ReportTargetType.REPORT_TARGET_TYPE_MESSAGE);
      expect(sent.targetId, '$kThreadId:$_peerMsg');
      expect(sent.messagePayload, bytes(40));
    });

    testWidgets('an unverified message adds the unverified sentence', (
      tester,
    ) async {
      await open(tester, payload: bytes(10));

      await choose(tester, _peerMsg2);

      expect(
        find.textContaining('$kReportEncryptedDetail $kReportUnverifiedDetail'),
        findsOneWidget,
      );
    });

    testWidgets('an undecodable message is reportable', (tester) async {
      final r = await open(
        tester,
        payload: bytes(10),
        entries: [entry(_peerMsg, check: MessageCheck.undecodable)],
      );
      r.port.setReportPayload(kThreadId, _peerMsg, bytes(10));

      await choose(tester, _peerMsg);

      expect(find.textContaining(kReportUnverifiedDetail), findsOneWidget);
    });

    testWidgets('null payload shows the snackbar and opens nothing', (
      tester,
    ) async {
      await open(tester, payload: null);

      await choose(tester, _peerMsg);

      expect(find.text(kReportUnavailableText), findsOneWidget);
      expect(find.textContaining(kReportEncryptedDetail), findsNothing);
      expect(find.text('Send report'), findsNothing);
    });

    testWidgets('an 8193-byte payload is treated as missing', (tester) async {
      await open(tester, payload: bytes(8193));

      await choose(tester, _peerMsg);

      expect(find.text(kReportUnavailableText), findsOneWidget);
      expect(find.text('Send report'), findsNothing);
    });

    testWidgets('an empty payload is treated as missing', (tester) async {
      await open(tester, payload: Uint8List(0));

      await choose(tester, _peerMsg);

      expect(find.text(kReportUnavailableText), findsOneWidget);
    });

    testWidgets('own, system, undecryptable and removed rows have no Report '
        'action', (tester) async {
      final r = await open(
        tester,
        entries: [
          entry(_ownMsg, mine: true, canReport: false),
          entry(
            _lostMsg,
            state: EncryptedMessageState.undecryptable,
            canReport: false,
          ),
          entry(
            _goneMsg,
            minutes: 1,
            state: EncryptedMessageState.removed,
            canReport: false,
          ),
          SystemLineEntry(
            id: _lineId,
            at: base.add(const Duration(minutes: 2)),
            kind: SystemLineKind.deviceAdded,
          ),
        ],
      );

      for (final id in [_ownMsg, _lostMsg, _goneMsg]) {
        await tester.longPress(bubble(id));
        await tester.pumpAndSettle();
        expect(find.text(kReportMessageLabel), findsNothing, reason: id);
      }
      expect(r.port.calls.where((c) => c == 'reportPayload'), isEmpty);
    });

    testWidgets('nothing is called when the reports flag is off', (
      tester,
    ) async {
      final r = await open(
        tester,
        flags: const {'messaging', 'graph', 'ui_shell'},
        payload: bytes(10),
      );

      await tester.longPress(bubble(_peerMsg));
      await tester.pumpAndSettle();

      expect(find.text(kReportMessageLabel), findsNothing);
      expect(r.port.calls.where((c) => c == 'reportPayload'), isEmpty);
      expect(r.rig.server.reports, isEmpty);
    });

    test('the target id is "<conv>:<msg>" and a malformed id throws', () {
      final ok = entry(_peerMsg);
      expect(encryptedReportTargetId(kThreadId, ok), '$kThreadId:$_peerMsg');

      expect(
        () => encryptedReportTargetId('not-an-id', ok),
        throwsArgumentError,
      );
      expect(
        () => encryptedReportTargetId(kThreadId, entry('e1')),
        throwsArgumentError,
      );
      expect(
        () => encryptedReportTargetId(kThreadId, entry(_ownMsg, mine: true)),
        throwsArgumentError,
      );
      expect(
        () => encryptedReportTargetId(
          kThreadId,
          entry(_peerMsg, canReport: false),
        ),
        throwsArgumentError,
      );
      expect(
        () => encryptedReportTargetId(
          kThreadId,
          entry(_peerMsg, state: EncryptedMessageState.removed),
        ),
        throwsArgumentError,
      );
    });
  });
}
