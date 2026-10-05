import 'package:bloc_test/bloc_test.dart';
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
    when(() => graphRepository.relationshipFor(profileUserId)).thenAnswer(
      (_) async => graph.Relationship(userId: profileUserId, blocking: blocking),
    );
  }

  void stubFeed(FeedKey key, TimelineSnapshot snapshot) {
    when(() => timeline.cached(key)).thenAnswer((_) async => snapshot);
    when(() => timeline.refresh(key)).thenAnswer((_) async => snapshot);
  }

  Future<void> open(WidgetTester tester, {ThemeData? theme}) async {
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
    stubFeed(
      targetFeed,
      snapshotOf([2, 1], authorId: 'target-uid'),
    );
    pending.add(
      PendingPost(
        localId: 'k',
        text: 'my pending post',
        author: common.AuthorSnapshot(userId: 'viewer-uid', handle: 'viewer'),
        createdAt: DateTime.now(),
      ),
    );

    await open(tester);

    expect(find.text('Kaif'), findsOneWidget);
    expect(find.text('Posts'), findsOneWidget); // the tab; the count is "2 Posts"
    expect(find.text('2 Posts'), findsOneWidget);
    expect(find.text('post 2'), findsOneWidget);
    expect(find.text('post 1'), findsOneWidget);
    // Someone else's profile never shows the viewer's pending posts.
    expect(find.text('my pending post'), findsNothing);
    // The Replies tab stays hidden until P3.
    expect(find.text('Replies'), findsNothing);
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
    when(() => graphRepository.relationshipFor('target-uid')).thenAnswer(
      (_) async => graph.Relationship(userId: 'target-uid', muting: true),
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
