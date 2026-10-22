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
import 'package:dzeroth/features/timeline/presentation/timeline_feed_view.dart';
import 'package:dzeroth/shared/widgets/app_avatar.dart';
import 'package:dzeroth/shared/widgets/app_pill_button.dart';
import 'package:dzeroth/shared/widgets/app_tab_bar.dart';
import 'package:dzeroth/shared/widgets/post_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
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
    when(() => timeline.sinceRefreshAttempt(feed)).thenAnswer((_) => since);
    when(() => timeline.rateLimitedFor()).thenReturn(null);
    when(() => posts.removedPosts).thenAnswer((_) => const Stream.empty());
  });

  tearDown(() => pending.close());

  TransitionBuilder scaled(double textScale) =>
      (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      );

  GoRouter homeRouter() => GoRouter(
    initialLocation: '/home',
    routes: [
      GoRoute(path: '/home', builder: (_, _) => const HomeScreen()),
      GoRoute(path: '/compose', builder: (_, _) => const Text('compose page')),
    ],
  );

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
    GoRouter? router,
    String avatarThumbUrl = '',
    Stream<OnboardingState> states = const Stream<OnboardingState>.empty(),
    double textScale = 1,
  }) async {
    whenListen(
      onboardingBloc,
      states,
      initialState: OnboardingState(
        enabledFeatures: features,
        profile: identity.Profile(
          userId: 'me',
          handle: 'me',
          avatarThumbUrl: avatarThumbUrl,
        ),
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
          child: router == null
              ? MaterialApp(
                  theme: theme ?? appLightTheme,
                  builder: scaled(textScale),
                  home: const HomeScreen(),
                )
              : MaterialApp.router(
                  theme: theme ?? appLightTheme,
                  builder: scaled(textScale),
                  routerConfig: router,
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
    final before = tester.getTopLeft(find.text('post 2'));

    refreshed.complete(snapshotOf([3, 2, 1], since: 's2'));
    await tester.pumpAndSettle();

    expect(find.text('1 new post'), findsOneWidget);
    // The pill floats under the two header rows: no layout shift.
    expect(tester.getTopLeft(find.text('post 2')), before);
    expect(
      tester.getRect(find.text('1 new post')).top,
      greaterThan(AppSize.headerRow * 2),
    );
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

  testWidgets('loading: skeleton rows while the first page is fetched', (
    tester,
  ) async {
    stubCached(const TimelineSnapshot());
    final never = Completer<TimelineSnapshot>();
    when(() => timeline.refresh(feed)).thenAnswer((_) => never.future);

    final handle = tester.ensureSemantics();
    await open(tester, settle: false);

    expect(find.bySemanticsLabel('Loading posts'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    handle.dispose();
    never.complete(const TimelineSnapshot());
    await tester.pumpAndSettle();
  });

  testWidgets('error with nothing cached: friendly message and Retry', (
    tester,
  ) async {
    stubCached(const TimelineSnapshot());
    when(() => timeline.refresh(feed))
        .thenAnswer((_) async => throw const NetworkException('offline'));

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

  testWidgets('offline over cached posts: banner with Retry that refreshes', (
    tester,
  ) async {
    stubCached(snapshotOf([2, 1]));
    var calls = 0;
    when(() => timeline.refresh(feed)).thenAnswer((_) async {
      calls++;
      if (calls == 1) throw const NetworkException('offline');
      return snapshotOf([2, 1]);
    });

    await open(tester);

    expect(find.text("You're offline. Showing saved posts."), findsOneWidget);
    expect(find.text('post 2'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Retry'));
    await tester.pumpAndSettle();

    expect(calls, 2);
    expect(find.text("You're offline. Showing saved posts."), findsNothing);
  });

  testWidgets('a rate limit banner offers no Retry', (tester) async {
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
    expect(find.widgetWithText(TextButton, 'Retry'), findsNothing);
  });

  testWidgets('a gap row loads once with its token and is replaced', (
    tester,
  ) async {
    final gap = gapEntry(4);
    stubCached(snapshotOf([5, 4], gapAfter: {4: gap}));
    since = const Duration(seconds: 1);
    when(() => timeline.fillGap(feed, gap.itemKey))
        .thenAnswer((_) async => snapshotOf([5, 4, 3, 2]));

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
    when(() => timeline.loadOlder(feed))
        .thenAnswer((_) async => snapshotOf([for (var i = 30; i >= 1; i--) i]));

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
    await tester.fling(
      find.byType(CustomScrollView),
      const Offset(0, 400),
      1000,
    );
    await tester.pumpAndSettle();

    verify(() => timeline.refresh(feed)).called(2);
    expect(find.text('post 3'), findsOneWidget);
    expect(find.textContaining('new post'), findsNothing);
  });

  testWidgets('a refresh that removed a post makes its card disappear', (
    tester,
  ) async {
    stubCached(snapshotOf([3, 2, 1]));
    stubRefresh(snapshotOf([3, 2, 1]));
    await open(tester);
    expect(find.text('post 2'), findsOneWidget);

    // removed_ids dropped post 2 from the cache; no extra RPC beyond the pull.
    stubRefresh(snapshotOf([3, 1], since: 's2'));
    await tester.fling(
      find.byType(CustomScrollView),
      const Offset(0, 400),
      1000,
    );
    await tester.pumpAndSettle();

    expect(find.text('post 2'), findsNothing);
    expect(find.text('post 3'), findsOneWidget);
    verify(() => timeline.refresh(feed)).called(2);
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
        entries: [
          postEntry(2, authorId: 'me'),
          postEntry(1),
        ],
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
      TimelineSnapshot(
        entries: [postEntry(2, authorId: 'me')],
        sinceToken: 's',
      ),
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

  group('composer entry row', () {
    const rowLabel = 'Write a post';

    void stubFeed() {
      stubCached(snapshotOf([2, 1]));
      stubRefresh(snapshotOf([2, 1]));
    }

    testWidgets('posts flag off: placeholder only, no row, no tabs', (
      tester,
    ) async {
      await open(tester, features: const {});

      expect(find.text(rowLabel), findsNothing);
      expect(find.byType(AppTabBar), findsNothing);
      expect(find.text('Your timeline is coming soon.'), findsOneWidget);
    });

    testWidgets('posts flag on: the Following tab, the row and the avatar '
        'show above the feed; no separate Post button', (tester) async {
      stubFeed();
      await open(tester);

      expect(find.text(rowLabel), findsOneWidget);
      expect(find.byType(AppAvatar), findsWidgets);
      expect(find.byType(AppTabBar), findsOneWidget);
      expect(find.text('Following'), findsOneWidget);
      expect(find.byType(AppPillButton), findsNothing);
      expect(
        tester.getTopLeft(find.text(rowLabel)).dy,
        lessThan(tester.getTopLeft(find.text('post 2')).dy),
      );
    });

    testWidgets('tapping the prompt row opens the composer', (tester) async {
      stubFeed();
      await open(tester, router: homeRouter());

      await tester.tap(find.text(rowLabel));
      await tester.pumpAndSettle();

      expect(find.text('compose page'), findsOneWidget);
    });

    testWidgets('the row makes no RPC of its own', (tester) async {
      stubFeed();
      await open(tester, router: homeRouter());
      clearInteractions(timeline);
      clearInteractions(posts);

      await tester.tap(find.text(rowLabel));
      await tester.pumpAndSettle();

      verifyNoMoreInteractions(timeline);
      verifyNoMoreInteractions(posts);
    });

    testWidgets('the row is announced once, the tab as one selected group', (
      tester,
    ) async {
      stubFeed();
      final handle = tester.ensureSemantics();
      await open(tester);

      expect(find.bySemanticsLabel(rowLabel), findsOneWidget);
      expect(find.bySemanticsLabel('Following'), findsOneWidget);
      expect(
        tester.getSemantics(find.bySemanticsLabel(rowLabel)),
        matchesSemantics(
          label: rowLabel,
          isButton: true,
          hasEnabledState: true,
          isEnabled: true,
          hasTapAction: true,
        ),
      );
      handle.dispose();
    });

    testWidgets('targets are at least 48 dp, and the row takes keyboard '
        'focus', (tester) async {
      stubFeed();
      await open(tester);

      final rowInk = find.ancestor(
        of: find.text(rowLabel),
        matching: find.byType(InkWell),
      );
      expect(
        tester.getSize(rowInk).height,
        greaterThanOrEqualTo(AppSpacing.minTapTarget),
      );

      // Tabbing reaches the prompt row.
      final rowFocus = Focus.of(tester.element(find.text(rowLabel)));
      for (var i = 0; i < 8 && !rowFocus.hasPrimaryFocus; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
      }
      expect(rowFocus.hasPrimaryFocus, isTrue);
    });

    for (final theme in {
      'dark': appDarkTheme,
      'light': appLightTheme,
    }.entries) {
      testWidgets(
        '${theme.key}: header and row at 2.0 text scale and 320 dp do not '
        'overflow',
        (tester) async {
          tester.view.physicalSize = const Size(320, 640);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          stubFeed();

          await open(tester, theme: theme.value, textScale: 2);

          expect(find.text(rowLabel), findsOneWidget);
          expect(find.text('Home'), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
      );
    }

    testWidgets('a new avatar rebuilds the row, not the feed', (tester) async {
      stubFeed();
      final states = StreamController<OnboardingState>();
      addTearDown(states.close);
      await open(tester, states: states.stream);
      final cardBefore = tester.widget(find.byType(PostCard).first);
      final feedBefore = tester.widget(find.byType(TimelineFeedView));

      final updated = OnboardingState(
        enabledFeatures: const {'posts'},
        profile: identity.Profile(
          userId: 'me',
          handle: 'me',
          avatarThumbUrl: 'https://example.test/new.jpg',
        ),
      );
      when(() => onboardingBloc.state).thenReturn(updated);
      states.add(updated);
      await tester.pump();
      await tester.pump();

      expect(
        tester.widget<AppAvatar>(find.byType(AppAvatar).first).url,
        'https://example.test/new.jpg',
      );
      expect(
        identical(tester.widget(find.byType(PostCard).first), cardBefore),
        isTrue,
      );
      expect(
        identical(tester.widget(find.byType(TimelineFeedView)), feedBefore),
        isTrue,
      );
    });
  });
}
