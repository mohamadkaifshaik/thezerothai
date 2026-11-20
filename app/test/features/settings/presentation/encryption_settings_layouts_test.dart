import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/vault/vault_status.dart';
import 'package:dzeroth/features/messages/domain/e2ee/encrypted_messaging.dart';
import 'package:dzeroth/features/messages/domain/messaging_feature_flag.dart';
import 'package:dzeroth/features/messages/presentation/e2ee/encryption_copy.dart';
import 'package:dzeroth/features/settings/presentation/widgets/own_device_row.dart';
import 'package:dzeroth/shared/widgets/primitives/settings_group.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../../support/fake_encrypted_messaging.dart';
import '../../../support/fake_encryption_device.dart';
import '../../../support/settings_tablet_rig.dart';

/// The Encrypted messages page and its Settings row at the three looks
/// (phone, tablet bands A and B, desktop), light and dark.
void main() {
  late FakeEncryptionDevice device;
  late FakeEncryptedMessaging port;

  final flagsOn = {...kSettingsTabletFlags, kFeatureE2eeDm};

  setUp(() {
    device = FakeEncryptionDevice();
    port = FakeEncryptedMessaging()
      ..setOwnDevices(
        OwnDeviceList(
          devices: [
            const OwnDevice(
              ref: 'ref-mine',
              thisDevice: true,
              inConversations: true,
            ),
            OwnDevice(
              ref: 'ref-a',
              thisDevice: false,
              addedAt: DateTime.now().subtract(const Duration(days: 50)),
              lastSeenAt: DateTime.now().subtract(const Duration(days: 1)),
              inConversations: true,
            ),
          ],
        ),
      );
  });

  for (final brightness in [Brightness.light, Brightness.dark]) {
    for (final (name, width) in const [
      ('phone', 390.0),
      ('tablet band A', 700.0),
      ('tablet band B', 1000.0),
      ('desktop', 1300.0),
    ]) {
      testWidgets('the page at $name, ${brightness.name}', (tester) async {
        final rig = SettingsTabletRig();
        await rig.pump(
          tester,
          width: width,
          height: 1800,
          location: AppRouter.encryptionSettingsPath,
          flags: flagsOn,
          brightness: brightness,
          encryptionDevice: device,
          encryptedMessaging: port,
        );
        expect(tester.takeException(), isNull);
        expect(find.text(kEncryptionSettingsTitle), findsWidgets);
        expect(find.text(kDevicesOthersHeader), findsOneWidget);
        // The leaf belongs to Privacy & safety: beside its list from 840 dp,
        // a full page below it.
        if (width >= 840) {
          expect(findCategoriesPane(), findsOneWidget);
          expect(selectedInCategoriesPane(tester), 'Privacy & safety');
        } else {
          expect(findCategoriesPane(), findsNothing);
        }
        // The readable column: 680 on the tablet layouts, 600 on the phone.
        for (final row in tester.widgetList(find.byType(OwnDeviceRow))) {
          final size = tester.getSize(find.byWidget(row));
          expect(size.width, lessThanOrEqualTo(680));
        }
        expect(port.calls.where((c) => c == 'ownDevices'), hasLength(1));
      });
    }
  }

  group('the Settings row', () {
    Future<void> pumpAt(
      WidgetTester tester,
      double width, {
      required Set<String> flags,
      bool vaultKnown = true,
      VaultStatus status = VaultStatus.ready,
      bool withDevice = true,
    }) async {
      device
        ..vaultKnown = vaultKnown
        ..vaultStatus.value = status;
      await SettingsTabletRig().pump(
        tester,
        width: width,
        height: 1800,
        location: width < 600 ? AppRouter.settingsPath : '/settings?c=privacy',
        flags: flags,
        encryptionDevice: withDevice ? device : null,
        encryptedMessaging: port,
      );
    }

    Finder row() => find.widgetWithText(SettingsRow, kEncryptionSettingsTitle);

    for (final width in const [390.0, 700.0, 1000.0, 1300.0]) {
      testWidgets('full: present at ${width.toInt()} dp', (tester) async {
        await pumpAt(tester, width, flags: flagsOn);
        expect(row(), findsOneWidget);
        expect(port.calls, isEmpty, reason: 'the list makes no device call');
      });

      testWidgets('manage: present at ${width.toInt()} dp', (tester) async {
        await pumpAt(tester, width, flags: kSettingsTabletFlags);
        expect(row(), findsOneWidget);
      });

      testWidgets('hidden: absent at ${width.toInt()} dp', (tester) async {
        await pumpAt(
          tester,
          width,
          flags: kSettingsTabletFlags,
          vaultKnown: false,
        );
        expect(row(), findsNothing);
      });

      testWidgets('unsupported: absent at ${width.toInt()} dp', (tester) async {
        await pumpAt(
          tester,
          width,
          flags: flagsOn,
          status: VaultStatus.unsupported,
        );
        expect(row(), findsNothing);
      });

      testWidgets('no provider: absent at ${width.toInt()} dp', (tester) async {
        await pumpAt(tester, width, flags: flagsOn, withDevice: false);
        expect(row(), findsNothing);
      });
    }

    testWidgets('a blocking status is the subtitle', (tester) async {
      await pumpAt(tester, 390, flags: flagsOn, status: VaultStatus.keyLost);
      expect(find.text(kStatusKeyLostTitle), findsOneWidget);
    });

    testWidgets('tapping the row opens the page', (tester) async {
      final rig = SettingsTabletRig();
      device.vaultKnown = true;
      await rig.pump(
        tester,
        width: 390,
        height: 1800,
        flags: flagsOn,
        encryptionDevice: device,
        encryptedMessaging: port,
      );
      await tester.tap(row());
      await tester.pumpAndSettle();
      expect(rig.uri.path, AppRouter.encryptionSettingsPath);
      expect(find.text(kDevicesOthersHeader), findsOneWidget);
    });
  });
}
