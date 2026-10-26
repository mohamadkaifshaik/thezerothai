import 'package:bloc_test/bloc_test.dart';
import 'package:connectrpc/connect.dart' as connect;
import 'package:dzeroth/app/session_wiring.dart';
import 'package:dzeroth/core/feature_flags/service_feature_gate.dart';
import 'package:dzeroth/core/network/api_client.dart';
import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/storage/session_epoch.dart';
import 'package:dzeroth/core/theme/theme_mode_cubit.dart';
import 'package:dzeroth/features/auth/domain/app_user.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_event.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_state.dart';
import 'package:dzeroth/features/engagement/data/bookmarks_repository.dart';
import 'package:dzeroth/features/engagement/data/engagement_repository.dart';
import 'package:dzeroth/features/engagement/presentation/bloc/bookmarks_cubit.dart';
import 'package:dzeroth/features/engagement/presentation/bloc/engagement_cubit.dart';
import 'package:dzeroth/features/engagement/presentation/bookmarks_screen.dart';
import 'package:dzeroth/features/engagement/presentation/engagement_error_messages.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../support/bookmarks_fixtures.dart';
import '../../support/fake_transport.dart';
import '../../support/posts_fixtures.dart';

class _MockAuthBloc extends MockBloc<AuthEvent, AuthState>
    implements AuthBloc {}

class _MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

class _MockEngagementRepository extends Mock implements EngagementRepository {}

class _NoThemeStore implements ThemeModeStore {
  @override
  Future<String?> read() async => null;

  @override
  Future<void> write(String value) async {}
}

/// `/bookmarks` on the real router (W2-7): a shell page that needs only the
/// `posts` flag (ADR-0023 D5: List and Remove need `bookmarks` only "not
/// globally off"), and the "not available" answer when it is off for everyone.
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
    FakeBookmarksServer? server,
  }) async {
    final script = server ?? FakeBookmarksServer();
    final auth = _MockAuthBloc();
    final onboarding = _MockOnboardingBloc();
    final repo = BookmarksRepository(
      apiClient: ApiClient.withTransport(FakeTransport(script.handle)),
      gate: ServiceFeatureGate(isEnabled: () => flags.contains('bookmarks')),
      epoch: SessionEpoch(),
    );
    addTearDown(repo.dispose);
    final overlay = BookmarksCubit(repository: repo);
    addTearDown(overlay.close);
    final engagement = EngagementCubit(repository: _MockEngagementRepository());
    addTearDown(engagement.close);
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
    appRouter.router.go(AppRouter.bookmarksPath);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<BookmarksRepository>.value(value: repo),
          RepositoryProvider<UnexpectedErrorReporter>.value(value: (_, _) {}),
        ],
        child: MultiBlocProvider(
          providers: [
            BlocProvider<AuthBloc>.value(value: auth),
            BlocProvider<OnboardingBloc>.value(value: onboarding),
            BlocProvider<EngagementCubit>.value(value: engagement),
            BlocProvider<BookmarksCubit>.value(value: overlay),
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

  test('the path', () {
    expect(AppRouter.bookmarksPath, '/bookmarks');
  });

  testWidgets('without the posts flag the caller is sent Home', (tester) async {
    for (final flags in <Set<String>>[
      const {},
      // The bookmarks flag alone is not enough: posts gates the service.
      const {'bookmarks'},
    ]) {
      final script = FakeBookmarksServer();
      final path = await openAt(tester, flags, server: script);
      expect(path, AppRouter.homePath, reason: '$flags');
      expect(find.byType(BookmarksScreen), findsNothing, reason: '$flags');
      expect(script.listTokens, isEmpty, reason: 'no RPC for a redirect');
    }
  });

  testWidgets('posts alone is enough: a caller dropped from the bookmarks '
      'allowlist still reaches the list (the List RPC is sent)', (
    tester,
  ) async {
    final script = FakeBookmarksServer()
      ..pages[''] = () => bookmarksPage([2, 1]);
    final path = await openAt(tester, const {'posts'}, server: script);

    expect(path, AppRouter.bookmarksPath);
    expect(find.byType(BookmarksScreen), findsOneWidget);
    expect(script.listTokens, ['']);
    expect(find.text(postView(2).post.text), findsOneWidget);
  });

  testWidgets('with both flags: the empty state', (tester) async {
    final path = await openAt(tester, const {'posts', 'bookmarks'});

    expect(path, AppRouter.bookmarksPath);
    expect(find.text(kBookmarksEmptyTitle), findsOneWidget);
  });

  testWidgets('the flag globally off: the not-available state', (tester) async {
    final script = FakeBookmarksServer()
      ..pages[''] = () => throw serverError(
        connect.Code.failedPrecondition,
        common.ErrorReason.ERROR_REASON_FEATURE_DISABLED,
        metadata: {'feature': 'bookmarks'},
      );
    final path = await openAt(tester, const {'posts'}, server: script);

    expect(path, AppRouter.bookmarksPath);
    expect(find.text(kBookmarksUnavailableTitle), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
  });
}
