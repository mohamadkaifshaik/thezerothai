import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/features/profile/presentation/widgets/profile_header.dart';
import 'package:dzeroth/shared/widgets/app_tab_bar.dart';
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
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:fixnum/fixnum.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/posts_fixtures.dart';
import '../../../support/timeline_fixtures.dart';

class MockIdentityRepository extends Mock implements IdentityRepository {}

class MockGraphRepository extends Mock implements GraphRepository {}

class MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

/// T18: the Posts tab under `ProfileHeader`.
void main() {
  late MockIdentityRepository identityRepository;
  late MockGraphRepository graphRepository;
  late MockTimelineRepository timeline;
  late MockPostsRepository posts;
  late MockOnboardingBloc onboardingBloc;
  late PendingPostsCubit pending;

  final targetFeed = FeedKey.user('target-uid');
  final ownFeed = FeedKey.user('viewer-uid');

  setUp(() {
    identityRepository = MockIdentityRepository();
    graphRepository = MockGraphRepository();
    timeline = MockTimelineRepository();
    posts = MockPostsRepository();
    onboardingBloc = MockOnboardingBloc();
    pending = PendingPostsCubit();
    when(() => graphRepository.cached(any())).thenReturn(null);
    when(() => timeline.rateLimitedFor()).thenReturn(null);
    when(() => timeline.sinceRefresh(any())).thenReturn(null);
    when(() => timeline.sinceRefreshAttempt(any())).thenReturn(null);
    when(() => posts.removedPosts).thenAnswer((_) => const Stream.empty());
  });

  setUpAll(() => registerFallbackValue(const FeedKey.home()));

  tearDown(() => pending.close());

  void arrange({
    required String profileUserId,
    Set<String> features = const {'posts'},
    int postsCount = 2,
    bool blocking = false,
  }) {
    whenListen(
      onboardingBloc,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        enabledFeatures: features,
        profile: identity.Profile(userId: 'viewer-uid', handle: 'viewer'),
      ),
    );
    when(() => identityRepository.getProfile(handle: 'kaif')).thenAnswer(
      (_) async => identity.Profile(
        userId: profileUserId,
        handle: 'kaif',
        displayName: 'Kaif',
        postsCount: Int64(postsCount),
      ),
    );
    when(() => graphRepository.profileRelationshipFor(profileUserId))
        .thenAnswer(
          (_) async => ProfileRelationship(
            relationship: graph.Relationship(
              userId: profileUserId,
              blocking: blocking,
            ),
          ),
        );
  }

  void stubFeed(FeedKey key, TimelineSnapshot snapshot) {
    when(() => timeline.cached(key)).thenAnswer((_) async => snapshot);
    when(() => timeline.refresh(key)).thenAnswer((_) async => snapshot);
  }

  Future<void> open(
    WidgetTester tester, {
    ThemeData? theme,
    double textScale = 1,
    bool keepSize = false,
  }) async {
    // The 3:1 banner and the taller header (W1-3) need a taller screen to
    // build the first posts of the lazy list.
    if (!keepSize) {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
    }
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
            theme: theme ?? appLightTheme,
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

  testWidgets('another profile: header, Posts tab and its posts', (
    tester,
  ) async {
    arrange(profileUserId: 'target-uid');
    stubFeed(targetFeed, snapshotOf([2, 1], authorId: 'target-uid'));
    pending.add(
      PendingPost(
        localId: 'k',
        text: 'my pending post',
        author: common.AuthorSnapshot(userId: 'viewer-uid', handle: 'viewer'),
        createdAt: DateTime.now(),
      ),
    );

    await open(tester);

    expect(
      find.descendant(
        of: find.byType(ProfileHeader),
        matching: find.text('Kaif'),
      ),
      findsOneWidget,
    );
    expect(
      find.text('Posts'),
      findsOneWidget,
    ); // the tab; the count is "2 Posts"
    expect(find.text('2 Posts'), findsOneWidget);
    expect(find.text('post 2'), findsOneWidget);
    expect(find.text('post 1'), findsOneWidget);
    // Someone else's profile never shows the viewer's pending posts.
    expect(find.text('my pending post'), findsNothing);
    // The Replies tab needs the `replies` sub-feature.
    expect(find.text('Replies'), findsNothing);
  });

  testWidgets('replies flag on: a Replies tab loads the include_replies feed '
      '(0 extra RPCs until tapped), without pending posts', (tester) async {
    final repliesFeed = FeedKey.user('viewer-uid', includeReplies: true);
    arrange(profileUserId: 'viewer-uid', features: {'posts', 'replies'});
    stubFeed(ownFeed, snapshotOf([2, 1], authorId: 'viewer-uid'));
    stubFeed(repliesFeed, snapshotOf([9], authorId: 'viewer-uid'));
    pending.add(
      PendingPost(
        localId: 'k',
        text: 'my pending post',
        author: common.AuthorSnapshot(userId: 'viewer-uid', handle: 'viewer'),
        createdAt: DateTime.now(),
      ),
    );

    await open(tester);

    expect(find.text('Replies'), findsOneWidget);
    expect(find.text('post 2'), findsOneWidget);
    verifyNever(() => timeline.refresh(repliesFeed));

    await tester.tap(find.text('Replies'));
    await tester.pumpAndSettle();

    verify(() => timeline.refresh(repliesFeed)).called(1);
    expect(find.text('post 9'), findsOneWidget);
    expect(find.text('post 2'), findsNothing);
    expect(find.text('my pending post'), findsNothing);

    await tester.tap(find.text('Posts'));
    await tester.pumpAndSettle();

    expect(find.text('post 2'), findsOneWidget);
    expect(find.text('my pending post'), findsOneWidget);
  });

  testWidgets('the tabs are equal-width, labelled as one group', (
    tester,
  ) async {
    arrange(profileUserId: 'viewer-uid', features: {'posts', 'replies'});
    stubFeed(ownFeed, snapshotOf([1], authorId: 'viewer-uid'));
    await open(tester);

    final posts = tester.getRect(find.text('Posts').first);
    final replies = tester.getRect(find.text('Replies'));
    final bar = tester.getRect(find.byType(AppTabBar));
    // Label centres at 1/4 and 3/4 of the bar.
    expect(posts.center.dx, closeTo(bar.left + bar.width / 4, 1));
    expect(replies.center.dx, closeTo(bar.left + bar.width * 3 / 4, 1));
  });

  for (final entry in {'dark': appDarkTheme, 'light': appLightTheme}.entries) {
    for (final width in const [360.0, 600.0, 1200.0]) {
      for (final scale in const [1.0, 1.3, 2.0]) {
        testWidgets(
          'responsive matrix (W1-9): ${entry.key} ${width.toInt()}dp x$scale '
          'header, tabs and posts do not overflow',
          (tester) async {
            arrange(
              profileUserId: 'viewer-uid',
              features: {'posts', 'replies'},
            );
            stubFeed(ownFeed, snapshotOf([2, 1], authorId: 'viewer-uid'));
            tester.view.physicalSize = Size(width, 2400);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.reset);

            await open(
              tester,
              theme: entry.value,
              textScale: scale,
              keepSize: true,
            );

            expect(tester.takeException(), isNull);
            expect(find.text('Replies'), findsOneWidget);
            expect(find.text('post 2'), findsOneWidget);
          },
        );
      }
    }
  }

  testWidgets('own empty Posts tab offers a Write a post action', (
    tester,
  ) async {
    arrange(profileUserId: 'viewer-uid', postsCount: 0);
    stubFeed(ownFeed, snapshotOf([], authorId: 'viewer-uid'));
    await open(tester);

    expect(find.text("You haven't posted yet"), findsOneWidget);
    expect(find.text('Write a post'), findsOneWidget);
  });

  testWidgets("another profile's empty Posts tab has no action", (
    tester,
  ) async {
    arrange(profileUserId: 'target-uid', postsCount: 0);
    stubFeed(targetFeed, snapshotOf([], authorId: 'target-uid'));
    await open(tester);

    expect(find.text("@kaif hasn't posted yet"), findsOneWidget);
    expect(find.text('Write a post'), findsNothing);
  });

  testWidgets('own profile: pending post above the feed, count shown', (
    tester,
  ) async {
    arrange(profileUserId: 'viewer-uid');
    stubFeed(ownFeed, snapshotOf([2, 1], authorId: 'viewer-uid'));
    pending.add(
      PendingPost(
        localId: 'k',
        text: 'my pending post',
        author: common.AuthorSnapshot(userId: 'viewer-uid', handle: 'viewer'),
        createdAt: DateTime.now(),
      ),
    );

    await open(tester);

    expect(find.text('my pending post'), findsOneWidget);
    expect(find.text('Posting...'), findsOneWidget);
    expect(find.text('post 2'), findsOneWidget);
  });

  testWidgets('deleting an own post removes it and decrements the count', (
    tester,
  ) async {
    arrange(profileUserId: 'viewer-uid');
    stubFeed(ownFeed, snapshotOf([2, 1], authorId: 'viewer-uid'));
    when(
      () => posts.deletePost(
        postId: postId(2),
        idempotencyKey: any(named: 'idempotencyKey'),
      ),
    ).thenAnswer((_) async {});

    await open(tester);
    expect(find.text('2 Posts'), findsOneWidget);

    await tester.tap(find.byTooltip('More options').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(find.text('post 2'), findsNothing);
    expect(find.text('post 1'), findsOneWidget);
    expect(find.text('1 Post'), findsOneWidget);
  });

  testWidgets('blocked by the viewer: banner first, posts only after "Show '
      'posts"', (tester) async {
    arrange(
      profileUserId: 'target-uid',
      features: const {'posts', 'graph'},
      blocking: true,
    );
    stubFeed(targetFeed, snapshotOf([2, 1], authorId: 'target-uid'));

    await open(tester);

    expect(find.text('You blocked @kaif ·'), findsOneWidget);
    expect(find.text('post 2'), findsNothing);
    // Nothing is requested while the posts stay hidden.
    verifyNever(() => timeline.cached(any()));
    verifyNever(() => timeline.refresh(any()));

    await tester.tap(find.text('Show posts'));
    await tester.pumpAndSettle();

    expect(find.text('post 2'), findsOneWidget);
    expect(find.text('You blocked @kaif ·'), findsNothing);
  });

  testWidgets('muted author: no banner, posts stay visible', (tester) async {
    arrange(profileUserId: 'target-uid', features: const {'posts', 'graph'});
    when(() => graphRepository.profileRelationshipFor('target-uid')).thenAnswer(
      (_) async => ProfileRelationship(
        relationship: graph.Relationship(userId: 'target-uid', muting: true),
      ),
    );
    stubFeed(targetFeed, snapshotOf([2], authorId: 'target-uid'));

    await open(tester);

    expect(find.textContaining('You blocked'), findsNothing);
    expect(find.text('post 2'), findsOneWidget);
  });

  testWidgets('empty: own and other profiles say so', (tester) async {
    arrange(profileUserId: 'viewer-uid', postsCount: 0);
    stubFeed(ownFeed, const TimelineSnapshot(sinceToken: 's'));
    await open(tester);
    expect(find.text("You haven't posted yet"), findsOneWidget);
  });

  testWidgets('empty: another profile', (tester) async {
    arrange(profileUserId: 'target-uid', postsCount: 0);
    stubFeed(targetFeed, const TimelineSnapshot(sinceToken: 's'));
    await open(tester);
    expect(find.text("@kaif hasn't posted yet"), findsOneWidget);
  });

  testWidgets('posts flag off: placeholder body and no timeline RPC', (
    tester,
  ) async {
    arrange(profileUserId: 'target-uid', features: const {});

    await open(tester);

    expect(find.text("This profile's posts are coming soon."), findsOneWidget);
    expect(find.text('2 Posts'), findsNothing);
    verifyNever(() => timeline.cached(any()));
    verifyNever(() => timeline.refresh(any()));
  });

  testWidgets('dark mode, wide layout: no overflow', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    arrange(profileUserId: 'target-uid');
    stubFeed(targetFeed, snapshotOf([2, 1], authorId: 'target-uid'));

    await open(tester, theme: appDarkTheme);

    expect(tester.takeException(), isNull);
    expect(find.text('post 2'), findsOneWidget);
  });
}
