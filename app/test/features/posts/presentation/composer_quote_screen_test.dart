import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/app/session_wiring.dart' show UnexpectedErrorReporter;
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
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
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
  final quoted = postId(5);

  final preview = pb.EmbeddedPost(
    postId: postId(5),
    text: 'the quoted words',
    author: common.AuthorSnapshot(
      userId: 'u-orig',
      handle: 'orig',
      displayName: 'Original Author',
    ),
  );

  setUp(() {
    repo = MockPostsRepository();
    authBloc = MockAuthBloc();
    onboardingBloc = MockOnboardingBloc();
    pending = PendingPostsCubit();
    when(() => repo.subFeatureEnabled(any())).thenReturn(true);
    whenListen(
      authBloc,
      const Stream<AuthState>.empty(),
      initialState: const AuthState(status: AuthStatus.authenticated),
    );
  });

  tearDown(() => pending.close());

  void features(Set<String> enabled) => whenListen(
    onboardingBloc,
    const Stream<OnboardingState>.empty(),
    initialState: OnboardingState(
      status: OnboardingStatus.ready,
      profile: identity.Profile(userId: 'me', handle: 'me'),
      enabledFeatures: enabled,
    ),
  );

  void stubCreate(Future<pb.PostView> Function() answer) {
    when(
      () => repo.createPost(
        idempotencyKey: any(named: 'idempotencyKey'),
        text: any(named: 'text'),
        replyToPostId: any(named: 'replyToPostId'),
        quoteOfPostId: any(named: 'quoteOfPostId'),
        mediaIds: any(named: 'mediaIds'),
        mediaAltTexts: any(named: 'mediaAltTexts'),
      ),
    ).thenAnswer((_) => answer());
  }

  Future<void> open(
    WidgetTester tester, {
    pb.EmbeddedPost? withPreview,
    String quote = '',
    double textScale = 1,
    double width = 400,
  }) async {
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => const Scaffold(body: Text('home page')),
        ),
        GoRoute(
          path: '/compose',
          builder: (context, state) =>
              ComposerScreen(quoteOfPostId: quote, quotePreview: withPreview),
        ),
      ],
    );
    tester.view.physicalSize = Size(width, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
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
            BlocProvider<AuthBloc>.value(value: authBloc),
            BlocProvider<OnboardingBloc>.value(value: onboardingBloc),
            BlocProvider<PendingPostsCubit>.value(value: pending),
          ],
          child: MaterialApp.router(
            routerConfig: router,
            theme: appDarkTheme,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(textScale)),
              child: child!,
            ),
          ),
        ),
      ),
    );
    unawaited(router.push('/compose'));
    await tester.pumpAndSettle();
  }

  testWidgets('shows the Quote title, hint and the quoted post', (
    tester,
  ) async {
    features({'engagement'});
    await open(tester, quote: quoted, withPreview: preview);

    expect(find.text('Quote'), findsOneWidget);
    expect(find.text('Add a comment'), findsOneWidget);
    expect(find.text('Original Author'), findsOneWidget);
    expect(find.text('the quoted words'), findsOneWidget);
    expect(find.text('280'), findsOneWidget);
  });

  testWidgets('without a preview (page reload) it still quotes', (
    tester,
  ) async {
    features({'engagement'});
    await open(tester, quote: quoted);

    expect(find.text('Quoting a post'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('Post sends quote_of_post_id and closes', (tester) async {
    features({'engagement'});
    stubCreate(() async => postView(9));
    await open(tester, quote: quoted, withPreview: preview);

    await tester.enterText(find.byType(TextField), 'my take');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Post'));
    await tester.pumpAndSettle();

    verify(
      () => repo.createPost(
        idempotencyKey: any(named: 'idempotencyKey'),
        text: 'my take',
        replyToPostId: any(named: 'replyToPostId'),
        quoteOfPostId: quoted,
        mediaIds: any(named: 'mediaIds'),
        mediaAltTexts: any(named: 'mediaAltTexts'),
      ),
    ).called(1);
    expect(find.text('home page'), findsOneWidget);
  });

  testWidgets('NOT_FOUND shows the quote wording and keeps the text', (
    tester,
  ) async {
    features({'engagement'});
    stubCreate(() async => throw const NotFoundException('post not found'));
    await open(tester, quote: quoted, withPreview: preview);

    await tester.enterText(find.byType(TextField), 'my take');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Post'));
    await tester.pumpAndSettle();

    expect(
      find.text("The post you're quoting isn't available any more."),
      findsOneWidget,
    );
    expect(find.text('my take'), findsOneWidget);
  });

  testWidgets('281 characters disable Post, like a plain post', (tester) async {
    features({'engagement'});
    await open(tester, quote: quoted, withPreview: preview);

    await tester.enterText(find.byType(TextField), 'a' * 281);
    await tester.pump();

    expect(find.text('-1'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Post'))
          .onPressed,
      isNull,
    );
  });

  testWidgets('engagement flag off: not available, no composer', (
    tester,
  ) async {
    features({});
    await open(tester, quote: quoted, withPreview: preview);

    expect(find.byType(TextField), findsNothing);
    expect(find.text('Quote'), findsOneWidget);
    verifyNever(
      () => repo.createPost(
        idempotencyKey: any(named: 'idempotencyKey'),
        text: any(named: 'text'),
        quoteOfPostId: any(named: 'quoteOfPostId'),
      ),
    );
  });

  testWidgets('quotes sub-feature known off: not available', (tester) async {
    features({'engagement'});
    when(() => repo.subFeatureEnabled('quotes')).thenReturn(false);
    await open(tester, quote: quoted, withPreview: preview);

    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('a plain /compose is unchanged', (tester) async {
    features({'engagement'});
    await open(tester);

    expect(find.text('New post'), findsOneWidget);
    expect(find.text("What's happening?"), findsOneWidget);
    expect(find.text('Quoting a post'), findsNothing);
  });

  testWidgets('large text on a narrow phone does not overflow', (tester) async {
    features({'engagement'});
    await open(
      tester,
      quote: quoted,
      withPreview: preview,
      textScale: 2,
      width: 320,
    );

    expect(tester.takeException(), isNull);
  });
}
