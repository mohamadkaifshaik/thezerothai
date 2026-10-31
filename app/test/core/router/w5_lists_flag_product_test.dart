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
import 'package:dzeroth/features/engagement/data/engagement_repository.dart';
import 'package:dzeroth/features/engagement/presentation/bloc/engagement_cubit.dart';
import 'package:dzeroth/features/lists/data/home_tabs_repository.dart';
import 'package:dzeroth/features/lists/data/lists_repository.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/features/timeline/data/timeline_repository.dart';
import 'package:dzeroth/features/timeline/data/timeline_store.dart';
import 'package:dzeroth/features/timeline/domain/feed_key.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../support/fake_transport.dart';

class _MockAuthBloc extends MockBloc<AuthEvent, AuthState>
    implements AuthBloc {}

class _MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

class _MockTimeline extends Mock implements TimelineRepository {}

class _MockPosts extends Mock implements PostsRepository {}

class _MockEngagementRepository extends Mock implements EngagementRepository {}

class _NoThemeStore implements ThemeModeStore {
  @override
  Future<String?> read() async => null;

  @override
  Future<void> write(String value) async {}
}

/// W5-16: the flag product `lists` x `ui_shell` x `engagement` on the REAL
/// router with the REAL `ListsRepository` / `HomeTabsRepository` over a
/// recording transport. Every Lists route needs `lists` (Manage pinned also
/// `ui_shell`); with `lists` off nothing may leave the device: not one
/// `ListService` or `SetHomeTabs` request and no list timeline read.
///
/// `engagement` is not read by any Lists screen (`grep kFeatureEngagement
/// lib/features/lists`: none), so its cells prove it changes nothing.
void main() {
  const user = AppUser(
    uid: 'uid-1',
    email: 'a@example.com',
    emailVerified: true,
    isPasswordProvider: true,
  );

  // path -> (needs lists, needs ui_shell)
  const routes = <String, (bool, bool)>{
    '/lists': (true, false),
    '/lists/77': (true, false),
    '/lists/77/members': (true, false),
    '/u/u9/lists': (true, false),
    '/home/pinned': (true, true),
  };

  Future<(String, FakeTransport, _MockTimeline)> openAt(
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
    final transport = FakeTransport((_, _) async {
      // The screens that DO open (lists on) get a calm "not deployed".
      throw connect.ConnectException(connect.Code.unimplemented, 'no');
    });
    final api = ApiClient.withTransport(transport);
    final gate = ServiceFeatureGate(
      isEnabled: () => flags.contains('lists'),
      onUnexpectedError: (_, _) {},
    );
    final lists = ListsRepository(apiClient: api, gate: gate);
    final tabs = HomeTabsRepository(
      apiClient: api,
      gate: gate,
      epoch: SessionEpoch(),
    );
    final timeline = _MockTimeline();
    final posts = _MockPosts();
    when(() => posts.removedPosts).thenAnswer((_) => const Stream.empty());
    when(() => timeline.rateLimitedFor()).thenReturn(null);
    when(() => timeline.sinceRefresh(any())).thenReturn(null);
    when(() => timeline.sinceRefreshAttempt(any())).thenReturn(null);
    when(() => timeline.cached(any()))
        .thenAnswer((_) async => const TimelineSnapshot());
    when(() => timeline.refresh(any()))
        .thenAnswer((_) async => const TimelineSnapshot());
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
          RepositoryProvider<TimelineRepository>.value(value: timeline),
          RepositoryProvider<PostsRepository>.value(value: posts),
          RepositoryProvider<HomeTabsRepository>.value(value: tabs),
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
    return (
      appRouter.router.routeInformationProvider.value.uri.path,
      transport,
      timeline,
    );
  }

  setUpAll(() {
    registerFallbackValue(const FeedKey.home());
  });

  for (final lists in [false, true]) {
    for (final shell in [false, true]) {
      for (final engagement in [false, true]) {
        final flags = {
          if (lists) 'lists',
          if (shell) 'ui_shell',
          if (engagement) 'engagement',
        };
        for (final entry in routes.entries) {
          final path = entry.key;
          final (needsLists, needsShell) = entry.value;
          final allowed = (!needsLists || lists) && (!needsShell || shell);
          final cell = flags.isEmpty ? 'no flags' : flags.join('+');
          testWidgets('$path with $cell: ${allowed ? 'opens' : 'goes Home'}'
              '${lists ? '' : ', zero list RPCs'}', (tester) async {
            final (landed, transport, timeline) = await openAt(
              tester,
              flags,
              path,
            );
            expect(landed, allowed ? path : AppRouter.homePath);
            if (!lists) {
              expect(
                transport.calledProcedures,
                isEmpty,
                reason: 'lists off: nothing may be sent',
              );
              verifyNever(() => timeline.cached(any()));
              verifyNever(() => timeline.refresh(any()));
            } else {
              for (final p in transport.calledProcedures) {
                expect(
                  p,
                  anyOf(contains('ListService'), contains('SetHomeTabs')),
                  reason: 'lists on talks to its own service only',
                );
              }
            }
          });
        }
      }
    }
  }
}
