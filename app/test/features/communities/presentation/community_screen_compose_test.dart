import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
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
import 'package:dzeroth/features/timeline/domain/feed_key.dart';
import 'package:dzeroth/gen/dzeroth/communities/v1/communities.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:fixnum/fixnum.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/geometry.dart';
import '../../../support/theme_harness.dart';
import '../../../support/timeline_fixtures.dart';

class _MockOnboarding extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

class _MockCommunities extends Mock implements CommunitiesRepository {}

class _MockTabs extends Mock implements HomeTabsRepository {}

class _MockGraph extends Mock implements GraphRepository {}

const _id = '1000000000000000077';

/// W5-34: the "Post" entry in the community page header opens the composer on
/// this community, only for someone who may post there.
void main() {
  final feed = FeedKey.community(_id);
  late MockTimelineRepository timeline;
  late MockPostsRepository posts;
  late _MockCommunities communities;
  late _MockTabs tabs;
  late _MockOnboarding onboarding;
  late pb.Community community;

  setUpAll(() {
    registerFallbackValue(HomeTabKind.community);
  });

  pb.Community make({
    pb.CommunityRole role = pb.CommunityRole.COMMUNITY_ROLE_MEMBER,
    pb.CommunityStatus status = pb.CommunityStatus.COMMUNITY_STATUS_ACTIVE,
  }) => pb.Community(
    communityId: _id,
    name: 'Chess club',
    memberCount: Int64(3),
    viewerRole: role,
    status: status,
  );

  setUp(() {
    community = make();
    timeline = MockTimelineRepository();
    posts = MockPostsRepository();
    communities = _MockCommunities();
    tabs = _MockTabs();
    onboarding = _MockOnboarding();
    when(() => posts.removedPosts).thenAnswer((_) => const Stream.empty());
    when(() => timeline.sinceRefresh(feed)).thenReturn(null);
    when(() => timeline.sinceRefreshAttempt(feed)).thenReturn(null);
    when(() => timeline.rateLimitedFor()).thenReturn(null);
    when(() => timeline.cached(feed)).thenAnswer((_) async => snapshotOf([]));
    when(() => timeline.refresh(feed)).thenAnswer((_) async => snapshotOf([]));
    when(() => communities.getCommunity(_id))
        .thenAnswer((_) async => pb.GetCommunityResponse(community: community));
    when(() => tabs.changes).thenAnswer((_) => const Stream.empty());
    when(() => tabs.isPinned(any(), any())).thenReturn(false);
    when(() => tabs.isFull).thenReturn(false);
    when(() => tabs.writeUnavailable).thenReturn(false);
  });

  void viewer({bool isPrivate = false, Set<String>? flags}) {
    whenListen(
      onboarding,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        status: OnboardingStatus.ready,
        profile: identity.Profile(
          userId: 'viewer',
          handle: 'me',
          isPrivate: isPrivate,
        ),
        enabledFeatures: flags ?? const {'communities', 'posts', 'graph'},
      ),
    );
  }

  Widget screen() => MultiRepositoryProvider(
    providers: [
      RepositoryProvider<TimelineRepository>.value(value: timeline),
      RepositoryProvider<PostsRepository>.value(value: posts),
      RepositoryProvider<CommunitiesRepository>.value(value: communities),
      RepositoryProvider<HomeTabsRepository>.value(value: tabs),
      RepositoryProvider<GraphRepository>.value(value: _MockGraph()),
    ],
    child: BlocProvider<OnboardingBloc>.value(
      value: onboarding,
      child: const CommunityScreen(communityId: _id),
    ),
  );

  final post = find.widgetWithText(OutlinedButton, 'Post');

  testWidgets(
    'a member sees Post and it opens the composer on this community',
    (tester) async {
      viewer();
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.reset);
      final router = GoRouter(
        initialLocation: '/communities/$_id',
        routes: [
          GoRoute(path: '/communities/:id', builder: (_, _) => screen()),
          GoRoute(
            path: '/compose',
            builder: (_, state) =>
                Text('composer ${state.uri.queryParameters['community']}'),
          ),
        ],
      );
      await tester.pumpWidget(
        MaterialApp.router(
          routerConfig: router,
          theme: buildAppTheme(brightness: Brightness.light),
        ),
      );
      await tester.pumpAndSettle();
      expect(post, findsOneWidget);
      await tester.tap(post);
      await tester.pumpAndSettle();
      expect(find.text('composer $_id'), findsOneWidget);
    },
  );

  group('who sees Post', () {
    Future<void> open(WidgetTester tester) => pumpThemed(
      tester,
      screen(),
      size: const Size(390, 844),
      useScaffold: false,
    );

    testWidgets('not a member: no Post', (tester) async {
      viewer();
      community = make(role: pb.CommunityRole.COMMUNITY_ROLE_NONE);
      await open(tester);
      expect(find.text('Join'), findsOneWidget);
      expect(post, findsNothing);
    });

    testWidgets('banned: no Post', (tester) async {
      viewer();
      community = make(role: pb.CommunityRole.COMMUNITY_ROLE_BANNED);
      await open(tester);
      expect(post, findsNothing);
    });

    testWidgets('an archived community is read-only: no Post', (tester) async {
      viewer();
      community = make(status: pb.CommunityStatus.COMMUNITY_STATUS_ARCHIVED);
      await open(tester);
      expect(find.text('Joined'), findsOneWidget);
      expect(post, findsNothing);
    });

    testWidgets('a protected account: no Post', (tester) async {
      viewer(isPrivate: true);
      await open(tester);
      expect(find.text('Joined'), findsOneWidget);
      expect(post, findsNothing);
    });

    testWidgets('posts flag off: no Post', (tester) async {
      viewer(flags: const {'communities', 'graph'});
      await open(tester);
      expect(post, findsNothing);
    });

    testWidgets('an owner and a moderator may post', (tester) async {
      viewer();
      community = make(role: pb.CommunityRole.COMMUNITY_ROLE_OWNER);
      await open(tester);
      expect(post, findsOneWidget);
    });
  });

  forEachThemeAndWidth('header with Post fits', (tester, env) async {
    viewer();
    final semantics = tester.ensureSemantics();
    await pumpThemed(
      tester,
      screen(),
      brightness: env.brightness,
      size: env.size,
      textScale: env.textScale,
      useScaffold: false,
    );
    expectNoOverflow(tester);
    expect(post, findsOneWidget);
    expect(find.text('Joined'), findsOneWidget);
    expect(find.text('Pin to Home'), findsOneWidget);
    semantics.dispose();
  }, textScales: kMatrixTextScalesLarge);
}
