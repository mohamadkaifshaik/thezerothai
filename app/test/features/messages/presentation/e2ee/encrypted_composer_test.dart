import 'dart:async';

import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/vault/vault_status.dart';
import 'package:dzeroth/features/messages/domain/e2ee/encrypted_messaging.dart';
import 'package:dzeroth/features/messages/domain/messaging_feature_flag.dart';
import 'package:dzeroth/features/messages/presentation/bloc/message_composer_cubit.dart';
import 'package:dzeroth/features/messages/presentation/e2ee/encryption_copy.dart';
import 'package:dzeroth/features/messages/presentation/e2ee/encryption_error_messages.dart';
import 'package:dzeroth/features/messages/presentation/e2ee/encryption_status.dart';
import 'package:dzeroth/features/messages/presentation/e2ee/encryption_status_banner.dart';
import 'package:dzeroth/features/messages/presentation/messaging_error_messages.dart';
import 'package:dzeroth/features/messages/presentation/widgets/message_composer.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pbenum.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../support/fake_encrypted_messaging.dart';
import '../../../../support/fake_encryption_device.dart';
import '../../../../support/fake_send_repository.dart';
import '../../../../support/thread_test_support.dart';
import '../../../../support/messaging_flow_rig.dart';

const _queued = SendOutcome(SendOutcomeKind.queued);
const _plain = SendOutcome(SendOutcomeKind.notEncrypted);

SendOutcome _refused(SendProblem problem, [AppException? error]) =>
    SendOutcome(SendOutcomeKind.refused, problem: problem, error: error);

final _sam = common.AuthorSnapshot(
  userId: 'u-sam',
  handle: 'sam',
  displayName: 'Sam Rivera',
);

void main() {
  group('MessageComposerCubit with a port', () {
    late FakeSendRepository repo;
    late FakeEncryptedMessaging port;
    late List<Object> reported;
    late int activity;
    late int cannotMessage;
    late List<String> created;

    setUp(() {
      repo = FakeSendRepository();
      port = FakeEncryptedMessaging();
      reported = [];
      activity = 0;
      cannotMessage = 0;
      created = [];
    });
    tearDown(() => port.dispose());

    MessageComposerCubit make({
      bool withPort = true,
      bool draft = false,
      common.AuthorSnapshot? recipient,
    }) {
      final c = MessageComposerCubit(
        repository: repo,
        outbox: repo.outbox,
        conversationId: draft ? null : kThreadId,
        recipientUserId: draft ? 'u-sam' : null,
        recipient: draft ? recipient : null,
        encrypted: withPort ? port : null,
        onActivity: () => activity++,
        onCannotMessage: () => cannotMessage++,
        onConversationCreated: created.add,
        onUnexpectedError: (e, _) => reported.add(e),
      );
      addTearDown(c.close);
      return c;
    }

    test('no port: sendMessage is called exactly as before', () async {
      final cubit = make(withPort: false);
      cubit.textChanged('hello');
      await cubit.send();
      expect(repo.sendTexts, ['hello']);
      expect(repo.sendKeys, hasLength(1));
      expect(port.calls, isEmpty);
      expect(cubit.state.outgoing, isEmpty);
      expect(cubit.state.draft.text, isEmpty);
      expect(cubit.state.refusedProblem, SendProblem.none);
    });

    test('queued clears the field, adds no outgoing row and does not call '
        'sendMessage', () async {
      final cubit = make();
      cubit.textChanged('hello');
      final before = activity;
      await cubit.send();
      expect(port.sent.single.text, 'hello');
      expect(port.sent.single.to, ThreadRef.conversation(kThreadId));
      expect(repo.sendKeys, isEmpty);
      expect(cubit.state.outgoing, isEmpty);
      expect(cubit.state.draft.text, isEmpty);
      expect(cubit.state.isSending, isFalse);
      expect(activity, greaterThan(before));
      expect(cubit.state.error, isNull);
    });

    test('while send is pending (holdSend) the composer is in its normal '
        'sending state, a second send sends nothing more and the text stays '
        'in the field', () async {
      final hold = Completer<void>();
      port.holdSend = hold;
      final cubit = make();
      cubit.textChanged('hello');
      final first = cubit.send();
      await Future<void>.delayed(Duration.zero);
      expect(cubit.state.isSending, isTrue);
      expect(cubit.state.canSend, isFalse);
      expect(cubit.state.draft.text, 'hello');
      expect(cubit.state.outgoing, isEmpty);
      await cubit.send();
      expect(port.sent, hasLength(1));
      hold.complete();
      await first;
      expect(cubit.state.isSending, isFalse);
      expect(cubit.state.draft.text, isEmpty);
    });

    test('notEncrypted calls sendMessage with the same id as idempotency '
        'key', () async {
      port.nextSendOutcome = _plain;
      final cubit = make();
      cubit.textChanged('hello');
      await cubit.send();
      expect(repo.sendKeys, [port.sent.single.localId]);
      expect(repo.sendTexts, ['hello']);
      expect(cubit.state.outgoing, isEmpty);
      expect(cubit.state.draft.text, isEmpty);
    });

    test('a first message to a peer with an empty device list goes out as an '
        'ordinary message and no peerHasNoDevice line is shown', () async {
      port.nextSendOutcome = _plain;
      final cubit = make(draft: true, recipient: _sam);
      cubit.textChanged('hi');
      await cubit.send();
      expect(port.sent.single.to, ThreadRef.recipientOf(_sam));
      expect(repo.sendRecipients, ['u-sam']);
      expect(cubit.state.refusedProblem, SendProblem.none);
      expect(cubit.state.error, isNull);
    });

    test('refused keeps the text and sets refusedProblem; the next edit '
        'clears it', () async {
      port.nextSendOutcome = _refused(SendProblem.peerHasNoDevice);
      final cubit = make();
      cubit.textChanged('hello');
      await cubit.send();
      expect(cubit.state.draft.text, 'hello');
      expect(cubit.state.refusedProblem, SendProblem.peerHasNoDevice);
      expect(cubit.state.isSending, isFalse);
      expect(repo.sendKeys, isEmpty);
      cubit.textChanged('hello!');
      expect(cubit.state.refusedProblem, SendProblem.none);
    });

    test('a refused text that is sent again uses the same id and a queued '
        'answer then forgets the key', () async {
      port.queueSendOutcomes([_refused(SendProblem.tryTomorrow), _queued]);
      final cubit = make();
      cubit.textChanged('hello');
      await cubit.send();
      await cubit.send();
      expect(port.sent.map((s) => s.localId).toSet(), hasLength(1));
      expect(cubit.keyFor('hello'), isNull);
      // The same words again are a new message with a new id.
      cubit.textChanged('hello');
      await cubit.send();
      expect(port.sent.map((s) => s.localId).toSet(), hasLength(2));
    });

    test('no send path calls accept in a request thread', () async {
      port.queueSendOutcomes([_queued, _plain, _refused(SendProblem.blocked)]);
      final cubit = make();
      for (final t in ['a', 'b', 'c']) {
        cubit.textChanged(t);
        await cubit.send();
      }
      // The fake repository answers only sendMessage; accept would throw.
      expect(repo.sendTexts, ['b']);
      expect(port.calls.where((c) => c != 'send'), isEmpty);
    });

    test('refused with CannotMessageException calls onCannotMessage', () async {
      port.nextSendOutcome = _refused(
        SendProblem.refused,
        const CannotMessageException(),
      );
      final cubit = make();
      cubit.textChanged('hello');
      await cubit.send();
      expect(cannotMessage, 1);
      expect(cubit.state.cannotMessage, isTrue);
      expect(repo.sendKeys, isEmpty);
    });

    test('refused with DegradedModeException sets degraded', () async {
      port.nextSendOutcome = _refused(
        SendProblem.refused,
        const DegradedModeException(''),
      );
      final cubit = make();
      cubit.textChanged('hello');
      await cubit.send();
      expect(cubit.state.degraded, isTrue);
      expect(cubit.state.draft.text, 'hello');
    });

    test('retry of a port row calls retrySend, never sendMessage', () async {
      final cubit = make();
      await cubit.retry('port-row-1');
      expect(port.retried, ['port-row-1']);
      expect(repo.sendKeys, isEmpty);
    });

    test('retry of an outgoing row is today\'s retry', () async {
      repo.failures.add(const NetworkException('offline'));
      final cubit = make(withPort: false);
      cubit.textChanged('hello');
      await cubit.send();
      await cubit.retry(cubit.state.outgoing.single.localId);
      expect(repo.sendKeys, hasLength(2));
      expect(port.retried, isEmpty);
    });

    test('the text is never passed to onUnexpectedError', () async {
      port.failNextOn(
        'send',
        ArgumentError.value('secret words', 'text', 'too long'),
      );
      final cubit = make();
      cubit.textChanged('secret words');
      await cubit.send();
      expect(reported, hasLength(1));
      expect(reported.single.toString(), isNot(contains('secret')));
      expect(cubit.state.draft.text, 'secret words');
      expect(cubit.state.error, isA<ValidationException>());
      expect(repo.sendKeys, isEmpty);
    });

    test(
      'another thrown error is today\'s unexpected error, text kept',
      () async {
        port.failNextOn('send', StateError('boom secret'));
        final cubit = make();
        cubit.textChanged('secret words');
        await cubit.send();
        expect(reported.single.toString(), isNot(contains('secret')));
        expect(cubit.state.error, isA<UnknownApiException>());
        expect(cubit.state.draft.text, 'secret words');
      },
    );

    test('refused retryable keeps the text, says "Couldn\'t send that. Please '
        'try again." and never calls sendMessage', () async {
      port.nextSendOutcome = _refused(SendProblem.retryable);
      final cubit = make();
      cubit.textChanged('hello');
      await cubit.send();
      expect(cubit.state.draft.text, 'hello');
      expect(cubit.state.refusedProblem, SendProblem.retryable);
      expect(
        composerRefusalText(SendProblem.retryable, null),
        "Couldn't send that. Please try again.",
      );
      expect(repo.sendKeys, isEmpty);
      // Tapping send again tries again.
      port.nextSendOutcome = _queued;
      await cubit.send();
      expect(port.sent, hasLength(2));
      expect(cubit.state.draft.text, isEmpty);
    });

    test('refused blocked while the vault is not ready keeps the text and '
        'never calls sendMessage', () async {
      port.nextSendOutcome = _refused(SendProblem.blocked);
      final cubit = make();
      cubit.textChanged('hello');
      await cubit.send();
      expect(cubit.state.draft.text, 'hello');
      expect(cubit.state.refusedProblem, SendProblem.blocked);
      expect(repo.sendKeys, isEmpty);
    });

    test('a draft composer with a port and no recipient snapshot never sends '
        'plaintext', () async {
      final cubit = make(draft: true);
      cubit.textChanged('hi');
      await cubit.send();
      expect(repo.sendKeys, isEmpty);
      expect(port.sent, isEmpty);
      expect(cubit.state.refusedProblem, SendProblem.blocked);
      expect(cubit.state.draft.text, 'hi');
    });

    test('draft mode queued with a conversation id switches once', () async {
      port.nextSendOutcome = SendOutcome(
        SendOutcomeKind.queued,
        conversationId: kThreadId,
      );
      final cubit = make(draft: true, recipient: _sam);
      cubit.textChanged('hi');
      await cubit.send();
      expect(created, [kThreadId]);
      expect(cubit.state.outgoing, isEmpty);
      expect(cubit.state.draft.text, isEmpty);
    });

    test('a draft composer asserts that the snapshot is the recipient', () {
      expect(
        () => MessageComposerCubit(
          repository: repo,
          outbox: repo.outbox,
          recipientUserId: 'u-other',
          recipient: _sam,
          encrypted: port,
        ),
        throwsA(isA<AssertionError>()),
      );
    });
  });

  group('composerRefusalText', () {
    test('each problem has its text', () {
      expect(
        composerRefusalText(SendProblem.peerHasNoDevice, null),
        kStatePeerNoDeviceText,
      );
      expect(
        composerRefusalText(SendProblem.tryTomorrow, null),
        kOutgoingTryTomorrowText,
      );
      expect(
        composerRefusalText(SendProblem.blocked, null, vaultBlocked: true),
        kSendWaitsForVaultText,
      );
      expect(
        composerRefusalText(SendProblem.blocked, null),
        kStateBlockedTitle,
      );
      expect(
        composerRefusalText(
          SendProblem.refused,
          const LimitReachedException('', quota: 'x'),
        ),
        messagingErrorMessage(const LimitReachedException('', quota: 'x')),
      );
    });
  });

  group('the screen', () {
    final ref = ThreadRef.conversation(kThreadId);

    Future<
      ({
        FakeEncryptedMessaging port,
        FakeEncryptionDevice device,
        MessagingFlowRig rig,
      })
    >
    open(
      WidgetTester tester, {
      ConversationEncryption encryption =
          ConversationEncryption.CONVERSATION_ENCRYPTION_NONE,
      VaultStatus vault = VaultStatus.ready,
      bool engineUnavailable = false,
      bool removedElsewhere = false,
    }) async {
      final server = MessagingFlowRig.serverWithConversation();
      server.conversations[kThreadId]!.encryption = encryption;
      final port = FakeEncryptedMessaging();
      addTearDown(port.dispose);
      port.setThread(
        ref,
        const EncryptedThread(
          conversationId: null,
          security: ConversationSecurity(
            state: ConversationEncryptionState.ready,
          ),
        ),
      );
      port.removedElsewhere.value = removedElsewhere;
      final device = FakeEncryptionDevice(status: vault);
      device.engineUnavailable.value = engineUnavailable;
      final status = EncryptionStatusCubit(
        device: device,
        messaging: port,
        flagOn: () => true,
      );
      addTearDown(status.close);
      final rig = MessagingFlowRig(
        server: server,
        flags: {'messaging', 'graph', 'reports', 'ui_shell', kFeatureE2eeDm},
      );
      await rig.pump(
        tester,
        location: AppRouter.messagePath(kThreadId),
        encrypted: port,
        device: device,
        extraBlocs: [BlocProvider<EncryptionStatusCubit>.value(value: status)],
      );
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

    testWidgets('while send is pending the text stays in the field, the button '
        'is its sending look and a second tap sends nothing', (tester) async {
      final o = await open(tester);
      final hold = Completer<void>();
      o.port.holdSend = hold;
      await typeAndSend(tester, 'hello');
      expect(fieldText(tester), 'hello');
      expect(
        tester
            .widget<IconButton>(find.byKey(MessageComposer.sendKey))
            .onPressed,
        isNull,
      );
      await tester.tap(
        find.byKey(MessageComposer.sendKey),
        warnIfMissed: false,
      );
      await tester.pump();
      expect(o.port.sent, hasLength(1));
      hold.complete();
      await tester.pumpAndSettle();
      expect(fieldText(tester), isEmpty);
      expect(o.rig.server.sends, isEmpty);
    });

    testWidgets('queued clears the field and sendMessage is not called', (
      tester,
    ) async {
      final o = await open(tester);
      await typeAndSend(tester, 'hello');
      await tester.pumpAndSettle();
      expect(fieldText(tester), isEmpty);
      expect(o.rig.server.sends, isEmpty);
    });

    testWidgets('refused peerHasNoDevice keeps the text and shows "They can\'t '
        'receive encrypted messages yet"', (tester) async {
      final o = await open(tester);
      o.port.nextSendOutcome = _refused(SendProblem.peerHasNoDevice);
      await typeAndSend(tester, 'hello');
      await tester.pumpAndSettle();
      expect(fieldText(tester), 'hello');
      expect(find.text(kStatePeerNoDeviceText), findsOneWidget);
      expect(o.rig.server.sends, isEmpty);
    });

    testWidgets('refused tryTomorrow shows "Not sent. Try again tomorrow"', (
      tester,
    ) async {
      final o = await open(tester);
      o.port.nextSendOutcome = _refused(SendProblem.tryTomorrow);
      await typeAndSend(tester, 'hello');
      await tester.pumpAndSettle();
      expect(find.text(kOutgoingTryTomorrowText), findsOneWidget);
      expect(fieldText(tester), 'hello');
    });

    testWidgets('the refusal line is a live region', (tester) async {
      final o = await open(tester);
      o.port.nextSendOutcome = _refused(SendProblem.tryTomorrow);
      await typeAndSend(tester, 'hello');
      await tester.pumpAndSettle();
      final semantics = tester.getSemantics(
        find.text(kOutgoingTryTomorrowText),
      );
      expect(semantics, isNotNull);
      final live = find.ancestor(
        of: find.text(kOutgoingTryTomorrowText),
        matching: find.byWidgetPredicate(
          (w) => w is Semantics && w.properties.liveRegion == true,
        ),
      );
      expect(live, findsWidgets);
    });

    testWidgets('a queued row that later arrives as notSent with problem '
        'refused shows its text under the bubble and nothing above the field', (
      tester,
    ) async {
      final o = await open(
        tester,
        encryption: ConversationEncryption.CONVERSATION_ENCRYPTION_MLS,
      );
      await typeAndSend(tester, 'hello');
      await tester.pumpAndSettle();
      final id = o.port.sent.single.localId;
      o.port.setThread(
        ref,
        EncryptedThread(
          conversationId: kThreadId,
          security: const ConversationSecurity(
            state: ConversationEncryptionState.ready,
          ),
          entries: [
            DecryptedMessage(
              id: id,
              at: DateTime.now().toUtc().add(const Duration(hours: 1)),
              mine: true,
              text: 'hello',
              progress: SendProgress.notSent,
              problem: SendProblem.refused,
              error: const LimitReachedException('', quota: 'x'),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      final text = messagingErrorMessage(
        const LimitReachedException('', quota: 'x'),
      );
      expect(find.text(text), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(MessageComposer),
          matching: find.text(text),
        ),
        findsNothing,
      );
    });

    testWidgets('a plaintext thread refused while the vault is not ready shows '
        'the vault status with Details', (tester) async {
      final o = await open(tester, vault: VaultStatus.opening);
      o.port.nextSendOutcome = _refused(SendProblem.blocked);
      await typeAndSend(tester, 'hello');
      await tester.pumpAndSettle();
      expect(find.text(kSendWaitsForVaultText), findsOneWidget);
      expect(find.byType(EncryptionStatusBanner), findsOneWidget);
      expect(find.text(kStatusDetails), findsOneWidget);
      expect(fieldText(tester), 'hello');
      expect(o.rig.server.sends, isEmpty);
    });

    for (final removed in [false, true]) {
      testWidgets('a blocked refusal with the vault ready never says the '
          'vault is not open (${removed ? 'removedElsewhere' : 'engine'})', (
        tester,
      ) async {
        final o = await open(
          tester,
          engineUnavailable: !removed,
          removedElsewhere: removed,
        );
        o.port.nextSendOutcome = _refused(SendProblem.blocked);
        await typeAndSend(tester, 'hello');
        await tester.pumpAndSettle();
        expect(find.text(kSendWaitsForVaultText), findsNothing);
        expect(find.text(kStateBlockedTitle), findsOneWidget);
      });
    }
  });
}
