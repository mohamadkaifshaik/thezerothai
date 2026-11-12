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
import 'package:dzeroth/shared/widgets/primitives/app_pill_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/geometry.dart';

class _MockOnboarding extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

class _MockAuth extends MockBloc<AuthEvent, AuthState> implements AuthBloc {}

/// Create profile at phone, tablet and desktop widths: one form, one set of
/// actions (Continue, Sign out, Delete account), arranged three ways.
void main() {
  const phone = Size(390, 844);
  const tablet = Size(1024, 768);
  const desktop = Size(1440, 900);

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
    whenListen(
      bloc,
      const Stream<OnboardingState>.empty(),
      initialState: const OnboardingState(
        status: OnboardingStatus.profileRequired,
        handle: 'kaif',
        displayName: 'Kaif',
        handleCheckStatus: HandleCheckStatus.available,
      ),
    );
  });

  Future<void> open(
    WidgetTester tester, {
    required Size size,
    double textScale = 1,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
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
          theme: buildAppTheme(brightness: Brightness.dark),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder cont() => find.widgetWithText(AppPillButton, 'Continue');

  testWidgets('phone: Sign out at the top, Continue pinned to the bottom, '
      'the name before the handle', (tester) async {
    await open(tester, size: phone);
    expect(find.text('Create your profile.'), findsOneWidget);
    expect(
      tester.getRect(find.widgetWithText(TextButton, 'Sign out')).top,
      lessThan(100),
    );
    expect(tester.getRect(cont()).bottom, greaterThan(phone.height - 140));
    expect(
      tester.getRect(find.widgetWithText(TextField, 'Display name')).top,
      lessThan(tester.getRect(find.widgetWithText(TextField, 'Handle')).top),
    );
  });

  testWidgets('tablet: one centred column, Sign out under Continue', (
    tester,
  ) async {
    await open(tester, size: tablet);
    final column = tester.getRect(cont());
    expect(column.width, AppAuthLayout.tabletFormWidth);
    expect(column.center.dx, moreOrLessEquals(tablet.width / 2));
    expect(
      tester.getRect(find.widgetWithText(TextButton, 'Sign out')).top,
      greaterThan(column.bottom),
    );
  });

  testWidgets('desktop: the hero beside the form, Sign out under Continue', (
    tester,
  ) async {
    await open(tester, size: desktop);
    expect(find.textContaining('Pick a handle.'), findsOneWidget);
    expect(tester.getRect(cont()).left, greaterThan(desktop.width * .6));
    expect(
      tester.getRect(find.widgetWithText(TextButton, 'Sign out')).top,
      greaterThan(tester.getRect(cont()).bottom),
    );
  });

  testWidgets('the same actions at every width', (tester) async {
    for (final size in [phone, tablet, desktop]) {
      await open(tester, size: size);
      await tester.tap(cont());
      await tester.tap(find.widgetWithText(TextButton, 'Delete account'));
      await tester.pumpAndSettle();
      expect(find.text('delete stub'), findsOneWidget);
    }
    verify(() => bloc.add(const OnboardingProfileSubmitted())).called(3);
  });

  testWidgets('phone at text scale 2.0: no overflow', (tester) async {
    await open(tester, size: phone, textScale: 2);
    expectNoOverflow(tester);
  });
}
