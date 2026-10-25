import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/app/session_wiring.dart';
import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/core/theme/theme_mode_cubit.dart';
import 'package:dzeroth/features/auth/domain/app_user.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_event.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_state.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/features/posts/domain/posts_feature_flag.dart';
import 'package:dzeroth/features/posts/presentation/bloc/pending_posts_cubit.dart';
import 'package:dzeroth/features/posts/presentation/composer_screen.dart';
import 'package:dzeroth/features/posts/presentation/scheduled_posts_screen.dart';
import 'package:dzeroth/features/settings/presentation/settings_screen.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockAuthBloc extends MockBloc<AuthEvent, AuthState>
    implements AuthBloc {}

class _MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

class _MockPostsRepository extends Mock implements PostsRepository {}

class _NoThemeStore implements ThemeModeStore {
  @override
  Future<String?> read() async => null;

  @override
  Future<void> write(String value) async {}
}

/// `/scheduled` and its flag redirect (CMP-D6): the Scheduled posts
/// list exists only with BOTH `posts` and `scheduled_posts`; without them the
/// router sends the caller to Settings.
///
/// The router is pointed at the route BEFORE the first frame, so the Home
/// screen (which needs the whole timeline wiring once `posts` is on) is never
/// built.
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
    final posts = _MockPostsRepository();
    when(
      () => posts.listScheduledPosts(
        pageToken: any(named: 'pageToken'),
        pageSize: any(named: 'pageSize'),
      ),
    ).thenAnswer((_) async => pb.ListScheduledPostsResponse());
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
    appRouter.router.go(AppRouter.scheduledPostsPath);
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<PostsRepository>.value(value: posts),
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
    return appRouter.router.routeInformationProvider.value.uri.path;
  }

  test('the path is a root-level route, not a shell page', () {
    expect(AppRouter.scheduledPostsPath, '/scheduled');
  });

  testWidgets('redirects to Settings unless BOTH flags are on', (tester) async {
    for (final flags in <Set<String>>[
      const {},
      const {kFeaturePosts},
      const {kFeatureScheduledPosts},
    ]) {
      final path = await openAt(tester, flags);
      expect(path, AppRouter.settingsPath, reason: '$flags');
      expect(find.byType(SettingsList), findsOneWidget, reason: '$flags');
      expect(find.byType(ScheduledPostsScreen), findsNothing);
    }
  });

  testWidgets('opens the list with both flags on', (tester) async {
    final path = await openAt(tester, const {
      kFeaturePosts,
      kFeatureScheduledPosts,
    });

    expect(path, AppRouter.scheduledPostsPath);
    expect(find.byType(ScheduledPostsScreen), findsOneWidget);
    expect(find.text('Nothing scheduled'), findsOneWidget);
  });
  testWidgets('from the composer: the dialog link pushes the list over the '
      'draft (real AppRouter, a shell page underneath), Back returns to it', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final auth = _MockAuthBloc();
    final onboarding = _MockOnboardingBloc();
    final posts = _MockPostsRepository();
    final pending = PendingPostsCubit();
    addTearDown(pending.close);
    when(() => posts.subFeatureEnabled(any())).thenReturn(true);
    when(
      () => posts.listScheduledPosts(
        pageToken: any(named: 'pageToken'),
        pageSize: any(named: 'pageSize'),
      ),
    ).thenAnswer((_) async => pb.ListScheduledPostsResponse());
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
        enabledFeatures: const {kFeaturePosts, kFeatureScheduledPosts},
      ),
    );
    final appRouter = AppRouter(authBloc: auth, onboardingBloc: onboarding);
    // Settings is a shell page that needs no timeline wiring (Home does).
    appRouter.router.go(AppRouter.settingsPath);
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<PostsRepository>.value(value: posts),
          RepositoryProvider<UnexpectedErrorReporter>.value(value: (_, _) {}),
        ],
        child: MultiBlocProvider(
          providers: [
            BlocProvider<AuthBloc>.value(value: auth),
            BlocProvider<OnboardingBloc>.value(value: onboarding),
            BlocProvider<PendingPostsCubit>.value(value: pending),
            BlocProvider<ThemeModeCubit>(
              create: (_) => ThemeModeCubit(_NoThemeStore()),
            ),
          ],
          child: MaterialApp.router(
            theme: buildAppTheme(brightness: Brightness.light),
            routerConfig: appRouter.router,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(SettingsList), findsOneWidget);

    // Shell page (Settings) -> /compose (root) -> a second shell page.
    unawaited(appRouter.router.push(AppRouter.composePath));
    await tester.pumpAndSettle();
    expect(find.byType(ComposerScreen), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'my draft');
    await tester.pump();

    await tester.tap(find.byTooltip('Schedule post'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Scheduled posts'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(ScheduledPostsScreen), findsOneWidget);

    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(ScheduledPostsScreen), findsNothing);
    expect(find.byType(ComposerScreen), findsOneWidget);
    expect(find.text('my draft'), findsOneWidget);
  });
}
