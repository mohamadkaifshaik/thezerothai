import 'dart:async';

import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/vault/vault_status.dart';
import 'package:dzeroth/features/messages/domain/e2ee/encrypted_messaging.dart';
import 'package:dzeroth/features/messages/domain/messaging_feature_flag.dart';
import 'package:dzeroth/features/messages/presentation/draft_thread_screen.dart';
import 'package:dzeroth/features/messages/presentation/e2ee/encryption_copy.dart';
import 'package:dzeroth/features/messages/presentation/e2ee/encryption_status.dart';
import 'package:dzeroth/features/messages/presentation/widgets/message_bubble.dart';
import 'package:dzeroth/features/messages/presentation/widgets/message_composer.dart';
import 'package:dzeroth/features/messages/presentation/widgets/not_encrypted_note.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../support/fake_encrypted_messaging.dart';
import '../../../../support/fake_encryption_device.dart';
import '../../../../support/thread_test_support.dart';
import '../../../../support/messaging_flow_rig.dart';

final _sam = common.AuthorSnapshot(
  userId: 'u-sam',
  handle: 'sam',
  displayName: 'Sam Rivera',
);

const _empty = EncryptedThread(
  security: ConversationSecurity(state: ConversationEncryptionState.ready),
);

void main() {
  final ref = ThreadRef.recipientOf(_sam);
  const heroText = 'Write your first message below.';

  Future<
    ({
      FakeEncryptedMessaging port,
      FakeEncryptionDevice device,
      MessagingFlowRig rig,
    })
  >
  open(
    WidgetTester tester, {
    bool flagOn = true,
    VaultStatus vault = VaultStatus.ready,
    bool vaultKnown = true,
  }) async {
    final server = FakeMessagingServer();
    final port = FakeEncryptedMessaging();
    addTearDown(port.dispose);
    final device = FakeEncryptionDevice(status: vault, vaultKnown: vaultKnown);
    final status = EncryptionStatusCubit(
      device: device,
      messaging: port,
      flagOn: () => flagOn,
    );
    addTearDown(status.close);
    final rig = MessagingFlowRig(
      server: server,
      flags: {
        'messaging',
        'graph',
        'reports',
        'ui_shell',
        if (flagOn) kFeatureE2eeDm,
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
    return (port: port, device: device, rig: rig);
  }

  Future<void> typeAndSend(WidgetTester tester, String text) async {
    await tester.enterText(find.byKey(MessageComposer.fieldKey), text);
    await tester.pump();
    await tester.tap(find.byKey(MessageComposer.sendKey));
    await tester.pump();
  }

  String fieldText(WidgetTester tester) => tester
      .widget<TextField>(find.byKey(MessageComposer.fieldKey))
      .controller!
      .text;

  DecryptedMessage row(
    String id, {
    SendProgress progress = SendProgress.waiting,
  }) => DecryptedMessage(
    id: id,
    at: DateTime.now().toUtc(),
    mine: true,
    text: 'hello',
    progress: progress,
  );

  testWidgets('an empty ready recipient thread draws nothing under the hero', (
    tester,
  ) async {
    final o = await open(tester);
    o.port.setThread(ref, _empty);
    await tester.pumpAndSettle();
    expect(find.text(heroText), findsOneWidget);
    expect(find.byType(MessageBubble), findsNothing);
    expect(o.port.calls, contains('watchThread'));
  });

  testWidgets('a pending send keeps the draft\'s normal sending state until '
      'it answers', (tester) async {
    final o = await open(tester);
    final hold = Completer<void>();
    o.port.holdSend = hold;
    await typeAndSend(tester, 'hello');
    expect(fieldText(tester), 'hello');
    expect(
      tester.widget<IconButton>(find.byKey(MessageComposer.sendKey)).onPressed,
      isNull,
    );
    expect(o.port.sent.single.to, ref);
    hold.complete();
    await tester.pumpAndSettle();
    expect(fieldText(tester), isEmpty);
    expect(o.rig.server.sends, isEmpty);
  });

  testWidgets('a queued first message shows as a waiting row under the hero', (
    tester,
  ) async {
    final o = await open(tester);
    await typeAndSend(tester, 'hello');
    await tester.pumpAndSettle();
    o.port.setThread(
      ref,
      EncryptedThread(
        entries: [row(o.port.sent.single.localId)],
        security: const ConversationSecurity(
          state: ConversationEncryptionState.ready,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text(kOutgoingWaitingText), findsOneWidget);
    expect(find.text('hello'), findsOneWidget);
    expect(find.byType(DraftThreadScreen), findsOneWidget);
  });

  testWidgets('when the conversation id arrives the screen switches to the '
      'thread once', (tester) async {
    final o = await open(tester);
    await typeAndSend(tester, 'hello');
    await tester.pumpAndSettle();
    final waiting = EncryptedThread(
      conversationId: kThreadId,
      entries: [row(o.port.sent.single.localId)],
      security: const ConversationSecurity(
        state: ConversationEncryptionState.ready,
      ),
    );
    o.port.setThread(ref, waiting);
    o.port.setThread(ref, waiting);
    await tester.pump();
    await tester.pump();
    expect(
      o.rig.stack.where((p) => p == AppRouter.messagePath(kThreadId)),
      hasLength(1),
    );
    expect(o.rig.stack, isNot(contains(AppRouter.messageDraftPath)));
  });

  testWidgets('notEncrypted behaves as today\'s draft send', (tester) async {
    final o = await open(tester);
    o.port.nextSendOutcome = const SendOutcome(SendOutcomeKind.notEncrypted);
    await typeAndSend(tester, 'hello');
    await tester.pumpAndSettle();
    expect(o.rig.server.sends.single.recipientUserId, 'u-sam');
    expect(
      o.rig.server.sends.single.idempotencyKey,
      o.port.sent.single.localId,
    );
    expect(o.rig.stack.last, startsWith('/messages/'));
    expect(o.rig.stack, isNot(contains(AppRouter.messageDraftPath)));
  });

  testWidgets('the draft is not written to the cache', (tester) async {
    final o = await open(tester);
    Future<({int conversations, int messages, int state})> counts() async {
      var done = false;
      final f = o.rig.messagingRowCounts().whenComplete(() => done = true);
      for (var i = 0; i < 200 && !done; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      return f;
    }

    final before = await counts();
    await typeAndSend(tester, 'hello');
    await tester.pumpAndSettle();
    o.port.setThread(
      ref,
      EncryptedThread(
        entries: [row(o.port.sent.single.localId)],
        security: const ConversationSecurity(
          state: ConversationEncryptionState.ready,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final after = await counts();
    expect(after, before);
  });

  testWidgets('the draft shows the not-encrypted note before the first send', (
    tester,
  ) async {
    await open(tester);
    expect(find.text(kMessagesNotEncryptedText), findsOneWidget);
  });

  testWidgets('with the flag off and a vault on this device the draft asks '
      'the port first', (tester) async {
    final o = await open(tester, flagOn: false);
    o.port.nextSendOutcome = const SendOutcome(SendOutcomeKind.notEncrypted);
    expect(find.text(kMessagesNotEncryptedText), findsNothing);
    await typeAndSend(tester, 'hello');
    await tester.pumpAndSettle();
    expect(o.port.sent, hasLength(1));
    expect(o.rig.server.sends, hasLength(1));
  });

  testWidgets('without the flag and no vault on this device the draft shows '
      'no note and the composer '
      'does not use the port for a person it knows nothing about', (
    tester,
  ) async {
    // Flag off and no vault known on this device: access is hidden.
    final o = await open(tester, flagOn: false, vaultKnown: false);
    expect(find.text(kMessagesNotEncryptedText), findsNothing);
    await typeAndSend(tester, 'hello');
    await tester.pumpAndSettle();
    expect(o.port.sent, isEmpty);
    expect(o.rig.server.sends.single.recipientUserId, 'u-sam');
  });

  testWidgets('the not-encrypted note is gone once the draft shows an '
      'encrypted row', (tester) async {
    final o = await open(tester);
    await typeAndSend(tester, 'hello');
    await tester.pumpAndSettle();
    expect(find.text(kMessagesNotEncryptedText), findsOneWidget);
    o.port.setThread(
      ref,
      EncryptedThread(
        entries: [row(o.port.sent.single.localId)],
        security: const ConversationSecurity(
          state: ConversationEncryptionState.ready,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text(kOutgoingWaitingText), findsOneWidget);
    expect(find.text(kMessagesNotEncryptedText), findsNothing);
  });

  testWidgets('a second tap on a retrying draft row sends nothing more', (
    tester,
  ) async {
    final o = await open(tester);
    o.port.setThread(
      ref,
      EncryptedThread(
        entries: [
          DecryptedMessage(
            id: 'r1',
            at: DateTime.now().toUtc(),
            mine: true,
            text: 'hello',
            progress: SendProgress.notSent,
            problem: SendProblem.retryable,
          ),
        ],
        security: const ConversationSecurity(
          state: ConversationEncryptionState.ready,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final tap = tester
        .widget<GestureDetector>(
          find
              .ancestor(
                of: find.byKey(MessageBubble.statusKey),
                matching: find.byType(GestureDetector),
              )
              .first,
        )
        .onTap!;
    // Both taps land before the first answers.
    tap();
    tap();
    await tester.pumpAndSettle();
    expect(o.port.retried, ['r1'], reason: 'one call for two taps');
  });
}
