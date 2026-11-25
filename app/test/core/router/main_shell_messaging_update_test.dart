import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/feature_flags/ui_shell_feature_flag.dart';
import 'package:dzeroth/core/router/main_shell.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/core/theme/theme_mode_cubit.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_event.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_state.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/messages/presentation/bloc/messages_badge_cubit.dart';
import 'package:dzeroth/features/notifications/presentation/bloc/unread_badge_cubit.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';

class _MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

class _MockAuthBloc extends MockBloc<AuthEvent, AuthState>
    implements AuthBloc {}

class _MockGraph extends Mock implements GraphRepository {}

class _MemoryThemeStore implements ThemeModeStore {
  @override
  Future<String?> read() async => null;

  @override
  Future<void> write(String value) async {}
}

/// The Messages destination of `MainShell` for a build below the server's
/// floor (Plan 6 Task 3.C): shown and opening `/messages` at 390, 700 and
/// 1300 dp when `features_needing_update` lists messaging; hidden when
/// messaging is simply off.
void main() {
  Future<GoRouter> pump(
    WidgetTester tester, {
    required double width,
    Set<String> needingUpdate = const {},
    Set<String> flags = const {'posts', 'notifications'},
  }) async {
    final onboarding = _MockOnboardingBloc();
    final auth = _MockAuthBloc();
    whenListen(
      auth,
      const Stream<AuthState>.empty(),
      initialState: const AuthState(status: AuthStatus.authenticated),
    );
    whenListen(
      onboarding,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        status: OnboardingStatus.ready,
        enabledFeatures: {...flags, kFeatureUiShell},
        featuresNeedingUpdate: needingUpdate,
        profile: identity.Profile(
          userId: 'u-alice',
          handle: 'alice',
          displayName: 'Alice A',
        ),
      ),
    );
    GoRoute route(String path) => GoRoute(
      path: path,
      builder: (context, state) => MainShell(
        location: state.matchedLocation,
        child: Center(child: Text('page $path')),
      ),
    );
    final router = GoRouter(
      initialLocation: '/home',
      routes: [
        route('/home'),
        route('/notifications'),
        route('/messages'),
        route('/settings'),
        route('/profile/alice'),
      ],
    );
    addTearDown(router.dispose);
    final messages = MessagesBadgeCubit();
    addTearDown(messages.close);
    final unread = UnreadBadgeCubit();
    addTearDown(unread.close);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 900);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiBlocProvider(
        providers: [
          BlocProvider<OnboardingBloc>.value(value: onboarding),
          BlocProvider<AuthBloc>.value(value: auth),
          BlocProvider<UnreadBadgeCubit>.value(value: unread),
          BlocProvider<MessagesBadgeCubit>.value(value: messages),
          BlocProvider<ThemeModeCubit>(
            create: (_) => ThemeModeCubit(_MemoryThemeStore()),
          ),
        ],
        child: RepositoryProvider<GraphRepository>.value(
          value: _MockGraph(),
          child: MaterialApp.router(
            theme: buildAppTheme(brightness: Brightness.light),
            routerConfig: router,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return router;
  }

  for (final width in [390.0, 700.0, 1300.0]) {
    testWidgets('${width.toInt()} dp: needs an update, the destination opens '
        'Messages', (tester) async {
      final router = await pump(
        tester,
        width: width,
        needingUpdate: const {'messaging'},
      );
      expect(find.byIcon(Icons.mail_outline), findsOneWidget);

      await tester.tap(find.byIcon(Icons.mail_outline));
      await tester.pumpAndSettle();

      expect(router.routeInformationProvider.value.uri.path, '/messages');
    });

    testWidgets('${width.toInt()} dp: messaging simply off, hidden', (
      tester,
    ) async {
      await pump(tester, width: width);
      expect(find.byIcon(Icons.mail_outline), findsNothing);
      expect(find.byIcon(Icons.mail), findsNothing);
    });

    testWidgets('${width.toInt()} dp: an update list with messaging on is '
        'the normal destination', (tester) async {
      await pump(
        tester,
        width: width,
        needingUpdate: const {'messaging'},
        flags: const {'posts', 'notifications', 'messaging'},
      );
      expect(find.byIcon(Icons.mail_outline), findsOneWidget);
    });
  }
}
