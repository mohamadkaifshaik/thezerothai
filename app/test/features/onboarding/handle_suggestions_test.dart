import 'package:bloc_test/bloc_test.dart';
import 'package:connectrpc/connect.dart' as connect;
import 'package:drift/native.dart';
import 'package:dzeroth/app/session_wiring.dart' show UnexpectedErrorReporter;
import 'package:dzeroth/core/network/api_client.dart';
import 'package:dzeroth/core/storage/app_database.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_event.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_state.dart';
import 'package:dzeroth/features/onboarding/data/identity_repository.dart';
import 'package:dzeroth/features/onboarding/domain/handle_rules.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/onboarding/presentation/create_profile_screen.dart';
import 'package:dzeroth/features/profile/domain/profile_edit_feature_flag.dart';
import 'package:dzeroth/features/profile/presentation/bloc/change_handle_cubit.dart';
import 'package:dzeroth/features/profile/presentation/change_handle_screen.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import '../../support/fake_transport.dart';
import '../../support/geometry.dart';
import '../../support/posts_fixtures.dart';
import '../../support/theme_harness.dart';

class _MockRepo extends Mock implements IdentityRepository {}

class _MockOnboarding extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

class _MockAuth extends MockBloc<AuthEvent, AuthState> implements AuthBloc {}

const _settle = Duration(milliseconds: 350);

/// Handle suggestions: asked only after a TAKEN answer, shown as up to five
/// chips, and a tap fills the field and checks it again. The chips are not in
/// the design mocks.
void main() {
  setUpAll(() {
    registerFallbackValue(const OnboardingHandleChanged(''));
    registerFallbackValue(const OnboardingRefreshRequested());
    registerFallbackValue(const AuthSignOutRequested());
  });

  final taken = identity.CheckHandleAvailabilityResponse(available: false);

  group('IdentityRepository.suggestHandles', () {
    late AppDatabase db;
    late IdentityRepository repo;
    late List<Object> requests;
    late Object Function() answer;

    setUp(() {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      requests = [];
      answer = () => throw StateError('unscripted');
      repo = IdentityRepository(
        apiClient: ApiClient.withTransport(
          FakeTransport((procedure, input) async {
            requests.add(input);
            final r = answer();
            if (r is Exception) throw r;
            return r;
          }),
        ),
        database: db,
      );
    });

    tearDown(() => db.close());

    test('sends the taken handle and caps the answer at five', () async {
      answer = () => identity.SuggestHandlesResponse(
        handles: ['a1', 'a2', 'a3', 'a4', 'a5', 'a6'],
      );
      final out = await repo.suggestHandles('kaif');
      expect(out, ['a1', 'a2', 'a3', 'a4', 'a5']);
      expect(
        (requests.single as identity.SuggestHandlesRequest).handle,
        'kaif',
      );
    });

    test('FEATURE_DISABLED shows nothing and is remembered', () async {
      answer = () => serverError(
        connect.Code.failedPrecondition,
        common.ErrorReason.ERROR_REASON_FEATURE_DISABLED,
        metadata: {'feature': 'handle_suggestions'},
      );
      expect(await repo.suggestHandles('kaif'), isEmpty);
      expect(await repo.suggestHandles('kaif2'), isEmpty);
      expect(requests, hasLength(1));
    });

    test('any other failure shows nothing and is not remembered', () async {
      answer = () => serverError(
        connect.Code.unavailable,
        common.ErrorReason.ERROR_REASON_UNSPECIFIED,
      );
      expect(await repo.suggestHandles('kaif'), isEmpty);
      answer = () => identity.SuggestHandlesResponse(handles: ['x1']);
      expect(await repo.suggestHandles('kaif'), ['x1']);
      expect(requests, hasLength(2));
    });
  });

  group('OnboardingBloc', () {
    late _MockRepo repo;

    setUp(() {
      repo = _MockRepo();
      when(() => repo.cachedOwnProfile(any())).thenAnswer((_) async => null);
    });

    blocTest<OnboardingBloc, OnboardingState>(
      'a TAKEN answer asks for suggestions and keeps them in state',
      build: () {
        when(() => repo.checkHandleAvailability('kaif'))
            .thenAnswer((_) async => taken);
        when(() => repo.suggestHandles('kaif'))
            .thenAnswer((_) async => ['kaif_1', 'kaif1']);
        return OnboardingBloc(identityRepository: repo);
      },
      act: (b) => b.add(const OnboardingHandleChanged('kaif')),
      wait: _settle,
      verify: (b) {
        expect(b.state.handleSuggestions, ['kaif_1', 'kaif1']);
        expect(b.state.handleCheckStatus, HandleCheckStatus.unavailable);
        verify(() => repo.suggestHandles('kaif')).called(1);
      },
    );

    blocTest<OnboardingBloc, OnboardingState>(
      'a malformed, reserved or free handle never asks',
      build: () {
        when(() => repo.checkHandleAvailability(any())).thenAnswer(
          (i) async => i.positionalArguments.single == 'reservedish'
              ? identity.CheckHandleAvailabilityResponse(
                  available: false,
                  reason: 'reserved',
                )
              : identity.CheckHandleAvailabilityResponse(available: true),
        );
        return OnboardingBloc(identityRepository: repo);
      },
      act: (b) async {
        b.add(const OnboardingHandleChanged('ab'));
        await Future<void>.delayed(_settle);
        b.add(const OnboardingHandleChanged('admin'));
        await Future<void>.delayed(_settle);
        b.add(const OnboardingHandleChanged('reservedish'));
        await Future<void>.delayed(_settle);
        b.add(const OnboardingHandleChanged('freehandle'));
      },
      wait: _settle,
      verify: (b) {
        verifyNever(() => repo.suggestHandles(any()));
        expect(b.state.handleSuggestions, isEmpty);
      },
    );

    blocTest<OnboardingBloc, OnboardingState>(
      'typing again clears the chips',
      build: () {
        when(() => repo.checkHandleAvailability(any()))
            .thenAnswer((_) async => taken);
        when(() => repo.suggestHandles('kaif'))
            .thenAnswer((_) async => ['kaif_1']);
        when(() => repo.suggestHandles('kaifx')).thenAnswer((_) async => []);
        return OnboardingBloc(identityRepository: repo);
      },
      act: (b) async {
        b.add(const OnboardingHandleChanged('kaif'));
        await Future<void>.delayed(_settle);
        b.add(const OnboardingHandleChanged('kaifx'));
      },
      wait: _settle,
      verify: (b) => expect(b.state.handleSuggestions, isEmpty),
    );
  });

  group('ChangeHandleCubit', () {
    late _MockRepo repo;
    setUp(() {
      repo = _MockRepo();
      when(() => repo.checkHandleAvailability(any()))
          .thenAnswer((_) async => taken);
      when(() => repo.suggestHandles(any()))
          .thenAnswer((_) async => ['neo_1', 'neo2']);
    });

    ChangeHandleCubit build({required bool enabled}) => ChangeHandleCubit(
      identityRepository: repo,
      currentHandle: 'me',
      debounce: Duration.zero,
      suggestionsEnabled: enabled,
    );

    test('flag on: a TAKEN answer fills the suggestions', () async {
      final c = build(enabled: true);
      c.handleChanged('neo');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(c.state.suggestions, ['neo_1', 'neo2']);
      c.handleChanged('neox');
      expect(c.state.suggestions, isEmpty);
      await c.close();
    });

    test('flag off: no SuggestHandles call at all', () async {
      final c = build(enabled: false);
      c.handleChanged('neo');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(c.state.suggestions, isEmpty);
      verifyNever(() => repo.suggestHandles(any()));
      await c.close();
    });

    test('flag on: a format error never asks', () async {
      final c = build(enabled: true);
      c.handleChanged('a b');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      verifyNever(() => repo.suggestHandles(any()));
      await c.close();
    });
  });

  // The screens, at the three widths, both themes, 1x and 2x text.
  final envs = [
    for (final b in Brightness.values)
      for (final w in const [360.0, 834.0, 1440.0])
        for (final s in const [1.0, 2.0])
          MatrixEnv(brightness: b, size: Size(w, 1200), textScale: s),
  ];

  for (final env in envs) {
    testWidgets('sign-up chips fit, a tap fills and re-checks [$env]', (
      tester,
    ) async {
      final bloc = _MockOnboarding();
      final auth = _MockAuth();
      whenListen(
        auth,
        const Stream<AuthState>.empty(),
        initialState: const AuthState(),
      );
      whenListen(
        bloc,
        const Stream<OnboardingState>.empty(),
        initialState: const OnboardingState(
          status: OnboardingStatus.profileRequired,
          handle: 'kaif',
          handleCheckStatus: HandleCheckStatus.unavailable,
          handleCheckMessage: kHandleTakenMessage,
          handleSuggestions: ['kaif_1', 'kaif1', 'kaif_', 'thekaif', 'kaif01'],
        ),
      );
      when(() => bloc.add(any())).thenReturn(null);
      tester.view.physicalSize = env.size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      tester.platformDispatcher.textScaleFactorTestValue = env.textScale;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpWidget(
        MultiBlocProvider(
          providers: [
            BlocProvider<AuthBloc>.value(value: auth),
            BlocProvider<OnboardingBloc>.value(value: bloc),
          ],
          child: MaterialApp(
            theme: buildAppTheme(brightness: env.brightness),
            home: const CreateProfileScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expectNoOverflow(tester);
      expect(find.byType(ActionChip), findsNWidgets(5));
      final chip = find.widgetWithText(ActionChip, '@kaif_1');
      await tester.ensureVisible(chip);
      await tester.tap(chip);
      await tester.pump();
      verify(
        () => bloc.add(
          any(
            that: isA<OnboardingHandleChanged>().having(
              (e) => e.handle,
              'handle',
              'kaif_1',
            ),
          ),
        ),
      ).called(1);
      expect(find.widgetWithText(TextField, 'kaif_1'), findsOneWidget);
    });
  }

  testWidgets('sign-up: no chips while the handle is not taken', (
    tester,
  ) async {
    final bloc = _MockOnboarding();
    final auth = _MockAuth();
    whenListen(
      auth,
      const Stream<AuthState>.empty(),
      initialState: const AuthState(),
    );
    whenListen(
      bloc,
      const Stream<OnboardingState>.empty(),
      initialState: const OnboardingState(
        status: OnboardingStatus.profileRequired,
        handle: 'kaif',
        handleCheckStatus: HandleCheckStatus.available,
        handleSuggestions: ['kaif_1'],
      ),
    );
    await tester.pumpWidget(
      MultiBlocProvider(
        providers: [
          BlocProvider<AuthBloc>.value(value: auth),
          BlocProvider<OnboardingBloc>.value(value: bloc),
        ],
        child: const MaterialApp(home: CreateProfileScreen()),
      ),
    );
    expect(find.byType(ActionChip), findsNothing);
  });

  for (final flagOn in [true, false]) {
    for (final env in envs) {
      testWidgets('change handle (flag ${flagOn ? 'on' : 'off'}) [$env]', (
        tester,
      ) async {
        final repo = _MockRepo();
        final bloc = _MockOnboarding();
        when(() => bloc.add(any())).thenReturn(null);
        when(() => repo.checkHandleAvailability(any()))
            .thenAnswer((_) async => taken);
        when(() => repo.suggestHandles(any()))
            .thenAnswer((_) async => ['neo_1', 'neo2']);
        whenListen(
          bloc,
          const Stream<OnboardingState>.empty(),
          initialState: OnboardingState(
            status: OnboardingStatus.ready,
            profile: identity.Profile(userId: 'me', handle: 'me'),
            enabledFeatures: {
              kFeatureProfileSnapshot,
              if (flagOn) kFeatureHandleSuggestions,
            },
          ),
        );
        tester.view.physicalSize = env.size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final router = GoRouter(
          routes: [
            GoRoute(path: '/', builder: (_, _) => const ChangeHandleScreen()),
          ],
        );
        addTearDown(router.dispose);
        await tester.pumpWidget(
          MultiRepositoryProvider(
            providers: [
              RepositoryProvider<IdentityRepository>.value(value: repo),
              RepositoryProvider<UnexpectedErrorReporter>.value(
                value: (error, _) {},
              ),
            ],
            child: BlocProvider<OnboardingBloc>.value(
              value: bloc,
              child: MaterialApp.router(
                routerConfig: router,
                theme: buildAppTheme(brightness: env.brightness),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(textScaler: TextScaler.linear(env.textScale)),
                  child: child!,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), 'neo');
        await tester.pump(_settle);
        await tester.pumpAndSettle();
        expectNoOverflow(tester);
        if (!flagOn) {
          expect(find.byType(ActionChip), findsNothing);
          verifyNever(() => repo.suggestHandles(any()));
          return;
        }
        expect(find.byType(ActionChip), findsNWidgets(2));
        final chip = find.widgetWithText(ActionChip, '@neo_1');
        await tester.ensureVisible(chip);
        await tester.tap(chip);
        await tester.pump(_settle);
        verify(() => repo.checkHandleAvailability('neo_1')).called(1);
        expect(find.widgetWithText(TextField, 'neo_1'), findsOneWidget);
        await tester.pumpAndSettle();
      });
    }
  }
}
