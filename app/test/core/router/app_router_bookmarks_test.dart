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
import 'package:dzeroth/features/engagement/data/likes_repository.dart';
import 'package:dzeroth/features/engagement/presentation/bloc/bookmarks_cubit.dart';
import 'package:dzeroth/features/engagement/presentation/bloc/engagement_cubit.dart';
import 'package:dzeroth/features/engagement/presentation/bookmarks_screen.dart';
import 'package:dzeroth/features/engagement/presentation/engagement_error_messages.dart';
import 'package:dzeroth/features/engagement/presentation/likes_tab.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:dzeroth/shared/widgets/app_tab_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../support/bookmarks_fixtures.dart';
import '../../support/fake_transport.dart';
import '../../support/likes_fixtures.dart';
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

  late Uri lastUri;

  Future<String> openAt(
    WidgetTester tester,
    Set<String> flags, {
    FakeBookmarksServer? server,
    FakeLikesServer? likes,
    String location = AppRouter.bookmarksPath,
  }) async {
    final script = server ?? FakeBookmarksServer();
    // One transport for both lists: the likes server hands the bookmark
    // procedures to the bookmarks server.
    final likesScript = likes ?? FakeLikesServer(bookmarks: script);
    final auth = _MockAuthBloc();
    final onboarding = _MockOnboardingBloc();
    final client = ApiClient.withTransport(FakeTransport(likesScript.handle));
    final epoch = SessionEpoch();
    final repo = BookmarksRepository(
      apiClient: client,
      gate: ServiceFeatureGate(isEnabled: () => flags.contains('bookmarks')),
      epoch: epoch,
    );
    addTearDown(repo.dispose);
    final likesRepo = LikesRepository(
      apiClient: client,
      gate: ServiceFeatureGate(isEnabled: () => flags.contains('likes_list')),
      epoch: epoch,
    );
    addTearDown(likesRepo.dispose);
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
    appRouter.router.go(location);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<BookmarksRepository>.value(value: repo),
          RepositoryProvider<LikesRepository>.value(value: likesRepo),
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
    lastUri = appRouter.router.routeInformationProvider.value.uri;
    return lastUri.path;
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

  group('/bookmarks?tab=likes (W3-18)', () {
    const likesLink = '${AppRouter.bookmarksPath}?tab=likes';

    testWidgets('with likes_list on the link lands on the Likes tab, query '
        'kept; Bookmarks is not asked for', (tester) async {
      final bookmarks = FakeBookmarksServer();
      final likes = FakeLikesServer(bookmarks: bookmarks)
        ..pages[''] = () => likesPage([4, 3]);
      final path = await openAt(
        tester,
        const {'posts', 'engagement', 'bookmarks', 'likes_list'},
        server: bookmarks,
        likes: likes,
        location: likesLink,
      );

      expect(path, AppRouter.bookmarksPath);
      expect(lastUri.queryParameters['tab'], 'likes');
      expect(find.byType(BookmarksScreen), findsOneWidget);
      expect(find.text('Liked post number 4'), findsOneWidget);
      expect(likes.listTokens, ['']);
      expect(bookmarks.listTokens, isEmpty);
    });

    testWidgets('likes_list alone (no bookmarks flag) is enough for the '
        'link', (tester) async {
      final likes = FakeLikesServer()..pages[''] = () => likesPage([4]);
      final path = await openAt(
        tester,
        const {'posts', 'likes_list'},
        likes: likes,
        location: likesLink,
      );

      expect(path, AppRouter.bookmarksPath);
      expect(find.text('Liked post number 4'), findsOneWidget);
    });

    testWidgets('with likes_list off the query is ignored: Bookmarks shows, '
        'no tab bar, no likes call', (tester) async {
      final bookmarks = FakeBookmarksServer()
        ..pages[''] = () => bookmarksPage([2, 1]);
      final likes = FakeLikesServer(bookmarks: bookmarks);
      final path = await openAt(
        tester,
        const {'posts', 'bookmarks'},
        server: bookmarks,
        likes: likes,
        location: likesLink,
      );

      expect(path, AppRouter.bookmarksPath);
      expect(find.byType(BookmarksScreen), findsOneWidget);
      expect(find.byType(AppTabBar), findsNothing);
      expect(find.text(postView(2).post.text), findsOneWidget);
      expect(find.text(kLikesEmptyTitle), findsNothing);
      expect(likes.listCalls, 0);
      expect(bookmarks.listTokens, ['']);
    });

    testWidgets('without the posts flag the link still goes Home, with or '
        'without likes_list', (tester) async {
      for (final flags in <Set<String>>[
        const {'likes_list'},
        const {'likes_list', 'bookmarks'},
      ]) {
        final likes = FakeLikesServer();
        final path = await openAt(
          tester,
          flags,
          likes: likes,
          location: likesLink,
        );
        expect(path, AppRouter.homePath, reason: '$flags');
        expect(find.byType(BookmarksScreen), findsNothing, reason: '$flags');
        expect(likes.listCalls, 0, reason: 'no RPC for a redirect');
      }
    });

    // W3-21: every combination of the three flags that decide the page, for
    // the plain path and for the Likes link. `posts` gates the route (the
    // redirect Home), `likes_list` the tab row and the query; `bookmarks`
    // gates only the entry points (drawer, rail), never the route.
    for (final posts in [false, true]) {
      for (final bookmarks in [false, true]) {
        for (final likesList in [false, true]) {
          final flags = {
            if (posts) 'posts',
            if (bookmarks) 'bookmarks',
            if (likesList) 'likes_list',
          };
          for (final location in [AppRouter.bookmarksPath, likesLink]) {
            testWidgets('flags $flags at $location', (tester) async {
              final script = FakeBookmarksServer()
                ..pages[''] = () => bookmarksPage([2, 1]);
              final likes = FakeLikesServer(bookmarks: script)
                ..pages[''] = () => likesPage([4, 3]);
              final path = await openAt(
                tester,
                flags,
                server: script,
                likes: likes,
                location: location,
              );

              if (!posts) {
                // The redirect: Home, and not one RPC for either list.
                expect(path, AppRouter.homePath);
                expect(find.byType(BookmarksScreen), findsNothing);
                expect(script.listTokens, isEmpty);
                expect(likes.listCalls, 0);
                return;
              }
              expect(path, AppRouter.bookmarksPath);
              expect(find.byType(BookmarksScreen), findsOneWidget);
              final wantsLikes = location == likesLink;
              if (!likesList) {
                // No tab row, the query is ignored, Bookmarks answers.
                expect(find.byType(AppTabBar), findsNothing);
                expect(find.text(postView(2).post.text), findsOneWidget);
                expect(likes.listCalls, 0);
                expect(script.listTokens, ['']);
                return;
              }
              final bar = tester.widget<AppTabBar>(find.byType(AppTabBar));
              expect(bar.selectedIndex, wantsLikes ? 1 : 0);
              expect(likes.listCalls, wantsLikes ? 1 : 0);
              expect(script.listTokens, wantsLikes ? isEmpty : ['']);
            });
          }
        }
      }
    }

    test('a signed-out cold open is not kept through sign-in: the history '
        'link is not a shareable target (W2-9 allowlist, W2-14 I-1)', () {
      expect(AppRouter.deepLinkTarget(Uri.parse(likesLink)), isNull);
      expect(AppRouter.deepLinkTarget(Uri.parse('/bookmarks')), isNull);
    });
  });
}
