import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/engagement/data/engagement_repository.dart';
import 'package:dzeroth/features/engagement/presentation/bloc/engagement_cubit.dart';
import 'package:dzeroth/features/engagement/presentation/widgets/post_engagement_bar.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/features/posts/presentation/post_photo_screen.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/engagement/v1/engagement.pb.dart' as eng;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/posts_fixtures.dart';

class _Posts extends Mock implements PostsRepository {}

class _Engagement extends Mock implements EngagementRepository {}

class _Onboarding extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

/// The viewer's paging (swipe, mouse drag, zoom lock) and its action row.
void main() {
  late _Posts posts;
  late _Engagement engagement;
  late EngagementCubit cubit;
  late GoRouter router;
  String? lastPushed;

  setUp(() {
    posts = _Posts();
    engagement = _Engagement();
    cubit = EngagementCubit(repository: engagement);
    lastPushed = null;
    final view = postView(1, text: 'Three photos.');
    view.post.media.addAll([
      common.MediaRef(),
      common.MediaRef(),
      common.MediaRef(),
    ]);
    when(() => posts.getPost(any())).thenAnswer((_) async => view);
    when(() => posts.subFeatureEnabled(any())).thenReturn(true);
    when(
      () => engagement.like(
        postId: any(named: 'postId'),
        idempotencyKey: any(named: 'idempotencyKey'),
      ),
    ).thenAnswer(
      (_) async => eng.PostEngagement(postId: postId(1), likedByViewer: true),
    );
  });

  tearDown(() => cubit.close());

  Future<void> open(
    WidgetTester tester, {
    Set<String> flags = const {'posts', 'engagement', 'replies'},
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    final onboarding = _Onboarding();
    whenListen(
      onboarding,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        status: OnboardingStatus.ready,
        enabledFeatures: flags,
      ),
    );
    router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const Scaffold(body: Text('Timeline')),
        ),
        GoRoute(
          path: '/compose/reply/:id',
          builder: (_, state) {
            lastPushed = state.uri.toString();
            return const Scaffold(body: Text('reply composer'));
          },
        ),
        GoRoute(
          path: '/post/:id/photo/:index',
          builder: (_, state) => PostPhotoScreen(
            postId: state.pathParameters['id']!,
            index: int.parse(state.pathParameters['index']!),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      RepositoryProvider<PostsRepository>.value(
        value: posts,
        child: MultiBlocProvider(
          providers: [
            BlocProvider<OnboardingBloc>.value(value: onboarding),
            BlocProvider<EngagementCubit>.value(value: cubit),
          ],
          child: MaterialApp.router(routerConfig: router, theme: appLightTheme),
        ),
      ),
    );
    unawaited(router.push(AppRouter.postPhotoPath(postId(1), 1)));
    await tester.pumpAndSettle();
  }

  Finder inBar(IconData icon) => find.descendant(
    of: find.byType(PostEngagementBar),
    matching: find.byIcon(icon),
  );

  String location() =>
      router.routerDelegate.currentConfiguration.last.matchedLocation;

  testWidgets('a touch swipe turns the page and the location follows', (
    tester,
  ) async {
    await open(tester);
    expect(find.text('1 / 3'), findsOneWidget);
    await tester.fling(find.byType(PageView), const Offset(-300, 0), 1000);
    await tester.pumpAndSettle();
    expect(find.text('2 / 3'), findsOneWidget);
    expect(location(), AppRouter.postPhotoPath(postId(1), 2));
    await tester.fling(find.byType(PageView), const Offset(300, 0), 1000);
    await tester.pumpAndSettle();
    expect(find.text('1 / 3'), findsOneWidget);
  });

  testWidgets('a mouse drag turns the page (web and desktop)', (tester) async {
    await open(tester);
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(PageView)),
      kind: PointerDeviceKind.mouse,
    );
    for (var i = 0; i < 10; i++) {
      await gesture.moveBy(const Offset(-30, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.text('2 / 3'), findsOneWidget);
  });

  testWidgets('the arrows still turn the page', (tester) async {
    await open(tester);
    await tester.tap(find.byTooltip('Next image'));
    await tester.pumpAndSettle();
    expect(find.text('2 / 3'), findsOneWidget);
    await tester.tap(find.byTooltip('Previous image'));
    await tester.pumpAndSettle();
    expect(find.text('1 / 3'), findsOneWidget);
  });

  testWidgets('a zoomed picture does not page', (tester) async {
    await open(tester);
    final center = tester.getCenter(find.byType(PageView));
    final a = await tester.startGesture(center - const Offset(20, 0));
    final b = await tester.startGesture(center + const Offset(20, 0));
    await tester.pump();
    await a.moveBy(const Offset(-60, 0));
    await b.moveBy(const Offset(60, 0));
    await tester.pump();
    await a.up();
    await b.up();
    await tester.pumpAndSettle();
    await tester.fling(find.byType(PageView), const Offset(-300, 0), 1000);
    await tester.pumpAndSettle();
    expect(find.text('1 / 3'), findsOneWidget);
  });

  testWidgets('the post actions are under the photo and work', (tester) async {
    await open(tester);
    expect(inBar(Icons.chat_bubble_outline), findsOneWidget);
    expect(inBar(Icons.repeat), findsOneWidget);
    expect(inBar(Icons.favorite_border), findsOneWidget);
    await tester.tap(inBar(Icons.favorite_border));
    await tester.pumpAndSettle();
    verify(
      () => engagement.like(
        postId: postId(1),
        idempotencyKey: any(named: 'idempotencyKey'),
      ),
    ).called(1);
    expect(inBar(Icons.favorite), findsOneWidget);
    await tester.tap(inBar(Icons.chat_bubble_outline));
    await tester.pumpAndSettle();
    expect(lastPushed, AppRouter.composeReplyPath(postId(1)));
  });

  testWidgets('without the engagement flag there is no action row', (
    tester,
  ) async {
    await open(tester, flags: const {'posts'});
    expect(inBar(Icons.favorite_border), findsNothing);
  });
}
