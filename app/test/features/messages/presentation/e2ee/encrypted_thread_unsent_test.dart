import 'dart:async';

import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/vault/vault_status.dart' show E2eeFlag;
import 'package:dzeroth/features/messages/domain/e2ee/encrypted_messaging.dart';
import 'package:dzeroth/features/messages/domain/messaging_feature_flag.dart';
import 'package:dzeroth/features/messages/presentation/e2ee/encryption_copy.dart';
import 'package:dzeroth/features/messages/presentation/e2ee/encryption_status.dart';
import 'package:dzeroth/features/messages/presentation/e2ee/widgets/unreadable_unsent_row.dart';
import 'package:dzeroth/features/messages/presentation/widgets/message_bubble.dart';
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pbenum.dart';
import 'package:dzeroth/shared/widgets/primitives/app_pill_button.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../../../support/fake_encrypted_messaging.dart';
import '../../../../support/fake_encryption_device.dart';
import '../../../../support/messaging_flow_rig.dart';
import '../../../../support/thread_test_support.dart';

// Plan 5b Task 14b items 1 and 2: the Discard action of an own row that is
// not delivered, and the rows of the port's unreadable unsent messages.

const _ready = ConversationSecurity(state: ConversationEncryptionState.ready);

void main() {
  final ref = ThreadRef.conversation(kThreadId);
  final base = DateTime.now().toUtc().add(const Duration(hours: 1));

  DecryptedMessage entry(
    String id, {
    bool mine = true,
    SendProgress progress = SendProgress.waiting,
    SendProblem problem = SendProblem.none,
    int minute = 0,
  }) => DecryptedMessage(
    id: id,
    at: base.add(Duration(minutes: minute)),
    mine: mine,
    text: 'text of $id',
    progress: progress,
    problem: problem,
  );

  Future<({FakeEncryptedMessaging port, MessagingFlowRig rig})> open(
    WidgetTester tester, {
    List<ThreadEntry> entries = const [],
    List<String> unreadable = const [],
    Size size = const Size(390, 844),
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
        entries: entries,
        security: _ready,
        unreadableUnsent: unreadable,
      ),
    );
    final device = FakeEncryptionDevice();
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
      size: size,
      encrypted: port,
      device: device,
      extraBlocs: [BlocProvider<EncryptionStatusCubit>.value(value: status)],
    );
    return (port: port, rig: rig);
  }

  Finder discardButton() =>
      find.widgetWithText(AppPillButton, kUnsentDiscardAction);

  group('Discard on an own row that is not delivered', () {
    testWidgets('is offered on every undelivered own row, never on a '
        'delivered or a received one', (tester) async {
      await open(
        tester,
        entries: [
          entry('w', progress: SendProgress.waiting, minute: 4),
          entry('s', progress: SendProgress.sending, minute: 3),
          entry(
            'f',
            progress: SendProgress.notSent,
            problem: SendProblem.retryable,
            minute: 2,
          ),
          entry('d', progress: SendProgress.delivered, minute: 1),
          entry('p', mine: false, progress: SendProgress.delivered),
        ],
      );
      expect(discardButton(), findsNWidgets(3));
    });

    testWidgets('calls discardUnsent with the row id, once for a double tap', (
      tester,
    ) async {
      final o = await open(tester, entries: [entry('w')]);
      final tap = tester.widget<AppPillButton>(discardButton()).onPressed!;
      tap();
      tap();
      await tester.pumpAndSettle();
      expect(o.port.discardedUnsent, ['w']);
    });

    for (final c in <(UnsentDiscard, String?)>[
      (UnsentDiscard.discarded, null),
      (UnsentDiscard.delivered, null),
      (UnsentDiscard.none, null),
      (UnsentDiscard.stopped, kInitDiscardedText),
      (UnsentDiscard.held, kInitDiscardHeldText),
      (UnsentDiscard.notDecided, kInitDiscardNotDecidedText),
    ]) {
      testWidgets('the answer ${c.$1.name} shows '
          '${c.$2 == null ? 'no line' : 'its line'}', (tester) async {
        final o = await open(tester, entries: [entry('w')]);
        o.port.nextDiscard = c.$1;
        await tester.tap(discardButton());
        await tester.pumpAndSettle();
        for (final line in [
          kInitDiscardedText,
          kInitDiscardHeldText,
          kInitDiscardNotDecidedText,
        ]) {
          expect(
            find.text(line),
            line == c.$2 ? findsOneWidget : findsNothing,
            reason: line,
          );
        }
      });
    }

    testWidgets('held never reads as delivered or discarded: the row stays '
        'and the line says it may still be delivered', (tester) async {
      final o = await open(tester, entries: [entry('w')]);
      o.port.nextDiscard = UnsentDiscard.held;
      await tester.tap(discardButton());
      await tester.pumpAndSettle();
      expect(find.text(kInitDiscardHeldText), findsOneWidget);
      expect(find.text('text of w'), findsOneWidget);
      expect(discardButton(), findsOneWidget);
      expect(find.text(kInitDiscardedText), findsNothing);
    });

    testWidgets('a failing port is notDecided, never discarded', (
      tester,
    ) async {
      final o = await open(tester, entries: [entry('w')]);
      o.port.failNextOn('discardUnsent', StateError('x'));
      await tester.tap(discardButton());
      await tester.pumpAndSettle();
      expect(find.text(kInitDiscardNotDecidedText), findsOneWidget);
      expect(find.text('text of w'), findsOneWidget);
    });
  });

  group('unreadable unsent rows', () {
    testWidgets('each is a row with the fixed text and Delete; nothing of '
        'the handle is shown or used as a key', (tester) async {
      await open(tester, unreadable: ['secret-h1', 'secret-h2']);
      expect(find.byType(UnreadableUnsentRow), findsNWidgets(2));
      expect(find.text(kUnsentUnreadableText), findsNWidgets(2));
      expect(find.text(kUnsentUnreadableDeleteAction), findsNWidgets(2));
      expect(find.textContaining('secret-h'), findsNothing);
      final keys = tester.allWidgets
          .map((w) => w.key)
          .whereType<Key>()
          .map((k) => k.toString());
      expect(keys.where((k) => k.contains('secret-h')), isEmpty);
    });

    testWidgets('Delete passes the handle back unchanged and the row goes', (
      tester,
    ) async {
      final o = await open(tester, unreadable: ['secret-h1', 'secret-h2']);
      await tester.tap(find.text(kUnsentUnreadableDeleteAction).first);
      await tester.pumpAndSettle();
      expect(o.port.deletedUnreadable, [(kThreadId, 'secret-h1')]);
      expect(find.byType(UnreadableUnsentRow), findsOneWidget);
    });

    testWidgets('with waiting rows left, a line offers one retry of the '
        'oldest', (tester) async {
      final o = await open(
        tester,
        unreadable: ['secret-h1'],
        entries: [
          entry('w2', minute: 2),
          entry('w1', minute: 1),
          entry('d', progress: SendProgress.delivered),
        ],
      );
      await tester.tap(find.text(kUnsentUnreadableDeleteAction));
      await tester.pumpAndSettle();
      expect(find.text(kUnsentDeletedWaitingText), findsOneWidget);
      expect(o.port.retried, isEmpty);
      await tester.tap(find.text(kUnsentRetryWaitingAction));
      await tester.pumpAndSettle();
      expect(o.port.retried, ['w1']);
    });

    testWidgets('with other unreadable rows left the line shows without the '
        'retry action (sends wait until each is deleted)', (tester) async {
      await open(
        tester,
        unreadable: ['secret-h1', 'secret-h2'],
        entries: [entry('w1')],
      );
      await tester.tap(find.text(kUnsentUnreadableDeleteAction).first);
      await tester.pumpAndSettle();
      expect(find.text(kUnsentDeletedWaitingText), findsOneWidget);
      expect(find.text(kUnsentRetryWaitingAction), findsNothing);
    });

    testWidgets('while its delete runs that row\'s Delete is disabled and the '
        'others stay enabled', (tester) async {
      final o = await open(tester, unreadable: ['secret-h1', 'secret-h2']);
      o.port.holdDeleteUnreadable = Completer<void>();
      final deletes = find.widgetWithText(
        AppPillButton,
        kUnsentUnreadableDeleteAction,
      );
      tester.widget<AppPillButton>(deletes.first).onPressed!();
      await tester.pump();
      expect(tester.widget<AppPillButton>(deletes.at(0)).onPressed, isNull);
      expect(tester.widget<AppPillButton>(deletes.at(1)).onPressed, isNotNull);
      o.port.holdDeleteUnreadable!.complete();
      await tester.pumpAndSettle();
      expect(o.port.deletedUnreadable, [(kThreadId, 'secret-h1')]);
    });

    testWidgets('a false answer (stale handle) shows nothing and the row is '
        'enabled again', (tester) async {
      final o = await open(tester, unreadable: ['secret-h1']);
      o.port.failNextOn('deleteUnreadableUnsent', StateError('x'));
      final delete = find.widgetWithText(
        AppPillButton,
        kUnsentUnreadableDeleteAction,
      );
      await tester.tap(delete);
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsNothing);
      expect(tester.widget<AppPillButton>(delete).onPressed, isNotNull);
    });

    testWidgets('with nothing waiting no retry is offered', (tester) async {
      await open(
        tester,
        unreadable: ['secret-h1'],
        entries: [entry('d', progress: SendProgress.delivered)],
      );
      await tester.tap(find.text(kUnsentUnreadableDeleteAction));
      await tester.pumpAndSettle();
      expect(find.text(kUnsentDeletedWaitingText), findsNothing);
    });

    testWidgets('a refused delete (false) shows no retry line', (tester) async {
      final o = await open(
        tester,
        unreadable: ['secret-h1'],
        entries: [entry('w')],
      );
      o.port.failNextOn('deleteUnreadableUnsent', StateError('x'));
      await tester.tap(find.text(kUnsentUnreadableDeleteAction));
      await tester.pumpAndSettle();
      expect(find.text(kUnsentDeletedWaitingText), findsNothing);
      expect(find.byType(UnreadableUnsentRow), findsOneWidget);
    });

    for (final width in [390.0, 834.0, 1280.0]) {
      testWidgets('draws without overflow at $width', (tester) async {
        await open(
          tester,
          unreadable: ['secret-h1'],
          entries: [entry('w')],
          size: Size(width, 900),
        );
        expect(tester.takeException(), isNull);
        expect(find.byType(UnreadableUnsentRow), findsOneWidget);
        expect(find.byType(MessageBubble), findsWidgets);
        expect(discardButton(), findsOneWidget);
      });
    }
  });

  testWidgets('access hidden: undelivered and unreadable state draws no '
      'Discard or Delete and calls none of the new port members', (
    tester,
  ) async {
    final server = MessagingFlowRig.serverWithConversation();
    final port = FakeEncryptedMessaging();
    addTearDown(port.dispose);
    port.setThread(
      ref,
      EncryptedThread(
        conversationId: kThreadId,
        entries: [
          entry('w'),
          entry(
            'f',
            progress: SendProgress.notSent,
            problem: SendProblem.retryable,
            minute: 1,
          ),
        ],
        security: _ready,
        unreadableUnsent: const ['secret-h1'],
      ),
    );
    final device = FakeEncryptionDevice(vaultKnown: false, flag: E2eeFlag.off);
    final rig = MessagingFlowRig(server: server);
    await rig.pump(
      tester,
      location: AppRouter.messagePath(kThreadId),
      encrypted: port,
      device: device,
    );
    await tester.pumpAndSettle();
    expect(find.text(kUnsentDiscardAction), findsNothing);
    expect(find.text(kUnsentUnreadableDeleteAction), findsNothing);
    expect(port.discardedUnsent, isEmpty);
    expect(port.deletedUnreadable, isEmpty);
    expect(port.retried, isEmpty);
    for (final name in [
      'discardUnsent',
      'deleteUnreadableUnsent',
      'retrySend',
    ]) {
      expect(port.calls, isNot(contains(name)), reason: name);
    }
  });

  testWidgets('flag off and no vault: nothing of this is drawn and the port '
      'is never called', (tester) async {
    final server = MessagingFlowRig.serverWithConversation();
    final port = FakeEncryptedMessaging();
    addTearDown(port.dispose);
    port.setThread(
      ref,
      EncryptedThread(
        conversationId: kThreadId,
        entries: [entry('w')],
        security: _ready,
        unreadableUnsent: const ['secret-h1'],
      ),
    );
    final device = FakeEncryptionDevice(vaultKnown: false, flag: E2eeFlag.off);
    final rig = MessagingFlowRig(server: server);
    await rig.pump(
      tester,
      location: AppRouter.messagePath(kThreadId),
      encrypted: port,
      device: device,
    );
    expect(discardButton(), findsNothing);
    expect(find.byType(UnreadableUnsentRow), findsNothing);
    expect(port.calls, isEmpty);
    expect(port.discardedUnsent, isEmpty);
    expect(port.deletedUnreadable, isEmpty);
  });
}
