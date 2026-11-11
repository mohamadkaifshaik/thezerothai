import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/app/session_wiring.dart';
import 'package:dzeroth/core/feature_flags/ui_shell_feature_flag.dart';
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
import 'package:dzeroth/features/settings/presentation/settings_screen.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:dzeroth/shared/widgets/primitives/settings_group.dart';
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

/// `/settings?c=<category>` through the real [AppRouter] (tablet plan
/// section 4.3): the query is not a deep-link target, so a cold open lands
/// Home through the redirects and `/settings` then shows the categories (A)
/// or the placeholder (B); a typed URL in a ready session keeps `c`.
void main() {
  const user = AppUser(
    uid: 'uid-1',
    email: 'a@example.com',
    emailVerified: true,
    isPasswordProvider: true,
  );
  const unknown = AuthState();
  const signedIn = AuthState(status: AuthStatus.authenticated, user: user);
  const idle = OnboardingState();
  final ready = OnboardingState(
    status: OnboardingStatus.ready,
    profile: identity.Profile(userId: 'uid-1', handle: 'me'),
    enabledFeatures: const {'graph', kFeatureUiShell, kFeatureUiTablet},
  );

  late _MockAuthBloc auth;
  late _MockOnboardingBloc onboarding;
  late AppRouter appRouter;

  void setStates(AuthState a, OnboardingState o) {
    when(() => auth.state).thenReturn(a);
    when(() => onboarding.state).thenReturn(o);
  }

  setUp(() {
    auth = _MockAuthBloc();
    onboarding = _MockOnboardingBloc();
    whenListen(auth, const Stream<AuthState>.empty(), initialState: unknown);
    whenListen(
      onboarding,
      const Stream<OnboardingState>.empty(),
      initialState: idle,
    );
    appRouter = AppRouter(authBloc: auth, onboardingBloc: onboarding);
  });

  /// What the router resolves [location] to (redirects included, query
  /// kept), without building a screen.
  Future<String> resolve(WidgetTester tester, String location) async {
    await tester.pumpWidget(const SizedBox());
    final context = tester.element(find.byType(SizedBox));
    final matches = await appRouter.router.routeInformationParser
        .parseRouteInformationWithDependencies(
          RouteInformation(uri: Uri.parse(location)),
          context,
        );
    return matches.uri.toString();
  }

  test('a category link is never a deep-link target', () {
    for (final link in [
      '/settings?c=account',
      '/settings?c=privacy',
      '/settings/blocked?c=privacy',
    ]) {
      expect(AppRouter.deepLinkTarget(Uri.parse(link)), isNull, reason: link);
    }
  });

  testWidgets('cold: the splash, then Home (c is not carried)', (tester) async {
    setStates(unknown, idle);
    expect(await resolve(tester, '/settings?c=account'), '/');

    setStates(signedIn, ready);
    expect(await resolve(tester, '/'), AppRouter.homePath);
  });

  testWidgets('typed in a ready session: c is kept', (tester) async {
    setStates(signedIn, ready);
    expect(await resolve(tester, '/settings?c=account'), '/settings?c=account');
    expect(await resolve(tester, '/settings?c=nope'), '/settings?c=nope');
  });

  for (final width in [700.0, 1024.0]) {
    testWidgets('${width.toInt()} dp: a typed category opens; /settings (the '
        'cold fallback) shows the ${width < 840 ? 'list' : 'placeholder'}', (
      tester,
    ) async {
      setStates(signedIn, ready);
      whenListen(auth, const Stream<AuthState>.empty(), initialState: signedIn);
      whenListen(
        onboarding,
        const Stream<OnboardingState>.empty(),
        initialState: ready,
      );
      final graph = _MockGraph();
      when(() => graph.followRequestsUnavailable).thenReturn(false);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 900);
      addTearDown(tester.view.reset);
      appRouter.router.go('/settings?c=privacy');
      await tester.pumpWidget(
        MultiRepositoryProvider(
          providers: [
            RepositoryProvider<GraphRepository>.value(value: graph),
            RepositoryProvider<UnexpectedErrorReporter>.value(value: (_, _) {}),
          ],
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
      await tester.pumpAndSettle();

      List<String> titles(Finder scope) => [
        for (final row in tester.widgetList<SettingsRow>(
          find.descendant(of: scope, matching: find.byType(SettingsRow)),
        ))
          row.title,
      ];
      final page = find.byType(SettingsScreen);
      expect(titles(page), ['Blocked accounts', 'Muted accounts']);
      if (width >= 840) {
        expect(
          tester
              .widget<SettingsRow>(
                find.descendant(
                  of: find.byType(SettingsCategoriesPane),
                  matching: find.widgetWithText(
                    SettingsRow,
                    'Privacy & safety',
                  ),
                ),
              )
              .selected,
          isTrue,
        );
      }

      appRouter.router.go(AppRouter.settingsPath);
      await tester.pumpAndSettle();
      if (width < 840) {
        expect(titles(page), [
          'Your account',
          'Privacy & safety',
          'Display',
          'About',
          'Sign out',
        ]);
      } else {
        expect(
          find.descendant(of: page, matching: find.text('Select a setting')),
          findsOneWidget,
        );
      }
      expect(tester.takeException(), isNull);
    });
  }
}
