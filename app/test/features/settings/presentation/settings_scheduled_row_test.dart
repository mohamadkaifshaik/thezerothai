import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/core/theme/theme_mode_cubit.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_event.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_state.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/posts/domain/posts_feature_flag.dart';
import 'package:dzeroth/features/settings/presentation/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

class _MockAuthBloc extends MockBloc<AuthEvent, AuthState>
    implements AuthBloc {}

class _MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

class _MemoryThemeStore implements ThemeModeStore {
  @override
  Future<String?> read() async => null;

  @override
  Future<void> write(String value) async {}
}

/// The "Scheduled posts" entry of Settings (CMP-D6): only with BOTH the
/// `posts` and `scheduled_posts` flags, and it opens the list route.
void main() {
  Future<void> open(WidgetTester tester, Set<String> flags) async {
    tester.view.physicalSize = const Size(390, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final auth = _MockAuthBloc();
    final onboarding = _MockOnboardingBloc();
    whenListen(
      auth,
      const Stream<AuthState>.empty(),
      initialState: const AuthState(status: AuthStatus.authenticated),
    );
    whenListen(
      onboarding,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(enabledFeatures: flags),
    );
    final router = GoRouter(
      routes: [
        GoRoute(path: '/', builder: (_, _) => const SettingsScreen()),
        GoRoute(
          path: AppRouter.scheduledPostsPath,
          builder: (_, _) => const Scaffold(body: Text('scheduled list')),
        ),
      ],
    );
    await tester.pumpWidget(
      MultiBlocProvider(
        providers: [
          BlocProvider<AuthBloc>.value(value: auth),
          BlocProvider<ThemeModeCubit>(
            create: (_) => ThemeModeCubit(_MemoryThemeStore()),
          ),
          BlocProvider<OnboardingBloc>.value(value: onboarding),
        ],
        child: MaterialApp.router(
          theme: buildAppTheme(brightness: Brightness.light),
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('hidden unless both flags are on', (tester) async {
    for (final flags in <Set<String>>[
      const {},
      const {kFeaturePosts},
      const {kFeatureScheduledPosts},
    ]) {
      await open(tester, flags);
      expect(find.text('Scheduled posts'), findsNothing, reason: '$flags');
    }
  });

  testWidgets('shown with both flags, in its own group, and opens the list', (
    tester,
  ) async {
    await open(tester, {kFeaturePosts, kFeatureScheduledPosts});

    expect(find.text('Posts'), findsOneWidget);
    expect(find.text('Scheduled posts'), findsOneWidget);
    expect(find.byIcon(Icons.schedule_send_outlined), findsOneWidget);

    await tester.tap(find.text('Scheduled posts'));
    await tester.pumpAndSettle();
    expect(find.text('scheduled list'), findsOneWidget);
  });
}
