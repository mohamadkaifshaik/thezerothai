import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/vault/vault_status.dart';
import 'package:dzeroth/features/messages/domain/e2ee/encryption_device.dart';
import 'package:dzeroth/features/messages/domain/messaging_feature_flag.dart';
import 'package:dzeroth/features/messages/presentation/e2ee/encryption_copy.dart';
import 'package:dzeroth/features/messages/presentation/e2ee/widgets/claim_headline.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pbenum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';

import '../../../../support/encrypted_inbox_rig.dart';
import '../../../../support/fake_encryption_device.dart';

/// Plan 6 Task 4.A: the claim headline in the Messages inbox header.
void main() {
  const live = {kFeatureClaimLive, kFeatureE2eeRequired};

  setUpAll(() => registerFallbackValue(Folder.FOLDER_INBOX));

  Finder headline() => find.text(kClaimHeadline);
  Finder covers() => find.byKey(ClaimHeadlineBody.coversKey);

  testWidgets('the headline is hidden without claim_live', (tester) async {
    final rig = EncryptedInboxRig(extraFeatures: {kFeatureE2eeRequired});
    await rig.open(tester);
    expect(headline(), findsNothing);
    expect(covers(), findsNothing);
  });

  testWidgets('hidden without e2ee_required', (tester) async {
    final rig = EncryptedInboxRig(extraFeatures: {kFeatureClaimLive});
    await rig.open(tester);
    expect(headline(), findsNothing);
  });

  testWidgets('hidden on iOS', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      final rig = EncryptedInboxRig(extraFeatures: live);
      await rig.open(tester);
      expect(headline(), findsNothing);
      expect(covers(), findsNothing);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('hidden while the vault is unavailable', (tester) async {
    final rig = EncryptedInboxRig(
      extraFeatures: live,
      vaultStatus: VaultStatus.unavailable,
    );
    await rig.open(tester);
    expect(headline(), findsNothing);
    expect(covers(), findsNothing);
  });

  testWidgets('hides at once when the vault stops opening', (tester) async {
    final rig = EncryptedInboxRig(extraFeatures: live);
    await rig.open(tester);
    expect(headline(), findsOneWidget);
    rig.device.vaultStatus.value = VaultStatus.unavailable;
    await tester.pump();
    expect(headline(), findsNothing);
    expect(covers(), findsNothing);
  });

  testWidgets('hidden without the encryption wiring', (tester) async {
    final rig = EncryptedInboxRig(extraFeatures: live, withDevice: false);
    await rig.open(tester);
    expect(headline(), findsNothing);
  });

  for (final (name, size) in const [
    ('phone', Size(400, 800)),
    ('tablet', Size(900, 900)),
    ('desktop', Size(1300, 900)),
  ]) {
    testWidgets('always shown with its covers link ($name)', (tester) async {
      final rig = EncryptedInboxRig(extraFeatures: live);
      await rig.open(tester, size: size);
      expect(tester.takeException(), isNull);
      expect(headline(), findsOneWidget);
      expect(covers(), findsOneWidget);
      expect(
        find.descendant(of: covers(), matching: find.text(kClaimCoversLink)),
        findsOneWidget,
      );
      // Beside the headline: in the same widget, on the same line or the
      // next one.
      final h = tester.getRect(headline());
      final l = tester.getRect(covers());
      expect((l.center.dy - h.center.dy).abs(), lessThan(h.height + l.height));
      expect(
        find.ancestor(of: headline(), matching: find.byType(ClaimHeadlineBody)),
        findsOneWidget,
      );
      expect(
        find.ancestor(of: covers(), matching: find.byType(ClaimHeadlineBody)),
        findsOneWidget,
      );
      await tester.tap(covers());
      await tester.pumpAndSettle();
      expect(rig.pushed, [AppRouter.encryptionAboutPath]);
    });
  }

  testWidgets('always shown with its covers link at text scale 2', (
    tester,
  ) async {
    final rig = EncryptedInboxRig(extraFeatures: live);
    await rig.open(tester, textScale: 2);
    expect(tester.takeException(), isNull);
    expect(headline(), findsOneWidget);
    expect(covers(), findsOneWidget);
  });

  testWidgets('ClaimHeadline alone: no OnboardingBloc means hidden', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Material(
          child: RepositoryProvider<EncryptionDevice>.value(
            value: FakeEncryptionDevice(),
            child: const ClaimHeadline(),
          ),
        ),
      ),
    );
    expect(headline(), findsNothing);
  });
}
