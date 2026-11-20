import 'dart:async';

import 'package:dzeroth/app/session_wiring.dart' show UnexpectedErrorReporter;
import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/core/vault/vault_session.dart';
import 'package:dzeroth/core/vault/vault_status.dart';
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

  setUp(() {
    // A device whose key was lost: the reset is offered, the flag is on.
    device = FakeEncryptionDevice(status: VaultStatus.keyLost);
    session = _MockVaultSession();
    when(() => session.resetByUser()).thenAnswer((_) async => true);
    reported = [];
  });

  Future<void> pump(
    WidgetTester tester, {
    bool withStatus = true,
    bool withSession = true,
    bool flagOn = true,
    bool removedElsewhere = false,
    double width = 390,
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
    router = GoRouter(
      initialLocation: AppRouter.resetEncryptionPath,
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
    if (withStatus) {
      app = BlocProvider<EncryptionStatusCubit>.value(
        value: status,
        child: app,
      );
    }
    await tester.pumpWidget(app);
    await tester.pumpAndSettle();
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
