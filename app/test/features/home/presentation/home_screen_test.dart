import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/home/presentation/home_screen.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/features/posts/presentation/bloc/pending_posts_cubit.dart';
import 'package:dzeroth/features/timeline/data/timeline_repository.dart';
import 'package:dzeroth/features/timeline/data/timeline_store.dart';
import 'package:dzeroth/features/timeline/domain/feed_key.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:dzeroth/shared/widgets/post_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/posts_fixtures.dart';
import '../../../support/timeline_fixtures.dart';

class MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

void main() {
  const feed = FeedKey.home();
  late MockTimelineRepository timeline;
  late MockPostsRepository posts;
  late MockOnboardingBloc onboardingBloc;
  late PendingPostsCubit pending;
  Duration? since;

  setUp(() {
    since = null;
    timeline = MockTimelineRepository();
    posts = MockPostsRepository();
    onboardingBloc = MockOnboardingBloc();
    pending = PendingPostsCubit();
    when(() => timeline.sinceRefresh(feed)).thenAnswer((_) => since);
    when(() => timeline.rateLimitedFor()).thenReturn(null);
    when(() => posts.removedPosts).thenAnswer((_) => const Stream.empty());
  });

  tearDown(() => pending.close());

  void stubCached(TimelineSnapshot s) {
    when(() => timeline.cached(feed)).thenAnswer((_) async => s);
  }

  void stubRefresh(TimelineSnapshot s) {
    when(() => timeline.refresh(feed)).thenAnswer((_) async => s);
  }

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
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<TimelineRepository>.value(value: timeline),
          RepositoryProvider<PostsRepository>.value(value: posts),
        ],
        child: MultiBlocProvider(
          providers: [
            BlocProvider<OnboardingBloc>.value(value: onboardingBloc),
            BlocProvider<PendingPostsCubit>.value(value: pending),
          ],
          child: MaterialApp(
            theme: theme ?? appLightTheme,
            home: const HomeScreen(),
          ),
        ),
      ),
    );
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
      await tester.pump();
    }
  }

  testWidgets('posts flag off: the placeholder remains, no RPC', (
    tester,
  ) async {
    await open(tester, features: const {});

    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Your timeline is coming soon.'), findsOneWidget);
    expect(find.byIcon(Icons.dynamic_feed_outlined), findsOneWidget);
    verifyNever(() => timeline.cached(feed));
    verifyNever(() => timeline.refresh(feed));
  });

  testWidgets('renders the cache first, then offers the new post in a pill', (
    tester,
  ) async {
    stubCached(snapshotOf([2, 1]));
    final refreshed = Completer<TimelineSnapshot>();
    when(() => timeline.refresh(feed)).thenAnswer((_) => refreshed.future);

    await open(tester, settle: false);

    // The cache is on screen while the refresh is still in flight.
    expect(find.text('post 2'), findsOneWidget);
    expect(find.text('post 1'), findsOneWidget);
    expect(find.textContaining('new post'), findsNothing);

    refreshed.complete(snapshotOf([3, 2, 1], since: 's2'));
    await tester.pumpAndSettle();

    expect(find.text('1 new post'), findsOneWidget);
    expect(find.text('post 3'), findsNothing);

    await tester.tap(find.text('1 new post'));
    await tester.pumpAndSettle();

    expect(find.text('post 3'), findsOneWidget);
    expect(find.text('1 new post'), findsNothing);
  });

  testWidgets('empty feed suggests following people', (tester) async {
    stubCached(const TimelineSnapshot());
    stubRefresh(const TimelineSnapshot(sinceToken: 's'));

    await open(tester);

    expect(find.text('Your timeline is empty'), findsOneWidget);
    expect(find.textContaining('Follow people'), findsOneWidget);
  });

  testWidgets('loading: a spinner while the first page is fetched', (
    tester,
  ) async {
    stubCached(const TimelineSnapshot());
    final never = Completer<TimelineSnapshot>();
    when(() => timeline.refresh(feed)).thenAnswer((_) => never.future);

    await open(tester, settle: false);

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    never.complete(const TimelineSnapshot());
    await tester.pumpAndSettle();
  });

  testWidgets('error with nothing cached: friendly message and Retry', (
    tester,
  ) async {
    stubCached(const TimelineSnapshot());
    when(
      () => timeline.refresh(feed),
    ).thenAnswer((_) async => throw const NetworkException('offline'));

    await open(tester);

    expect(
      find.text('No connection. Check your network and try again.'),
      findsOneWidget,
    );

    stubRefresh(snapshotOf([1]));
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('post 1'), findsOneWidget);
  });

  testWidgets('daily read limit: banner over the cache, no retry storm', (
    tester,
  ) async {
    stubCached(snapshotOf([2, 1]));
    when(() => timeline.refresh(feed)).thenAnswer(
      (_) async => throw const RateLimitedException(
        'limited',
        retryAfter: Duration(hours: 3),
        limitName: 'read_budget_daily',
      ),
    );

    await open(tester);

    expect(find.textContaining("today's refresh limit"), findsOneWidget);
    expect(find.text('post 2'), findsOneWidget);

    when(() => timeline.rateLimitedFor()).thenReturn(
      const RateLimitedException(
        'limited',
        retryAfter: Duration(hours: 3),
        limitName: 'read_budget_daily',
      ),
    );
    await tester.pump(const Duration(seconds: 125));
    verify(() => timeline.refresh(feed)).called(1);
  });

  testWidgets('a gap row loads once with its token and is replaced', (
    tester,
  ) async {
    final gap = gapEntry(4);
    stubCached(snapshotOf([5, 4], gapAfter: {4: gap}));
    since = const Duration(seconds: 1);
    when(
      () => timeline.fillGap(feed, gap.itemKey),
    ).thenAnswer((_) async => snapshotOf([5, 4, 3, 2]));

    await open(tester);
    expect(find.text('Show more posts'), findsOneWidget);

    await tester.tap(find.text('Show more posts'));
    await tester.pumpAndSettle();

    verify(() => timeline.fillGap(feed, gap.itemKey)).called(1);
    expect(find.text('Show more posts'), findsNothing);
    expect(find.text('post 3'), findsOneWidget);
    expect(find.text('post 2'), findsOneWidget);
  });

  testWidgets('scrolling past 70% loads the next page once', (tester) async {
    stubCached(snapshotOf([for (var i = 30; i >= 1; i--) i], older: 'o1'));
    since = const Duration(seconds: 1);
    when(
      () => timeline.loadOlder(feed),
    ).thenAnswer((_) async => snapshotOf([for (var i = 30; i >= 1; i--) i]));

    await open(tester);
    verifyNever(() => timeline.loadOlder(feed));

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -4000));
    await tester.pumpAndSettle();

    verify(() => timeline.loadOlder(feed)).called(1);
  });

  testWidgets('pull-to-refresh shows new posts directly', (tester) async {
    stubCached(snapshotOf([2, 1]));
    stubRefresh(snapshotOf([2, 1]));
    await open(tester);

    stubRefresh(snapshotOf([3, 2, 1], since: 's2'));
    await tester.fling(find.byType(CustomScrollView), const Offset(0, 400), 1000);
    await tester.pumpAndSettle();

    verify(() => timeline.refresh(feed)).called(2);
    expect(find.text('post 3'), findsOneWidget);
    expect(find.textContaining('new post'), findsNothing);
  });

  group('foreground refresh', () {
    testWidgets('resume refreshes only after the throttle, never in the '
        'background', (tester) async {
      stubCached(snapshotOf([2, 1]));
      stubRefresh(snapshotOf([2, 1]));
      await open(tester);
      verify(() => timeline.refresh(feed)).called(1);

      // Backgrounded: the foreground tick stops.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      since = const Duration(minutes: 5);
      await tester.pump(const Duration(seconds: 125));
      verifyNever(() => timeline.refresh(feed));

      // Resume 20 s after the last refresh: nothing is sent.
      since = const Duration(seconds: 20);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      verifyNever(() => timeline.refresh(feed));

      // 61 s: one refresh.
      since = const Duration(seconds: 61);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      verify(() => timeline.refresh(feed)).called(1);
    });

    testWidgets('the 30 s tick refreshes at most once per 60 s', (
      tester,
    ) async {
      stubCached(snapshotOf([2, 1]));
      stubRefresh(snapshotOf([2, 1]));
      await open(tester);
      clearInteractions(timeline);

      since = const Duration(seconds: 30);
      await tester.pump(const Duration(seconds: 31));
      verifyNever(() => timeline.refresh(feed));

      since = const Duration(seconds: 61);
      await tester.pump(const Duration(seconds: 30));
      verify(() => timeline.refresh(feed)).called(1);
    });
  });

  testWidgets('shows the optimistic post above the feed', (tester) async {
    stubCached(snapshotOf([2, 1]));
    since = const Duration(seconds: 1);
    pending.add(
      PendingPost(
        localId: 'k1',
        text: 'on its way',
        author: common.AuthorSnapshot(userId: 'me', handle: 'me'),
        createdAt: DateTime.now(),
      ),
    );

    await open(tester);

    expect(find.text('on its way'), findsOneWidget);
    expect(find.text('Posting...'), findsOneWidget);
  });

  testWidgets('deleting an own post removes it from the list at once', (
    tester,
  ) async {
    stubCached(
      TimelineSnapshot(
        entries: [postEntry(2, authorId: 'me'), postEntry(1)],
        sinceToken: 's',
      ),
    );
    since = const Duration(seconds: 1);
    when(
      () => posts.deletePost(
        postId: postId(2),
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
        postId: postId(2),
        idempotencyKey: any(named: 'idempotencyKey'),
      ),
    ).called(1);
    expect(find.text('post 2'), findsNothing);
    expect(find.text('post 1'), findsOneWidget);
  });

  testWidgets('a failed delete brings the post back with a snackbar', (
    tester,
  ) async {
    stubCached(
      TimelineSnapshot(entries: [postEntry(2, authorId: 'me')], sinceToken: 's'),
    );
    since = const Duration(seconds: 1);
    when(
      () => posts.deletePost(
        postId: postId(2),
        idempotencyKey: any(named: 'idempotencyKey'),
      ),
    ).thenAnswer((_) async => throw const NetworkException('offline'));

    await open(tester);
    await tester.tap(find.byTooltip('More options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(find.text('post 2'), findsOneWidget);
    expect(find.textContaining("Couldn't delete the post"), findsOneWidget);
  });

  testWidgets('dark mode: the feed renders with 48dp pill target', (
    tester,
  ) async {
    stubCached(snapshotOf([2, 1]));
    stubRefresh(snapshotOf([3, 2, 1]));

    await open(tester, theme: appDarkTheme);

    final pill = tester.getSize(
      find.byWidgetPredicate((widget) => widget is FilledButton),
    );
    expect(pill.height, greaterThanOrEqualTo(48));
  });

  testWidgets('wide screens cap the feed width without overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    stubCached(snapshotOf([2, 1]));
    since = const Duration(seconds: 1);

    await open(tester);

    expect(tester.takeException(), isNull);
    final width = tester.getSize(find.byType(PostCard).first).width;
    expect(width, AppBreakpoints.mobile);
  });
}
