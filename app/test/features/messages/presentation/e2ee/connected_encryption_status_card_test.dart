import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/app/session_wiring.dart' show UnexpectedErrorReporter;
import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/core/vault/vault_status.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_event.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_state.dart';
import 'package:dzeroth/features/keys/domain/device_keys_service.dart'
    show DeviceKeysStatus;
import 'package:dzeroth/features/messages/domain/e2ee/encrypted_messaging.dart';
import 'package:dzeroth/features/messages/presentation/e2ee/connected_encryption_status_card.dart';
import 'package:dzeroth/features/messages/presentation/e2ee/encryption_copy.dart';
import 'package:dzeroth/features/messages/presentation/e2ee/encryption_status.dart';
import 'package:dzeroth/shared/widgets/primitives/app_dialog.dart';
import 'package:dzeroth/shared/widgets/primitives/app_pill_button.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';

import '../../../../support/fake_encrypted_messaging.dart';
import '../../../../support/fake_encryption_device.dart';

class _MockAuthBloc extends MockBloc<AuthEvent, AuthState>
    implements AuthBloc {}

/// A port whose three device calls wait for the test.
class _SlowMessaging extends FakeEncryptedMessaging {
  Completer<void> gate = Completer<void>();

  @override
  Future<void> checkRemovedAgain() async {
    await super.checkRemovedAgain();
    await gate.future;
  }

  @override
  Future<void> setUpDeviceAgain() async {
    await super.setUpDeviceAgain();
    await gate.future;
  }
}

void main() {
  late FakeEncryptionDevice device;
  late FakeEncryptedMessaging messaging;
  late _MockAuthBloc auth;
  late List<Object> reported;
  late List<String> pushed;

  setUpAll(() => registerFallbackValue(const AuthSignOutRequested()));

  setUp(() {
    device = FakeEncryptionDevice();
    messaging = FakeEncryptedMessaging();
    auth = _MockAuthBloc();
    whenListen(
      auth,
      const Stream<AuthState>.empty(),
      initialState: const AuthState(status: AuthStatus.unauthenticated),
    );
    reported = [];
    pushed = [];
  });

  Future<EncryptionStatusCubit> pump(
    WidgetTester tester, {
    EncryptedMessaging? port,
    bool withPort = true,
    bool showManageDevices = true,
    bool showReset = true,
    bool withCubit = true,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 1600);
    addTearDown(tester.view.reset);
    final cubit = EncryptionStatusCubit(
      device: device,
      messaging: withPort ? (port ?? messaging) : null,
      flagOn: () => true,
    );
    addTearDown(cubit.close);
    Widget page(BuildContext context) => Scaffold(
      body: SingleChildScrollView(
        child: ConnectedEncryptionStatusCard(
          showManageDevices: showManageDevices,
          showReset: showReset,
        ),
      ),
    );
    final router = GoRouter(
      routes: [
        GoRoute(path: '/', builder: (c, _) => page(c)),
        for (final path in [
          AppRouter.encryptionSettingsPath,
          AppRouter.resetEncryptionPath,
        ])
          GoRoute(
            path: path,
            builder: (c, _) {
              pushed.add(path);
              return const Scaffold(body: Text('stub'));
            },
          ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: [
          BlocProvider<AuthBloc>.value(value: auth),
          if (withCubit)
            BlocProvider<EncryptionStatusCubit>.value(value: cubit),
          if (withPort)
            RepositoryProvider<EncryptedMessaging?>.value(
              value: port ?? messaging,
            ),
          RepositoryProvider<UnexpectedErrorReporter?>.value(
            value: (e, _) => reported.add(e),
          ),
        ],
        child: MaterialApp.router(
          theme: buildAppTheme(brightness: Brightness.light),
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();
    return cubit;
  }

  Finder button(String label) => find.widgetWithText(AppPillButton, label);

  Future<void> tap(WidgetTester tester, String label) async {
    await tester.tap(button(label));
    await tester.pump();
  }

  testWidgets('Try again calls the cubit retry once', (tester) async {
    device.vaultStatus.value = VaultStatus.unavailable;
    await pump(tester);
    await tap(tester, kStatusTryAgain);
    expect(device.retryOpenCalls, 1);
  });

  testWidgets('Check again calls the port once', (tester) async {
    messaging.removedElsewhere.value = true;
    await pump(tester);
    await tap(tester, kStatusCheckAgain);
    await tester.pumpAndSettle();
    expect(messaging.checkRemovedAgainCalls, 1);
    expect(messaging.setUpAgainCalls, 0);
  });

  Finder inDialog(String text) => find.descendant(
    of: find.byType(AppConfirmDialog),
    matching: find.text(text),
  );

  Future<void> confirmSetUp(WidgetTester tester) async {
    await tester.tap(inDialog(kSetUpAgainAction));
    await tester.pumpAndSettle();
  }

  testWidgets('Set up again asks first and calls the port once on confirm', (
    tester,
  ) async {
    messaging.removedElsewhere.value = true;
    await pump(tester);
    await tap(tester, kSetUpAgainAction);
    await tester.pumpAndSettle();
    expect(find.byType(AppConfirmDialog), findsOneWidget);
    expect(inDialog(kSetUpAgainTitle), findsOneWidget);
    expect(inDialog(kSetUpAgainMessage), findsOneWidget);
    expect(inDialog(kSetUpAgainAction), findsOneWidget);
    expect(messaging.setUpAgainCalls, 0, reason: 'nothing before confirm');
    await confirmSetUp(tester);
    expect(messaging.setUpAgainCalls, 1);
    expect(messaging.checkRemovedAgainCalls, 0);
    expect(find.byType(AppConfirmDialog), findsNothing);
  });

  testWidgets('cancelling the set-up-again confirmation makes no call', (
    tester,
  ) async {
    messaging.removedElsewhere.value = true;
    await pump(tester);
    await tap(tester, kSetUpAgainAction);
    await tester.pumpAndSettle();
    await tester.tap(inDialog('Cancel'));
    await tester.pumpAndSettle();
    expect(messaging.setUpAgainCalls, 0);
    // The barrier dismisses it too, and the next tap asks again.
    await tap(tester, kSetUpAgainAction);
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(find.byType(AppConfirmDialog), findsNothing);
    expect(messaging.setUpAgainCalls, 0);
    await tap(tester, kSetUpAgainAction);
    await tester.pumpAndSettle();
    expect(find.byType(AppConfirmDialog), findsOneWidget);
  });

  testWidgets('a dialog that cannot be shown reports a fixed step and makes no '
      'call', (tester) async {
    messaging.removedElsewhere.value = true;
    final cubit = EncryptionStatusCubit(
      device: device,
      messaging: messaging,
      flagOn: () => true,
    );
    addTearDown(cubit.close);
    // No Navigator above the card: showing a dialog throws.
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: MediaQuery(
          data: const MediaQueryData(size: Size(800, 800)),
          child: Theme(
            data: buildAppTheme(brightness: Brightness.light),
            child: Material(
              child: MultiRepositoryProvider(
                providers: [
                  BlocProvider<EncryptionStatusCubit>.value(value: cubit),
                  RepositoryProvider<EncryptedMessaging?>.value(
                    value: messaging,
                  ),
                  RepositoryProvider<UnexpectedErrorReporter?>.value(
                    value: (e, _) => reported.add(e),
                  ),
                ],
                child: const ConnectedEncryptionStatusCard(),
              ),
            ),
          ),
        ),
      ),
    );
    await tap(tester, kSetUpAgainAction);
    await tester.pump();
    expect(messaging.setUpAgainCalls, 0);
    expect(reported, hasLength(1));
    expect(reported.single.toString(), 'Bad state: setUpAgainConfirm');
    // The next tap asks (and fails) again.
    await tap(tester, kSetUpAgainAction);
    await tester.pump();
    expect(reported, hasLength(2));
    expect(messaging.setUpAgainCalls, 0);
  });

  testWidgets('Sign out goes through requestSignOut', (tester) async {
    messaging.removedElsewhere.value = true;
    await pump(tester);
    await tap(tester, kSignOutVaultLabel);
    await tester.pumpAndSettle();
    verify(() => auth.add(any(that: isA<AuthSignOutRequested>()))).called(1);
  });

  testWidgets('Reset opens the reset path', (tester) async {
    device.vaultStatus.value = VaultStatus.keyLost;
    await pump(tester);
    await tap(tester, kStatusReset);
    await tester.pumpAndSettle();
    expect(pushed, [AppRouter.resetEncryptionPath]);
  });

  testWidgets('Manage devices opens the encryption settings path', (
    tester,
  ) async {
    device.deviceKeys.value = DeviceKeysStatus.deviceLimitReached;
    await pump(tester);
    await tap(tester, kStatusManageDevices);
    await tester.pumpAndSettle();
    expect(pushed, [AppRouter.encryptionSettingsPath]);
  });

  testWidgets('optional parameters hide Manage devices and Reset', (
    tester,
  ) async {
    device.vaultStatus.value = VaultStatus.keyLost;
    await pump(tester, showReset: false);
    expect(button(kStatusReset), findsNothing);
    expect(button(kStatusTryAgain), findsOneWidget);
  });

  testWidgets('Check again is always offered on a removed-elsewhere card when '
      'a port exists', (tester) async {
    messaging.removedElsewhere.value = true;
    device.flag = E2eeFlag.off; // mayStart false: no Set up again
    await pump(tester);
    expect(button(kStatusCheckAgain), findsOneWidget);
    expect(button(kSetUpAgainAction), findsNothing);
  });

  testWidgets('a double tap makes one call', (tester) async {
    final slow = _SlowMessaging();
    slow.removedElsewhere.value = true;
    await pump(tester, port: slow);
    await tap(tester, kStatusCheckAgain);
    await tap(tester, kStatusCheckAgain);
    expect(slow.checkRemovedAgainCalls, 1);
    slow.gate.complete();
    await tester.pumpAndSettle();
    // Once finished a new tap calls again.
    await tap(tester, kStatusCheckAgain);
    expect(slow.checkRemovedAgainCalls, 2);
    slow.gate = Completer<void>();
    await tap(tester, kSetUpAgainAction);
    await tester.pumpAndSettle();
    await confirmSetUp(tester);
    expect(slow.setUpAgainCalls, 1);
    // In flight: another tap does nothing (no second dialog, no second call).
    await tap(tester, kSetUpAgainAction);
    await tester.pumpAndSettle();
    expect(find.byType(AppConfirmDialog), findsNothing);
    expect(slow.setUpAgainCalls, 1);
    slow.gate.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('a failing port call is reported once with the fixed step and '
      'leaves the card usable', (tester) async {
    messaging.removedElsewhere.value = true;
    messaging.failNextOn('checkRemovedAgain', Exception('secret detail'));
    await pump(tester);
    await tap(tester, kStatusCheckAgain);
    await tester.pumpAndSettle();
    expect(reported, hasLength(1));
    expect(reported.single, isA<StateError>());
    expect(reported.single.toString(), 'Bad state: checkRemovedAgain');
    expect(find.textContaining('secret'), findsNothing);
    expect(button(kStatusCheckAgain), findsOneWidget);
    await tap(tester, kStatusCheckAgain);
    await tester.pumpAndSettle();
    expect(messaging.checkRemovedAgainCalls, 2);
    expect(reported, hasLength(1));

    messaging.failNextOn('setUpDeviceAgain', Exception('secret detail'));
    await tap(tester, kSetUpAgainAction);
    await tester.pumpAndSettle();
    await confirmSetUp(tester);
    expect(reported, hasLength(2));
    expect(reported.last.toString(), 'Bad state: setUpDeviceAgain');
  });

  testWidgets('no port: the card still renders with the remaining buttons', (
    tester,
  ) async {
    device.vaultStatus.value = VaultStatus.keyLost;
    await pump(tester, withPort: false);
    expect(button(kStatusTryAgain), findsOneWidget);
    expect(button(kStatusReset), findsOneWidget);
    expect(button(kStatusCheckAgain), findsNothing);
    expect(button(kSetUpAgainAction), findsNothing);
  });

  testWidgets('no cubit in the tree draws nothing', (tester) async {
    await pump(tester, withCubit: false);
    expect(find.byType(AppPillButton), findsNothing);
    expect(find.byType(Text), findsNothing);
  });
}
