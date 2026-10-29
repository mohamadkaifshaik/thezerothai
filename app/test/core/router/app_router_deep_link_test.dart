import 'dart:async';

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
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/features/posts/presentation/post_detail_screen.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../support/posts_fixtures.dart';

class _MockAuthBloc extends MockBloc<AuthEvent, AuthState>
    implements AuthBloc {}

class _MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

class _MockPostsRepository extends Mock implements PostsRepository {}

class _MockGraphRepository extends Mock implements GraphRepository {}

class _NoThemeStore implements ThemeModeStore {
  @override
  Future<String?> read() async => null;

  @override
  Future<void> write(String value) async {}
}

/// W2-9: a shared link (`/post/<id>`, `/u/<id>`, `/profile/<handle>`) that a
/// visitor cold-opens survives every `_redirect` hop (splash while auth is
/// unknown, sign-in, onboarding, the email prompt) and only those three shapes
/// are ever kept.
void main() {
  const user = AppUser(
    uid: 'uid-1',
    email: 'a@example.com',
    emailVerified: true,
    isPasswordProvider: true,
  );
  const unknown = AuthState();
  const signedOut = AuthState(status: AuthStatus.unauthenticated);
  const signedIn = AuthState(status: AuthStatus.authenticated, user: user);
  const unverified = AuthState(
    status: AuthStatus.needsEmailVerification,
    user: user,
  );
  const ready = OnboardingState(status: OnboardingStatus.ready);
  const noProfile = OnboardingState(status: OnboardingStatus.profileRequired);
  const idle = OnboardingState();

  final targets = <String>[
    '/post/${postId(7)}',
    AppRouter.profileByIdPath('uid-9'),
    AppRouter.profilePath('maria'),
  ];

  late _MockAuthBloc auth;
  late _MockOnboardingBloc onboarding;
  late AppRouter appRouter;

  /// Moves the (mock) blocs to [a] / [o] the way a real emit would.
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

  /// What the router resolves [location] to, redirect chain included, without
  /// building any screen: the same parser a browser's initial URL goes through.
  Future<String> resolve(WidgetTester tester, String location) async {
    await tester.pumpWidget(const SizedBox());
    final context = tester.element(find.byType(SizedBox));
    final matches = await appRouter.router.routeInformationParser
        .parseRouteInformationWithDependencies(
          RouteInformation(uri: Uri.parse(location)),
          context,
        );
    return matches.uri.path;
  }

  group('deepLinkTarget', () {
    test('keeps the three shareable shapes, as a bare path', () {
      expect(
        AppRouter.deepLinkTarget(Uri.parse('/post/${postId(7)}')),
        '/post/${postId(7)}',
      );
      expect(AppRouter.deepLinkTarget(Uri.parse('/u/abc123')), '/u/abc123');
      expect(
        AppRouter.deepLinkTarget(Uri.parse('/profile/maria')),
        '/profile/maria',
      );
      // The edges of the grammars (I-1).
      for (final good in [
        '/u/${'a' * 128}',
        '/u/A-1',
        '/profile/abc',
        '/profile/Maria_99',
        '/profile/${'a' * 15}',
      ]) {
        expect(AppRouter.deepLinkTarget(Uri.parse(good)), good, reason: good);
      }
      // A query and a fragment are dropped, never carried along.
      expect(
        AppRouter.deepLinkTarget(Uri.parse('/profile/maria?x=1#frag')),
        '/profile/maria',
      );
    });

    // W7-19: a conversation link is exactly 32 lower-case hex digits.
    final convId = 'ab12' * 8;

    test('keeps /messages/<32 lower-case hex> as a bare path', () {
      for (final good in [
        '/messages/$convId',
        '/messages/${'0' * 32}',
        '/messages/${'f' * 32}',
        '/messages/0123456789abcdef0123456789abcdef',
      ]) {
        expect(AppRouter.deepLinkTarget(Uri.parse(good)), good, reason: good);
      }
    });

    test('rejects every other /messages shape (the allowlist is exact)', () {
      for (final bad in <String>[
        // Not conversation targets at all.
        '/messages',
        '/messages/',
        '/messages/requests',
        '/messages/new',
        '/messages/new/draft',
        // Length: 31 and 33 digits, short ids.
        '/messages/${'a' * 31}',
        '/messages/${'a' * 33}',
        '/messages/ABC',
        '/messages/${'ab12' * 8}0',
        // Case and alphabet: upper-case hex, a g, a dash.
        '/messages/${'AB12' * 8}',
        '/messages/${'ab12' * 7}ab1G',
        '/messages/${'ab12' * 7}ab1g',
        '/messages/${'ab12' * 7}ab1-',
        // Shape: a trailing slash, a sub-path, an encoded slash or space.
        '/messages/$convId/',
        '/messages/$convId/x',
        '/messages/${'ab12' * 7}ab1%2F',
        '/messages/${'ab12' * 7}ab1%20',
        '/messages/${'ab12' * 7}%2e%2e',
        '/messages/%2e%2e/$convId',
        '/messages//$convId',
        '/Messages/$convId',
        // Not relative.
        '//evil/messages/$convId',
        'https://evil.example/messages/$convId',
        'javascript:/messages/$convId',
      ]) {
        expect(AppRouter.deepLinkTarget(Uri.parse(bad)), isNull, reason: bad);
      }
    });

    test('a query or a fragment disqualifies a conversation link', () {
      // Tighter than /u/... and /profile/..., which drop them and keep the
      // path (above): here the whole link is refused.
      for (final bad in <String>[
        '/messages/$convId?x=1',
        '/messages/$convId?',
        '/messages/$convId#f',
        '/messages/$convId#',
        '/messages/$convId?x=1#f',
      ]) {
        expect(AppRouter.deepLinkTarget(Uri.parse(bad)), isNull, reason: bad);
      }
      expect(
        AppRouter.deepLinkTarget(Uri.parse('/post/${postId(7)}?x=1')),
        '/post/${postId(7)}',
      );
    });

    test('rejects everything else', () {
      for (final bad in <String>[
        '//evil',
        '//evil/post/${postId(7)}',
        'https://evil.example/post/${postId(7)}',
        'http://evil.example/u/abc',
        'javascript:alert(1)',
        '/post/abc',
        '/post/${postId(7)}0',
        '/post/${postId(7).substring(1)}',
        '/post/${postId(7)}/x',
        '/post/',
        '/u/',
        '/u/a/b',
        '/profile/',
        '/profile/maria/followers',
        // I-1: encoded slashes, CR/LF and other characters outside the uid
        // and handle grammars never become a target.
        '/u/a%2Fb',
        '/u/a%2fb',
        '/u/abc%0D%0Adef',
        '/u/abc%0Adef',
        '/u/abc%20',
        '/u/..%2F..',
        '/u/ab_c',
        '/u/${'a' * 129}',
        '/profile/ma%2Fria',
        '/profile/maria%0D%0A',
        '/profile/%0D%0Amaria',
        '/profile/ma.ria',
        '/profile/ma-ria',
        '/profile/ab',
        '/profile/${'a' * 16}',
        '/settings',
        '/settings/delete-account',
        '/compose',
        '/home',
        '/',
        '/sign-in',
        '/onboarding',
        '/__/auth/handler',
        '/__/auth/iframe',
        '',
      ]) {
        expect(AppRouter.deepLinkTarget(Uri.parse(bad)), isNull, reason: bad);
      }
    });
  });

  for (final target in targets) {
    group('cold open of $target', () {
      testWidgets('auth unknown: the splash, then the target once ready', (
        tester,
      ) async {
        setStates(unknown, idle);
        expect(await resolve(tester, target), '/');

        // Auth resolves; the splash re-evaluates its own location.
        setStates(signedIn, ready);
        expect(await resolve(tester, '/'), target);
        // Moving on to another page forgets it: a later splash goes Home.
        expect(await resolve(tester, AppRouter.homePath), AppRouter.homePath);
        expect(await resolve(tester, '/'), AppRouter.homePath);
      });

      testWidgets('auth unknown, then signed out: sign-in, then the target '
          'after sign-in', (tester) async {
        setStates(unknown, idle);
        expect(await resolve(tester, target), '/');

        setStates(signedOut, idle);
        expect(await resolve(tester, '/'), AppRouter.signInPath);

        setStates(signedIn, ready);
        expect(await resolve(tester, AppRouter.signInPath), target);
      });

      testWidgets('signed out: sign-in (and sign-up) lead to the target', (
        tester,
      ) async {
        setStates(signedOut, idle);
        expect(await resolve(tester, target), AppRouter.signInPath);

        setStates(signedIn, ready);
        expect(await resolve(tester, AppRouter.signUpPath), target);
      });

      testWidgets('signed in without a profile: onboarding, then the target '
          'once the profile exists', (tester) async {
        setStates(signedIn, noProfile);
        expect(await resolve(tester, target), AppRouter.onboardingPath);

        setStates(signedIn, ready);
        expect(await resolve(tester, AppRouter.onboardingPath), target);
      });

      testWidgets('sign-in to onboarding to the target (the whole chain)', (
        tester,
      ) async {
        setStates(signedOut, idle);
        expect(await resolve(tester, target), AppRouter.signInPath);

        // Signed in, GetMe says profile required: sign-in hops to the target,
        // which hops to onboarding and must keep stashing the target.
        setStates(signedIn, noProfile);
        expect(
          await resolve(tester, AppRouter.signInPath),
          AppRouter.onboardingPath,
        );

        setStates(signedIn, ready);
        expect(await resolve(tester, AppRouter.onboardingPath), target);
      });

      testWidgets('signed in, email not verified: stays on the target (the '
          'gate shows the prompt in place)', (tester) async {
        setStates(unverified, idle);
        expect(await resolve(tester, target), target);

        // After a sign-in with an unverified address.
        setStates(signedOut, idle);
        expect(await resolve(tester, target), AppRouter.signInPath);
        setStates(unverified, idle);
        expect(await resolve(tester, AppRouter.signInPath), target);
      });

      testWidgets('onboarding says the email is unverified: stays on the '
          'target', (tester) async {
        setStates(
          signedIn,
          const OnboardingState(
            status: OnboardingStatus.emailVerificationRequired,
          ),
        );
        expect(await resolve(tester, target), target);
      });

      testWidgets('ready: opens the target directly', (tester) async {
        setStates(signedIn, ready);
        expect(await resolve(tester, target), target);
      });
    });
  }

  group('conversation links (W7-19)', () {
    final link = '/messages/${'ab12' * 8}';
    const readyMessaging = OnboardingState(
      status: OnboardingStatus.ready,
      enabledFeatures: {'messaging'},
    );

    testWidgets('a cold open while auth is unknown ends on the conversation', (
      tester,
    ) async {
      setStates(unknown, idle);
      expect(await resolve(tester, link), '/');

      setStates(signedIn, readyMessaging);
      expect(await resolve(tester, '/'), link);
      // Moving on forgets it.
      expect(await resolve(tester, AppRouter.homePath), AppRouter.homePath);
      expect(await resolve(tester, '/'), AppRouter.homePath);
    });

    testWidgets('signed out: sign-in leads to the conversation', (
      tester,
    ) async {
      setStates(signedOut, idle);
      expect(await resolve(tester, link), AppRouter.signInPath);

      setStates(signedIn, readyMessaging);
      expect(await resolve(tester, AppRouter.signInPath), link);
    });

    testWidgets('no profile yet: onboarding, then the conversation', (
      tester,
    ) async {
      setStates(signedOut, idle);
      expect(await resolve(tester, link), AppRouter.signInPath);

      setStates(signedIn, noProfile);
      expect(
        await resolve(tester, AppRouter.signInPath),
        AppRouter.onboardingPath,
      );

      setStates(signedIn, readyMessaging);
      expect(await resolve(tester, AppRouter.onboardingPath), link);
    });

    testWidgets('ready with messaging on: opens directly', (tester) async {
      setStates(signedIn, readyMessaging);
      expect(await resolve(tester, link), link);
    });

    testWidgets('messaging off for the caller: every messages route goes Home '
        '(flag-off redirect)', (tester) async {
      setStates(signedIn, ready);
      for (final route in <String>[
        link,
        AppRouter.messagesPath,
        AppRouter.messageRequestsPath,
        AppRouter.messageNewPath,
        AppRouter.messageDraftPath,
      ]) {
        expect(await resolve(tester, route), AppRouter.homePath, reason: route);
      }
    });

    testWidgets('a link that is not exactly a conversation id is not stashed '
        '(Home after sign-in)', (tester) async {
      final id = 'ab12' * 8;
      for (final bad in <String>[
        '/messages/ABC',
        '/messages/${id}0',
        '/messages/${id.substring(1)}',
        '/messages/${id.toUpperCase()}',
        '/messages/$id?x=1',
        '/messages/$id#f',
        // (A trailing slash is canonicalised by go_router before the redirect
        // runs, so it becomes the exact path; deepLinkTarget itself refuses
        // it, see the table above.)
        AppRouter.messagesPath,
        AppRouter.messageRequestsPath,
        AppRouter.messageNewPath,
      ]) {
        // A fresh router per link: landing once would hide a stash later.
        appRouter = AppRouter(authBloc: auth, onboardingBloc: onboarding);
        setStates(signedOut, idle);
        expect(await resolve(tester, bad), AppRouter.signInPath, reason: bad);

        setStates(signedIn, readyMessaging);
        expect(
          await resolve(tester, AppRouter.signInPath),
          AppRouter.homePath,
          reason: bad,
        );
      }
    });
  });

  group('what is not kept', () {
    testWidgets('an unlisted route goes Home after the hops', (tester) async {
      for (final route in <String>[
        AppRouter.settingsPath,
        '/post/abc',
        '/profile/maria/followers',
      ]) {
        setStates(unknown, idle);
        await resolve(tester, route);
        setStates(signedIn, ready);
        expect(await resolve(tester, '/'), AppRouter.homePath, reason: route);
      }
    });

    testWidgets('a route that is not shareable replaces an older target', (
      tester,
    ) async {
      setStates(signedOut, idle);
      expect(await resolve(tester, targets.first), AppRouter.signInPath);
      // The visitor went elsewhere signed out: that is where they were sent.
      expect(
        await resolve(tester, AppRouter.settingsPath),
        AppRouter.signInPath,
      );

      setStates(signedIn, ready);
      expect(await resolve(tester, AppRouter.signInPath), AppRouter.homePath);
    });

    testWidgets('//evil and absolute URLs never become the landing page', (
      tester,
    ) async {
      for (final bad in <String>[
        '//evil',
        'https://evil.example/post/${postId(7)}',
      ]) {
        setStates(unknown, idle);
        await resolve(tester, bad);
        setStates(signedIn, ready);
        final landed = await resolve(tester, AppRouter.signInPath);
        expect(landed, AppRouter.homePath, reason: bad);
      }
    });

    testWidgets('/__/auth/ paths are not captured as a target', (tester) async {
      setStates(unknown, idle);
      await resolve(tester, '/__/auth/handler');
      setStates(signedIn, ready);
      expect(await resolve(tester, '/'), AppRouter.homePath);
    });

    testWidgets('after landing, a sign-out and sign-in goes Home, not back to '
        'the old link', (tester) async {
      setStates(signedOut, idle);
      await resolve(tester, targets.first);
      setStates(signedIn, ready);
      expect(await resolve(tester, AppRouter.signInPath), targets.first);
      // The visitor is on the post, signed in and ready.
      expect(await resolve(tester, targets.first), targets.first);

      // Sign-out while on the post, then (maybe another account) sign-in.
      setStates(signedOut, idle);
      expect(await resolve(tester, targets.first), AppRouter.signInPath);
      setStates(signedIn, ready);
      expect(await resolve(tester, AppRouter.signInPath), AppRouter.homePath);
    });

    testWidgets('while GetMe is still loading the target is not spent', (
      tester,
    ) async {
      setStates(signedOut, idle);
      await resolve(tester, targets.first);

      // Signed in, onboarding not answered yet: the post opens in place...
      setStates(
        signedIn,
        const OnboardingState(status: OnboardingStatus.loading),
      );
      expect(await resolve(tester, AppRouter.signInPath), targets.first);
      expect(await resolve(tester, targets.first), targets.first);

      // ...and GetMe then says profile required: onboarding, then the post.
      setStates(signedIn, noProfile);
      expect(await resolve(tester, targets.first), AppRouter.onboardingPath);
      setStates(signedIn, ready);
      expect(await resolve(tester, AppRouter.onboardingPath), targets.first);
    });
  });

  group('through the real UI', () {
    late _MockPostsRepository posts;
    late _MockGraphRepository graph;
    late StreamController<AuthState> authEvents;
    late StreamController<OnboardingState> onboardingEvents;

    setUp(() {
      posts = _MockPostsRepository();
      graph = _MockGraphRepository();
      when(() => graph.cached(any())).thenReturn(null);
      when(() => posts.getPost(postId(7)))
          .thenAnswer((_) async => postView(7, text: 'shared hello'));
      authEvents = StreamController<AuthState>.broadcast();
      onboardingEvents = StreamController<OnboardingState>.broadcast();
      addTearDown(authEvents.close);
      addTearDown(onboardingEvents.close);
    });

    void emit(AuthState a, OnboardingState o) {
      setStates(a, o);
      authEvents.add(a);
      onboardingEvents.add(o);
    }

    testWidgets('a cold open while auth is unknown ends on the post', (
      tester,
    ) async {
      // A browser's initial URL, as go_router reads it on the first build.
      tester.binding.platformDispatcher.defaultRouteNameTestValue =
          '/post/${postId(7)}';
      addTearDown(
        tester.binding.platformDispatcher.clearDefaultRouteNameTestValue,
      );

      whenListen(auth, authEvents.stream, initialState: unknown);
      whenListen(onboarding, onboardingEvents.stream, initialState: idle);
      appRouter = AppRouter(authBloc: auth, onboardingBloc: onboarding);
      await tester.pumpWidget(
        MultiRepositoryProvider(
          providers: [
            RepositoryProvider<PostsRepository>.value(value: posts),
            RepositoryProvider<GraphRepository>.value(value: graph),
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
      await tester.pump();
      String path() => appRouter.router.routeInformationProvider.value.uri.path;

      // The splash holds the page while Firebase reports.
      expect(path(), '/');
      expect(find.byType(PostDetailScreen), findsNothing);

      // Signed out: sign-in. Then signed in with no profile yet: onboarding.
      emit(signedOut, idle);
      await tester.pump();
      await tester.pump();
      expect(path(), AppRouter.signInPath);
      emit(signedIn, noProfile);
      await tester.pump();
      await tester.pump();
      expect(path(), AppRouter.onboardingPath);

      // The profile is created: the post, not Home.
      emit(
        signedIn,
        OnboardingState(
          status: OnboardingStatus.ready,
          enabledFeatures: const {'posts'},
          profile: identity.Profile(userId: 'uid-1', handle: 'me'),
        ),
      );
      await tester.pumpAndSettle();
      expect(path(), '/post/${postId(7)}');
      expect(find.byType(PostDetailScreen), findsOneWidget);
      expect(find.text('shared hello'), findsOneWidget);
    });
  });
}
