import 'package:dzeroth/features/messages/domain/e2ee/encrypted_messaging.dart';
import 'package:dzeroth/features/messages/presentation/e2ee/encryption_copy.dart';
import 'package:dzeroth/features/messages/presentation/e2ee/widgets/conversation_state_notice.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  Future<void> pumpNotice(
    WidgetTester tester,
    ConversationSecurity security, {
    VoidCallback? onReset,
    VoidCallback? onBlock,
    bool resetting = false,
  }) => tester.pumpWidget(
    _host(
      ConversationStateNotice(
        security: security,
        peerName: 'Sam',
        onReset: onReset,
        onBlock: onBlock,
        resetting: resetting,
      ),
    ),
  );

  testWidgets('states with no notice draw nothing', (tester) async {
    for (final s in [
      ConversationEncryptionState.ready,
      ConversationEncryptionState.syncing,
      ConversationEncryptionState.sendPaused,
      ConversationEncryptionState.pendingRequest,
    ]) {
      await pumpNotice(tester, ConversationSecurity(state: s));
      expect(find.byType(Text), findsNothing, reason: '$s');
      expect(conversationStateHasNotice(ConversationSecurity(state: s)), false);
    }
  });

  testWidgets('Reset is drawn only with canReset, a callback and no sent '
      'request; Block only with a callback', (tester) async {
    var resets = 0;
    var blocks = 0;
    const stuck = ConversationSecurity(
      state: ConversationEncryptionState.stuck,
      canSend: false,
      canReset: true,
    );
    await pumpNotice(
      tester,
      stuck,
      onReset: () => resets++,
      onBlock: () => blocks++,
    );
    await tester.tap(find.text(kConversationResetAction));
    await tester.tap(find.text('Block'));
    expect((resets, blocks), (1, 1));

    await pumpNotice(tester, stuck);
    expect(find.text(kConversationResetAction), findsNothing);
    expect(find.text('Block'), findsNothing);

    await pumpNotice(
      tester,
      const ConversationSecurity(
        state: ConversationEncryptionState.stuck,
        canSend: false,
        canReset: true,
        sentRequest: true,
      ),
      onReset: () {},
    );
    expect(find.text(kConversationResetAction), findsNothing);
  });

  testWidgets('a running reset turns the button off', (tester) async {
    var resets = 0;
    await pumpNotice(
      tester,
      const ConversationSecurity(
        state: ConversationEncryptionState.stuck,
        canSend: false,
        canReset: true,
      ),
      onReset: () => resets++,
      resetting: true,
    );
    await tester.tap(
      find.byKey(ConversationStateNotice.resetKey),
      warnIfMissed: false,
    );
    expect(resets, 0);
  });

  testWidgets('the notice is a live region with a header title', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await pumpNotice(
      tester,
      const ConversationSecurity(
        state: ConversationEncryptionState.waitingForDevice,
        canSend: false,
      ),
    );
    final node = tester.getSemantics(find.text(kStateWaitingTitle));
    expect(node.flagsCollection.isHeader, isTrue);
    handle.dispose();
  });
}
