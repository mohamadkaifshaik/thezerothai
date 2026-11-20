import 'package:dzeroth/core/vault/vault_status.dart';
import 'package:dzeroth/features/messages/domain/e2ee/encrypted_messaging.dart';
import 'package:dzeroth/features/messages/domain/e2ee/encryption_device.dart';
import 'package:dzeroth/features/messages/domain/messaging_feature_flag.dart';
import 'package:dzeroth/features/messages/presentation/e2ee/encryption_copy.dart';
import 'package:dzeroth/features/messages/presentation/e2ee/encryption_status.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:dzeroth/features/messages/presentation/e2ee/encryption_status_banner.dart';
import 'package:dzeroth/features/messages/presentation/widgets/conversation_row.dart';
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pbenum.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../../support/encrypted_inbox_rig.dart';
import '../../../../support/fake_encrypted_messaging.dart';
import '../../../../support/fake_encryption_device.dart';
import '../../../../support/messaging_flow_rig.dart';
import '../../../../support/messaging_fixtures.dart';

/// The inbox with the status banner and encrypted rows at the three looks
/// (phone, tablet, desktop), at text scale 2.0 and once right-to-left. A
/// layout exception fails the test on its own.
void main() {
  setUpAll(() => registerFallbackValue(Folder.FOLDER_INBOX));

  for (final width in [390.0, 700.0, 1000.0, 1300.0]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('banner and encrypted rows [${width.toInt()}dp x$scale]', (
        tester,
      ) async {
        final rig = EncryptedInboxRig(vaultStatus: VaultStatus.keyLost);
        rig.port.setPreviews({
          'a': const ConversationPreview(
            kind: PreviewKind.text,
            text:
                'a very long preview line that must clamp to a single line '
                'at every width and every text scale without overflow',
            mine: true,
          ),
          'b': const ConversationPreview(kind: PreviewKind.undecryptable),
        });
        rig.stub(
          network: [
            conv('a', snippet: '')..lastMessage.encrypted = true,
            conv('b', snippet: '')..lastMessage.encrypted = true,
            conv('c', snippet: '')..lastMessage.encrypted = true,
          ],
        );
        await rig.open(tester, size: Size(width, 900), textScale: scale);

        expect(find.byType(EncryptionStatusBanner), findsOneWidget);
        expect(find.text(kStatusDetails), findsOneWidget);
        expect(find.byType(ConversationRow), findsNWidgets(3));
        expect(find.text(kCouldNotDecryptText), findsOneWidget);
        expect(find.text(kEncryptedPlaceholderText), findsOneWidget);

        // The banner sits in the list column: inside the rows' own width.
        final banner = tester.getRect(find.byType(EncryptionStatusBanner));
        final row = tester.getRect(find.byType(ConversationRow).first);
        expect(banner.left, greaterThanOrEqualTo(row.left));
        expect(banner.right, lessThanOrEqualTo(row.right));
        expect(banner.bottom, lessThanOrEqualTo(row.top));
      });
    }
  }

  // The real shell, hoisted lists: one banner in the list column at every
  // width (band B has a list pane beside the detail placeholder).
  for (final width in [390.0, 700.0, 1000.0, 1300.0]) {
    testWidgets('the real shell shows one banner [${width.toInt()}dp]', (
      tester,
    ) async {
      final port = FakeEncryptedMessaging();
      addTearDown(port.dispose);
      final device = FakeEncryptionDevice(status: VaultStatus.keyLost);
      final status = EncryptionStatusCubit(
        device: device,
        messaging: port,
        flagOn: () => true,
      );
      addTearDown(status.close);
      final rig = MessagingFlowRig(
        server: MessagingFlowRig.serverWithConversation(),
        flags: {'graph', 'messaging', 'ui_shell', kFeatureE2eeDm},
      );
      await rig.pump(
        tester,
        size: Size(width, 900),
        hoisted: true,
        extraProviders: [
          RepositoryProvider<EncryptionDevice>.value(value: device),
          RepositoryProvider<EncryptedMessaging?>.value(value: port),
        ],
        extraBlocs: [BlocProvider<EncryptionStatusCubit>.value(value: status)],
      );

      expect(find.byType(EncryptionStatusBanner), findsOneWidget);
      expect(find.text(kStatusDetails), findsOneWidget);
      expect(find.text('hello from sam'), findsOneWidget);
    });
  }

  testWidgets('right-to-left: the banner and the rows lay out', (tester) async {
    final rig = EncryptedInboxRig(vaultStatus: VaultStatus.keyLost);
    rig.port.setPreviews({
      'a': const ConversationPreview(kind: PreviewKind.text, text: 'مرحبا'),
    });
    rig.stub(network: [conv('a', snippet: '')..lastMessage.encrypted = true]);
    await rig.open(
      tester,
      size: const Size(700, 900),
      textScale: 2,
      textDirection: TextDirection.rtl,
    );

    expect(find.byType(EncryptionStatusBanner), findsOneWidget);
    expect(find.text('مرحبا'), findsOneWidget);
  });
}
