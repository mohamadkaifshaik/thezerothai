import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:drift/native.dart';
import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/storage/app_database.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/features/posts/presentation/post_detail_screen.dart';
import 'package:dzeroth/features/posts/presentation/reply_composer_screen.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:dzeroth/shared/widgets/primitives/app_pill_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/posts_fixtures.dart';

class _Posts extends Mock implements PostsRepository {}

class _Graph extends Mock implements GraphRepository {}

class _Onboarding extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

/// P1-3 for replies: the reply screen and the thread's inline reply bar are
/// bound to the session they were opened in. After a sign-out or an account
/// switch nothing the old account typed is sent.
void main() {
  late _Posts posts;
  late _Graph graph;
  late _Onboarding onboarding;
  late AppDatabase db;
  late StreamController<String> removed;

  setUp(() {
    posts = _Posts();
    graph = _Graph();
    onboarding = _Onboarding();
    db = AppDatabase.forTesting(NativeDatabase.memory());
    removed = StreamController<String>.broadcast();
    addTearDown(removed.close);
    when(() => posts.removedPosts).thenAnswer((_) => removed.stream);
    when(() => posts.subFeatureEnabled(any())).thenReturn(true);
    when(() => posts.getPost(any())).thenAnswer((_) async => postView(1));
    when(
      () => posts.getThread(
        postId(1),
        pageToken: any(named: 'pageToken'),
        pageSize: any(named: 'pageSize'),
      ),
    ).thenAnswer(
      (_) async => pb.GetThreadResponse(focal: postView(1, text: 'focal')),
    );
    when(
      () => posts.createPost(
        idempotencyKey: any(named: 'idempotencyKey'),
        text: any(named: 'text'),
        replyToPostId: any(named: 'replyToPostId'),
        mediaIds: any(named: 'mediaIds'),
        mediaAltTexts: any(named: 'mediaAltTexts'),
      ),
    ).thenAnswer((_) async => postView(2, text: 'a reply'));
    when(() => graph.cached(any())).thenReturn(null);
    whenListen(
      onboarding,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        enabledFeatures: const {'posts', 'replies'},
        profile: identity.Profile(userId: 'me', handle: 'me'),
      ),
    );
  });

  void verifyNothingSent() => verifyNever(
    () => posts.createPost(
      idempotencyKey: any(named: 'idempotencyKey'),
      text: any(named: 'text'),
      replyToPostId: any(named: 'replyToPostId'),
      mediaIds: any(named: 'mediaIds'),
      mediaAltTexts: any(named: 'mediaAltTexts'),
    ),
  );

  /// Pushes [paths] in order over the timeline; returns the router.
  Future<GoRouter> open(
    WidgetTester tester,
    String path, [
    List<String> over = const [],
  ]) async {
    addTearDown(() => tester.runAsync(db.close));
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const Scaffold(body: Text('Timeline')),
        ),
        GoRoute(
          path: '/home',
          builder: (_, _) => const Scaffold(body: Text('Timeline')),
        ),
        GoRoute(
          path: '/sign-in',
          builder: (_, _) => const Scaffold(body: Text('Sign in page')),
        ),
        GoRoute(
          path: '/post/:id',
          builder: (_, state) =>
              PostDetailScreen(postId: state.pathParameters['id']!),
        ),
        GoRoute(
          path: '/compose/reply/:id',
          builder: (_, state) =>
              ReplyComposerScreen(postId: state.pathParameters['id']!),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<PostsRepository>.value(value: posts),
          RepositoryProvider<GraphRepository>.value(value: graph),
          RepositoryProvider<AppDatabase>.value(value: db),
        ],
        child: BlocProvider<OnboardingBloc>.value(
          value: onboarding,
          child: MaterialApp.router(routerConfig: router, theme: appLightTheme),
        ),
      ),
    );
    for (final p in [...over, path]) {
      unawaited(router.push(p));
      await tester.pumpAndSettle();
    }
    return router;
  }

  testWidgets('the reply screen closes on an account switch, sending nothing', (
    tester,
  ) async {
    await open(tester, AppRouter.composeReplyPath(postId(1)));
    await tester.enterText(find.byType(TextField), 'from the old account');
    await tester.pump();

    db.sessionEpoch.end();
    await tester.pumpAndSettle();

    expect(find.text('Timeline'), findsOneWidget, reason: 'it left');
    expect(find.text('from the old account'), findsNothing);
    expect(find.text('Discard reply?'), findsNothing, reason: 'nothing asked');
    verifyNothingSent();
  });

  testWidgets('the inline reply bar clears and disables on an account switch', (
    tester,
  ) async {
    await open(tester, '/post/${postId(1)}');
    expect(find.text('Post your reply'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'from the old account');
    await tester.pump();
    Finder reply() => find.widgetWithText(AppPillButton, 'Reply');
    expect(tester.widget<AppPillButton>(reply()).onPressed, isNotNull);

    db.sessionEpoch.end();
    await tester.pumpAndSettle();

    expect(find.text('from the old account'), findsNothing, reason: 'cleared');
    expect(tester.widget<AppPillButton>(reply()).onPressed, isNull);
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
    await tester.tap(reply(), warnIfMissed: false);
    await tester.pumpAndSettle();
    verifyNothingSent();
    expect(find.text('focal'), findsOneWidget, reason: 'the thread stays');
  });

  group('the reply screen over the post page', () {
    Future<GoRouter> openOverThePost(WidgetTester tester) async {
      final router = await open(tester, AppRouter.composeReplyPath(postId(1)), [
        '/post/${postId(1)}',
      ]);
      expect(find.text('Replying to @hu1'), findsOneWidget);
      return router;
    }

    void expectOnThePostPage() {
      expect(find.text('focal'), findsOneWidget, reason: 'the post page stays');
      expect(find.text('Timeline'), findsNothing, reason: 'popped once only');
      expect(find.text('Replying to @hu1'), findsNothing);
    }

    testWidgets('leaves once when the session ends with a reply in flight', (
      tester,
    ) async {
      final answer = Completer<pb.PostView>();
      when(
        () => posts.createPost(
          idempotencyKey: any(named: 'idempotencyKey'),
          text: any(named: 'text'),
          replyToPostId: any(named: 'replyToPostId'),
          mediaIds: any(named: 'mediaIds'),
          mediaAltTexts: any(named: 'mediaAltTexts'),
        ),
      ).thenAnswer((_) => answer.future);
      await openOverThePost(tester);
      await tester.enterText(find.byType(TextField).last, 'sent before');
      await tester.pump();
      await tester.tap(find.widgetWithText(AppPillButton, 'Reply'));
      await tester.pump();

      // The session ends while the reply is on the wire; it lands after.
      db.sessionEpoch.end();
      answer.complete(postView(2, text: 'a reply'));
      await tester.pumpAndSettle();

      expectOnThePostPage();
    });

    testWidgets('"Discard reply?" open on a switch goes with the screen', (
      tester,
    ) async {
      await openOverThePost(tester);
      await tester.enterText(find.byType(TextField).last, 'old account');
      await tester.pump();
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(find.text('Discard reply?'), findsOneWidget);

      db.sessionEpoch.end();
      await tester.pumpAndSettle();

      expect(find.text('Discard reply?'), findsNothing);
      expect(find.text('old account'), findsNothing);
      expectOnThePostPage();
      verifyNothingSent();
    });

    testWidgets('a redirect replaced the stack first: the leave pops nothing', (
      tester,
    ) async {
      final router = await openOverThePost(tester);
      // What a sign-out redirect does: a new stack, the reply screen leaving.
      router.go('/sign-in');
      await tester.pump();

      db.sessionEpoch.end();
      await tester.pumpAndSettle();

      expect(find.text('Sign in page'), findsOneWidget, reason: 'stays put');
      expect(find.text('focal'), findsNothing, reason: 'no go(post)');
      expect(find.text('Timeline'), findsNothing);
      expect(find.text('Replying to @hu1'), findsNothing);
    });
  });
}
