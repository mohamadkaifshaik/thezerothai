import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/features/messages/domain/e2ee/encrypted_messaging.dart';
import 'package:dzeroth/features/messages/domain/messaging_feature_flag.dart';
import 'package:dzeroth/features/messages/presentation/e2ee/encryption_copy.dart';
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
      final note = tester.getRect(find.text(kEncryptedNoteText));
      final column = tester.getRect(find.text('hello'));
      expect(note.center.dx, greaterThan(column.left));
      expect(
        (note.center.dx - width / 2).abs(),
        lessThan(width / 2),
        reason: 'inside the screen',
      );
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
}
