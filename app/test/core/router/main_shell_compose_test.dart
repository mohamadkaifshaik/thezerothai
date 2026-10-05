import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/router/main_shell.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

class MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

void main() {
  late MockOnboardingBloc onboardingBloc;

  setUp(() => onboardingBloc = MockOnboardingBloc());

  Future<void> pump(
    WidgetTester tester, {
    required Set<String> flags,
    String location = '/home',
  }) async {
    whenListen(
      onboardingBloc,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        status: OnboardingStatus.ready,
        enabledFeatures: flags,
      ),
    );
    final router = GoRouter(
      initialLocation: location,
      routes: [
        GoRoute(
          path: '/home',
          builder: (context, state) =>
              MainShell(location: '/home', child: const Text('home body')),
        ),
        GoRoute(
          path: '/settings',
          builder: (context, state) =>
              MainShell(location: '/settings', child: const Text('settings')),
        ),
        GoRoute(
          path: '/compose',
          builder: (context, state) => const Text('compose page'),
        ),
      ],
    );
    await tester.pumpWidget(
      BlocProvider<OnboardingBloc>.value(
        value: onboardingBloc,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('shows the New post button when posts is on and opens compose', (
    tester,
  ) async {
    await pump(tester, flags: {'posts'});
    expect(find.byTooltip('New post'), findsOneWidget);
    await tester.tap(find.byTooltip('New post'));
    await tester.pumpAndSettle();
    expect(find.text('compose page'), findsOneWidget);
  });

  testWidgets('hides it when the posts flag is off', (tester) async {
    await pump(tester, flags: {});
    expect(find.byTooltip('New post'), findsNothing);
  });

  testWidgets('hides it on Settings', (tester) async {
    await pump(tester, flags: {'posts'}, location: '/settings');
    expect(find.byTooltip('New post'), findsNothing);
  });
}
