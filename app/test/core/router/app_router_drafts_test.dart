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
import 'package:dzeroth/features/posts/data/drafts_repository.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/features/posts/domain/composer_draft.dart';
import 'package:dzeroth/features/posts/domain/posts_feature_flag.dart';
import 'package:dzeroth/features/posts/presentation/bloc/pending_posts_cubit.dart';
import 'package:dzeroth/features/posts/presentation/composer_screen.dart';
import 'package:dzeroth/features/posts/presentation/drafts_screen.dart';
import 'package:dzeroth/features/posts/presentation/scheduled_posts_screen.dart';
import 'package:dzeroth/features/settings/presentation/settings_screen.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../support/fake_drafts_repository.dart';

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

/// `/drafts`, the `/scheduled` alias and the composer's way into the list, on
/// the real [AppRouter] (W6-15, ADR-0029).
void main() {
  const user = AppUser(
    uid: 'uid-1',
    email: 'a@example.com',
    emailVerified: true,
    isPasswordProvider: true,
  );
  final now = DateTime.now();
  late FakeDraftsRepository drafts;

  setUp(() {
    drafts = FakeDraftsRepository(
      drafts: [
        ComposerDraft(
          id: '00000000000000a1',
          uid: 'uid-1',
          text: 'saved earlier',
          createdAt: now.subtract(const Duration(minutes: 9)),
          updatedAt: now.subtract(const Duration(minutes: 8)),
        ),
      ],
    );
  });

  Future<AppRouter> start(
    WidgetTester tester,
    Set<String> flags,
    String location, {
    Size size = const Size(390, 844),
  }) async {
    tester.view.physicalSize = size;
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
        enabledFeatures: flags,
      ),
    );
    final appRouter = AppRouter(authBloc: auth, onboardingBloc: onboarding);
    appRouter.router.go(location);
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<PostsRepository>.value(value: posts),
          RepositoryProvider<DraftsRepository>.value(value: drafts),
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
    return appRouter;
  }

  String path(AppRouter r) =>
      r.router.routeInformationProvider.value.uri.toString();

  const on = {kFeaturePosts, kFeatureDrafts};

  test('the paths', () {
    expect(AppRouter.draftsPath, '/drafts');
    expect(AppRouter.scheduledTabPath, '/drafts?tab=scheduled');
    expect(
      AppRouter.composeDraftPath('00000000000000a1'),
      '/compose?draft=00000000000000a1',
    );
  });

  testWidgets('/drafts opens on Unsent posts with drafts on', (tester) async {
    final r = await start(tester, on, AppRouter.draftsPath);
    expect(path(r), '/drafts');
    expect(find.byType(DraftsScreen), findsOneWidget);
    expect(find.text('saved earlier'), findsOneWidget);
  });

  testWidgets('/scheduled is an alias for the Scheduled tab', (tester) async {
    final r = await start(tester, on, AppRouter.scheduledPostsPath);
    expect(path(r), AppRouter.scheduledTabPath);
    expect(find.byType(DraftsScreen), findsOneWidget);
    expect(find.text('Nothing scheduled'), findsOneWidget);
    expect(find.text('saved earlier'), findsNothing);
  });

  testWidgets('drafts off: /scheduled stays the old screen', (tester) async {
    final r = await start(tester, const {
      kFeaturePosts,
    }, AppRouter.scheduledPostsPath);
    expect(path(r), AppRouter.scheduledPostsPath);
    expect(find.byType(ScheduledPostsScreen), findsOneWidget);
    expect(find.byType(DraftsScreen), findsNothing);
  });

  testWidgets('drafts without posts: /scheduled goes to Settings', (
    tester,
  ) async {
    final r = await start(tester, const {
      kFeatureDrafts,
    }, AppRouter.scheduledPostsPath);
    expect(path(r), AppRouter.settingsPath);
    expect(find.byType(SettingsList), findsOneWidget);
  });

  testWidgets('/compose?draft=<id> opens the saved draft', (tester) async {
    await start(tester, on, AppRouter.composeDraftPath('00000000000000a1'));
    expect(find.byType(ComposerScreen), findsOneWidget);
    expect(find.text('saved earlier'), findsOneWidget);
  });

  testWidgets('a malformed draft id opens a new post', (tester) async {
    await start(tester, on, '/compose?draft=../../x');
    expect(find.byType(ComposerScreen), findsOneWidget);
    expect(find.text('saved earlier'), findsNothing);
  });

  /// Settings -> /compose -> Drafts -> pick a draft: one composer, loaded in
  /// place; Back from the list without a choice returns to the same one.
  Future<void> composerToDraftsAndBack(WidgetTester tester, Size size) async {
    final r = await start(tester, on, AppRouter.settingsPath, size: size);
    expect(find.byType(SettingsList), findsOneWidget);
    unawaited(r.router.push(AppRouter.composePath));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'in progress');
    await tester.pump();

    await tester.tap(find.widgetWithText(TextButton, 'Drafts'));
    await tester.pumpAndSettle();
    expect(find.byType(DraftsScreen), findsOneWidget);
    // The text typed before opening the list is kept and listed.
    expect(find.text('in progress'), findsOneWidget);

    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.byType(ComposerScreen), findsOneWidget);
    expect(find.text('in progress'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Drafts'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('saved earlier'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(DraftsScreen), findsNothing);
    expect(find.byType(ComposerScreen), findsOneWidget, reason: 'only one');
    expect(find.text('saved earlier'), findsOneWidget);
  }

  testWidgets('from the composer on a phone: pick a draft, one composer', (
    tester,
  ) async {
    await composerToDraftsAndBack(tester, const Size(390, 844));
  });

  testWidgets('same on a wide screen', (tester) async {
    await composerToDraftsAndBack(tester, const Size(1200, 900));
  });

  testWidgets('the Schedule dialog link goes to the Scheduled tab', (
    tester,
  ) async {
    final r = await start(tester, const {
      kFeaturePosts,
      kFeatureScheduledPosts,
      kFeatureDrafts,
    }, AppRouter.settingsPath);
    unawaited(r.router.push(AppRouter.composePath));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'my draft');
    await tester.pump();
    await tester.tap(find.byTooltip('Schedule post'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Scheduled posts'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(DraftsScreen), findsOneWidget);
    expect(find.text('Nothing scheduled'), findsOneWidget);

    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.byType(ComposerScreen), findsOneWidget);
    expect(find.text('my draft'), findsOneWidget);
  });
}
