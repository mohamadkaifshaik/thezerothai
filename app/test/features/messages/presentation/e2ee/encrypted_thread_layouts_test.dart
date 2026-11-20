import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/features/messages/domain/e2ee/encrypted_messaging.dart';
import 'package:dzeroth/features/messages/domain/messaging_feature_flag.dart';
import 'package:dzeroth/features/messages/presentation/e2ee/encryption_copy.dart';
import 'package:dzeroth/features/messages/presentation/e2ee/widgets/conversation_encryption_note.dart';
import 'package:dzeroth/features/messages/presentation/e2ee/widgets/conversation_state_notice.dart';
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pbenum.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../support/fake_encrypted_messaging.dart';
import '../../../../support/fake_encryption_device.dart';
import '../../../../support/messaging_flow_rig.dart';
import '../../../../support/thread_test_support.dart';

/// The encrypted thread at the three widths (the note row is centred at every
/// one, no side column on the tablet), at text scale 2.0 and once in RTL: no
/// exception, no overflow.
void main() {
  final base = DateTime.now().toUtc().subtract(const Duration(minutes: 30));

  Future<void> pumpAt(
    WidgetTester tester,
    double width, {
    double textScale = 1,
    TextDirection direction = TextDirection.ltr,
  }) async {
    final server = MessagingFlowRig.serverWithConversation();
    server.conversations[kThreadId]!.encryption =
        ConversationEncryption.CONVERSATION_ENCRYPTION_MLS;
    final port = FakeEncryptedMessaging();
    addTearDown(port.dispose);
    port.setThread(
      ThreadRef.conversation(kThreadId),
      EncryptedThread(
        conversationId: kThreadId,
        entries: [
          DecryptedMessage(
            id: 'e2',
            at: base.add(const Duration(minutes: 1)),
            mine: true,
            text: 'a long message that has to wrap at a large text scale',
          ),
          DecryptedMessage(id: 'e1', at: base, mine: false, text: 'hello'),
        ],
        security: const ConversationSecurity(
          state: ConversationEncryptionState.ready,
        ),
      ),
    );
    final rig = MessagingFlowRig(
      server: server,
      flags: {'messaging', 'graph', 'reports', 'ui_shell', kFeatureE2eeDm},
    );
    await rig.pump(
      tester,
      location: AppRouter.messagePath(kThreadId),
      size: Size(width, 900),
      textScale: textScale,
      textDirection: direction,
      encrypted: port,
      device: FakeEncryptionDevice(),
    );
  }

  for (final width in [390.0, 700.0, 1000.0, 1300.0]) {
    testWidgets('the note row is centred at $width dp', (tester) async {
      await pumpAt(tester, width);
      expect(tester.takeException(), isNull);
      // The whole note (lock and text), not just the text.
      final note = tester.getRect(find.byType(ConversationEncryptionNote));
      final list = tester.getRect(find.byType(CustomScrollView));
      expect(
        (note.center.dx - list.center.dx).abs(),
        lessThan(4),
        reason: 'the note sits on the centre of the message list column',
      );
      expect(note.left, greaterThanOrEqualTo(list.left));
      expect(note.right, lessThanOrEqualTo(list.right));
    });
  }

  testWidgets('the encrypted thread wraps at text scale 2.0', (tester) async {
    await pumpAt(tester, 390, textScale: 2);
    expect(tester.takeException(), isNull);
    expect(find.text(kEncryptedNoteText), findsOneWidget);
  });

  testWidgets('the encrypted thread builds in RTL', (tester) async {
    await pumpAt(tester, 390, direction: TextDirection.rtl);
    expect(tester.takeException(), isNull);
    expect(find.text(kEncryptedNoteText), findsOneWidget);
  });

  group('the state notices', () {
    Future<void> pumpNotice(
      WidgetTester tester,
      double width,
      ConversationSecurity security, {
      double textScale = 1,
      TextDirection direction = TextDirection.ltr,
    }) async {
      final server = MessagingFlowRig.serverWithConversation();
      server.conversations[kThreadId]!.encryption =
          ConversationEncryption.CONVERSATION_ENCRYPTION_MLS;
      final port = FakeEncryptedMessaging();
      addTearDown(port.dispose);
      port.setThread(
        ThreadRef.conversation(kThreadId),
        EncryptedThread(
          conversationId: kThreadId,
          entries: [
            DecryptedMessage(id: 'e1', at: base, mine: false, text: 'hello'),
          ],
          security: security,
        ),
      );
      final rig = MessagingFlowRig(
        server: server,
        flags: {'messaging', 'graph', 'reports', 'ui_shell', kFeatureE2eeDm},
      );
      await rig.pump(
        tester,
        location: AppRouter.messagePath(kThreadId),
        size: Size(width, 900),
        textScale: textScale,
        textDirection: direction,
        encrypted: port,
        device: FakeEncryptionDevice(),
      );
    }

    const blocked = ConversationSecurity(
      state: ConversationEncryptionState.changesBlocked,
      canSend: false,
      canReset: true,
    );
    const unverifiable = ConversationSecurity(
      state: ConversationEncryptionState.listUnverifiable,
    );

    for (final width in [390.0, 700.0, 1000.0, 1300.0]) {
      testWidgets('changesBlocked fits at $width dp; actions stack on a '
          'phone and sit in a row from the tablet up', (tester) async {
        await pumpNotice(tester, width, blocked);
        expect(tester.takeException(), isNull);
        expect(find.text(kStateBlockedTitle), findsOneWidget);
        // Both actions are present at every width.
        expect(find.text(kConversationResetAction), findsOneWidget);
        expect(find.text('Block'), findsOneWidget);
        final reset = tester.getRect(find.text(kConversationResetAction));
        final block = tester.getRect(find.text('Block'));
        if (width < 600) {
          expect(reset.top, isNot(block.top), reason: 'stacked');
        } else {
          expect(
            (reset.center.dy - block.center.dy).abs(),
            lessThan(4),
            reason: 'one row from the tablet up',
          );
        }
        // No side column: the notice stays inside the thread pane.
        final pane = tester.getRect(find.byType(CustomScrollView));
        final notice = tester.getRect(find.byType(ConversationStateNotice));
        expect(notice.left, greaterThanOrEqualTo(pane.left - 0.5));
        expect(notice.right, lessThanOrEqualTo(pane.right + 0.5));
      });

      testWidgets('listUnverifiable fits at $width dp', (tester) async {
        await pumpNotice(tester, width, unverifiable);
        expect(tester.takeException(), isNull);
        expect(find.text(kStateListUnverifiableTitle), findsOneWidget);
      });
    }

    final both = {'changesBlocked': blocked, 'listUnverifiable': unverifiable};
    for (final e in both.entries) {
      testWidgets('${e.key} wraps at text scale 2.0', (tester) async {
        await pumpNotice(tester, 390, e.value, textScale: 2);
        expect(tester.takeException(), isNull);
      });

      testWidgets('${e.key} builds in RTL', (tester) async {
        await pumpNotice(tester, 390, e.value, direction: TextDirection.rtl);
        expect(tester.takeException(), isNull);
      });
    }
  });
}
