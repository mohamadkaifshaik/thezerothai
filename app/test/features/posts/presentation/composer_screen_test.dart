import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/network/app_exception.dart';
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
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/posts_fixtures.dart';

class MockPostsRepository extends Mock implements PostsRepository {}

class MockAuthBloc extends MockBloc<AuthEvent, AuthState> implements AuthBloc {}

class MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

void main() {
  late MockPostsRepository repo;
  late MockAuthBloc authBloc;
  late MockOnboardingBloc onboardingBloc;
  late PendingPostsCubit pending;

  setUp(() {
    repo = MockPostsRepository();
    authBloc = MockAuthBloc();
    onboardingBloc = MockOnboardingBloc();
    pending = PendingPostsCubit();
    whenListen(
      authBloc,
      const Stream<AuthState>.empty(),
      initialState: const AuthState(status: AuthStatus.authenticated),
    );
    whenListen(
      onboardingBloc,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        status: OnboardingStatus.ready,
        profile: identity.Profile(userId: 'me', handle: 'me'),
      ),
    );
  });

  tearDown(() => pending.close());

  void stubCreate(Future<dynamic> Function() answer) {
    when(
      () => repo.createPost(
        idempotencyKey: any(named: 'idempotencyKey'),
        text: any(named: 'text'),
      ),
    ).thenAnswer((_) async => await answer());
  }

  /// Opens `/compose` on top of a home page so a successful post can pop.
  Future<void> open(WidgetTester tester, {ThemeData? theme}) async {
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => const Scaffold(body: Text('home page')),
        ),
        GoRoute(
          path: '/compose',
          builder: (context, state) => const ComposerScreen(),
        ),
      ],
    );
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: [RepositoryProvider<PostsRepository>.value(value: repo)],
        child: MultiBlocProvider(
          providers: [
            BlocProvider<AuthBloc>.value(value: authBloc),
            BlocProvider<OnboardingBloc>.value(value: onboardingBloc),
            BlocProvider<PendingPostsCubit>.value(value: pending),
          ],
          child: MaterialApp.router(
            routerConfig: router,
            theme: theme ?? appLightTheme,
          ),
        ),
      ),
    );
    unawaited(router.push('/compose'));
    await tester.pumpAndSettle();
  }

  FilledButton postButton(WidgetTester tester) =>
      tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Post'));

  testWidgets('starts empty: Post disabled, counter 280', (tester) async {
    await open(tester);
    expect(find.text('New post'), findsOneWidget);
    expect(postButton(tester).onPressed, isNull);
    expect(find.text('280'), findsOneWidget);
  });

  testWidgets('281 code points: counter -1 and Post disabled', (tester) async {
    await open(tester);
    await tester.enterText(find.byType(TextField), 'a' * 281);
    await tester.pump();
    expect(find.text('-1'), findsOneWidget);
    expect(postButton(tester).onPressed, isNull);
    expect(
      find.bySemanticsLabel('Characters over the limit: 1'),
      findsOneWidget,
    );
  });

  testWidgets('decomposed input counts after NFC (0 remaining)', (tester) async {
    await open(tester);
    await tester.enterText(find.byType(TextField), 'é' * 280);
    await tester.pump();
    expect(find.text('0'), findsOneWidget);
    expect(postButton(tester).onPressed, isNotNull);
  });

  testWidgets('11 lines disables Post and explains why', (tester) async {
    await open(tester);
    await tester.enterText(
      find.byType(TextField),
      List.filled(11, 'x').join('\n'),
    );
    await tester.pump();
    expect(postButton(tester).onPressed, isNull);
    expect(find.text('Posts can have at most 10 lines.'), findsOneWidget);
  });

  testWidgets('Post sends the normalised text, shows the optimistic post, '
      'then closes', (tester) async {
    stubCreate(() async {
      // While the call is in flight the optimistic post is pending.
      expect(pending.state, hasLength(1));
      return postView(1);
    });
    await open(tester);
    await tester.enterText(find.byType(TextField), '  hello world  ');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Post'));
    await tester.pumpAndSettle();

    verify(
      () => repo.createPost(
        idempotencyKey: any(named: 'idempotencyKey'),
        text: 'hello world',
      ),
    ).called(1);
    expect(pending.state, isEmpty);
    expect(find.text('home page'), findsOneWidget);
  });

  testWidgets('QUOTA_EXCEEDED shows a snackbar and keeps the text', (
    tester,
  ) async {
    stubCreate(() async => throw const QuotaExceededException('quota'));
    await open(tester);
    await tester.enterText(find.byType(TextField), 'hello');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Post'));
    await tester.pumpAndSettle();

    expect(find.textContaining("reached today's limit"), findsOneWidget);
    expect(find.text('hello'), findsOneWidget);
    expect(pending.state, isEmpty);
    expect(postButton(tester).onPressed, isNotNull);
  });

  testWidgets('DEGRADED_MODE shows the limited-mode message', (tester) async {
    stubCreate(() async => throw const DegradedModeException('degraded'));
    await open(tester);
    await tester.enterText(find.byType(TextField), 'hello');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Post'));
    await tester.pumpAndSettle();
    expect(find.textContaining('limited mode'), findsOneWidget);
  });

  testWidgets('EMAIL_NOT_VERIFIED swaps in VerifyEmailView, back returns', (
    tester,
  ) async {
    stubCreate(() async => throw const EmailNotVerifiedException('verify'));
    await open(tester);
    await tester.enterText(find.byType(TextField), 'hello');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Post'));
    await tester.pumpAndSettle();

    expect(find.text('Verify your email'), findsOneWidget);
    expect(find.text('Please verify your email address to post.'), findsOneWidget);

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('New post'), findsOneWidget);
  });

  testWidgets('works in dark mode with 48dp targets', (tester) async {
    await open(tester, theme: appDarkTheme);
    final size = tester.getSize(find.widgetWithText(FilledButton, 'Post'));
    expect(size.height, greaterThanOrEqualTo(48));
    final close = tester.getSize(find.byTooltip('Close'));
    expect(close.height, greaterThanOrEqualTo(48));
    expect(close.width, greaterThanOrEqualTo(48));
  });
}
