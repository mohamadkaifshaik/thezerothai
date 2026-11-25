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
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';

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
  setUpAll(() => registerFallbackValue(const OnboardingState()));

  Future<({FakeEncryptedMessaging port, MessagingFlowRig rig})> open(
    WidgetTester tester, {
    required bool e2eeDm,
    bool required = true,
    bool vaultKnown = true,
    // Runs on the rig's onboarding mock before the draft opens.
    void Function(MessagingFlowRig rig)? beforeOpen,
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
    beforeOpen?.call(rig);
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
    // A draft has no earlier messages: its own note, never the thread's
    // "Earlier messages here ..." (code review Minor 1).
    expect(find.text(kRequiredDraftNoteText), findsOneWidget);
    expect(find.text(kRequiredNoteText), findsNothing);
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

    // Code review Minor 4: the title and the body are ONE live region, so a
    // screen reader announces the refusal once, both lines together.
    final liveRegions = find.ancestor(
      of: find.text(kPeerCannotReceiveYetBody),
      matching: find.byWidgetPredicate(
        (w) => w is Semantics && (w.properties.liveRegion ?? false),
      ),
    );
    expect(liveRegions, findsOneWidget);
    expect(
      find.descendant(
        of: liveRegions,
        matching: find.text(kPeerCannotReceiveYetTitle),
      ),
      findsOneWidget,
    );
    final handle = tester.ensureSemantics();
    final label = tester
        .getSemantics(find.text(kPeerCannotReceiveYetTitle))
        .label;
    expect(label, contains(kPeerCannotReceiveYetTitle));
    expect(label, contains(kPeerCannotReceiveYetBody));
    handle.dispose();
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
    // This checks the COPY only: the fake port is scripted to refuse. That
    // the real port refuses here is pinned in encrypted_messaging_impl_test
    // ("required without e2ee_dm").
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

  testWidgets('code review Nit 1: the draft note follows the fail-closed '
      'rule the sends use (a flag set of another user reads as required)', (
    tester,
  ) async {
    // The flag set lacks e2ee_required but was emitted for another user than
    // the one the bloc serves now (an account switch in flight). The live
    // swap of a note is covered on the thread screen (encrypted thread
    // tests); this rig's router drops a pushed draft on an onboarding change.
    final o = await open(
      tester,
      e2eeDm: true,
      required: false,
      beforeOpen: (rig) {
        when(() => rig.onboarding.uidOf(any())).thenReturn('uid-previous');
        when(() => rig.onboarding.currentUid).thenReturn('uid-1');
      },
    );
    expect(find.text(kMessagesNotEncryptedText), findsNothing);
    expect(find.text(kRequiredDraftNoteText), findsOneWidget);
    // And its send is refused on the device: no plaintext call.
    o.port.nextSendOutcome = const SendOutcome(SendOutcomeKind.notEncrypted);
    await typeAndSend(tester, 'hello');
    expect(o.rig.server.sends, isEmpty);
  });

  testWidgets('required off: today\'s note and today\'s plaintext send', (
    tester,
  ) async {
    final o = await open(tester, e2eeDm: true, required: false);
    expect(find.text(kMessagesNotEncryptedText), findsOneWidget);
    expect(find.text(kRequiredDraftNoteText), findsNothing);
    o.port.nextSendOutcome = const SendOutcome(SendOutcomeKind.notEncrypted);
    await typeAndSend(tester, 'hello');
    expect(o.rig.server.sends.single.recipientUserId, 'u-sam');
  });
}
