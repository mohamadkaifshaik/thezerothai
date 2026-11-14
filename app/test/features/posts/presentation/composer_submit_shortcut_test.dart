import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/app/session_wiring.dart' show UnexpectedErrorReporter;
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_event.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_state.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/features/posts/presentation/bloc/pending_posts_cubit.dart';
import 'package:dzeroth/features/posts/presentation/composer_screen.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

class _MockPosts extends Mock implements PostsRepository {}

class _MockAuth extends MockBloc<AuthEvent, AuthState> implements AuthBloc {}

class _MockOnboarding extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

/// Ctrl+Enter and Cmd+Enter post from the composer, exactly when Post is on.
void main() {
  late _MockPosts repo;
  late PendingPostsCubit pending;
  late Completer<dynamic> answer;
  var created = 0;

  setUp(() {
    repo = _MockPosts();
    pending = PendingPostsCubit();
    answer = Completer<dynamic>();
    created = 0;
    when(
      () => repo.createPost(
        idempotencyKey: any(named: 'idempotencyKey'),
        text: any(named: 'text'),
        replyToPostId: any(named: 'replyToPostId'),
        mediaIds: any(named: 'mediaIds'),
        mediaAltTexts: any(named: 'mediaAltTexts'),
      ),
    ).thenAnswer((_) async {
      created++;
      return await answer.future;
    });
  });

  tearDown(() => pending.close());

  int sent() => created;

  Future<void> open(WidgetTester tester) async {
    final auth = _MockAuth();
    final onboarding = _MockOnboarding();
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
        profile: identity.Profile(userId: 'me', handle: 'me'),
      ),
    );
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => const Scaffold(body: Text('home')),
        ),
        GoRoute(
          path: '/compose',
          builder: (context, state) => const ComposerScreen(),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<PostsRepository>.value(value: repo),
          RepositoryProvider<UnexpectedErrorReporter>.value(
            value: (error, stack) {},
          ),
        ],
        child: MultiBlocProvider(
          providers: [
            BlocProvider<AuthBloc>.value(value: auth),
            BlocProvider<OnboardingBloc>.value(value: onboarding),
            BlocProvider<PendingPostsCubit>.value(value: pending),
          ],
          child: MaterialApp.router(routerConfig: router, theme: appLightTheme),
        ),
      ),
    );
    unawaited(router.push('/compose'));
    await tester.pumpAndSettle();
  }

  Future<void> chord(WidgetTester tester, LogicalKeyboardKey modifier) async {
    await tester.sendKeyDownEvent(modifier);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(modifier);
    await tester.pump();
  }

  for (final (name, key) in [
    ('Ctrl+Enter', LogicalKeyboardKey.controlLeft),
    ('Cmd+Enter', LogicalKeyboardKey.metaLeft),
  ]) {
    testWidgets('$name posts when Post is enabled', (tester) async {
      await open(tester);
      await tester.enterText(find.byType(TextField), 'hello');
      await tester.pump();
      await chord(tester, key);
      expect(sent(), 1);
    });

    testWidgets('$name does nothing while Post is disabled', (tester) async {
      await open(tester);
      await chord(tester, key);
      expect(sent(), 0);
    });
  }

  testWidgets('a second chord while the send is in flight sends nothing', (
    tester,
  ) async {
    await open(tester);
    await tester.enterText(find.byType(TextField), 'hello');
    await tester.pump();
    await chord(tester, LogicalKeyboardKey.controlLeft);
    await chord(tester, LogicalKeyboardKey.controlLeft);
    await chord(tester, LogicalKeyboardKey.metaLeft);
    expect(sent(), 1);
  });

  testWidgets('plain Enter does not post', (tester) async {
    await open(tester);
    await tester.enterText(find.byType(TextField), 'hello');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(sent(), 0);
  });
}
