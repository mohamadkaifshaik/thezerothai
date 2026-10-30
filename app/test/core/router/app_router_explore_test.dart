import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/theme/theme_mode_cubit.dart';
import 'package:dzeroth/features/auth/domain/app_user.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_event.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_state.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

class _MockAuthBloc extends MockBloc<AuthEvent, AuthState>
    implements AuthBloc {}

class _MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

class _NoThemeStore implements ThemeModeStore {
  @override
  Future<String?> read() async => null;

  @override
  Future<void> write(String value) async {}
}

/// `/explore` on the real router (W4-17): a destination of the new shell,
/// reachable only with `search` and `ui_shell`, else Home.
void main() {
  const user = AppUser(
    uid: 'uid-1',
    email: 'a@example.com',
    emailVerified: true,
    isPasswordProvider: true,
  );

  Future<String> openAt(WidgetTester tester, Set<String> flags) async {
    final auth = _MockAuthBloc();
    final onboarding = _MockOnboardingBloc();
    whenListen(
      auth,
      const Stream<AuthState>.empty(),
      initialState: const AuthState(
        status: AuthStatus.authenticated,
        user: user,
      ),
    );
    whenListen(
      onboarding,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        status: OnboardingStatus.ready,
        profile: identity.Profile(userId: 'uid-1', handle: 'me'),
        enabledFeatures: flags,
      ),
    );
    final appRouter = AppRouter(authBloc: auth, onboardingBloc: onboarding);
    await tester.pumpWidget(
      MultiBlocProvider(
        providers: [
          BlocProvider<AuthBloc>.value(value: auth),
          BlocProvider<OnboardingBloc>.value(value: onboarding),
          BlocProvider<ThemeModeCubit>(
            create: (_) => ThemeModeCubit(_NoThemeStore()),
          ),
        ],
        child: MaterialApp.router(routerConfig: appRouter.router),
      ),
    );
    appRouter.router.go(AppRouter.explorePath);
    await tester.pump();
    await tester.pump();
    // The landing page needs repositories this test does not provide; only the
    // location matters here.
    tester.takeException();
    return appRouter.router.routeInformationProvider.value.uri.path;
  }

  final cases = <String, ({Set<String> flags, bool stays})>{
    'search + ui_shell': (flags: {'search', 'ui_shell'}, stays: true),
    'search only (legacy chrome)': (flags: {'search'}, stays: false),
    'ui_shell only': (flags: {'ui_shell'}, stays: false),
    'neither': (flags: <String>{}, stays: false),
  };

  for (final entry in cases.entries) {
    testWidgets(
      '${entry.key}: ${entry.value.stays ? 'stays' : 'redirects Home'}',
      (tester) async {
        final path = await openAt(tester, entry.value.flags);
        expect(path, entry.value.stays ? AppRouter.explorePath : '/home');
      },
    );
  }
}
