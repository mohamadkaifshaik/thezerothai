import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/communities/data/communities_repository.dart';
import 'package:dzeroth/features/communities/presentation/community_screen.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/lists/data/home_tabs_repository.dart';
import 'package:dzeroth/features/lists/domain/home_tab_entry.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/features/timeline/data/timeline_repository.dart';
import 'package:dzeroth/features/timeline/data/timeline_store.dart';
import 'package:dzeroth/features/timeline/domain/feed_key.dart';
import 'package:dzeroth/gen/dzeroth/communities/v1/communities.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as posts_pb;
import 'package:fixnum/fixnum.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/posts_fixtures.dart';
import '../../../support/theme_harness.dart';
import '../../../support/timeline_fixtures.dart';

class _MockOnboarding extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

class _MockCommunities extends Mock implements CommunitiesRepository {}

class _MockTabs extends Mock implements HomeTabsRepository {}

class _MockGraph extends Mock implements GraphRepository {}

/// W5-35: moderator entries on `/communities/:id`. The role is the server's
/// `viewer_role`; a member sees none of them.
void main() {
  final feed = FeedKey.community('77');
  late MockTimelineRepository timeline;
  late MockPostsRepository posts;
  late _MockCommunities communities;
  late _MockTabs tabs;
  late _MockOnboarding onboarding;

  TimelineEntry communityPost(int n) {
    final view = postView(n, authorId: 'u1', text: 'post $n');
    view.post.community = posts_pb.CommunityRef(id: '77', name: 'Chess club');
    return TimelineEntry.post(postId(n), postId(n), view);
  }

  void stubRole(pb.CommunityRole role) {
    when(() => communities.getCommunity('77')).thenAnswer(
      (_) async => pb.GetCommunityResponse(
        community: pb.Community(
          communityId: '77',
          name: 'Chess club',
          memberCount: Int64(3),
          viewerRole: role,
        ),
      ),
    );
  }

  setUpAll(() {
    registerFallbackValue(HomeTabKind.community);
  });

  setUp(() {
    timeline = MockTimelineRepository();
    posts = MockPostsRepository();
    communities = _MockCommunities();
    tabs = _MockTabs();
    onboarding = _MockOnboarding();
    when(() => posts.removedPosts).thenAnswer((_) => const Stream.empty());
    when(() => timeline.sinceRefresh(feed)).thenReturn(null);
    when(() => timeline.sinceRefreshAttempt(feed)).thenReturn(null);
    when(() => timeline.rateLimitedFor()).thenReturn(null);
    final snapshot = TimelineSnapshot(
      entries: [communityPost(2), communityPost(1)],
      sinceToken: 's',
      olderPageToken: '',
    );
    when(() => timeline.cached(feed)).thenAnswer((_) async => snapshot);
    when(() => timeline.refresh(feed)).thenAnswer((_) async => snapshot);
    when(() => tabs.changes).thenAnswer((_) => const Stream.empty());
    when(() => tabs.isPinned(any(), any())).thenReturn(false);
    when(() => tabs.isFull).thenReturn(false);
    when(() => tabs.writeUnavailable).thenReturn(false);
    whenListen(
      onboarding,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        status: OnboardingStatus.ready,
        profile: identity.Profile(userId: 'viewer', handle: 'me'),
        enabledFeatures: const {'communities', 'posts', 'graph'},
      ),
    );
  });

  Future<void> open(WidgetTester tester) => pumpThemed(
    tester,
    MultiRepositoryProvider(
      providers: [
        RepositoryProvider<TimelineRepository>.value(value: timeline),
        RepositoryProvider<PostsRepository>.value(value: posts),
        RepositoryProvider<CommunitiesRepository>.value(value: communities),
        RepositoryProvider<HomeTabsRepository>.value(value: tabs),
        RepositoryProvider<GraphRepository>.value(value: _MockGraph()),
      ],
      child: BlocProvider<OnboardingBloc>.value(
        value: onboarding,
        child: const CommunityScreen(communityId: '77'),
      ),
    ),
    size: const Size(600, 1600),
    useScaffold: false,
  );

  void stubHide({Object? error}) {
    when(
      () => communities.hidePost(
        idempotencyKey: any(named: 'idempotencyKey'),
        communityId: '77',
        postId: any(named: 'postId'),
      ),
    ).thenAnswer((_) async {
      if (error != null) throw error;
    });
  }

  Future<void> hideFirst(WidgetTester tester) async {
    await tester.tap(find.byTooltip('More options').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove from Community'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
  }

  for (final role in [
    pb.CommunityRole.COMMUNITY_ROLE_MEMBER,
    pb.CommunityRole.COMMUNITY_ROLE_NONE,
    pb.CommunityRole.COMMUNITY_ROLE_BANNED,
  ]) {
    testWidgets('${role.name}: no moderation log, no Remove row', (
      tester,
    ) async {
      stubRole(role);
      await open(tester);
      expect(find.text('post 2'), findsOneWidget);
      expect(find.text('Moderation log'), findsNothing);
      expect(find.text('Remove from Community'), findsNothing);
    });
  }

  for (final role in [
    pb.CommunityRole.COMMUNITY_ROLE_OWNER,
    pb.CommunityRole.COMMUNITY_ROLE_MODERATOR,
  ]) {
    testWidgets('${role.name}: Moderation log in the header', (tester) async {
      stubRole(role);
      await open(tester);
      expect(find.text('Moderation log'), findsOneWidget);
    });
  }

  testWidgets('hide: the post leaves the feed at once and the call is made', (
    tester,
  ) async {
    stubRole(pb.CommunityRole.COMMUNITY_ROLE_MODERATOR);
    stubHide();
    await open(tester);
    await hideFirst(tester);
    expect(find.text('post 2'), findsNothing);
    expect(find.text('post 1'), findsOneWidget);
    verify(
      () => communities.hidePost(
        idempotencyKey: any(named: 'idempotencyKey'),
        communityId: '77',
        postId: postId(2),
      ),
    ).called(1);
  });

  testWidgets('hide that fails puts the post back with a sentence', (
    tester,
  ) async {
    stubRole(pb.CommunityRole.COMMUNITY_ROLE_MODERATOR);
    stubHide(
      error: CommunityForbiddenException(CommunityForbiddenReason.notModerator),
    );
    await open(tester);
    await hideFirst(tester);
    expect(find.text('post 2'), findsOneWidget);
    expect(find.text('Only moderators can do that.'), findsOneWidget);
  });

  testWidgets('Undo restores on the server and brings the post back', (
    tester,
  ) async {
    stubRole(pb.CommunityRole.COMMUNITY_ROLE_OWNER);
    stubHide();
    when(
      () => communities.restorePost(
        idempotencyKey: any(named: 'idempotencyKey'),
        communityId: '77',
        postId: postId(2),
      ),
    ).thenAnswer((_) async {});
    await open(tester);
    await hideFirst(tester);
    expect(find.text('post 2'), findsNothing);
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(find.text('post 2'), findsOneWidget);
  });
}
