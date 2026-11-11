import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/storage/app_database.dart';
import 'package:dzeroth/core/telemetry/telemetry_adapters.dart';
import 'package:dzeroth/core/telemetry/telemetry_consent_store.dart';
import 'package:dzeroth/core/telemetry/telemetry_controller.dart';
import 'package:dzeroth/core/telemetry/telemetry_device_forget.dart';
import 'package:drift/native.dart';
import 'package:dzeroth/app/session_wiring.dart';
import 'package:dzeroth/core/feature_flags/ui_shell_feature_flag.dart';
import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/core/widgets/shell_geometry.dart';
import 'package:dzeroth/core/widgets/app_bottom_bar.dart';
import 'package:dzeroth/core/widgets/responsive_scaffold.dart';
import 'package:dzeroth/features/account/data/account_repository.dart';
import 'package:dzeroth/features/account/presentation/delete_account_screen.dart';
import 'package:dzeroth/features/auth/data/auth_repository.dart';
import 'package:dzeroth/features/auth/domain/app_user.dart';
import 'package:dzeroth/features/auth/domain/auth_failure.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_event.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_state.dart';
import 'package:dzeroth/features/notifications/data/push_opt_in_store.dart';
import 'package:dzeroth/features/posts/data/drafts_repository.dart';

import '../../../support/fake_drafts_repository.dart';

import 'package:dzeroth/features/posts/domain/composer_draft.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:dzeroth/shared/widgets/primitives/app_pill_button.dart';
import 'package:dzeroth/shared/widgets/primitives/app_surface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import '../../../core/telemetry/fake_telemetry.dart';
import '../../../support/fake_push_opt_in_store.dart';

class _MockAccounts extends Mock implements AccountRepository {}

class _MockAuth extends Mock implements AuthRepository {}

class _MockAuthBloc extends MockBloc<AuthEvent, AuthState>
    implements AuthBloc {}

class _MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

const _shellDestinations = [
  AppNavDestination(
    icon: Icons.home_outlined,
    selectedIcon: Icons.home,
    label: 'Home',
  ),
  AppNavDestination(
    icon: Icons.notifications_none,
    selectedIcon: Icons.notifications,
    label: 'Notifications',
  ),
];

/// [screen] inside the shell's phone chrome: the floating bar (`ui_shell` on)
/// or the docked legacy bar.
Widget _inShell(Widget screen, {required bool floating}) => ResponsiveScaffold(
  selectedIndex: null,
  onDestinationSelected: (_) {},
  destinations: _shellDestinations,
  floatingBar: floating,
  body: screen,
);

/// Jumps the page's list to its end: not a user scroll, so the floating bar
/// stays up.
Future<void> _jumpToEnd(WidgetTester tester, Finder inList) async {
  final position = tester
      .state<ScrollableState>(
        find.ancestor(of: inList, matching: find.byType(Scrollable)).first,
      )
      .position;
  position.jumpTo(position.maxScrollExtent);
  await tester.pumpAndSettle();
}

Rect _pillRect(WidgetTester tester) => tester.getRect(
  find.descendant(
    of: find.byType(AppFloatingBottomBar),
    matching: find.byType(Material),
  ),
);

double _barOpacity(WidgetTester tester) => tester
    .widget<AnimatedOpacity>(
      find.ancestor(
        of: find.byType(AppBottomBar),
        matching: find.byType(AnimatedOpacity),
      ),
    )
    .opacity;

void main() {
  late _MockAccounts accounts;
  late _MockAuth auth;
  late _MockAuthBloc authBloc;
  late _MockOnboardingBloc onboardingBloc;
  late FakePushOptInStore optIn;
  late FakeDraftsRepository drafts;
  late List<Object> reported;
  String? passwordSeen;

  setUpAll(() {
    registerFallbackValue(const AuthSignOutRequested());
  });

  setUp(() {
    passwordSeen = null;
    accounts = _MockAccounts();
    auth = _MockAuth();
    authBloc = _MockAuthBloc();
    onboardingBloc = _MockOnboardingBloc();
    reported = [];
    drafts = FakeDraftsRepository();
    // Two accounts remembered a "Not now"; only the deleted one may go.
    optIn = FakePushOptInStore(
      records: {
        'uid-1': DateTime.now().toUtc(),
        'uid-2': DateTime.now().toUtc(),
      },
    );
    when(() => authBloc.add(any())).thenReturn(null);
    whenListen(
      authBloc,
      const Stream<AuthState>.empty(),
      initialState: const AuthState(
        status: AuthStatus.authenticated,
        user: AppUser(
          uid: 'uid-1',
          email: 'a@example.com',
          emailVerified: true,
          isPasswordProvider: true,
        ),
      ),
    );
    whenListen(
      onboardingBloc,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        status: OnboardingStatus.ready,
        profile: identity.Profile(userId: 'u1', handle: 'Kaif'),
      ),
    );
    when(() => auth.reauthNeedsGesture).thenReturn(false);
    when(
      () => auth.reauthenticate(promptPassword: any(named: 'promptPassword')),
    ).thenAnswer((_) async => const ReauthResult());
    when(
      () =>
          accounts.deleteAccount(idempotencyKey: any(named: 'idempotencyKey')),
    ).thenAnswer((_) async => DateTime(2026));
  });

  Future<GoRouter> pump(
    WidgetTester tester, {
    Size? size,
    double textScale = 1,
    String initial = AppRouter.deleteAccountPath,
    TelemetryDeviceForget? telemetry,
    bool? floatingBar,
    Widget Function(Widget screen)? wrapScreen,
  }) async {
    if (size != null) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
    }
    final router = GoRouter(
      initialLocation: initial,
      routes: [
        GoRoute(
          path: AppRouter.deleteAccountPath,
          builder: (_, _) => wrapScreen != null
              ? wrapScreen(const DeleteAccountScreen())
              : floatingBar == null
              ? const DeleteAccountScreen()
              : _inShell(const DeleteAccountScreen(), floating: floatingBar),
        ),
        GoRoute(
          path: AppRouter.accountDeletedPath,
          builder: (_, _) => const AccountDeletedScreen(),
        ),
        GoRoute(
          path: AppRouter.exportDataPath,
          builder: (_, _) => const Scaffold(body: Text('export stub')),
        ),
        GoRoute(
          path: AppRouter.signInPath,
          builder: (_, _) => const Scaffold(body: Text('sign in stub')),
        ),
      ],
    );
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<AccountRepository>.value(value: accounts),
          RepositoryProvider<AuthRepository>.value(value: auth),
          RepositoryProvider<PushOptInStore>.value(value: optIn),
          RepositoryProvider<DraftsRepository>.value(value: drafts),
          RepositoryProvider<UnexpectedErrorReporter>.value(
            value: (error, _) => reported.add(error),
          ),
        ],
        child: MultiBlocProvider(
          providers: [
            BlocProvider<AuthBloc>.value(value: authBloc),
            BlocProvider<OnboardingBloc>.value(value: onboardingBloc),
          ],
          child: TelemetryForgetScope(
            forget: telemetry ?? const TelemetryDeviceForget.none(),
            child: MaterialApp.router(
              routerConfig: router,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(textScale)),
                child: child!,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return router;
  }

  // R4: the action is the danger pill (DeleteAccount.dc.html).
  Finder button() => find.widgetWithText(AppPillButton, 'Delete my account');
  bool enabled(WidgetTester tester) {
    final pill = tester.widget<AppPillButton>(button());
    return pill.onPressed != null && !pill.busy;
  }

  Future<void> typeHandle(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField), text);
    await tester.pump();
  }

  testWidgets('explains the consequences and links to the export', (
    tester,
  ) async {
    await pump(tester);

    expect(find.textContaining('permanent'), findsOneWidget);
    expect(find.textContaining('What remains'), findsOneWidget);
    await tester.tap(find.text('Download my data first'));
    await tester.pumpAndSettle();
    expect(find.text('export stub'), findsOneWidget);
  });

  testWidgets('the button stays disabled until the handle matches', (
    tester,
  ) async {
    await pump(tester);

    expect(enabled(tester), isFalse);
    await typeHandle(tester, 'wrong');
    expect(enabled(tester), isFalse);
    await typeHandle(tester, '@kaif ');
    expect(enabled(tester), isTrue);
    verifyNever(
      () => auth.reauthenticate(promptPassword: any(named: 'promptPassword')),
    );
  });

  testWidgets('success re-auths, deletes once, signs out and confirms', (
    tester,
  ) async {
    await pump(tester);
    await typeHandle(tester, 'kaif');

    await tester.tap(button());
    await tester.pumpAndSettle();

    verify(
      () =>
          accounts.deleteAccount(idempotencyKey: any(named: 'idempotencyKey')),
    ).called(1);
    verify(() => authBloc.add(const AuthSignOutRequested())).called(1);
    expect(find.text('Your account is being deleted'), findsOneWidget);

    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.text('sign in stub'), findsOneWidget);
  });

  testWidgets('success wipes the deleted uid\'s drafts and only that uid\'s', (
    tester,
  ) async {
    ComposerDraft draft(String id, String uid) => ComposerDraft(
      id: id,
      uid: uid,
      text: 'unsent $id',
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );
    await drafts.upsert(draft('a', 'uid-1'));
    await drafts.upsert(draft('b', 'uid-2'));
    await pump(tester);
    await typeHandle(tester, 'kaif');

    await tester.tap(button());
    await tester.pumpAndSettle();

    expect(drafts.wiped, ['uid-1']);
    expect(await drafts.watch('uid-1').first, isEmpty);
    expect((await drafts.watch('uid-2').first).map((d) => d.id), ['b']);
  });

  testWidgets('success forgets the deleted uid\'s "Not now" before the final '
      'page, and only that uid', (tester) async {
    await pump(tester);
    await typeHandle(tester, 'kaif');

    await tester.tap(button());
    await tester.pumpAndSettle();

    expect(optIn.forgotten, ['uid-1']);
    expect(optIn.records.keys, ['uid-2']);
    expect(find.text('Your account is being deleted'), findsOneWidget);
  });

  testWidgets('success forgets the device telemetry of the deleted uid before '
      'the final page (TEL-8)', (tester) async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    final consent = TelemetryConsentStore(database);
    final log = CallLog();
    final controller = TelemetryController(
      adapters: TelemetryAdapters(
        crash: FakeCrashReporter(log),
        analytics: FakeUsageAnalytics(log),
      ),
      platformSupported: true,
      consent: consent,
      debugLog: (_) {},
    );
    addTearDown(() async {
      await controller.dispose();
      await consent.dispose();
      await database.close();
    });
    for (final uid in ['uid-1', 'uid-2']) {
      await consent.setAll(uid, {
        TelemetryKind.crash: ConsentChoice.on,
        TelemetryKind.usage: ConsentChoice.on,
      });
    }
    log.clear();
    await pump(
      tester,
      telemetry: TelemetryDeviceForget.of(
        consent: consent,
        controller: controller,
      ),
    );
    await typeHandle(tester, 'kaif');

    await tester.tap(button());
    await tester.pumpAndSettle();

    expect(await database.readSetting('telemetry_consent:crash:uid-1'), isNull);
    expect(await database.readSetting('telemetry_consent:usage:uid-1'), isNull);
    expect(await database.readSetting('telemetry_consent:crash:uid-2'), 'on');
    expect(log.calls, containsAll(['crash.deleteUnsent', 'usage.reset']));
    expect(find.text('Your account is being deleted'), findsOneWidget);
  });

  testWidgets('a failed delete leaves the device telemetry alone', (
    tester,
  ) async {
    var forgotten = <String>[];
    when(
      () =>
          accounts.deleteAccount(idempotencyKey: any(named: 'idempotencyKey')),
    ).thenThrow(const UnknownApiException('boom'));
    await pump(
      tester,
      telemetry: TelemetryDeviceForget((uid) async => forgotten.add(uid)),
    );
    await typeHandle(tester, 'kaif');

    await tester.tap(button());
    await tester.pumpAndSettle();

    expect(forgotten, isEmpty);
  });

  testWidgets('a failed delete leaves the "Not now" record alone', (
    tester,
  ) async {
    when(
      () =>
          accounts.deleteAccount(idempotencyKey: any(named: 'idempotencyKey')),
    ).thenThrow(const NetworkException('offline'));
    await pump(tester);
    await typeHandle(tester, 'kaif');

    await tester.tap(button());
    await tester.pumpAndSettle();

    expect(optIn.forgotten, isEmpty);
    expect(optIn.records.keys, containsAll(['uid-1', 'uid-2']));
  });

  testWidgets('a failed delete leaves the unsent posts alone', (tester) async {
    when(
      () =>
          accounts.deleteAccount(idempotencyKey: any(named: 'idempotencyKey')),
    ).thenThrow(const NetworkException('offline'));
    await drafts.upsert(
      ComposerDraft(
        id: 'a',
        uid: 'uid-1',
        text: 'still mine',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ),
    );
    await pump(tester);
    await typeHandle(tester, 'kaif');

    await tester.tap(button());
    await tester.pumpAndSettle();

    expect(drafts.wiped, isEmpty);
    expect((await drafts.watch('uid-1').first).map((d) => d.id), ['a']);
  });

  testWidgets('W6-19: deleteAll failing is reported, the "Not now" record is '
      'still forgotten and the final page still shows', (tester) async {
    drafts = _FailingDeleteAllDrafts();
    await pump(tester);
    await typeHandle(tester, 'kaif');

    await tester.tap(button());
    await tester.pumpAndSettle();

    expect(reported, hasLength(1));
    expect(optIn.forgotten, ['uid-1']);
    expect(find.text('Your account is being deleted'), findsOneWidget);
    verify(() => authBloc.add(const AuthSignOutRequested())).called(1);
  });

  testWidgets('a storage failure is reported and never blocks the final page', (
    tester,
  ) async {
    optIn.failForget = true;
    await pump(tester);
    await typeHandle(tester, 'kaif');

    await tester.tap(button());
    await tester.pumpAndSettle();

    expect(reported, hasLength(1));
    expect(find.text('Your account is being deleted'), findsOneWidget);
    verify(() => authBloc.add(const AuthSignOutRequested())).called(1);
  });

  testWidgets('the client sign-out racing the cubit still forgets the uid', (
    tester,
  ) async {
    final signedOut = StreamController<AuthState>();
    addTearDown(signedOut.close);
    whenListen(
      authBloc,
      signedOut.stream,
      initialState: const AuthState(
        status: AuthStatus.authenticated,
        user: AppUser(
          uid: 'uid-1',
          email: 'a@example.com',
          emailVerified: true,
          isPasswordProvider: true,
        ),
      ),
    );
    final gate = Completer<DateTime?>();
    when(
      () =>
          accounts.deleteAccount(idempotencyKey: any(named: 'idempotencyKey')),
    ).thenAnswer((_) => gate.future);
    await pump(tester);
    await typeHandle(tester, 'kaif');
    await tester.tap(button());
    await tester.pump();

    signedOut.add(const AuthState(status: AuthStatus.unauthenticated));
    await tester.pumpAndSettle();

    expect(optIn.forgotten, ['uid-1']);
    expect(find.text('Your account is being deleted'), findsOneWidget);
  });

  testWidgets('cancelled re-auth sends nothing and says so', (tester) async {
    when(
      () => auth.reauthenticate(promptPassword: any(named: 'promptPassword')),
    ).thenThrow(const AuthFailure.cancelled());
    await pump(tester);
    await typeHandle(tester, 'kaif');

    await tester.tap(button());
    await tester.pumpAndSettle();

    verifyNever(
      () =>
          accounts.deleteAccount(idempotencyKey: any(named: 'idempotencyKey')),
    );
    expect(find.textContaining('Nothing was changed'), findsOneWidget);
    expect(enabled(tester), isTrue);
  });

  testWidgets('REAUTH_REQUIRED after re-auth shows an error, no loop', (
    tester,
  ) async {
    when(() => auth.reauthNeedsGesture).thenReturn(true);
    when(
      () =>
          accounts.deleteAccount(idempotencyKey: any(named: 'idempotencyKey')),
    ).thenThrow(const ReauthRequiredException('stale'));
    await pump(tester);
    await typeHandle(tester, 'kaif');

    await tester.tap(button());
    await tester.pumpAndSettle();

    expect(find.textContaining("couldn't confirm it's you"), findsOneWidget);
    verify(
      () =>
          accounts.deleteAccount(idempotencyKey: any(named: 'idempotencyKey')),
    ).called(1);
    verifyNever(() => authBloc.add(any()));
  });

  testWidgets('a network error is friendly and keeps the screen', (
    tester,
  ) async {
    when(
      () =>
          accounts.deleteAccount(idempotencyKey: any(named: 'idempotencyKey')),
    ).thenThrow(const NetworkException('boom'));
    await pump(tester);
    await typeHandle(tester, 'kaif');

    await tester.tap(button());
    await tester.pumpAndSettle();

    expect(find.textContaining('No connection'), findsOneWidget);
    expect(find.text('Delete account'), findsOneWidget);
  });

  testWidgets('shows progress and blocks a second tap while working', (
    tester,
  ) async {
    final gate = Completer<DateTime?>();
    when(
      () =>
          accounts.deleteAccount(idempotencyKey: any(named: 'idempotencyKey')),
    ).thenAnswer((_) => gate.future);
    await pump(tester);
    await typeHandle(tester, 'kaif');

    await tester.tap(button());
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(enabled(tester), isFalse);
    gate.complete(null);
    await tester.pumpAndSettle();
  });

  for (final size in const [Size(360, 640), Size(800, 1024), Size(1400, 900)]) {
    testWidgets('no overflow at ${size.width.toInt()}dp', (tester) async {
      await pump(tester, size: size);
      expect(tester.takeException(), isNull);
    });
  }

  for (final path in const [
    AppRouter.deleteAccountPath,
    AppRouter.accountDeletedPath,
  ]) {
    testWidgets('no overflow at 2x text on 360x640 ($path)', (tester) async {
      await pump(
        tester,
        size: const Size(360, 640),
        textScale: 2,
        initial: path,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('ACCOUNT_RESTRICTED shows the in-progress deletion message', (
    tester,
  ) async {
    when(
      () =>
          accounts.deleteAccount(idempotencyKey: any(named: 'idempotencyKey')),
    ).thenThrow(const AccountRestrictedException('restricted'));
    await pump(tester);
    await typeHandle(tester, 'kaif');

    await tester.tap(button());
    await tester.pumpAndSettle();

    expect(find.textContaining('deletion is in progress'), findsOneWidget);
    verifyNever(() => authBloc.add(any()));
  });

  group('password prompt (password accounts)', () {
    // The screen's re-auth asks for the password through the shared dialog.
    void stubPasswordReauth() {
      when(
        () => auth.reauthenticate(promptPassword: any(named: 'promptPassword')),
      ).thenAnswer((invocation) async {
        final prompt =
            invocation.namedArguments[#promptPassword]
                as Future<String?> Function();
        final password = await prompt();
        if (password == null) throw const AuthFailure.cancelled();
        passwordSeen = password;
        return const ReauthResult();
      });
    }

    testWidgets('Cancel cancels the flow and sends nothing', (tester) async {
      stubPasswordReauth();
      await pump(tester);
      await typeHandle(tester, 'kaif');

      await tester.tap(button());
      // The in-button spinner never settles while the dialog is open.
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(passwordSeen, isNull);
      expect(find.textContaining('Nothing was changed'), findsOneWidget);
      verifyNever(
        () => accounts.deleteAccount(
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      );
    });

    testWidgets('Continue is disabled while empty and passes the text', (
      tester,
    ) async {
      stubPasswordReauth();
      await pump(tester);
      await typeHandle(tester, 'kaif');

      await tester.tap(button());
      // The in-button spinner never settles while the dialog is open.
      await tester.pump(const Duration(milliseconds: 400));

      final continueButton = find.widgetWithText(FilledButton, 'Continue');
      expect(tester.widget<FilledButton>(continueButton).onPressed, isNull);

      await tester.enterText(find.byType(TextField).last, 's3cret');
      await tester.pump();
      expect(tester.widget<FilledButton>(continueButton).onPressed, isNotNull);

      await tester.tap(continueButton);
      await tester.pumpAndSettle();

      expect(passwordSeen, 's3cret');
      verify(
        () => accounts.deleteAccount(
          idempotencyKey: any(named: 'idempotencyKey'),
        ),
      ).called(1);
    });
  });

  testWidgets('Done signs out again while still authenticated', (tester) async {
    await pump(tester, initial: AppRouter.accountDeletedPath);

    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();

    verify(() => authBloc.add(const AuthSignOutRequested())).called(1);
    expect(find.text('sign in stub'), findsOneWidget);
  });

  testWidgets('Done does not sign out again when already unauthenticated', (
    tester,
  ) async {
    whenListen(
      authBloc,
      const Stream<AuthState>.empty(),
      initialState: const AuthState(status: AuthStatus.unauthenticated),
    );
    await pump(tester, initial: AppRouter.accountDeletedPath);

    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();

    verifyNever(() => authBloc.add(any()));
    expect(find.text('sign in stub'), findsOneWidget);
  });

  testWidgets('without a profile: confirm word, no export link, client delete '
      'after PROFILE_REQUIRED', (tester) async {
    whenListen(
      onboardingBloc,
      const Stream<OnboardingState>.empty(),
      initialState: const OnboardingState(
        status: OnboardingStatus.profileRequired,
      ),
    );
    when(
      () =>
          accounts.deleteAccount(idempotencyKey: any(named: 'idempotencyKey')),
    ).thenThrow(const ProfileRequiredException('x', fromServerReason: true));
    when(() => auth.deleteCurrentUser()).thenAnswer((_) async {});
    await pump(tester);

    expect(find.text('Download my data first'), findsNothing);
    expect(find.text('Type DELETE to confirm'), findsOneWidget);
    expect(enabled(tester), isFalse);
    await typeHandle(tester, 'delete');
    expect(enabled(tester), isTrue);

    await tester.tap(button());
    await tester.pumpAndSettle();

    verify(() => auth.deleteCurrentUser()).called(1);
    expect(find.text('Your account is being deleted'), findsOneWidget);
  });

  test('confirmWordMatches ignores case and spaces', () {
    expect(confirmWordMatches(' delete '), isTrue);
    expect(confirmWordMatches('del'), isFalse);
  });

  test('handleMatches ignores case, @ and spaces', () {
    expect(handleMatches(' @KAIF ', 'kaif'), isTrue);
    expect(handleMatches('@Kaif', 'kAIF'), isTrue);
    expect(handleMatches('', ''), isFalse);
    expect(handleMatches('kai', 'kaif'), isFalse);
  });

  testWidgets('the onboarding route (outside the shell) keeps the 16 dp '
      'padding over a 34 dp home indicator', (tester) async {
    // A caller with no profile yet reaches the page from onboarding, through
    // the real router: a root route, no bottom bar.
    final noProfile = _MockOnboardingBloc();
    whenListen(
      noProfile,
      const Stream<OnboardingState>.empty(),
      initialState: const OnboardingState(
        status: OnboardingStatus.profileRequired,
      ),
    );
    final appRouter = AppRouter(authBloc: authBloc, onboardingBloc: noProfile);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 800);
    tester.view.padding = const FakeViewPadding(bottom: 34);
    tester.view.viewPadding = const FakeViewPadding(bottom: 34);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<AccountRepository>.value(value: accounts),
          RepositoryProvider<AuthRepository>.value(value: auth),
          RepositoryProvider<PushOptInStore>.value(value: optIn),
          RepositoryProvider<DraftsRepository>.value(value: drafts),
          RepositoryProvider<UnexpectedErrorReporter>.value(
            value: (error, _) => reported.add(error),
          ),
        ],
        child: MultiBlocProvider(
          providers: [
            BlocProvider<AuthBloc>.value(value: authBloc),
            BlocProvider<OnboardingBloc>.value(value: noProfile),
          ],
          child: TelemetryForgetScope(
            forget: const TelemetryDeviceForget.none(),
            child: MaterialApp.router(routerConfig: appRouter.router),
          ),
        ),
      ),
    );
    appRouter.router.go(AppRouter.onboardingDeletePath);
    await tester.pumpAndSettle();

    expect(find.byType(DeleteAccountScreen), findsOneWidget);
    final list = tester.widget<ListView>(
      find.descendant(
        of: find.byType(DeleteAccountScreen),
        matching: find.byType(ListView),
      ),
    );
    // The page's own padding, exactly as before the floating bar: the
    // home-indicator inset is not added outside the shell.
    expect(list.padding, const EdgeInsets.all(16));
  });

  group('under the shell bar (bottom inset)', () {
    Finder deleteButton() =>
        find.widgetWithText(AppPillButton, 'Delete my account');

    /// The height at which the final action ends 40 dp above the bottom
    /// edge: inside the 90 dp of the floating bar, on a page that fits the
    /// screen without the bar.
    Future<double> shortHeight(WidgetTester tester) async {
      await pump(tester, size: const Size(360, 2000), floatingBar: false);
      return (tester.getRect(deleteButton()).bottom + 40).roundToDouble();
    }

    testWidgets('ui_shell on: "Delete my account" ends above the pill', (
      tester,
    ) async {
      final height = await shortHeight(tester);
      await pump(tester, size: Size(360, height), floatingBar: true);
      await _jumpToEnd(tester, deleteButton());

      expect(_barOpacity(tester), 1);
      final pill = _pillRect(tester);
      expect(pill.top, height - 90);
      expect(
        tester.getRect(deleteButton()).bottom,
        lessThanOrEqualTo(pill.top),
      );
    });

    testWidgets('ui_shell off: the docked bar; the page is unchanged', (
      tester,
    ) async {
      final height = await shortHeight(tester);
      await pump(tester, size: Size(360, height), floatingBar: false);
      final before = tester.getRect(deleteButton());
      await _jumpToEnd(tester, deleteButton());

      expect(find.byType(AppFloatingBottomBar), findsNothing);
      final barTop = tester.getRect(find.byType(AppBottomBar)).top;
      expect(barTop, height - 56);
      // The list keeps its 16 dp padding: the docked bar takes the inset.
      final list = tester.widget<ListView>(
        find.ancestor(of: deleteButton(), matching: find.byType(ListView)),
      );
      expect(list.padding, const EdgeInsets.all(16));
      expect(tester.getRect(deleteButton()).bottom, lessThanOrEqualTo(barTop));
      expect(
        tester.getRect(deleteButton()).bottom,
        lessThanOrEqualTo(before.bottom),
      );
    });
  });
  // T8e and the UX review: the readable column. As a Settings leaf on the
  // tablet layout (in the shell, `ShellGeometry` above it) the page is at
  // most 680; at `/onboarding/delete-account` (AU, tablet plan section 4.2:
  // no shell) it keeps 600, as it does on phones and desktop.
  group('the readable column', () {
    void tabletFlags() => whenListen(
      onboardingBloc,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        status: OnboardingStatus.ready,
        profile: identity.Profile(userId: 'u1', handle: 'Kaif'),
        enabledFeatures: const {kFeatureUiShell, kFeatureUiTablet},
      ),
    );
    double listWidth(WidgetTester tester) => tester
        .getSize(
          find.descendant(
            of: find.byType(DeleteAccountScreen),
            matching: find.byType(ListView),
          ),
        )
        .width;

    testWidgets('a Settings leaf on the tablet layout (1024): 680', (
      tester,
    ) async {
      tabletFlags();
      const window = Size(1024, 900);
      await pump(
        tester,
        size: window,
        wrapScreen: (screen) => ShellGeometry(
          data: ShellGeometry.contentRectFor(
            window,
            EdgeInsets.zero,
            ShellLayout.tablet,
          ),
          child: screen,
        ),
      );
      expect(listWidth(tester), AppSize.readableMax);
    });

    for (final width in [600.0, 839.0, 1024.0, 1199.0]) {
      testWidgets('the AU route at ${width.toInt()} (both flags, no shell): '
          '600', (tester) async {
        tabletFlags();
        await pump(tester, size: Size(width, 900));
        expect(listWidth(tester), 600);
      });
    }

    for (final width in [360.0, 1440.0]) {
      testWidgets('${width.toInt()}: the width as before', (tester) async {
        tabletFlags();
        await pump(tester, size: Size(width, 900));
        expect(listWidth(tester), width < 600 ? width : 600);
      });
    }
  });

  group('R4 design fidelity', () {
    testWidgets('DeleteAccount.dc.html: eyebrow, headline, data card, danger '
        'pill', (tester) async {
      await pump(tester);
      expect(find.text("THIS CAN'T BE UNDONE"), findsOneWidget);
      expect(find.text('Delete your account?'), findsOneWidget);
      expect(
        find.ancestor(
          of: find.text('Download my data first'),
          matching: find.byType(AppSurface),
        ),
        findsOneWidget,
      );
      final pill = tester.widget<AppPillButton>(button());
      expect(pill.variant, AppButtonVariant.danger);
      expect(pill.size, AppButtonSize.large);
    });

    testWidgets(
      'AccountDeleted.dc.html: header, eyebrow, headline, Done pill',
      (tester) async {
        await pump(tester);
        await typeHandle(tester, 'kaif');
        await tester.tap(button());
        await tester.pumpAndSettle();
        expect(
          find.descendant(
            of: find.byType(AppBar),
            matching: find.text('Account deleted'),
          ),
          findsOneWidget,
        );
        expect(find.text('ACCOUNT STATUS'), findsOneWidget);
        expect(find.text('Your account is being deleted'), findsOneWidget);
        expect(
          tester
              .widget<AppPillButton>(find.widgetWithText(AppPillButton, 'Done'))
              .variant,
          AppButtonVariant.primary,
        );
      },
    );
  });
}

/// A drafts store whose wipe throws (a locked or corrupt database).
class _FailingDeleteAllDrafts extends FakeDraftsRepository {
  @override
  Future<void> deleteAll(String uid) async => throw StateError('disk');
}
