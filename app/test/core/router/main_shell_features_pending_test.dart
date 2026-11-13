import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/router/main_shell.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/core/widgets/splash_screen.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_event.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_state.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/messages/presentation/bloc/messages_badge_cubit.dart';
import 'package:dzeroth/features/notifications/presentation/bloc/unread_badge_cubit.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

class _MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

class _MockAuthBloc extends MockBloc<AuthEvent, AuthState>
    implements AuthBloc {}

class _MockGraph extends Mock implements GraphRepository {}

// Startup: until the first GetMe answers, no flag reads on. The shell must
// hold the splash, not draw the flags-off page with the legacy bar.
void main() {
  final profile = identity.Profile(
    userId: 'u-alice',
    handle: 'alice',
    displayName: 'Alice A',
  );

  Future<StreamController<OnboardingState>> pump(
    WidgetTester tester,
    OnboardingState initial,
  ) async {
    final onboarding = _MockOnboardingBloc();
    final auth = _MockAuthBloc();
    final controller = StreamController<OnboardingState>.broadcast();
    addTearDown(controller.close);
    whenListen(
      auth,
      const Stream<AuthState>.empty(),
      initialState: const AuthState(status: AuthStatus.authenticated),
    );
    whenListen(onboarding, controller.stream, initialState: initial);
    final router = GoRouter(
      initialLocation: '/home',
      routes: [
        ShellRoute(
          builder: (context, state, child) =>
              MainShell(location: state.matchedLocation, child: child),
          routes: [
            GoRoute(
              path: '/home',
              builder: (context, state) =>
                  const Scaffold(body: Text('home page')),
            ),
          ],
        ),
      ],
    );
    addTearDown(router.dispose);
    final unread = UnreadBadgeCubit(0);
    addTearDown(unread.close);
    final messages = MessagesBadgeCubit();
    addTearDown(messages.close);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 800);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiBlocProvider(
        providers: [
          BlocProvider<OnboardingBloc>.value(value: onboarding),
          BlocProvider<AuthBloc>.value(value: auth),
          BlocProvider<UnreadBadgeCubit>.value(value: unread),
          BlocProvider<MessagesBadgeCubit>.value(value: messages),
        ],
        child: RepositoryProvider<GraphRepository>.value(
          value: _MockGraph(),
          child: MaterialApp.router(
            theme: buildAppTheme(brightness: Brightness.light),
            routerConfig: router,
          ),
        ),
      ),
    );
    await tester.pump();
    return controller;
  }

  for (final (name, initial) in [
    ('loading', const OnboardingState(status: OnboardingStatus.loading)),
    (
      'a cached profile, GetMe not answered',
      OnboardingState(
        status: OnboardingStatus.ready,
        profile: profile,
        flagsPending: true,
      ),
    ),
  ]) {
    testWidgets('$name: the splash, no page and no nav bar', (tester) async {
      await pump(tester, initial);

      expect(find.byType(SplashScreen), findsOneWidget);
      expect(find.text('home page'), findsNothing);
      expect(find.byType(NavigationBar), findsNothing);
      expect(find.byType(BottomNavigationBar), findsNothing);
    });
  }

  testWidgets('the shell appears once the flags are known', (tester) async {
    final controller = await pump(
      tester,
      OnboardingState(
        status: OnboardingStatus.ready,
        profile: profile,
        flagsPending: true,
      ),
    );
    expect(find.byType(SplashScreen), findsOneWidget);

    controller.add(
      OnboardingState(
        status: OnboardingStatus.ready,
        profile: profile,
        enabledFeatures: const {'posts'},
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.byType(SplashScreen), findsNothing);
    expect(find.text('home page'), findsOneWidget);
  });
}
