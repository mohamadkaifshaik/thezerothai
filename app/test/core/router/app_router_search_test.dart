import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/app/session_wiring.dart';
import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/theme/theme_mode_cubit.dart';
import 'package:dzeroth/features/auth/domain/app_user.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_event.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_state.dart';
import 'package:dzeroth/features/engagement/data/engagement_repository.dart';
import 'package:dzeroth/features/engagement/presentation/bloc/engagement_cubit.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/search/data/search_repository.dart';
import 'package:dzeroth/features/search/domain/search_results_tab.dart';
import 'package:dzeroth/features/search/presentation/search_results_screen.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../support/fake_search_repository.dart';
import '../../support/posts_fixtures.dart';

class _MockAuthBloc extends MockBloc<AuthEvent, AuthState>
    implements AuthBloc {}

class _MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

class _MockGraphRepository extends Mock implements GraphRepository {}

class _MockEngagementRepository extends Mock implements EngagementRepository {}

class _NoThemeStore implements ThemeModeStore {
  @override
  Future<String?> read() async => null;

  @override
  Future<void> write(String value) async {}
}

/// `/search` on the real router (W4-15): behind the `search` flag, the tab
/// and the query from the URL.
void main() {
  const user = AppUser(
    uid: 'uid-1',
    email: 'a@example.com',
    emailVerified: true,
    isPasswordProvider: true,
  );

  late FakeSearchRepository search;

  Future<String> openAt(
    WidgetTester tester,
    Set<String> flags,
    String location,
  ) async {
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
    final engagement = EngagementCubit(repository: _MockEngagementRepository());
    addTearDown(engagement.close);
    final appRouter = AppRouter(authBloc: auth, onboardingBloc: onboarding);
    appRouter.router.go(location);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<SearchRepository>.value(value: search),
          RepositoryProvider<GraphRepository>.value(
            value: _MockGraphRepository(),
          ),
          RepositoryProvider<UnexpectedErrorReporter>.value(value: (_, _) {}),
        ],
        child: MultiBlocProvider(
          providers: [
            BlocProvider<AuthBloc>.value(value: auth),
            BlocProvider<OnboardingBloc>.value(value: onboarding),
            BlocProvider<EngagementCubit>.value(value: engagement),
            BlocProvider<ThemeModeCubit>(
              create: (_) => ThemeModeCubit(_NoThemeStore()),
            ),
          ],
          child: MaterialApp.router(routerConfig: appRouter.router),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return appRouter.router.routeInformationProvider.value.uri.path;
  }

  setUp(() => search = FakeSearchRepository());

  test('searchPath keeps the sigil, percent-encoded, and the tab', () {
    expect(AppRouter.searchPath('#launch'), '/search?q=%23launch');
    expect(
      AppRouter.searchPath('#launch', tab: SearchResultsTab.latest),
      '/search?q=%23launch&tab=latest',
    );
    expect(AppRouter.searchPath('@bob'), '/search?q=%40bob');
    expect(AppRouter.searchPath('a b&c'), '/search?q=a+b%26c');
  });

  testWidgets('without the search flag the caller is sent Home', (
    tester,
  ) async {
    final path = await openAt(tester, const {'posts'}, '/search?q=%23go');

    expect(path, AppRouter.homePath);
    expect(find.byType(SearchResultsScreen), findsNothing);
    expect(search.calls, isEmpty, reason: 'no RPC for a redirect');
  });

  testWidgets('with the flag, the query and Top come from the URL', (
    tester,
  ) async {
    search.postsResult = SearchPostsPage(posts: [postView(1)]);
    final path = await openAt(tester, const {'search'}, '/search?q=%23go');

    expect(path, '/search');
    expect(find.byType(SearchResultsScreen), findsOneWidget);
    expect(search.calls, ['posts:#go:SEARCH_TAB_TOP']);
  });

  testWidgets('?tab=latest opens Latest', (tester) async {
    await openAt(tester, const {'search'}, '/search?q=%23go&tab=latest');

    expect(search.calls, ['posts:#go:SEARCH_TAB_LATEST']);
  });

  testWidgets('an @handle query defaults to People', (tester) async {
    await openAt(tester, const {'search'}, '/search?q=%40bob');

    expect(search.calls, ['people:bob']);
  });

  testWidgets('an unknown tab value falls back to the default', (tester) async {
    await openAt(tester, const {'search'}, '/search?q=%23go&tab=nope');

    expect(search.calls, ['posts:#go:SEARCH_TAB_TOP']);
  });
}

