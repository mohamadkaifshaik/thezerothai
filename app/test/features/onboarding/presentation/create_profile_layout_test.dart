import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_event.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_state.dart';
import 'package:dzeroth/features/onboarding/domain/handle_rules.dart'
    show HandleCheckStatus;
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/onboarding/presentation/create_profile_screen.dart';
import 'package:dzeroth/shared/widgets/app_gradient_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

class _MockOnboarding extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

class _MockAuth extends MockBloc<AuthEvent, AuthState> implements AuthBloc {}

/// Layout and state coverage of the restyled create-profile screen (UI slice
/// profile + onboarding). The validation and submit behaviour is owned by
/// create_profile_screen_test.dart and the bloc tests; the Continue-disabled
/// rules are repeated here against the new button.
void main() {
  setUpAll(() {
    registerFallbackValue(const OnboardingHandleChanged(''));
    registerFallbackValue(const AuthSignOutRequested());
  });

  late _MockOnboarding bloc;
  late _MockAuth auth;

  setUp(() {
    bloc = _MockOnboarding();
    auth = _MockAuth();
    whenListen(
      auth,
      const Stream<AuthState>.empty(),
      initialState: const AuthState(),
    );
    when(() => auth.add(any())).thenReturn(null);
  });

  Future<void> open(
    WidgetTester tester,
    OnboardingState state, {
    Size size = const Size(390, 844),
    Brightness brightness = Brightness.light,
    double textScale = 1,
  }) async {
    // A spinner on screen (checking / submitting) never lets the tree settle.
    final spinning =
        state.isSubmitting ||
        state.handleCheckStatus == HandleCheckStatus.checking;
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    whenListen(
      bloc,
      const Stream<OnboardingState>.empty(),
      initialState: state,
    );
    final router = GoRouter(
      routes: [
        GoRoute(path: '/', builder: (_, _) => const CreateProfileScreen()),
        GoRoute(
          path: AppRouter.onboardingDeletePath,
          builder: (_, _) => const Scaffold(body: Text('delete stub')),
        ),
      ],
    );
    await tester.pumpWidget(
      MultiBlocProvider(
        providers: [
          BlocProvider<AuthBloc>.value(value: auth),
          BlocProvider<OnboardingBloc>.value(value: bloc),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          theme: buildAppTheme(brightness: brightness),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
        ),
      ),
    );
    if (spinning) {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    } else {
      await tester.pumpAndSettle();
    }
  }

  AppGradientButton continueButton(WidgetTester tester) =>
      tester.widget(find.widgetWithText(AppGradientButton, 'Continue'));

  const empty = OnboardingState(status: OnboardingStatus.profileRequired);
  const ready = OnboardingState(
    status: OnboardingStatus.profileRequired,
    handle: 'kaif',
    displayName: 'Kaif',
    handleCheckStatus: HandleCheckStatus.available,
    handleCheckMessage: 'kaif is available.',
  );

  group('layout', () {
    for (final size in const [Size(390, 844), Size(1440, 900)]) {
      for (final brightness in Brightness.values) {
        for (final textScale in const [1.0, 2.0]) {
          testWidgets(
            '${size.width.toInt()}x${size.height.toInt()} ${brightness.name} '
            'text x$textScale: no overflow, welcome, fields, delete escape',
            (tester) async {
              await open(
                tester,
                ready,
                size: size,
                brightness: brightness,
                textScale: textScale,
              );
              expect(tester.takeException(), isNull);
              expect(find.text('Welcome to Dzeroth'), findsOneWidget);
              expect(
                find.text(
                  'Pick a handle and a name. You can change these later.',
                ),
                findsOneWidget,
              );
              expect(find.text('Handle'), findsOneWidget);
              expect(find.text('Display name'), findsOneWidget);
              // At large text the lower part of the form is below the fold.
              await tester.scrollUntilVisible(
                find.widgetWithText(TextButton, 'Delete account'),
                100,
                scrollable: find.byType(Scrollable).first,
              );
              expect(find.text('Continue'), findsOneWidget);
              expect(find.text('Delete account'), findsOneWidget);
              expect(tester.takeException(), isNull);
            },
          );
        }
      }
    }

    testWidgets('wide: the form sits in a card at most 440dp wide', (
      tester,
    ) async {
      await open(tester, ready, size: const Size(1440, 900));
      expect(
        tester.getSize(find.byType(AppGradientButton)).width,
        lessThanOrEqualTo(440),
      );
    });

    testWidgets('the sign-out icon keeps its label and a 48dp target', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await open(tester, empty);
      expect(
        tester.getSemantics(find.byTooltip('Sign out')),
        isSemantics(tooltip: 'Sign out', isButton: true),
      );
      expect(
        tester.getSemantics(find.byTooltip('Sign out')).rect.height,
        greaterThanOrEqualTo(AppSpacing.minTapTarget),
      );
      await tester.tap(find.byIcon(Icons.logout));
      verify(() => auth.add(any(that: isA<AuthSignOutRequested>()))).called(1);
      handle.dispose();
    });
  });

  group('states', () {
    testWidgets('empty: Continue is disabled and the format hint is shown', (
      tester,
    ) async {
      await open(tester, empty);
      expect(continueButton(tester).onPressed, isNull);
      expect(
        find.text('3-20 characters: lowercase letters, numbers, underscore.'),
        findsOneWidget,
      );
    });

    testWidgets('Continue stays disabled exactly as before: no name, taken '
        'handle, checking, submitting', (tester) async {
      for (final state in const [
        OnboardingState(
          status: OnboardingStatus.profileRequired,
          handle: 'kaif',
          handleCheckStatus: HandleCheckStatus.available,
        ),
        OnboardingState(
          status: OnboardingStatus.profileRequired,
          handle: 'kaif',
          displayName: 'Kaif',
          handleCheckStatus: HandleCheckStatus.unavailable,
        ),
        OnboardingState(
          status: OnboardingStatus.profileRequired,
          handle: 'kaif',
          displayName: 'Kaif',
          handleCheckStatus: HandleCheckStatus.checking,
        ),
        OnboardingState(
          status: OnboardingStatus.profileRequired,
          handle: 'kaif',
          displayName: 'Kaif',
          handleCheckStatus: HandleCheckStatus.available,
          isSubmitting: true,
        ),
      ]) {
        await open(tester, state);
        expect(continueButton(tester).onPressed, isNull, reason: '$state');
      }
    });

    testWidgets('available (or unknown) with a name enables Continue, and '
        'the tap submits', (tester) async {
      await open(tester, ready);
      expect(continueButton(tester).onPressed, isNotNull);
      expect(find.text('kaif is available.'), findsOneWidget);
      await tester.tap(find.widgetWithText(AppGradientButton, 'Continue'));
      verify(() => bloc.add(any(that: isA<OnboardingProfileSubmitted>())))
          .called(1);

      await open(
        tester,
        ready.copyWith(handleCheckStatus: HandleCheckStatus.unknown),
      );
      expect(continueButton(tester).onPressed, isNotNull);
    });

    testWidgets('taken: the existing message is shown and Continue is off', (
      tester,
    ) async {
      await open(
        tester,
        ready.copyWith(
          handleCheckStatus: HandleCheckStatus.unavailable,
          handleCheckMessage: '',
        ),
      );
      expect(find.text('That handle is taken.'), findsOneWidget);
      expect(continueButton(tester).onPressed, isNull);
    });

    testWidgets('submitting: Continue is busy and ignores taps', (
      tester,
    ) async {
      await open(tester, ready.copyWith(isSubmitting: true));
      expect(continueButton(tester).busy, isTrue);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await tester.tap(find.byType(AppGradientButton));
      verifyNever(() => bloc.add(any(that: isA<OnboardingProfileSubmitted>())));
    });

    testWidgets('checking shows the spinner; the status icons use theme '
        'colours', (tester) async {
      await open(
        tester,
        ready.copyWith(handleCheckStatus: HandleCheckStatus.checking),
      );
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      await open(tester, ready);
      expect(
        tester.widget<Icon>(find.byIcon(Icons.check_circle)).color,
        appLightTheme.colorScheme.primary,
      );
      await open(
        tester,
        ready.copyWith(handleCheckStatus: HandleCheckStatus.unavailable),
      );
      expect(
        tester.widget<Icon>(find.byIcon(Icons.error)).color,
        appLightTheme.colorScheme.error,
      );
    });

    testWidgets('the delete-account escape stays reachable and opens its '
        'page', (tester) async {
      await open(tester, empty);
      final link = find.widgetWithText(TextButton, 'Delete account');
      expect(tester.getSize(link).height, greaterThanOrEqualTo(48));
      await tester.ensureVisible(link);
      await tester.tap(link);
      await tester.pumpAndSettle();
      expect(find.text('delete stub'), findsOneWidget);
    });

    testWidgets('semantics: Continue is a disabled button, the welcome '
        'heading a header', (tester) async {
      final handle = tester.ensureSemantics();
      await open(tester, empty);
      expect(
        tester.getSemantics(find.byType(AppGradientButton)),
        isSemantics(label: 'Continue', isButton: true, isEnabled: false),
      );
      expect(
        tester.getSemantics(find.text('Welcome to Dzeroth')),
        isSemantics(label: 'Welcome to Dzeroth', isHeader: true),
      );
      handle.dispose();
    });
  });
}
