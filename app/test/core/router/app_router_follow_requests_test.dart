import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/theme/theme_mode_cubit.dart';
import 'package:dzeroth/features/auth/domain/app_user.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_event.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_state.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockAuthBloc extends MockBloc<AuthEvent, AuthState>
    implements AuthBloc {}

class _MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

class _MockGraph extends Mock implements GraphRepository {}

class _NoThemeStore implements ThemeModeStore {
  @override
  Future<String?> read() async => null;

  @override
  Future<void> write(String value) async {}
}

/// `/follow-requests` on the real router (W3-34): reachable with `graph` and
/// either `private_accounts` or a protected caller (the undo rule), else Home.
void main() {
  const user = AppUser(
    uid: 'uid-1',
    email: 'a@example.com',
    emailVerified: true,
    isPasswordProvider: true,
  );

  Future<String> openAt(
    WidgetTester tester,
    Set<String> flags, {
    required bool protected,
  }) async {
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
        profile: identity.Profile(
          userId: 'uid-1',
          handle: 'me',
          isPrivate: protected,
        ),
        enabledFeatures: flags,
      ),
    );
    final graphRepo = _MockGraph();
    when(
      () => graphRepo.listFollowRequests(
        pageSize: any(named: 'pageSize'),
        pageToken: any(named: 'pageToken'),
      ),
    ).thenAnswer((_) async => const GraphPage(items: [], nextPageToken: ''));
    final appRouter = AppRouter(authBloc: auth, onboardingBloc: onboarding);
    await tester.pumpWidget(
      RepositoryProvider<GraphRepository>.value(
        value: graphRepo,
        child: MultiBlocProvider(
          providers: [
            BlocProvider<AuthBloc>.value(value: auth),
            BlocProvider<OnboardingBloc>.value(value: onboarding),
            BlocProvider<ThemeModeCubit>(
              create: (_) => ThemeModeCubit(_NoThemeStore()),
            ),
          ],
          child: MaterialApp.router(routerConfig: appRouter.router),
        ),
      ),
    );
    appRouter.router.go(AppRouter.followRequestsPath);
    await tester.pump();
    await tester.pump();
    // The landing page (Home or the requests list) needs repositories this
    // test does not provide; only the location matters here.
    tester.takeException();
    return appRouter.router.routeInformationProvider.value.uri.path;
  }

  final cases = <String, ({Set<String> flags, bool protected, bool stays})>{
    'public caller, private_accounts on': (
      flags: {'graph', 'private_accounts'},
      protected: false,
      stays: true,
    ),
    'protected caller, private_accounts OFF everywhere (undo rule)': (
      flags: {'graph'},
      protected: true,
      stays: true,
    ),
    'public caller, private_accounts off': (
      flags: {'graph'},
      protected: false,
      stays: false,
    ),
    'protected caller, graph off': (
      flags: {'private_accounts'},
      protected: true,
      stays: false,
    ),
  };
  for (final entry in cases.entries) {
    testWidgets(
      '${entry.key}: ${entry.value.stays ? 'stays' : 'redirects Home'}',
      (tester) async {
        final path = await openAt(
          tester,
          entry.value.flags,
          protected: entry.value.protected,
        );
        expect(
          path,
          entry.value.stays ? AppRouter.followRequestsPath : AppRouter.homePath,
        );
      },
    );
  }
}
