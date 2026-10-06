import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/features/posts/presentation/post_detail_screen.dart';
import 'package:dzeroth/gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/posts_fixtures.dart';
import '../../../support/timeline_fixtures.dart';

class MockGraphRepository extends Mock implements GraphRepository {}

class MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

void main() {
  late MockPostsRepository posts;
  late MockGraphRepository graphRepository;
  late MockOnboardingBloc onboardingBloc;

  setUp(() {
    posts = MockPostsRepository();
    graphRepository = MockGraphRepository();
    onboardingBloc = MockOnboardingBloc();
    when(() => graphRepository.cached(any())).thenReturn(null);
  });

  /// Opens `/post/<id>` on top of a home page so Back/delete can pop.
  Future<void> open(
    WidgetTester tester, {
    Set<String> features = const {'posts'},
    ThemeData? theme,
    bool settle = true,
  }) async {
    whenListen(
      onboardingBloc,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        enabledFeatures: features,
        profile: identity.Profile(userId: 'me', handle: 'me'),
      ),
    );
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => const Scaffold(body: Text('home page')),
        ),
        GoRoute(
          path: '/home',
          builder: (context, state) => const Scaffold(body: Text('home page')),
        ),
        GoRoute(
          path: '/post/:id',
          builder: (context, state) =>
              PostDetailScreen(postId: state.pathParameters['id']!),
        ),
      ],
    );
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<PostsRepository>.value(value: posts),
          RepositoryProvider<GraphRepository>.value(value: graphRepository),
        ],
        child: BlocProvider<OnboardingBloc>.value(
          value: onboardingBloc,
          child: MaterialApp.router(
            routerConfig: router,
            theme: theme ?? appLightTheme,
          ),
        ),
      ),
    );
    unawaited(router.push('/post/${postId(1)}'));
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
      await tester.pump();
    }
  }

  testWidgets('loads and shows the post', (tester) async {
    final done = Completer<void>();
    when(() => posts.getPost(postId(1))).thenAnswer((_) async {
      await done.future;
      return postView(1, text: 'hello detail');
    });

    await open(tester, settle: false);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    done.complete();
    await tester.pumpAndSettle();

    expect(find.text('hello detail'), findsOneWidget);
    expect(find.text('Post'), findsOneWidget); // the app bar title
    verify(() => posts.getPost(postId(1))).called(1);
  });

  testWidgets('NOT_FOUND: "This post isn\'t available", no retry loop', (
    tester,
  ) async {
    when(
      () => posts.getPost(postId(1)),
    ).thenAnswer((_) async => throw const NotFoundException('post not found'));

    await open(tester);
    await tester.pump(const Duration(seconds: 30));

    expect(find.text("This post isn't available"), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
    verify(() => posts.getPost(postId(1))).called(1);

    await tester.tap(find.text('Go to Home'));
    await tester.pumpAndSettle();
    expect(find.text('home page'), findsOneWidget);
  });

  testWidgets('a network error offers Retry', (tester) async {
    when(
      () => posts.getPost(postId(1)),
    ).thenAnswer((_) async => throw const NetworkException('offline'));
    await open(tester);
    expect(
      find.text('No connection. Check your network and try again.'),
      findsOneWidget,
    );

    when(
      () => posts.getPost(postId(1)),
    ).thenAnswer((_) async => postView(1, text: 'back online'));
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('back online'), findsOneWidget);
  });

  testWidgets('deleting an own post calls DeletePost and leaves the screen', (
    tester,
  ) async {
    when(
      () => posts.getPost(postId(1)),
    ).thenAnswer((_) async => postView(1, authorId: 'me', text: 'mine'));
    when(
      () => posts.deletePost(
        postId: postId(1),
        idempotencyKey: any(named: 'idempotencyKey'),
      ),
    ).thenAnswer((_) async {});

    await open(tester);
    await tester.tap(find.byTooltip('More options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();

    verify(
      () => posts.deletePost(
        postId: postId(1),
        idempotencyKey: any(named: 'idempotencyKey'),
      ),
    ).called(1);
    expect(find.text('home page'), findsOneWidget);
  });

  testWidgets('a blocked author sits behind a "Show post" banner', (
    tester,
  ) async {
    when(
      () => posts.getPost(postId(1)),
    ).thenAnswer((_) async => postView(1, text: 'hidden words'));
    when(
      () => graphRepository.cached('u1'),
    ).thenReturn(graph.Relationship(userId: 'u1', blocking: true));

    await open(tester, features: const {'posts', 'graph'});

    expect(find.text('You blocked @hu1 ·'), findsOneWidget);
    expect(find.text('hidden words'), findsNothing);

    await tester.tap(find.text('Show post'));
    await tester.pumpAndSettle();

    expect(find.text('hidden words'), findsOneWidget);
  });

  testWidgets('posts flag off: nothing is requested', (tester) async {
    await open(tester, features: const {});

    expect(find.text("This feature isn't available yet."), findsOneWidget);
    verifyNever(() => posts.getPost(any()));
  });

  testWidgets('dark mode, wide layout: no overflow', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    when(
      () => posts.getPost(postId(1)),
    ).thenAnswer((_) async => postView(1, text: 'wide'));

    await open(tester, theme: appDarkTheme);

    expect(tester.takeException(), isNull);
    expect(find.text('wide'), findsOneWidget);
  });
}
