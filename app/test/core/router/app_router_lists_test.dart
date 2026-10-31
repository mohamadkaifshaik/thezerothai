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
import 'package:dzeroth/features/lists/data/lists_repository.dart';
import 'package:dzeroth/features/lists/presentation/lists_screen.dart';
import 'package:dzeroth/features/lists/presentation/user_lists_screen.dart';
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

class _MockLists extends Mock implements ListsRepository {}

class _MockEngagementRepository extends Mock implements EngagementRepository {}

class _NoThemeStore implements ThemeModeStore {
  @override
  Future<String?> read() async => null;

  @override
  Future<void> write(String value) async {}
}

/// `/lists` on the real router (W5-11): needs the `lists` flag, else Home.
void main() {
  const user = AppUser(
    uid: 'uid-1',
    email: 'a@example.com',
    emailVerified: true,
    isPasswordProvider: true,
  );

  Future<(String, _MockLists)> openAt(
    WidgetTester tester,
    Set<String> flags,
    String location,
  ) async {
    final auth = _MockAuthBloc();
    final onboarding = _MockOnboardingBloc();
    final lists = _MockLists();
    when(() => lists.enabled).thenReturn(true);
    when(
      () => lists.listUserLists(
        ownerId: any(named: 'ownerId'),
        containsUserId: any(named: 'containsUserId'),
        pageSize: any(named: 'pageSize'),
        pageToken: any(named: 'pageToken'),
      ),
    ).thenAnswer((_) async => const ListsPage(lists: []));
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
          RepositoryProvider<ListsRepository>.value(value: lists),
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
    return (appRouter.router.routeInformationProvider.value.uri.path, lists);
  }

  test('the paths', () {
    expect(AppRouter.listsPath, '/lists');
    expect(AppRouter.listPath('12'), '/lists/12');
    expect(AppRouter.userListsPath('u 1'), '/u/u%201/lists');
  });

  testWidgets('lists off: /lists and /lists/1 redirect Home, no RPC', (
    tester,
  ) async {
    for (final location in ['/lists', '/lists/1']) {
      final (path, lists) = await openAt(tester, const {}, location);
      expect(path, AppRouter.homePath, reason: location);
      expect(find.byType(ListsScreen), findsNothing);
      verifyNever(
        () => lists.listUserLists(
          ownerId: any(named: 'ownerId'),
          containsUserId: any(named: 'containsUserId'),
          pageSize: any(named: 'pageSize'),
          pageToken: any(named: 'pageToken'),
        ),
      );
    }
  });

  testWidgets('lists on: /lists shows the screen', (tester) async {
    final (path, _) = await openAt(tester, const {'lists'}, '/lists');
    expect(path, '/lists');
    expect(find.byType(ListsScreen), findsOneWidget);
  });

  testWidgets('lists off: /u/:id/lists redirects Home, no RPC', (tester) async {
    final (path, lists) = await openAt(tester, const {}, '/u/u9/lists');
    expect(path, AppRouter.homePath);
    expect(find.byType(UserListsScreen), findsNothing);
    verifyNever(
      () => lists.listUserLists(
        ownerId: any(named: 'ownerId'),
        containsUserId: any(named: 'containsUserId'),
        pageSize: any(named: 'pageSize'),
        pageToken: any(named: 'pageToken'),
      ),
    );
  });

  testWidgets('lists on: /u/:id/lists shows that person\'s lists', (
    tester,
  ) async {
    final (path, lists) = await openAt(tester, const {'lists'}, '/u/u9/lists');
    expect(path, '/u/u9/lists');
    expect(find.byType(UserListsScreen), findsOneWidget);
    verify(
      () => lists.listUserLists(
        ownerId: 'u9',
        pageSize: any(named: 'pageSize'),
        pageToken: any(named: 'pageToken'),
      ),
    ).called(1);
  });
}
