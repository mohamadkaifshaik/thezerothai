import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/features/settings/presentation/bloc/encryption_devices_cubit.dart';
import 'package:dzeroth/shared/widgets/primitives/settings_group.dart';
import 'package:dzeroth/app/session_wiring.dart' show UnexpectedErrorReporter;
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/core/vault/vault_status.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_event.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_state.dart';
import 'package:dzeroth/features/keys/domain/device_keys_service.dart'
    show DeviceKeysStatus;
import 'package:dzeroth/features/messages/domain/e2ee/encrypted_messaging.dart';
import 'package:dzeroth/features/messages/domain/e2ee/encryption_device.dart';
import 'package:dzeroth/features/messages/domain/messaging_feature_flag.dart';
import 'package:dzeroth/features/messages/presentation/e2ee/encryption_copy.dart';
import 'package:dzeroth/features/messages/presentation/e2ee/encryption_status.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/settings/presentation/encryption_settings_screen.dart';
import 'package:dzeroth/shared/widgets/primitives/app_dialog.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';

import '../../../support/fake_encrypted_messaging.dart';
import '../../../support/fake_encryption_device.dart';
import '../../../support/settings_tablet_rig.dart';

class _MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

class _MockAuthBloc extends MockBloc<AuthEvent, AuthState>
    implements AuthBloc {}

// Relative to the real clock (the screen gets `now: () => _now`): no fixed date.
final _now = DateTime.now().toUtc();
DateTime _daysAgo(int n) => _now.subtract(Duration(days: n));
String _date(DateTime t) => DateFormat.yMMMd().format(t.toLocal());

final _mine = OwnDevice(
  ref: 'ref-mine',
  thisDevice: true,
  addedAt: _daysAgo(19),
  inConversations: true,
);
final _older = OwnDevice(
  ref: 'ref-older',
  thisDevice: false,
  addedAt: _daysAgo(80),
  lastSeenAt: _now.subtract(const Duration(days: 3)),
  inConversations: true,
);
final _newer = OwnDevice(
  ref: 'ref-newer',
  thisDevice: false,
  addedAt: _daysAgo(50),
  lastSeenAt: _now.subtract(const Duration(hours: 5)),
  inConversations: true,
);

Finder _removeButtons() => find.widgetWithText(TextButton, kDeviceRemoveAction);

Finder _inDialog(String text) => find.descendant(
  of: find.byType(AppConfirmDialog),
  matching: find.text(text),
);

void main() {
  late FakeEncryptionDevice device;
  late FakeEncryptedMessaging port;
  late List<Object> reported;

  setUp(() {
    device = FakeEncryptionDevice();
    port = FakeEncryptedMessaging()
      ..setOwnDevices(OwnDeviceList(devices: [_mine, _older, _newer]));
    reported = [];
  });

  Future<void> pump(
    WidgetTester tester, {
    bool flagOn = true,
    bool withPort = true,
    bool withDevice = true,
    bool withStatus = true,
    double textScale = 1,
    double width = 900,
    bool settle = true,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 2400);
    addTearDown(tester.view.reset);
    final onboarding = _MockOnboardingBloc();
    whenListen(
      onboarding,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        status: OnboardingStatus.ready,
        enabledFeatures: {if (flagOn) kFeatureE2eeDm},
      ),
    );
    final auth = _MockAuthBloc();
    whenListen(
      auth,
      const Stream<AuthState>.empty(),
      initialState: const AuthState(status: AuthStatus.unauthenticated),
    );
    final status = EncryptionStatusCubit(
      device: device,
      messaging: withPort ? port : null,
      flagOn: () => flagOn,
    );
    addTearDown(status.close);
    await tester.pumpWidget(
      MultiBlocProvider(
        providers: [
          BlocProvider<OnboardingBloc>.value(value: onboarding),
          BlocProvider<AuthBloc>.value(value: auth),
          if (withStatus)
            BlocProvider<EncryptionStatusCubit>.value(value: status),
        ],
        child: MultiRepositoryProvider(
          providers: [
            if (withDevice)
              RepositoryProvider<EncryptionDevice>.value(value: device),
            RepositoryProvider<EncryptedMessaging?>.value(
              value: withPort ? port : null,
            ),
            RepositoryProvider<UnexpectedErrorReporter?>.value(
              value: (e, _) => reported.add(e),
            ),
          ],
          child: MaterialApp(
            theme: buildAppTheme(brightness: Brightness.light),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(textScale)),
              child: child!,
            ),
            home: EncryptionSettingsScreen(now: () => _now),
          ),
        ),
      ),
    );
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
    }
  }

  /// Taps Remove on the first row and confirms; one frame, no settle (the
  /// spinner never settles).
  Future<void> confirmRemoveFirst(WidgetTester tester) async {
    await tester.tap(_removeButtons().first);
    await tester.pumpAndSettle();
    await tester.tap(_inDialog(kDeviceRemoveAction));
    await tester.pump();
    await tester.pump();
  }

  /// The Settings list itself (the page under the row), for the access tests:
  /// the row lives in the Settings screen, not on this page.
  Future<void> pumpSettingsRow(
    WidgetTester tester, {
    required bool flagOn,
  }) async {
    await SettingsTabletRig().pump(
      tester,
      width: 390,
      height: 1800,
      flags: flagOn
          ? {...kSettingsTabletFlags, kFeatureE2eeDm}
          : kSettingsTabletFlags,
      encryptionDevice: device,
      encryptedMessaging: port,
    );
  }

  Finder settingsRow() =>
      find.widgetWithText(SettingsRow, kEncryptionSettingsTitle);

  void manageAccess() {
    device.flag = E2eeFlag.off;
  }

  group('access', () {
    testWidgets(
      'access hidden: no Settings row and the route shows the unavailable headline, no port call',
      (tester) async {
        device.vaultKnown = false;
        await pump(tester, flagOn: false);
        expect(find.text(kEncryptionSettingsUnavailableTitle), findsOneWidget);
        expect(find.text(kEncryptionSettingsUnavailableBody), findsOneWidget);
        expect(port.calls, isEmpty);
        await pumpSettingsRow(tester, flagOn: false);
        expect(settingsRow(), findsNothing);
        expect(port.calls, isEmpty);
      },
    );

    testWidgets('access unsupported: the same', (tester) async {
      device.vaultStatus.value = VaultStatus.unsupported;
      await pump(tester);
      expect(find.text(kEncryptionSettingsUnavailableTitle), findsOneWidget);
      expect(port.calls, isEmpty);
    });

    testWidgets('no EncryptionDevice in the tree: the same, no call', (
      tester,
    ) async {
      await pump(tester, withDevice: false);
      expect(find.text(kEncryptionSettingsUnavailableTitle), findsOneWidget);
      expect(port.calls, isEmpty);
    });

    testWidgets(
      'access manage: row and page exist, Remove works, no Set up again',
      (tester) async {
        manageAccess();
        await pump(tester, flagOn: false);
        expect(find.text(kEncryptionSettingsUnavailableTitle), findsNothing);
        expect(find.text(kDevicesOthersHeader), findsOneWidget);
        expect(find.text(kSetUpAgainAction), findsNothing);
        await tester.tap(_removeButtons().first);
        await tester.pumpAndSettle();
        await tester.tap(_inDialog(kDeviceRemoveAction));
        await tester.pumpAndSettle();
        expect(port.removedDevices, ['ref-older']);
        expect(find.text(kDeviceRemovedText), findsOneWidget);
        // Manage access never starts encryption: no retry, no set up.
        expect(port.retryDeviceSetupCalls, 0);
        expect(port.setUpAgainCalls, 0);
        await pumpSettingsRow(tester, flagOn: false);
        expect(settingsRow(), findsOneWidget);
      },
    );

    testWidgets('no port: the card and About only, no device call', (
      tester,
    ) async {
      await pump(tester, withPort: false);
      expect(find.text(kDevicesOthersHeader), findsNothing);
      expect(find.text(kDevicesAboutHeader), findsOneWidget);
      expect(port.calls, isEmpty);
    });
  });

  group('device rows', () {
    testWidgets(
      'this device first, others oldest first, count "3 of 5 devices"',
      (tester) async {
        await pump(tester);
        // The group header and the row title are the same words.
        expect(find.text(kDeviceThisTitle), findsNWidgets(2));
        expect(find.text(deviceAddedSubtitle(_date(_mine.addedAt!))), findsOne);
        expect(find.text(devicesCount(3)), findsOneWidget);
        final older = tester.getTopLeft(
          find.text(deviceAddedTitle(_date(_older.addedAt!))),
        );
        final newer = tester.getTopLeft(
          find.text(deviceAddedTitle(_date(_newer.addedAt!))),
        );
        final self = tester.getTopLeft(find.text(kDeviceThisTitle).last);
        expect(self.dy, lessThan(older.dy));
        expect(older.dy, lessThan(newer.dy));
        expect(find.text('Last active 3 days ago'), findsOneWidget);
      },
    );

    testWidgets(
      'an inactive device says "Not used for 30 days" and still has Remove',
      (tester) async {
        port.setOwnDevices(
          OwnDeviceList(
            devices: [
              _mine,
              OwnDevice(
                ref: 'ref-old',
                thisDevice: false,
                addedAt: _daysAgo(300),
                inactive: true,
              ),
            ],
          ),
        );
        await pump(tester);
        expect(find.text(kDeviceInactive), findsOneWidget);
        expect(find.text(kDeviceRemovedText), findsNothing);
        expect(_removeButtons(), findsOneWidget);
      },
    );

    testWidgets(
      'a device in conversations but not in the directory shows the warning pill and note and no Remove',
      (tester) async {
        port.setOwnDevices(
          OwnDeviceList(
            devices: [
              _mine,
              OwnDevice(
                ref: 'ref-ghost',
                thisDevice: false,
                inDirectory: false,
                inConversations: true,
              ),
            ],
          ),
        );
        await pump(tester);
        expect(find.text(kDeviceUnlistedPill), findsOneWidget);
        expect(find.text(kDeviceUnlistedNote), findsOneWidget);
        expect(find.text(kDeviceUnknownDate), findsOneWidget);
        expect(_removeButtons(), findsNothing);
      },
    );

    testWidgets(
      'a device in the directory but in no conversation shows the neutral pill',
      (tester) async {
        port.setOwnDevices(
          OwnDeviceList(
            devices: [
              _mine,
              OwnDevice(
                ref: 'ref-new',
                thisDevice: false,
                addedAt: _daysAgo(1),
              ),
            ],
          ),
        );
        await pump(tester);
        expect(find.text(kDeviceNotJoinedPill), findsOneWidget);
        expect(_removeButtons(), findsOneWidget);
      },
    );

    testWidgets('this device has no Remove', (tester) async {
      port.setOwnDevices(OwnDeviceList(devices: [_mine]));
      await pump(tester);
      expect(_removeButtons(), findsNothing);
      expect(find.text(kDevicesNoOthers), findsOneWidget);
    });

    testWidgets('this device not in the directory nor in conversations', (
      tester,
    ) async {
      port.setOwnDevices(const OwnDeviceList());
      await pump(tester);
      expect(find.text(kDeviceNotSetUp), findsOneWidget);
    });

    testWidgets('no device id appears anywhere on the page', (tester) async {
      await pump(tester);
      for (final text in tester.widgetList<Text>(find.byType(Text))) {
        expect(text.data ?? '', isNot(contains('ref-')));
      }
      expect(find.bySemanticsLabel(RegExp('ref-')), findsNothing);
    });
  });

  group('removal', () {
    testWidgets(
      'Remove asks with the exact R17 sentence, calls the port only on confirm and shows "Device removed"',
      (tester) async {
        await pump(tester);
        await tester.tap(_removeButtons().first);
        await tester.pumpAndSettle();
        expect(find.text(kDeviceRemoveTitle), findsOneWidget);
        expect(find.text(kDeviceRemoveMessage), findsOneWidget);
        expect(
          kDeviceRemoveMessage,
          contains(
            'Until each conversation has been updated, that device may still receive and send messages.',
          ),
        );
        expect(port.removedDevices, isEmpty);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(port.removedDevices, isEmpty);
        await tester.tap(_removeButtons().first);
        await tester.pumpAndSettle();
        await tester.tap(_inDialog(kDeviceRemoveAction));
        await tester.pumpAndSettle();
        expect(port.removedDevices, ['ref-older']);
        expect(find.text(kDeviceRemovedText), findsOneWidget);
        expect(port.calls.where((c) => c == 'ownDevices'), hasLength(2));
      },
    );

    for (final (name, error) in <(String, Object)>[
      ('a typed refusal', const UnknownApiException('x')),
      ('a network error', const NetworkException('x')),
    ]) {
      testWidgets(
        'removal failure says the device can still read and send, and names block and reset ($name)',
        (tester) async {
          await pump(tester);
          port.failNextOn('removeDevice', error);
          await tester.tap(_removeButtons().first);
          await tester.pumpAndSettle();
          await tester.tap(_inDialog(kDeviceRemoveAction));
          await tester.pumpAndSettle();
          expect(find.text(kDeviceRemoveFailedText), findsOneWidget);
          expect(kDeviceRemoveFailedText, contains('can still read and send'));
          expect(kDeviceRemoveFailedText, contains('block the person'));
          expect(kDeviceRemoveFailedText, contains('reset encryption'));
          expect(find.text(kDeviceRemovedText), findsNothing);
          expect(_removeButtons(), findsNWidgets(2));
        },
      );
    }

    testWidgets('removalsPending 12 shows the count and the note', (
      tester,
    ) async {
      port.removalsPending.value = 12;
      await pump(tester);
      expect(find.text('12 conversations still to update'), findsOneWidget);
      expect(find.text(kRemovalsNote), findsOneWidget);
    });

    testWidgets('removalsPending 1 uses the singular', (tester) async {
      port.removalsPending.value = 1;
      await pump(tester);
      expect(find.text('1 conversation still to update'), findsOneWidget);
    });

    testWidgets('removalsPending 0 shows no progress line', (tester) async {
      await pump(tester);
      expect(find.text(kRemovalsNote), findsNothing);
    });
  });

  group('list reading', () {
    testWidgets(
      'directoryKnown false says the list could not be read, with Try again, and shows no false warning',
      (tester) async {
        port.setOwnDevices(
          OwnDeviceList(
            devices: [_mine, _older.copyForTest(inDirectory: false)],
            directoryKnown: false,
          ),
        );
        await pump(tester);
        expect(find.text(kDevicesLoadFailed), findsOneWidget);
        expect(find.text(kStatusTryAgain), findsOneWidget);
        // The port cannot say why, so never the offline note.
        expect(find.text(kDevicesOfflineNote), findsNothing);
        expect(find.text(kDeviceThisTitle), findsNWidgets(2));
        expect(find.textContaining('of 5 devices'), findsNothing);
        // A device the directory could not confirm is not "unlisted".
        expect(find.text(kDeviceUnlistedPill), findsNothing);
        expect(find.text(kDeviceUnlistedNote), findsNothing);
        expect(find.text(kDeviceNotSetUp), findsNothing);
      },
    );

    testWidgets(
      'directoryKnown false with this device missing from the list does not say "Not set up"',
      (tester) async {
        port.setOwnDevices(const OwnDeviceList(directoryKnown: false));
        await pump(tester);
        expect(find.text(kDeviceNotSetUp), findsNothing);
        expect(find.text(kDeviceUnlistedPill), findsNothing);
      },
    );

    testWidgets('no other device shows Remove while the directory is unread', (
      tester,
    ) async {
      port.setOwnDevices(
        OwnDeviceList(devices: [_mine, _older, _newer], directoryKnown: false),
      );
      await pump(tester);
      expect(_removeButtons(), findsNothing);
    });

    testWidgets('Try again reads the list again', (tester) async {
      port.setOwnDevices(
        OwnDeviceList(devices: [_mine, _older], directoryKnown: false),
      );
      await pump(tester);
      port.setOwnDevices(OwnDeviceList(devices: [_mine, _older]));
      await tester.tap(find.text(kStatusTryAgain));
      await tester.pumpAndSettle();
      expect(find.text(kDevicesLoadFailed), findsNothing);
      expect(_removeButtons(), findsOneWidget);
    });

    testWidgets('a rate-limited answer shows no warning', (tester) async {
      await pump(tester);
      expect(find.text(kDevicesOfflineNote), findsNothing);
      expect(find.text(kDevicesLoadFailed), findsNothing);
    });

    testWidgets('ownDevices throwing shows the error view with Retry', (
      tester,
    ) async {
      port.failNextOn('ownDevices', const NetworkException('x'));
      await pump(tester);
      expect(find.text('Retry'), findsOneWidget);
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text(kDevicesOthersHeader), findsOneWidget);
    });
  });

  group('status', () {
    testWidgets(
      'deviceLimitReached shows the card and five rows, and removing one calls retryDeviceSetup',
      (tester) async {
        device.deviceKeys.value = DeviceKeysStatus.deviceLimitReached;
        port.setOwnDevices(
          OwnDeviceList(
            devices: [
              _mine,
              for (var i = 0; i < 4; i++)
                OwnDevice(
                  ref: 'ref-$i',
                  thisDevice: false,
                  addedAt: _daysAgo(100 + i),
                  inConversations: true,
                ),
            ],
          ),
        );
        await pump(tester);
        expect(find.text(kStatusDeviceLimitTitle), findsOneWidget);
        expect(find.text(devicesCount(5)), findsOneWidget);
        expect(_removeButtons(), findsNWidgets(4));
        await tester.tap(_removeButtons().first);
        await tester.pumpAndSettle();
        await tester.tap(_inDialog(kDeviceRemoveAction));
        await tester.pumpAndSettle();
        expect(port.retryDeviceSetupCalls, 1);
      },
    );

    testWidgets(
      'removedElsewhere shows the card with Set up again, Check again and Sign out and hides the device groups',
      (tester) async {
        port.removedElsewhere.value = true;
        await pump(tester);
        expect(find.text(kStatusRemovedTitle), findsOneWidget);
        expect(find.text(kSetUpAgainAction), findsOneWidget);
        expect(find.text(kStatusCheckAgain), findsOneWidget);
        expect(find.text(kSignOutVaultLabel), findsOneWidget);
        expect(find.text(kDevicesThisHeader), findsNothing);
        expect(find.text(kDevicesOthersHeader), findsNothing);
        expect(port.calls, isNot(contains('ownDevices')));
      },
    );

    testWidgets(
      'removedElsewhere with mayStart false has Check again and Sign out only',
      (tester) async {
        manageAccess();
        port.removedElsewhere.value = true;
        await pump(tester, flagOn: false);
        expect(find.text(kSetUpAgainAction), findsNothing);
        expect(find.text(kStatusCheckAgain), findsOneWidget);
        expect(find.text(kSignOutVaultLabel), findsOneWidget);
      },
    );

    testWidgets('Check again calls checkRemovedAgain once and asks nothing', (
      tester,
    ) async {
      port.removedElsewhere.value = true;
      await pump(tester);
      await tester.tap(find.text(kStatusCheckAgain));
      await tester.pumpAndSettle();
      expect(port.checkRemovedAgainCalls, 1);
      expect(find.byType(AppConfirmDialog), findsNothing);
    });

    testWidgets('Set up again asks first and calls the port on confirm', (
      tester,
    ) async {
      port.removedElsewhere.value = true;
      await pump(tester);
      await tester.tap(find.text(kSetUpAgainAction));
      await tester.pumpAndSettle();
      expect(find.text(kSetUpAgainTitle), findsOneWidget);
      expect(port.setUpAgainCalls, 0);
      await tester.tap(_inDialog(kSetUpAgainAction));
      await tester.pumpAndSettle();
      expect(port.setUpAgainCalls, 1);
    });

    testWidgets(
      'vault keyLost: card with Try again and Reset, no device call',
      (tester) async {
        device.vaultStatus.value = VaultStatus.keyLost;
        await pump(tester);
        expect(find.text(kStatusKeyLostTitle), findsOneWidget);
        expect(find.text(kStatusTryAgain), findsOneWidget);
        // Task 12: Reset opens the reset screen.
        expect(find.text(kStatusReset), findsOneWidget);
        expect(find.text(kDevicesThisHeader), findsNothing);
        expect(port.calls, isEmpty);
        expect(find.text(kDevicesAboutHeader), findsOneWidget);
      },
    );
  });

  group('removal in flight', () {
    testWidgets(
      'while a removal is in flight every Remove is disabled and the row shows its spinner',
      (tester) async {
        await pump(tester);
        port.holdRemoveDevice = Completer<void>();
        await confirmRemoveFirst(tester);
        expect(port.removedDevices, ['ref-older']);
        expect(_removeButtons(), findsNothing);
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        port.holdRemoveDevice!.complete();
        await tester.pumpAndSettle();
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(find.text(kDeviceRemovedText), findsOneWidget);
      },
    );

    testWidgets(
      'the spinner is a disabled node under the row label, not a live announcement',
      (tester) async {
        final handle = tester.ensureSemantics();
        await pump(tester);
        port.holdRemoveDevice = Completer<void>();
        await confirmRemoveFirst(tester);
        final label = deviceRemoveLabel(_date(_older.addedAt!));
        final node = find.bySemanticsLabel(label);
        expect(node, findsOneWidget);
        expect(
          tester.getSemantics(node),
          isSemantics(
            label: label,
            isButton: true,
            hasEnabledState: true,
            isEnabled: false,
          ),
        );
        expect(
          tester.getSemantics(node),
          isNot(isSemantics(isLiveRegion: true)),
        );
        port.holdRemoveDevice!.complete();
        await tester.pumpAndSettle();
        handle.dispose();
      },
    );

    testWidgets(
      'a second confirm during a removal calls nothing and shows no failure',
      (tester) async {
        await pump(tester);
        // Open the dialog on a row, then a removal starts elsewhere.
        await tester.tap(_removeButtons().last);
        await tester.pumpAndSettle();
        final cubit = BlocProvider.of<EncryptionDevicesCubit>(
          tester.element(find.text(kDevicesOthersHeader)),
        );
        port.holdRemoveDevice = Completer<void>();
        unawaited(cubit.remove('ref-older'));
        await tester.pump();
        final callsBefore = port.calls.length;
        await tester.tap(_inDialog(kDeviceRemoveAction));
        await tester.pump();
        await tester.pump();
        expect(port.calls, hasLength(callsBefore));
        expect(port.removedDevices, ['ref-older']);
        expect(find.text(kDeviceRemoveFailedText), findsNothing);
        expect(find.text(kDeviceRemovedText), findsNothing);
        port.holdRemoveDevice!.complete();
        await tester.pumpAndSettle();
      },
    );

    testWidgets('a removal off the device limit never calls retryDeviceSetup', (
      tester,
    ) async {
      await pump(tester);
      await confirmRemoveFirst(tester);
      await tester.pumpAndSettle();
      expect(port.removedDevices, ['ref-older']);
      expect(port.retryDeviceSetupCalls, 0);
    });

    testWidgets('at the device limit the list is reloaded after the retry', (
      tester,
    ) async {
      device.deviceKeys.value = DeviceKeysStatus.deviceLimitReached;
      await pump(tester);
      port.calls.clear();
      await confirmRemoveFirst(tester);
      await tester.pumpAndSettle();
      expect(port.calls, ['removeDevice', 'retryDeviceSetup', 'ownDevices']);
    });
  });

  group('loading and summary', () {
    testWidgets('the loading placeholder shows while the list is read', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      port.holdOwnDevices = Completer<void>();
      await pump(tester, settle: false);
      expect(find.byType(SettingsGroupPlaceholder), findsOneWidget);
      expect(find.bySemanticsLabel(kDevicesLoading), findsOneWidget);
      expect(find.text(kDevicesOthersHeader), findsNothing);
      port.holdOwnDevices!.complete();
      await tester.pumpAndSettle();
      expect(find.byType(SettingsGroupPlaceholder), findsNothing);
      expect(find.text(kDevicesOthersHeader), findsOneWidget);
      handle.dispose();
    });
  });

  for (final width in const [900.0, 390.0]) {
    testWidgets(
      'text scale 2.0 lays out without overflow at ${width.toInt()} dp',
      (tester) async {
        await pump(tester, textScale: 2, width: width);
        final error = tester.takeException();
        expect(error, isNull, reason: error?.toString());
      },
    );
  }
}

extension on OwnDevice {
  OwnDevice copyForTest({bool? inDirectory}) => OwnDevice(
    ref: ref,
    thisDevice: thisDevice,
    addedAt: addedAt,
    lastSeenAt: lastSeenAt,
    inactive: inactive,
    inDirectory: inDirectory ?? this.inDirectory,
    inConversations: inConversations,
  );
}
