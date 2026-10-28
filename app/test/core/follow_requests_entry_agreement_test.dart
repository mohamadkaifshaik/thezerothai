import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/core/theme/theme_mode_cubit.dart';
import 'package:dzeroth/core/widgets/app_account_chip.dart';
import 'package:dzeroth/core/widgets/app_drawer.dart';
import 'package:dzeroth/features/auth/domain/app_user.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_event.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_state.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/notifications/presentation/widgets/follow_requests_row.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockAuth extends MockBloc<AuthEvent, AuthState> implements AuthBloc {}

class _MockOnboarding extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

class _MockGraph extends Mock implements GraphRepository {}

class _NoThemeStore implements ThemeModeStore {
  @override
  Future<String?> read() async => null;

  @override
  Future<void> write(String value) async {}
}

typedef _Case = ({Set<String> flags, bool isProtected, bool backedOff});

/// W3-34b: the drawer row, the account menu entry, the Notifications row and
/// the `/follow-requests` guard follow one rule. This table walks the flag on
/// and off, protected and public, and the backoff, and asserts the four
/// places agree. The count (3) only drives the badge, never visibility. The
/// router has no backoff leg (the screen explains itself): it follows the
/// flags alone.
void main() {
  const user = AppUser(
    uid: 'uid-1',
    email: 'a@example.com',
    emailVerified: true,
    isPasswordProvider: true,
  );

  final cases = <String, _Case>{
    'graph on, protected, private_accounts off': (
      flags: {'graph'},
      isProtected: true,
      backedOff: false,
    ),
    'graph + private_accounts on, public': (
      flags: {'graph', 'private_accounts'},
      isProtected: false,
      backedOff: false,
    ),
    'graph + private_accounts on, protected': (
      flags: {'graph', 'private_accounts'},
      isProtected: true,
      backedOff: false,
    ),
    'graph on, public, private_accounts off (stale count)': (
      flags: {'graph'},
      isProtected: false,
      backedOff: false,
    ),
    'graph off, protected': (
      flags: {'private_accounts'},
      isProtected: true,
      backedOff: false,
    ),
    'graph off, public': (
      flags: <String>{},
      isProtected: false,
      backedOff: false,
    ),
    'backed off, protected': (
      flags: {'graph'},
      isProtected: true,
      backedOff: true,
    ),
    'backed off, public with private_accounts on': (
      flags: {'graph', 'private_accounts'},
      isProtected: false,
      backedOff: true,
    ),
  };

  ({_MockOnboarding onboarding, _MockAuth auth, _MockGraph graph}) rig(
    _Case c,
  ) {
    final onboarding = _MockOnboarding();
    whenListen(
      onboarding,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        status: OnboardingStatus.ready,
        pendingFollowRequestCount: 3,
        enabledFeatures: c.flags,
        profile: identity.Profile(
          userId: 'uid-1',
          handle: 'me',
          displayName: 'Me',
          isPrivate: c.isProtected,
        ),
      ),
    );
    final auth = _MockAuth();
    whenListen(
      auth,
      const Stream<AuthState>.empty(),
      initialState: const AuthState(
        status: AuthStatus.authenticated,
        user: user,
      ),
    );
    final graphRepo = _MockGraph();
    when(() => graphRepo.followRequestsUnavailable).thenReturn(c.backedOff);
    when(
      () => graphRepo.listFollowRequests(
        pageSize: any(named: 'pageSize'),
        pageToken: any(named: 'pageToken'),
      ),
    ).thenAnswer((_) async => const GraphPage(items: [], nextPageToken: ''));
    return (onboarding: onboarding, auth: auth, graph: graphRepo);
  }

  Widget providers(
    ({_MockOnboarding onboarding, _MockAuth auth, _MockGraph graph}) r,
    Widget child,
  ) {
    return RepositoryProvider<GraphRepository>.value(
      value: r.graph,
      child: MultiBlocProvider(
        providers: [
          BlocProvider<OnboardingBloc>.value(value: r.onboarding),
          BlocProvider<AuthBloc>.value(value: r.auth),
          BlocProvider<ThemeModeCubit>(
            create: (_) => ThemeModeCubit(_NoThemeStore()),
          ),
        ],
        child: child,
      ),
    );
  }

  cases.forEach((name, c) {
    final allowed =
        c.flags.contains('graph') &&
        (c.flags.contains('private_accounts') || c.isProtected);
    final shown = allowed && !c.backedOff;

    testWidgets('drawer, account menu, Notifications row: $name', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(800, 900);
      addTearDown(tester.view.reset);
      final r = rig(c);
      final scaffoldKey = GlobalKey<ScaffoldState>();
      await tester.pumpWidget(
        providers(
          r,
          MaterialApp(
            theme: appLightTheme,
            home: Scaffold(
              key: scaffoldKey,
              drawer: const AppDrawer(),
              body: const Align(
                alignment: Alignment.topLeft,
                child: Column(
                  children: [
                    FollowRequestsRow(),
                    AppAccountChip(extended: false),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('notifications-follow-requests')),
        shown ? findsOneWidget : findsNothing,
        reason: 'notifications row',
      );
      await tester.tap(find.byType(AppAccountChip));
      await tester.pumpAndSettle();
      expect(
        find.text('Follow requests'),
        shown ? findsOneWidget : findsNothing,
        reason: 'account menu',
      );
      await tester.tapAt(const Offset(790, 890));
      await tester.pumpAndSettle();
      scaffoldKey.currentState!.openDrawer();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('drawer-follow-requests')),
        shown ? findsOneWidget : findsNothing,
        reason: 'drawer',
      );
      // 0 RPCs: the entries read GetMe state and the backoff flag only.
      verifyNever(
        () => r.graph.listFollowRequests(
          pageSize: any(named: 'pageSize'),
          pageToken: any(named: 'pageToken'),
        ),
      );
    });

    testWidgets('router guard: $name', (tester) async {
      final r = rig(c);
      final appRouter = AppRouter(
        authBloc: r.auth,
        onboardingBloc: r.onboarding,
      );
      await tester.pumpWidget(
        providers(r, MaterialApp.router(routerConfig: appRouter.router)),
      );
      appRouter.router.go(AppRouter.followRequestsPath);
      await tester.pump();
      await tester.pump();
      // The landing page needs repositories this test does not provide.
      tester.takeException();
      expect(
        appRouter.router.routeInformationProvider.value.uri.path,
        allowed ? AppRouter.followRequestsPath : AppRouter.homePath,
      );
    });
  });
}
