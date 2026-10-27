import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/onboarding/data/identity_repository.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/features/posts/presentation/bloc/pending_posts_cubit.dart';
import 'package:dzeroth/features/profile/presentation/profile_screen.dart';
import 'package:dzeroth/features/timeline/data/timeline_repository.dart';
import 'package:dzeroth/features/timeline/data/timeline_store.dart';
import 'package:dzeroth/features/timeline/domain/feed_key.dart';
import 'package:dzeroth/features/timeline/presentation/timeline_feed_view.dart';
import 'package:dzeroth/gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:dzeroth/shared/widgets/app_tab_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/theme_harness.dart';
import '../../../support/timeline_fixtures.dart';

class _MockIdentityRepository extends Mock implements IdentityRepository {}

class _MockGraphRepository extends Mock implements GraphRepository {}

class _MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

/// W3-16: the profile's Reposts and Media tabs behind `profile_tabs`. Every
/// tab is its own cached feed (`FeedKey.user(uid, tab: ...)`).
void main() {
  late _MockIdentityRepository identityRepository;
  late _MockGraphRepository graphRepository;
  late MockTimelineRepository timeline;
  late MockPostsRepository posts;
  late _MockOnboardingBloc onboardingBloc;
  late PendingPostsCubit pending;

  const viewer = 'viewer-uid';
  const target = 'target-uid';
  final postsOf = {viewer: FeedKey.user(viewer), target: FeedKey.user(target)};
  FeedKey repliesOf(String uid) => FeedKey.user(uid, includeReplies: true);
  FeedKey repostsOf(String uid) => FeedKey.user(uid, tab: UserFeedTab.reposts);
  FeedKey mediaOf(String uid) => FeedKey.user(uid, tab: UserFeedTab.media);

  const withTabs = {'posts', 'replies', 'graph', 'profile_tabs'};
  const withoutTabs = {'posts', 'replies', 'graph'};

  setUpAll(() => registerFallbackValue(const FeedKey.home()));

  setUp(() {
    identityRepository = _MockIdentityRepository();
    graphRepository = _MockGraphRepository();
    timeline = MockTimelineRepository();
    posts = MockPostsRepository();
    onboardingBloc = _MockOnboardingBloc();
    pending = PendingPostsCubit();
    when(() => graphRepository.cached(any())).thenReturn(null);
    when(() => timeline.rateLimitedFor()).thenReturn(null);
    when(() => timeline.sinceRefresh(any())).thenReturn(null);
    when(() => timeline.sinceRefreshAttempt(any())).thenReturn(null);
    when(() => posts.removedPosts).thenAnswer((_) => const Stream.empty());
  });

  tearDown(() => pending.close());

  /// A profile of [own] (the viewer) or [target]; every tab gets 30 rows
  /// (posts 1-30, replies 101-130, reposts 201-230, media 301-330) unless
  /// [rows] says otherwise for a tab.
  void arrange({
    bool own = true,
    Set<String> features = withTabs,
    Map<String, List<int>> rows = const {},
  }) {
    final uid = own ? viewer : target;
    whenListen(
      onboardingBloc,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        enabledFeatures: features,
        profile: identity.Profile(userId: viewer, handle: 'viewer'),
      ),
    );
    when(() => identityRepository.getProfile(handle: 'kaif')).thenAnswer(
      (_) async => identity.Profile(
        userId: uid,
        handle: 'kaif',
        displayName: 'Kaif',
        bio: 'Builds things.',
      ),
    );
    when(() => graphRepository.profileRelationshipFor(uid)).thenAnswer(
      (_) async =>
          ProfileRelationship(relationship: graph.Relationship(userId: uid)),
    );
    final byTab = {
      'posts': (postsOf[uid]!, [for (var i = 30; i >= 1; i--) i]),
      'replies': (repliesOf(uid), [for (var i = 130; i >= 101; i--) i]),
      'reposts': (repostsOf(uid), [for (var i = 230; i >= 201; i--) i]),
      'media': (mediaOf(uid), [for (var i = 330; i >= 301; i--) i]),
    };
    for (final entry in byTab.entries) {
      final (feed, defaults) = entry.value;
      final snapshot = snapshotOf(rows[entry.key] ?? defaults, authorId: uid);
      when(() => timeline.cached(feed)).thenAnswer((_) async => snapshot);
      when(() => timeline.refresh(feed)).thenAnswer((_) async => snapshot);
    }
  }

  Future<void> open(
    WidgetTester tester, {
    Size size = const Size(400, 800),
    Brightness brightness = Brightness.light,
    double textScale = 1,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<IdentityRepository>.value(
            value: identityRepository,
          ),
          RepositoryProvider<GraphRepository>.value(value: graphRepository),
          RepositoryProvider<TimelineRepository>.value(value: timeline),
          RepositoryProvider<PostsRepository>.value(value: posts),
        ],
        child: MultiBlocProvider(
          providers: [
            BlocProvider<OnboardingBloc>.value(value: onboardingBloc),
            BlocProvider<PendingPostsCubit>.value(value: pending),
          ],
          child: MaterialApp(
            theme: buildAppTheme(brightness: brightness),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(textScale)),
              child: child!,
            ),
            home: const ProfileScreen(handle: 'kaif'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// The labels of the tab bar, in order.
  List<String> tabLabels(WidgetTester tester) => [
    for (final tab in tester.widget<AppTabBar>(find.byType(AppTabBar)).tabs)
      tab.label,
  ];

  Finder tab(String label) =>
      find.descendant(of: find.byType(AppTabBar), matching: find.text(label));

  /// The selected tab's list (the inner scroll view of the nested scroll).
  ScrollPosition innerPosition(WidgetTester tester) => tester
      .state<ScrollableState>(
        find
            .descendant(
              of: find.byType(TimelineFeedView),
              matching: find.byType(Scrollable),
            )
            .first,
      )
      .position;

  Future<void> scrollUp(WidgetTester tester, double dy) async {
    await tester.drag(
      find.byType(TimelineFeedView),
      Offset(0, -dy),
      warnIfMissed: false,
    );
    await tester.pumpAndSettle();
  }

  const disabled = FeatureDisabledException(
    'This part of posts is not available.',
    feature: 'profile_tabs',
  );

  group('tab list', () {
    forEachThemeAndWidth(
      'flag off: Posts and Replies, as before [equal width]',
      (tester, env) async {
        arrange(features: withoutTabs);
        await open(
          tester,
          size: env.size,
          brightness: env.brightness,
          textScale: env.textScale,
        );

        expect(tabLabels(tester), ['Posts', 'Replies']);
        expect(find.text('Reposts'), findsNothing);
        expect(find.text('Media'), findsNothing);
        final bar = tester.getRect(find.byType(AppTabBar));
        final centers = [
          for (final label in ['Posts', 'Replies'])
            tester.getCenter(tab(label)).dx,
        ];
        expect(centers[1] - centers[0], closeTo(bar.width / 2, 1));
        expect(tester.takeException(), isNull);
        // Without the flag no Reposts or Media request is ever made.
        verifyNever(() => timeline.refresh(repostsOf(viewer)));
        verifyNever(() => timeline.refresh(mediaOf(viewer)));
      },
    );

    forEachThemeAndWidth(
      'flag on: Posts, Replies, Reposts, Media in equal widths, no overflow',
      (tester, env) async {
        arrange();
        await open(
          tester,
          size: env.size,
          brightness: env.brightness,
          textScale: env.textScale,
        );

        expect(tabLabels(tester), ['Posts', 'Replies', 'Reposts', 'Media']);
        final bar = tester.getRect(find.byType(AppTabBar));
        final centers = [
          for (final label in ['Posts', 'Replies', 'Reposts', 'Media'])
            tester.getCenter(tab(label)).dx,
        ];
        for (var i = 1; i < centers.length; i++) {
          expect(centers[i] - centers[i - 1], closeTo(bar.width / 4, 1));
        }
        expect(centers.first, closeTo(bar.left + bar.width / 8, 1));
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('360dp at text scale 2.0: four tabs do not overflow', (
      tester,
    ) async {
      arrange();
      await open(tester, size: const Size(360, 800), textScale: 2);

      expect(tabLabels(tester), hasLength(4));
      expect(tester.takeException(), isNull);
    });

    testWidgets('without the replies sub-feature: Posts, Reposts, Media', (
      tester,
    ) async {
      arrange(features: const {'posts', 'graph', 'profile_tabs'});
      await open(tester);

      expect(tabLabels(tester), ['Posts', 'Reposts', 'Media']);
    });

    testWidgets('a tab nobody opens costs no request', (tester) async {
      arrange();
      await open(tester);

      verify(() => timeline.refresh(postsOf[viewer]!)).called(1);
      verifyNever(() => timeline.refresh(repliesOf(viewer)));
      verifyNever(() => timeline.refresh(repostsOf(viewer)));
      verifyNever(() => timeline.refresh(mediaOf(viewer)));
    });
  });

  group('one cubit and cache per tab', () {
    testWidgets('Reposts and Media each load their own feed once', (
      tester,
    ) async {
      arrange();
      await open(tester);

      await tester.tap(tab('Reposts'));
      await tester.pumpAndSettle();
      expect(find.text('post 230'), findsOneWidget);
      expect(find.text('post 30'), findsNothing);
      verify(() => timeline.refresh(repostsOf(viewer))).called(1);

      await tester.tap(tab('Media'));
      await tester.pumpAndSettle();
      expect(find.text('post 330'), findsOneWidget);
      expect(find.text('post 230'), findsNothing);
      verify(() => timeline.refresh(mediaOf(viewer))).called(1);

      // Back to Posts and Reposts: rows come from each tab's cubit, no new
      // request.
      await tester.tap(tab('Posts'));
      await tester.pumpAndSettle();
      expect(find.text('post 30'), findsOneWidget);
      await tester.tap(tab('Reposts'));
      await tester.pumpAndSettle();
      expect(find.text('post 230'), findsOneWidget);
      verifyNever(() => timeline.refresh(repostsOf(viewer)));
      verify(() => timeline.refresh(postsOf[viewer]!)).called(1);
    });

    testWidgets('each tab keeps its own scroll offset (Posts, Media, Posts)', (
      tester,
    ) async {
      arrange();
      await open(tester);

      await scrollUp(tester, 1800);
      final postsOffset = innerPosition(tester).pixels;
      expect(postsOffset, greaterThan(100));

      await tester.tap(tab('Media'));
      await tester.pumpAndSettle();
      expect(innerPosition(tester).pixels, 0);
      await scrollUp(tester, 400);
      final mediaOffset = innerPosition(tester).pixels;
      expect(mediaOffset, greaterThan(100));
      expect(mediaOffset, isNot(closeTo(postsOffset, 1)));

      await tester.tap(tab('Posts'));
      await tester.pumpAndSettle();
      expect(innerPosition(tester).pixels, closeTo(postsOffset, 0.5));

      await tester.tap(tab('Media'));
      await tester.pumpAndSettle();
      expect(innerPosition(tester).pixels, closeTo(mediaOffset, 0.5));
    });

    testWidgets('scrolling Reposts past 70 % loads the next page of that '
        'tab, with the tab\'s own feed', (tester) async {
      arrange();
      final reposts = repostsOf(viewer);
      final withMore = snapshotOf(
        [for (var i = 230; i >= 201; i--) i],
        older: 'o-reposts',
        authorId: viewer,
      );
      when(() => timeline.cached(reposts)).thenAnswer((_) async => withMore);
      when(() => timeline.refresh(reposts)).thenAnswer((_) async => withMore);
      when(() => timeline.loadOlder(reposts)).thenAnswer(
        (_) async =>
            snapshotOf([for (var i = 230; i >= 190; i--) i], authorId: viewer),
      );
      await open(tester);
      await tester.tap(tab('Reposts'));
      await tester.pumpAndSettle();
      verifyNever(() => timeline.loadOlder(reposts));

      await scrollUp(tester, 4000);

      verify(() => timeline.loadOlder(reposts)).called(1);
      verifyNever(() => timeline.loadOlder(postsOf[viewer]!));
    });
  });

  group('empty states (our own copy)', () {
    testWidgets('own Reposts and Media', (tester) async {
      arrange(rows: const {'reposts': [], 'media': []});
      await open(tester);

      await tester.tap(tab('Reposts'));
      await tester.pumpAndSettle();
      expect(find.text("You haven't reposted yet"), findsOneWidget);
      expect(
        find.text('Posts you repost will be listed here.'),
        findsOneWidget,
      );

      await tester.tap(tab('Media'));
      await tester.pumpAndSettle();
      expect(find.text("You haven't shared any images yet"), findsOneWidget);
      expect(
        find.text('Posts with your images will be listed here.'),
        findsOneWidget,
      );
      // The "Write a post" shortcut belongs to the Posts tab only.
      expect(find.text('Write a post'), findsNothing);
    });

    testWidgets("another user's Reposts and Media name them", (tester) async {
      arrange(own: false, rows: const {'reposts': [], 'media': []});
      await open(tester);

      await tester.tap(tab('Reposts'));
      await tester.pumpAndSettle();
      expect(find.text("@kaif hasn't reposted yet"), findsOneWidget);
      expect(
        find.text('Posts they repost will be listed here.'),
        findsOneWidget,
      );

      await tester.tap(tab('Media'));
      await tester.pumpAndSettle();
      expect(find.text("@kaif hasn't shared any images yet"), findsOneWidget);
      expect(
        find.text('Posts with their images will be listed here.'),
        findsOneWidget,
      );
    });
  });

  group('FEATURE_DISABLED profile_tabs although GetMe listed it', () {
    testWidgets('Media: the extra tabs go away, Posts is shown, one request '
        'only', (tester) async {
      arrange();
      when(() => timeline.cached(mediaOf(viewer)))
          .thenAnswer((_) async => const TimelineSnapshot());
      when(() => timeline.refresh(mediaOf(viewer)))
          .thenAnswer((_) => Future.error(disabled));
      await open(tester);
      expect(tabLabels(tester), hasLength(4));

      await tester.tap(tab('Media'));
      await tester.pumpAndSettle();

      expect(tabLabels(tester), ['Posts', 'Replies']);
      expect(find.text('post 30'), findsOneWidget);
      // The refusal is not shown as an error.
      expect(find.text('Retry'), findsNothing);
      expect(tester.takeException(), isNull);
      verify(() => timeline.refresh(mediaOf(viewer))).called(1);
      verifyNever(() => timeline.refresh(repostsOf(viewer)));
    });

    testWidgets('Reposts with cached rows: the refusal arrives as a notice '
        'and also drops the tabs', (tester) async {
      arrange();
      when(() => timeline.refresh(repostsOf(viewer)))
          .thenAnswer((_) => Future.error(disabled));
      await open(tester);

      await tester.tap(tab('Reposts'));
      await tester.pumpAndSettle();

      expect(tabLabels(tester), ['Posts', 'Replies']);
      expect(find.text('post 30'), findsOneWidget);
      verify(() => timeline.refresh(repostsOf(viewer))).called(1);
    });

    testWidgets('a FEATURE_DISABLED for something else leaves the tabs', (
      tester,
    ) async {
      arrange();
      when(() => timeline.cached(mediaOf(viewer)))
          .thenAnswer((_) async => const TimelineSnapshot());
      when(() => timeline.refresh(mediaOf(viewer))).thenAnswer(
        (_) => Future.error(
          const FeatureDisabledException('Not available.', feature: 'media'),
        ),
      );
      await open(tester);

      await tester.tap(tab('Media'));
      await tester.pumpAndSettle();

      expect(tabLabels(tester), hasLength(4));
    });

    testWidgets('another failure shows the error with Retry and keeps the '
        'tabs (no error storm: one request)', (tester) async {
      arrange();
      when(() => timeline.cached(mediaOf(viewer)))
          .thenAnswer((_) async => const TimelineSnapshot());
      when(() => timeline.refresh(mediaOf(viewer)))
          .thenAnswer((_) => Future.error(const UnknownApiException('boom')));
      await open(tester);

      await tester.tap(tab('Media'));
      await tester.pumpAndSettle();

      expect(tabLabels(tester), hasLength(4));
      expect(find.text('Retry'), findsOneWidget);
      verify(() => timeline.refresh(mediaOf(viewer))).called(1);
    });
  });

  group('pages shorter than asked (the token is followed)', () {
    testWidgets('Reposts: rows that do not fill the screen load the next '
        'page without any scrolling', (tester) async {
      arrange();
      final reposts = repostsOf(viewer);
      final short = snapshotOf([203, 202], older: 'o1', authorId: viewer);
      when(() => timeline.cached(reposts)).thenAnswer((_) async => short);
      when(() => timeline.refresh(reposts)).thenAnswer((_) async => short);
      when(
        () => timeline.loadOlder(reposts),
      ).thenAnswer((_) async => snapshotOf([203, 202, 201], authorId: viewer));
      await open(tester);

      await tester.tap(tab('Reposts'));
      await tester.pumpAndSettle();

      verify(() => timeline.loadOlder(reposts)).called(1);
      expect(find.text('post 201'), findsOneWidget);
    });

    testWidgets('Reposts: an empty page with a next token is not "empty" '
        'until the token is exhausted', (tester) async {
      arrange();
      final reposts = repostsOf(viewer);
      const none = TimelineSnapshot(sinceToken: 's', olderPageToken: 'o1');
      final next = Completer<TimelineSnapshot>();
      when(() => timeline.cached(reposts)).thenAnswer((_) async => none);
      when(() => timeline.refresh(reposts)).thenAnswer((_) async => none);
      when(() => timeline.loadOlder(reposts)).thenAnswer((_) => next.future);
      await open(tester);

      await tester.tap(tab('Reposts'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      verify(() => timeline.loadOlder(reposts)).called(1);
      expect(find.text("You haven't reposted yet"), findsNothing);

      next.complete(snapshotOf([205], authorId: viewer));
      await tester.pumpAndSettle();
      expect(find.text('post 205'), findsOneWidget);
      expect(find.text("You haven't reposted yet"), findsNothing);
    });

    testWidgets('Reposts: the last page empty shows the empty copy', (
      tester,
    ) async {
      arrange();
      final reposts = repostsOf(viewer);
      const none = TimelineSnapshot(sinceToken: 's', olderPageToken: 'o1');
      when(() => timeline.cached(reposts)).thenAnswer((_) async => none);
      when(() => timeline.refresh(reposts)).thenAnswer((_) async => none);
      when(() => timeline.loadOlder(reposts))
          .thenAnswer((_) async => const TimelineSnapshot(sinceToken: 's'));
      await open(tester);

      await tester.tap(tab('Reposts'));
      await tester.pumpAndSettle();

      verify(() => timeline.loadOlder(reposts)).called(1);
      expect(find.text("You haven't reposted yet"), findsOneWidget);
    });

    testWidgets('a RATE_LIMITED hold stops the follow: no request and no '
        'frame-by-frame retry loop', (tester) async {
      arrange();
      final reposts = repostsOf(viewer);
      final short = snapshotOf([203], older: 'o1', authorId: viewer);
      when(() => timeline.cached(reposts)).thenAnswer((_) async => short);
      when(() => timeline.rateLimitedFor()).thenReturn(
        const RateLimitedException(
          'Slow down.',
          retryAfter: Duration(hours: 1),
          limitName: 'read_budget_daily',
        ),
      );
      await open(tester);

      await tester.tap(tab('Reposts'));
      // One short row plus the notice banner leaves nothing to scroll; the
      // test would never settle if every held ask scheduled the next one.
      await tester.pumpAndSettle();

      verifyNever(() => timeline.loadOlder(reposts));
      verifyNever(() => timeline.refresh(reposts));
      expect(find.text('post 203'), findsOneWidget);
    });

    testWidgets('Posts keeps its behaviour: a short page is not followed '
        'until the user scrolls', (tester) async {
      arrange();
      final feed = postsOf[viewer]!;
      final short = snapshotOf([3, 2], older: 'o1', authorId: viewer);
      when(() => timeline.cached(feed)).thenAnswer((_) async => short);
      when(() => timeline.refresh(feed)).thenAnswer((_) async => short);

      await open(tester);

      verifyNever(() => timeline.loadOlder(feed));
    });
  });
}
