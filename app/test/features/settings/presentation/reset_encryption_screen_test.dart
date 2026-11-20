import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/app/session_wiring.dart' show UnexpectedErrorReporter;
import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/core/vault/vault_session.dart';
import 'package:dzeroth/core/vault/vault_status.dart';
import 'package:dzeroth/features/auth/domain/app_user.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_event.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_state.dart';
import 'package:dzeroth/features/keys/domain/device_keys_service.dart'
    show DeviceKeysStatus;
import 'package:dzeroth/features/messages/presentation/e2ee/encryption_copy.dart';
import 'package:dzeroth/features/messages/presentation/e2ee/encryption_status.dart';
import 'package:dzeroth/features/settings/presentation/reset_encryption_screen.dart';
import 'package:dzeroth/shared/widgets/primitives/app_dialog.dart';
import 'package:dzeroth/shared/widgets/primitives/app_pill_button.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/fake_encrypted_messaging.dart';
import '../../../support/fake_encryption_device.dart';

class _MockVaultSession extends Mock implements VaultSession {}

class _MockAuthBloc extends MockBloc<AuthEvent, AuthState>
    implements AuthBloc {}

AuthState _signedIn(String uid) => AuthState(
  status: AuthStatus.authenticated,
  user: AppUser(
    uid: uid,
    email: 'a@example.com',
    emailVerified: true,
    isPasswordProvider: true,
  ),
);

Finder _action() => find.widgetWithText(AppPillButton, kResetAction);

/// Steps time without waiting for animations to end: a busy spinner and a
/// snackbar's timer never let `pumpAndSettle` finish.
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
  await tester.pump(const Duration(seconds: 1));
}

Finder _inDialog(String text) => find.descendant(
  of: find.byType(AppConfirmDialog),
  matching: find.text(text),
);

void main() {
  late FakeEncryptionDevice device;
  late _MockVaultSession session;
  late List<Object> reported;
  late EncryptionStatusCubit status;
  late GoRouter router;
  late _MockAuthBloc auth;

  setUp(() {
    // A device whose key was lost: the reset is offered, the flag is on.
    device = FakeEncryptionDevice(status: VaultStatus.keyLost);
    session = _MockVaultSession();
    when(() => session.resetByUser()).thenAnswer((_) async => true);
    reported = [];
    auth = _MockAuthBloc();
    when(() => auth.add(any())).thenReturn(null);
    whenListen(
      auth,
      const Stream<AuthState>.empty(),
      initialState: _signedIn('uid-1'),
    );
  });

  setUpAll(() => registerFallbackValue(const AuthSignOutRequested()));

  Future<void> pump(
    WidgetTester tester, {
    bool withStatus = true,
    bool withSession = true,
    bool flagOn = true,
    bool removedElsewhere = false,
    double width = 390,
    // Starts on the encryption page and pushes the reset route over it, so a
    // system back has something to pop to.
    bool pushed = false,
    // The screen sits with no Navigator above it: showDialog throws.
    bool noNavigator = false,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 2400);
    addTearDown(tester.view.reset);
    final port = FakeEncryptedMessaging();
    if (removedElsewhere) port.removedElsewhere.value = true;
    status = EncryptionStatusCubit(
      device: device,
      messaging: port,
      flagOn: () => flagOn,
    );
    addTearDown(status.close);
    if (noNavigator) {
      await tester.pumpWidget(
        MultiRepositoryProvider(
          providers: [
            RepositoryProvider<VaultSession>.value(value: session),
            RepositoryProvider<UnexpectedErrorReporter?>.value(
              value: (e, _) => reported.add(e),
            ),
          ],
          child: BlocProvider<AuthBloc>.value(
            value: auth,
            child: BlocProvider<EncryptionStatusCubit>.value(
              value: status,
              child: MediaQuery(
                data: MediaQueryData(size: Size(width, 2400)),
                child: Theme(
                  data: buildAppTheme(brightness: Brightness.light),
                  child: Localizations(
                    locale: const Locale('en'),
                    delegates: const [
                      DefaultWidgetsLocalizations.delegate,
                      DefaultMaterialLocalizations.delegate,
                    ],
                    child: const Directionality(
                      textDirection: TextDirection.ltr,
                      child: Material(child: ResetEncryptionScreen()),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return;
    }
    router = GoRouter(
      initialLocation: pushed
          ? AppRouter.encryptionSettingsPath
          : AppRouter.resetEncryptionPath,
      routes: [
        GoRoute(
          path: AppRouter.resetEncryptionPath,
          builder: (context, state) => const ResetEncryptionScreen(),
        ),
        GoRoute(
          path: AppRouter.encryptionSettingsPath,
          builder: (context, state) =>
              const Scaffold(body: Text('encryption page')),
        ),
      ],
    );
    addTearDown(router.dispose);
    Widget app = MultiRepositoryProvider(
      providers: [
        if (withSession) RepositoryProvider<VaultSession>.value(value: session),
        RepositoryProvider<UnexpectedErrorReporter?>.value(
          value: (e, _) => reported.add(e),
        ),
      ],
      child: MaterialApp.router(
        theme: buildAppTheme(brightness: Brightness.light),
        routerConfig: router,
      ),
    );
    app = BlocProvider<AuthBloc>.value(value: auth, child: app);
    if (withStatus) {
      app = BlocProvider<EncryptionStatusCubit>.value(
        value: status,
        child: app,
      );
    }
    await tester.pumpWidget(app);
    await tester.pumpAndSettle();
    if (pushed) {
      unawaited(router.push(AppRouter.resetEncryptionPath));
      await tester.pumpAndSettle();
    }
  }

  Future<void> confirmFirst(WidgetTester tester) async {
    await tester.ensureVisible(_action());
    await tester.tap(_action());
    await tester.pumpAndSettle();
    await tester.tap(_inDialog(kResetConfirmLabel));
    // The busy spinner never settles: step past the dialog's exit instead.
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
  }

  group('nothing to reset', () {
    for (final (name, setUpDevice) in <(String, void Function())>[
      ('none', () => device.vaultStatus.value = VaultStatus.ready),
      ('opening', () => device.vaultStatus.value = VaultStatus.opening),
      (
        'dormant',
        () {
          device.vaultStatus.value = VaultStatus.ready;
          device.flag = E2eeFlag.off;
        },
      ),
      ('hidden access', () => device.vaultKnown = false),
    ]) {
      testWidgets('$name shows Nothing to reset and no button', (tester) async {
        setUpDevice();
        await pump(tester, flagOn: name != 'hidden access');
        expect(find.text(kResetNothingTitle), findsOneWidget);
        expect(find.text(kResetNothingBody), findsOneWidget);
        expect(_action(), findsNothing);
        verifyNever(() => session.resetByUser());
      });
    }

    testWidgets('removedElsewhere shows Nothing to reset', (tester) async {
      device.vaultStatus.value = VaultStatus.ready;
      device.deviceKeys.value = DeviceKeysStatus.dormant;
      // The removed-elsewhere kind comes from the port flag only.
      await pump(tester, removedElsewhere: true);
      expect(find.text(kResetNothingTitle), findsOneWidget);
      expect(_action(), findsNothing);
      verifyNever(() => session.resetByUser());
    });

    testWidgets('no status cubit and no session: harmless', (tester) async {
      await pump(tester, withStatus: false, withSession: false);
      expect(tester.takeException(), isNull);
      expect(find.text(kResetNothingTitle), findsOneWidget);
      expect(_action(), findsNothing);
    });
  });

  group('content', () {
    testWidgets(
      'flag on: lead, three points plus the offline point, no warning block',
      (tester) async {
        await pump(tester);
        expect(find.text(kResetLead), findsOneWidget);
        expect(find.textContaining(kResetPoint1), findsOneWidget);
        expect(find.textContaining(kResetPoint2), findsOneWidget);
        expect(find.textContaining(kResetPoint3), findsOneWidget);
        expect(find.textContaining(kResetPoint4), findsOneWidget);
        expect(find.text(kResetNoRestartWarning), findsNothing);
        expect(_action(), findsOneWidget);
      },
    );

    testWidgets('the no-restart warning is a live region', (tester) async {
      final handle = tester.ensureSemantics();
      device.flag = E2eeFlag.off;
      await pump(tester);
      final region = find.ancestor(
        of: find.text(kResetNoRestartWarning),
        matching: find.byWidgetPredicate(
          (w) => w is Semantics && w.properties.liveRegion == true,
        ),
      );
      expect(region, findsOneWidget);
      expect(tester.getSemantics(region).flagsCollection.isLiveRegion, isTrue);
      handle.dispose();
    });

    for (final flag in [E2eeFlag.off, E2eeFlag.unknown]) {
      testWidgets(
        'flag ${flag.name}: the fixed warning is shown and the new-device point is not',
        (tester) async {
          device.flag = flag;
          await pump(tester);
          expect(find.text(kResetNoRestartWarning), findsOneWidget);
          expect(find.textContaining(kResetPoint3), findsNothing);
          expect(find.textContaining(kResetPoint1), findsOneWidget);
          expect(find.textContaining(kResetPoint4), findsOneWidget);
          expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
        },
      );
    }
  });

  group('confirmation', () {
    testWidgets('flag on: one confirmation, then resetByUser is called once', (
      tester,
    ) async {
      await pump(tester);
      await tester.ensureVisible(_action());
      await tester.tap(_action());
      await tester.pumpAndSettle();
      expect(_inDialog(kResetConfirmTitle), findsOneWidget);
      expect(_inDialog(kResetConfirmMessage), findsOneWidget);
      verifyNever(() => session.resetByUser());
      await tester.tap(_inDialog(kResetConfirmLabel));
      await tester.pumpAndSettle();
      expect(find.byType(AppConfirmDialog), findsNothing);
      verify(() => session.resetByUser()).called(1);
    });

    testWidgets(
      'flag off: two confirmations; cancelling the second calls nothing',
      (tester) async {
        device.flag = E2eeFlag.off;
        await pump(tester);
        await tester.ensureVisible(_action());
        await tester.tap(_action());
        await tester.pumpAndSettle();
        await tester.tap(_inDialog(kResetConfirmLabel));
        await tester.pumpAndSettle();
        expect(_inDialog(kResetSecondTitle), findsOneWidget);
        expect(_inDialog('$kResetNoRestartWarning.'), findsOneWidget);
        verifyNever(() => session.resetByUser());
        await tester.tap(find.text('Cancel').last);
        await tester.pumpAndSettle();
        verifyNever(() => session.resetByUser());
        // And confirming both runs it, once.
        await tester.tap(_action());
        await tester.pumpAndSettle();
        await tester.tap(_inDialog(kResetConfirmLabel));
        await tester.pumpAndSettle();
        await tester.tap(_inDialog(kResetSecondLabel));
        await tester.pumpAndSettle();
        verify(() => session.resetByUser()).called(1);
      },
    );

    testWidgets(
      'the flag turning off while the first dialog is open adds the second',
      (tester) async {
        await pump(tester);
        await tester.ensureVisible(_action());
        await tester.tap(_action());
        await tester.pumpAndSettle();
        device.flag = E2eeFlag.off;
        status.refresh();
        await tester.tap(_inDialog(kResetConfirmLabel));
        await tester.pumpAndSettle();
        expect(_inDialog(kResetSecondTitle), findsOneWidget);
        verifyNever(() => session.resetByUser());
        await tester.tap(_inDialog(kResetSecondLabel));
        await tester.pumpAndSettle();
        verify(() => session.resetByUser()).called(1);
      },
    );

    testWidgets(
      'a flag that turned off before Reset was pressed still asks the second confirmation',
      (tester) async {
        await pump(tester);
        // The device's plain flag changed and nobody called status.refresh().
        device.flag = E2eeFlag.off;
        expect(status.state.mayStart, isTrue);
        await tester.ensureVisible(_action());
        await tester.tap(_action());
        await tester.pumpAndSettle();
        await tester.tap(_inDialog(kResetConfirmLabel));
        await tester.pumpAndSettle();
        expect(_inDialog(kResetSecondTitle), findsOneWidget);
        verifyNever(() => session.resetByUser());
        await tester.tap(_inDialog(kResetSecondLabel));
        await tester.pumpAndSettle();
        verify(() => session.resetByUser()).called(1);
      },
    );

    testWidgets(
      'a vault that became healthy while the dialog was open is not reset',
      (tester) async {
        await pump(tester);
        await tester.ensureVisible(_action());
        await tester.tap(_action());
        await tester.pumpAndSettle();
        device.vaultStatus.value = VaultStatus.ready;
        await tester.pump();
        await tester.tap(_inDialog(kResetConfirmLabel));
        await tester.pumpAndSettle();
        verifyNever(() => session.resetByUser());
        expect(find.text(kResetNothingTitle), findsOneWidget);
        expect(_action(), findsNothing);
      },
    );

    testWidgets(
      'two taps before the dialog shows open one dialog and call once',
      (tester) async {
        await pump(tester);
        await tester.ensureVisible(_action());
        // Two presses in the same frame: a real second tap would already hit
        // the dialog's barrier, so call the button's own handler twice.
        final press = tester.widget<AppPillButton>(_action()).onPressed!;
        press();
        press();
        await tester.pumpAndSettle();
        // A second dialog would sit offstage under the first.
        expect(
          find.byType(AppConfirmDialog, skipOffstage: false),
          findsOneWidget,
        );
        await tester.tap(_inDialog(kResetConfirmLabel));
        await tester.pumpAndSettle();
        expect(
          find.byType(AppConfirmDialog, skipOffstage: false),
          findsNothing,
        );
        verify(() => session.resetByUser()).called(1);
      },
    );

    testWidgets(
      'a confirmation that cannot be shown resets nothing and reports no detail',
      (tester) async {
        await pump(tester, noNavigator: true);
        await tester.ensureVisible(_action());
        await tester.tap(_action());
        await tester.pumpAndSettle();
        expect(reported, hasLength(1));
        expect(reported.single, isA<StateError>());
        expect(reported.single.toString(), 'Bad state: resetConfirm');
        expect(tester.takeException(), isNull);
        verifyNever(() => session.resetByUser());
        // Nothing is stuck: the button is still there and enabled.
        expect(tester.widget<AppPillButton>(_action()).onPressed, isNotNull);
      },
    );

    testWidgets(
      'a confirmation given before an account change resets nothing',
      (tester) async {
        await pump(tester);
        await tester.ensureVisible(_action());
        await tester.tap(_action());
        await tester.pumpAndSettle();
        when(() => auth.state).thenReturn(_signedIn('uid-2'));
        await tester.tap(_inDialog(kResetConfirmLabel));
        await tester.pumpAndSettle();
        verifyNever(() => session.resetByUser());
        expect(reported, isEmpty);
      },
    );

    testWidgets('cancelling the first dialog calls nothing', (tester) async {
      await pump(tester);
      await tester.ensureVisible(_action());
      await tester.tap(_action());
      await tester.pumpAndSettle();
      await tester.tap(_inDialog('Cancel'));
      await tester.pumpAndSettle();
      expect(find.byType(AppConfirmDialog), findsNothing);
      verifyNever(() => session.resetByUser());
      expect(_action(), findsOneWidget);
    });
  });

  group('running and outcome', () {
    late Completer<bool> hold;

    setUp(() {
      // Made when the screen calls, inside the test's own zone: a completer
      // made in setUp would deliver its result outside the fake clock.
      when(() => session.resetByUser()).thenAnswer((_) {
        hold = Completer<bool>();
        return hold.future;
      });
    });

    testWidgets('running disables the button and back', (tester) async {
      await pump(tester);
      await confirmFirst(tester);
      final button = tester.widget<AppPillButton>(
        find.byType(AppPillButton).first,
      );
      expect(button.busy, isTrue);
      expect(button.onPressed, isNull);
      final pop = find.descendant(
        of: find.byType(ResetEncryptionScreen),
        matching: find.byWidgetPredicate((w) => w is PopScope),
      );
      expect((tester.widget(pop.first) as PopScope).canPop, isFalse);
      // This route cannot pop and has no up button here: no arrow at all.
      expect(find.byIcon(Icons.arrow_back), findsNothing);
      hold.complete(true);
      await _settle(tester);
    });

    testWidgets('a second tap while running does not call again', (
      tester,
    ) async {
      await pump(tester);
      await confirmFirst(tester);
      await tester.tap(find.byType(AppPillButton).first, warnIfMissed: false);
      await tester.pump();
      expect(find.byType(AppConfirmDialog), findsNothing);
      verify(() => session.resetByUser()).called(1);
      hold.complete(true);
      await _settle(tester);
    });

    testWidgets('a system back while the reset runs changes nothing', (
      tester,
    ) async {
      await pump(tester, pushed: true);
      expect(router.state.uri.path, AppRouter.resetEncryptionPath);
      await confirmFirst(tester);
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(router.state.uri.path, AppRouter.resetEncryptionPath);
      expect(
        tester.widget<AppPillButton>(find.byType(AppPillButton).first).busy,
        isTrue,
      );
      verify(() => session.resetByUser()).called(1);
      // A route that can pop shows the arrow, disabled.
      expect(
        tester
            .widget<IconButton>(
              find.widgetWithIcon(IconButton, Icons.arrow_back),
            )
            .onPressed,
        isNull,
      );
      hold.complete(true);
      await _settle(tester);
    });

    testWidgets(
      'a failed reset that no longer offers a reset returns to Encrypted messages with the failure text',
      (tester) async {
        // The local device record is unusable, so the reset is offered.
        device.vaultStatus.value = VaultStatus.ready;
        device.deviceKeys.value = const DeviceKeysStatus.failed(
          retryable: false,
        );
        device.localRecordUnusable = true;
        await pump(tester);
        expect(_action(), findsOneWidget);
        await confirmFirst(tester);
        // The failed wipe ends in an unavailable vault: nothing to reset.
        device.vaultStatus.value = VaultStatus.unavailable;
        await tester.pump();
        hold.complete(false);
        await _settle(tester);
        expect(find.text(kResetFailedText), findsOneWidget);
        expect(router.state.uri.path, AppRouter.encryptionSettingsPath);
        expect(find.text('encryption page'), findsOneWidget);
        expect(find.text(kResetNothingTitle), findsNothing);
        verify(() => session.resetByUser()).called(1);
      },
    );

    testWidgets('true shows the done text and goes to the encryption page', (
      tester,
    ) async {
      await pump(tester);
      await confirmFirst(tester);
      hold.complete(true);
      await _settle(tester);
      expect(find.text(kResetDoneText), findsOneWidget);
      expect(find.text('encryption page'), findsOneWidget);
      expect(router.state.uri.path, AppRouter.encryptionSettingsPath);
    });

    testWidgets('false shows the failed text and re-enables the button', (
      tester,
    ) async {
      await pump(tester);
      await confirmFirst(tester);
      hold.complete(false);
      await _settle(tester);
      expect(find.text(kResetFailedText), findsOneWidget);
      expect(find.text(kResetDoneText), findsNothing);
      expect(router.state.uri.path, AppRouter.resetEncryptionPath);
      final button = tester.widget<AppPillButton>(_action());
      expect(button.busy, isFalse);
      expect(button.onPressed, isNotNull);
    });

    testWidgets('a throw is failed and reported without details', (
      tester,
    ) async {
      await pump(tester);
      await confirmFirst(tester);
      hold.completeError(Exception('secret device id d-123'));
      await _settle(tester);
      expect(find.text(kResetFailedText), findsOneWidget);
      expect(router.state.uri.path, AppRouter.resetEncryptionPath);
      expect(reported, hasLength(1));
      expect(reported.single, isA<StateError>());
      expect('${reported.single}', isNot(contains('d-123')));
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'the status changing while running keeps the screen and finishes',
      (tester) async {
        await pump(tester);
        await confirmFirst(tester);
        // The session wipes: the vault is no longer in a state that offers it.
        device.vaultStatus.value = VaultStatus.off;
        status.refresh();
        await tester.pump();
        expect(find.text(kResetNothingTitle), findsNothing);
        hold.complete(true);
        await _settle(tester);
        expect(find.text('encryption page'), findsOneWidget);
      },
    );
  });

  group('ResetEncryptionCubit', () {
    test('run called again while running does nothing', () async {
      final hold = Completer<bool>();
      var calls = 0;
      final cubit = ResetEncryptionCubit(
        reset: () {
          calls++;
          return hold.future;
        },
      );
      final first = cubit.run();
      final second = cubit.run();
      await second;
      expect(calls, 1);
      expect(cubit.state, ResetEncryptionPhase.running);
      hold.complete(true);
      await first;
      expect(cubit.state, ResetEncryptionPhase.done);
      expect(calls, 1);
      await cubit.close();
    });

    test('idle -> running -> done, and failed can run again', () async {
      var results = [false, true];
      final cubit = ResetEncryptionCubit(
        reset: () async => results.removeAt(0),
      );
      final phases = <ResetEncryptionPhase>[];
      final sub = cubit.stream.listen(phases.add);
      await cubit.run();
      await cubit.run();
      await cubit.run();
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      expect(phases, [
        ResetEncryptionPhase.running,
        ResetEncryptionPhase.failed,
        ResetEncryptionPhase.running,
        ResetEncryptionPhase.done,
      ]);
      await cubit.close();
    });
  });
}
