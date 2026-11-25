import 'dart:async';

import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/vault/vault_status.dart';
import 'package:dzeroth/features/messages/domain/e2ee/encrypted_messaging.dart';
import 'package:dzeroth/features/messages/domain/messaging_feature_flag.dart';
import 'package:dzeroth/features/messages/presentation/draft_thread_screen.dart';
import 'package:dzeroth/features/messages/presentation/e2ee/encryption_copy.dart';
import 'package:dzeroth/features/messages/presentation/e2ee/encryption_status.dart';
import 'package:dzeroth/features/messages/presentation/widgets/message_composer.dart';
import 'package:dzeroth/features/messages/presentation/widgets/not_encrypted_note.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../../support/fake_encrypted_messaging.dart';
import '../../../support/fake_encryption_device.dart';
import '../../../support/messaging_flow_rig.dart';

// Plan 6 Task 1.B: the draft thread under `e2ee_required`. Real router and
// screens (MessagingFlowRig), a fake port and device.

final _sam = common.AuthorSnapshot(
  userId: 'u-sam',
  handle: 'sam',
  displayName: 'Sam Rivera',
);

void main() {
  Future<({FakeEncryptedMessaging port, MessagingFlowRig rig})> open(
    WidgetTester tester, {
    required bool e2eeDm,
    bool required = true,
    bool vaultKnown = true,
  }) async {
    final server = FakeMessagingServer();
    final port = FakeEncryptedMessaging();
    addTearDown(port.dispose);
    final device = FakeEncryptionDevice(
      status: vaultKnown ? VaultStatus.ready : VaultStatus.off,
      vaultKnown: vaultKnown,
    );
    final status = EncryptionStatusCubit(
      device: device,
      messaging: port,
      flagOn: () => e2eeDm,
    );
    addTearDown(status.close);
    final rig = MessagingFlowRig(
      server: server,
      flags: {
        'messaging',
        'graph',
        'reports',
        'ui_shell',
        if (e2eeDm) kFeatureE2eeDm,
        if (required) kFeatureE2eeRequired,
      },
    );
    await rig.pump(
      tester,
      encrypted: port,
      device: device,
      extraBlocs: [BlocProvider<EncryptionStatusCubit>.value(value: status)],
    );
    unawaited(
      rig.appRouter.router.push<void>(AppRouter.messageDraftPath, extra: _sam),
    );
    await tester.pumpAndSettle();
    expect(find.byType(DraftThreadScreen), findsOneWidget);
    return (port: port, rig: rig);
  }

  Future<void> typeAndSend(WidgetTester tester, String text) async {
    await tester.enterText(find.byKey(MessageComposer.fieldKey), text);
    await tester.pump();
    await tester.tap(find.byKey(MessageComposer.sendKey));
    await tester.pumpAndSettle();
  }

  String fieldText(WidgetTester tester) => tester
      .widget<TextField>(find.byKey(MessageComposer.fieldKey))
      .controller!
      .text;

  testWidgets('under required the draft shows the required note and the '
      'peer-cannot-receive state', (tester) async {
    final o = await open(tester, e2eeDm: true);
    expect(find.text(kRequiredNoteText), findsOneWidget);
    expect(find.text(kMessagesNotEncryptedText), findsNothing);

    o.port.nextSendOutcome = const SendOutcome(
      SendOutcomeKind.refused,
      problem: SendProblem.peerHasNoDevice,
    );
    await typeAndSend(tester, 'hello');
    expect(find.text(kPeerCannotReceiveYetTitle), findsOneWidget);
    expect(find.text(kPeerCannotReceiveYetBody), findsOneWidget);
    expect(fieldText(tester), 'hello');
    expect(o.port.sent, hasLength(1));
    expect(o.rig.server.sends, isEmpty);
  });

  testWidgets('under required a notEncrypted answer is never sent in '
      'plaintext', (tester) async {
    final o = await open(tester, e2eeDm: true);
    o.port.nextSendOutcome = const SendOutcome(SendOutcomeKind.notEncrypted);
    await typeAndSend(tester, 'hello');
    expect(o.rig.server.sends, isEmpty);
    expect(fieldText(tester), 'hello');
    expect(find.byType(DraftThreadScreen), findsOneWidget);
  });

  testWidgets('required without e2ee_dm: no send at all, with its own copy', (
    tester,
  ) async {
    final o = await open(tester, e2eeDm: false, vaultKnown: false);
    // The port is the one that decides; it refuses (no plaintext, no start).
    o.port.nextSendOutcome = const SendOutcome(
      SendOutcomeKind.refused,
      problem: SendProblem.requiredUnavailable,
    );
    expect(find.text(kMessagesNotEncryptedText), findsNothing);
    await typeAndSend(tester, 'hello');
    expect(find.text(kRequiredUnavailableTitle), findsOneWidget);
    expect(find.text(kRequiredUnavailableBody), findsOneWidget);
    expect(fieldText(tester), 'hello');
    expect(o.rig.server.sends, isEmpty);
  });

  testWidgets('required off: today\'s note and today\'s plaintext send', (
    tester,
  ) async {
    final o = await open(tester, e2eeDm: true, required: false);
    expect(find.text(kMessagesNotEncryptedText), findsOneWidget);
    expect(find.text(kRequiredNoteText), findsNothing);
    o.port.nextSendOutcome = const SendOutcome(SendOutcomeKind.notEncrypted);
    await typeAndSend(tester, 'hello');
    expect(o.rig.server.sends.single.recipientUserId, 'u-sam');
  });
}
