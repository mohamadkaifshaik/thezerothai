import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/feature_flags/ui_shell_feature_flag.dart';
import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/core/theme/theme_mode_cubit.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_event.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_state.dart';
import 'package:dzeroth/features/messages/data/messaging_repository.dart';
import 'package:dzeroth/features/messages/domain/messaging_feature_flag.dart';
import 'package:dzeroth/features/messages/domain/messaging_feature_gate.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/settings/presentation/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/theme_harness.dart';

class _MockAuthBloc extends MockBloc<AuthEvent, AuthState>
    implements AuthBloc {}

class _MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

class _MockMessagingRepository extends Mock implements MessagingRepository {}

class _MemoryThemeStore implements ThemeModeStore {
  @override
  Future<String?> read() async => null;

  @override
  Future<void> write(String value) async {}
}

/// The "Messages" entry of Settings (W7-19): the legacy chrome (no
/// `ui_shell`) has no Messages tab, so Settings carries the only entry. The
/// new shell has the bar / rail destination and no Settings row.
void main() {
  Future<void> open(
    WidgetTester tester,
    Set<String> flags, {
    Size size = const Size(390, 1100),
    Brightness brightness = Brightness.light,
    double textScale = 1,
    MessagingFeatureGate? gate,
  }) async {
    tester.view.physicalSize = size;
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
          path: AppRouter.messagesPath,
          builder: (_, _) => const Scaffold(body: Text('inbox page')),
        ),
      ],
    );
    addTearDown(router.dispose);
    final repository = _MockMessagingRepository();
    if (gate != null) when(() => repository.gate).thenReturn(gate);
    Widget scope(Widget child) => gate == null
        ? child
        : RepositoryProvider<MessagingRepository>.value(
            value: repository,
            child: child,
          );
    await tester.pumpWidget(
      scope(
        MultiBlocProvider(
          providers: [
            BlocProvider<AuthBloc>.value(value: auth),
            BlocProvider<ThemeModeCubit>(
              create: (_) => ThemeModeCubit(_MemoryThemeStore()),
            ),
            BlocProvider<OnboardingBloc>.value(value: onboarding),
          ],
          child: MaterialApp.router(
            theme: buildAppTheme(brightness: brightness),
            routerConfig: router,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(textScale)),
              child: child!,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('hidden unless messaging is on and ui_shell is off', (
    tester,
  ) async {
    for (final flags in <Set<String>>[
      const {},
      const {kFeatureUiShell},
      const {kFeatureMessaging, kFeatureUiShell}, // the bar/rail has it
    ]) {
      await open(tester, flags);
      expect(find.text('Messages'), findsNothing, reason: '$flags');
      expect(find.text('Messaging'), findsNothing, reason: '$flags');
    }
  });

  Future<MessagingFeatureGate> readOnlyGate() async {
    final gate = MessagingFeatureGate(isMessagingEnabled: () => false);
    await gate.probe(hasCached: () async => true, refresh: () async {});
    return gate;
  }

  testWidgets('read-only Messages (W7-26) shows the row in both chromes and '
      'opens the inbox', (tester) async {
    for (final flags in <Set<String>>[
      const {},
      const {kFeatureUiShell},
    ]) {
      await open(tester, flags, gate: await readOnlyGate());
      expect(find.text('Messages'), findsOneWidget, reason: '$flags');
    }
    await tester.tap(find.text('Messages'));
    await tester.pumpAndSettle();
    expect(find.text('inbox page'), findsOneWidget);
  });

  testWidgets('no row before the probe answers, or without a repository', (
    tester,
  ) async {
    final gate = MessagingFeatureGate(isMessagingEnabled: () => false);
    await open(tester, const {}, gate: gate);
    expect(find.text('Messages'), findsNothing);
    await open(tester, const {});
    expect(find.text('Messages'), findsNothing);
  });

  testWidgets('shown in the legacy chrome, in its own group, and opens the '
      'inbox', (tester) async {
    await open(tester, {kFeatureMessaging});

    expect(find.text('Messaging'), findsOneWidget);
    expect(find.text('Messages'), findsOneWidget);
    expect(find.byIcon(Icons.mail_outline), findsOneWidget);

    await tester.tap(find.text('Messages'));
    await tester.pumpAndSettle();
    expect(find.text('inbox page'), findsOneWidget);
  });

  forEachThemeAndWidth(
    'the entry fits',
    (tester, env) async {
      await open(
        tester,
        {kFeatureMessaging},
        size: Size(env.size.width, 1400),
        brightness: env.brightness,
        textScale: env.textScale,
      );

      expect(tester.takeException(), isNull);
      expect(find.text('Messages'), findsOneWidget);
    },
    textScales: kMatrixTextScalesLarge,
    height: 1400,
  );
}
