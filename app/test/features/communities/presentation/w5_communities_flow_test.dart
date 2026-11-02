import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/app/session_wiring.dart' show UnexpectedErrorReporter;
import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/core/theme/theme_mode_cubit.dart';
import 'package:dzeroth/features/auth/domain/app_user.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_event.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_state.dart';
import 'package:dzeroth/features/communities/data/communities_repository.dart';
import 'package:dzeroth/features/communities/presentation/communities_screen.dart';
import 'package:dzeroth/features/communities/presentation/community_screen.dart';
import 'package:dzeroth/features/engagement/data/engagement_repository.dart';
import 'package:dzeroth/features/engagement/presentation/bloc/engagement_cubit.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/lists/data/home_tabs_repository.dart';
import 'package:dzeroth/features/lists/data/lists_repository.dart';
import 'package:dzeroth/features/lists/domain/home_tab_entry.dart';
import 'package:dzeroth/features/moderation/data/moderation_repository.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/features/posts/presentation/bloc/pending_posts_cubit.dart';
import 'package:dzeroth/features/posts/presentation/composer_screen.dart';
import 'package:dzeroth/features/timeline/data/timeline_repository.dart';
import 'package:dzeroth/features/timeline/data/timeline_store.dart';
import 'package:dzeroth/features/timeline/domain/feed_key.dart';
import 'package:dzeroth/features/timeline/presentation/bloc/timeline_cubit.dart';
import 'package:dzeroth/features/timeline/presentation/timeline_feed_view.dart';
import 'package:dzeroth/gen/dzeroth/communities/v1/communities.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:dzeroth/gen/dzeroth/moderation/v1/moderation.pbenum.dart';
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as posts_pb;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pbenum.dart';
import 'package:dzeroth/shared/widgets/post/post_card.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/posts_fixtures.dart';
import '../../../support/timeline_fixtures.dart';

class _MockAuth extends MockBloc<AuthEvent, AuthState> implements AuthBloc {}

class _MockOnboarding extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

class _MockCommunities extends Mock implements CommunitiesRepository {}

class _MockTabs extends Mock implements HomeTabsRepository {}

class _MockGraph extends Mock implements GraphRepository {}

class _MockLists extends Mock implements ListsRepository {}

class _MockModeration extends Mock implements ModerationRepository {}

class _MockEngagement extends Mock implements EngagementRepository {}

class _NoThemeStore implements ThemeModeStore {
  @override
  Future<String?> read() async => null;

  @override
  Future<void> write(String value) async {}
}

const _id = '77';

/// A Home feed over the shared `TimelineFeedView`: the real Home screen needs
/// push, telemetry and suggestion cubits that the flow does not exercise.
class _HomeFeed extends StatelessWidget {
  const _HomeFeed();

  @override
  Widget build(BuildContext context) => Scaffold(
    body: BlocProvider<TimelineCubit>(
      create: (context) => TimelineCubit(
        feed: const FeedKey.home(),
        timeline: context.read<TimelineRepository>(),
        posts: context.read<PostsRepository>(),
        viewerUserId: 'viewer',
      )..load(),
      child: const TimelineFeedView(
        viewerUserId: 'viewer',
        emptyTitle: 'Nothing here yet',
        showPending: false,
      ),
    ),
  );
}

/// W5-37: the flows. The cross-screen flow runs the real Communities, Community
/// and Composer screens and a real feed over stateful fake repositories (one
/// small "server" in memory); the flag product runs the real `AppRouter`.
void main() {
  setUpAll(() {
    registerFallbackValue(HomeTabKind.community);
    registerFallbackValue(const FeedKey.home());
    registerFallbackValue(ReplyPolicy.REPLY_POLICY_UNSPECIFIED);
    registerFallbackValue(ReportTargetType.REPORT_TARGET_TYPE_COMMUNITY);
    registerFallbackValue(ReportReason.REPORT_REASON_SPAM);
    registerFallbackValue(
      pb.CommunityMemberFilter.COMMUNITY_MEMBER_FILTER_JOINED,
    );
  });

  group('flow: Communities, join, post, label in Home, community page, '
      'moderator hide, report', () {
    late _MockCommunities communities;
    late MockTimelineRepository timeline;
    late MockPostsRepository posts;
    late _MockTabs tabs;
    late _MockModeration moderation;
    late _MockOnboarding onboarding;
    late _MockAuth auth;
    late PendingPostsCubit pending;

    // The in-memory "server".
    var role = pb.CommunityRole.COMMUNITY_ROLE_NONE;
    late List<posts_pb.PostView> inCommunity; // newest first
    late List<posts_pb.PostView> inHome;
    late List<String> hidden;
    late List<String> joinedWith;
    late List<(ReportTargetType, String, ReportReason)> reported;
    late List<String?> createdIn;

    pb.Community community() => pb.Community(
      communityId: _id,
      name: 'Chess club',
      description: 'Openings and endgames',
      memberCount: Int64(5),
      viewerRole: role,
    );

    TimelineSnapshot snap(List<posts_pb.PostView> views) => TimelineSnapshot(
      entries: [
        for (final v in views)
          TimelineEntry.post(v.post.postId, v.post.postId, v),
      ],
      sinceToken: 's',
      olderPageToken: '',
    );

    setUp(() {
      role = pb.CommunityRole.COMMUNITY_ROLE_NONE;
      inCommunity = [];
      inHome = [];
      hidden = [];
      joinedWith = [];
      reported = [];
      createdIn = [];
      communities = _MockCommunities();
      timeline = MockTimelineRepository();
      posts = MockPostsRepository();
      tabs = _MockTabs();
      moderation = _MockModeration();
      onboarding = _MockOnboarding();
      auth = _MockAuth();
      pending = PendingPostsCubit();

      when(() => communities.enabled).thenReturn(true);
      when(() => communities.cachedMine).thenReturn(null);
      bool joined() => role != pb.CommunityRole.COMMUNITY_ROLE_NONE;
      when(
        () => communities.listMyCommunities(
          pageSize: any(named: 'pageSize'),
          pageToken: any(named: 'pageToken'),
        ),
      ).thenAnswer(
        (_) async => MyCommunities(
          communities: [if (joined()) community()],
          canCreate: false,
        ),
      );
      when(() => communities.myCommunities(refresh: any(named: 'refresh')))
          .thenAnswer(
            (_) async => MyCommunities(
              communities: [if (joined()) community()],
              canCreate: false,
            ),
          );
      when(
        () => communities.listCommunities(
          pageSize: any(named: 'pageSize'),
          pageToken: any(named: 'pageToken'),
        ),
      ).thenAnswer((_) async => CommunitiesPage(communities: [community()]));
      when(
        () => communities.joinCommunity(
          idempotencyKey: any(named: 'idempotencyKey'),
          communityId: any(named: 'communityId'),
        ),
      ).thenAnswer((i) async {
        joinedWith.add(i.namedArguments[#communityId] as String);
        role = pb.CommunityRole.COMMUNITY_ROLE_MEMBER;
        return community();
      });
      when(() => communities.getCommunity(_id)).thenAnswer(
        (_) async => pb.GetCommunityResponse(community: community()),
      );
      when(
        () => communities.hidePost(
          idempotencyKey: any(named: 'idempotencyKey'),
          communityId: any(named: 'communityId'),
          postId: any(named: 'postId'),
        ),
      ).thenAnswer((i) async {
        final id = i.namedArguments[#postId] as String;
        hidden.add(id);
        inCommunity.removeWhere((v) => v.post.postId == id);
      });

      when(() => posts.removedPosts).thenAnswer((_) => const Stream.empty());
      when(() => posts.subFeatureEnabled(any())).thenReturn(true);
      when(
        () => posts.createPost(
          idempotencyKey: any(named: 'idempotencyKey'),
          text: any(named: 'text'),
          replyToPostId: any(named: 'replyToPostId'),
          quoteOfPostId: any(named: 'quoteOfPostId'),
          mediaIds: any(named: 'mediaIds'),
          mediaAltTexts: any(named: 'mediaAltTexts'),
          replyPolicy: any(named: 'replyPolicy'),
          communityId: any(named: 'communityId'),
        ),
      ).thenAnswer((i) async {
        final cid = i.namedArguments[#communityId] as String;
        createdIn.add(cid);
        final view = postView(9, authorId: 'viewer', text: 'e4 is best');
        if (cid.isNotEmpty) {
          view.post.community = posts_pb.CommunityRef(
            id: cid,
            name: 'Chess club',
          );
          inCommunity.insert(0, view);
        }
        inHome.insert(0, view);
        return view;
      });

      for (final feed in [const FeedKey.home(), FeedKey.community(_id)]) {
        when(() => timeline.sinceRefresh(feed)).thenReturn(null);
        when(() => timeline.sinceRefreshAttempt(feed)).thenReturn(null);
        when(() => timeline.cached(feed)).thenAnswer(
          (_) async =>
              snap(feed == FeedKey.community(_id) ? inCommunity : inHome),
        );
        when(() => timeline.refresh(feed)).thenAnswer(
          (_) async =>
              snap(feed == FeedKey.community(_id) ? inCommunity : inHome),
        );
      }
      when(() => timeline.rateLimitedFor()).thenReturn(null);
      when(() => tabs.changes).thenAnswer((_) => const Stream.empty());
      when(() => tabs.isPinned(any(), any())).thenReturn(false);
      when(() => tabs.isFull).thenReturn(false);
      when(() => tabs.writeUnavailable).thenReturn(false);
      when(
        () => moderation.report(
          idempotencyKey: any(named: 'idempotencyKey'),
          targetType: any(named: 'targetType'),
          targetId: any(named: 'targetId'),
          reason: any(named: 'reason'),
          note: any(named: 'note'),
        ),
      ).thenAnswer((i) async {
        reported.add((
          i.namedArguments[#targetType] as ReportTargetType,
          i.namedArguments[#targetId] as String,
          i.namedArguments[#reason] as ReportReason,
        ));
        return const ReportReceipt(reportId: 'r1', alreadyReported: false);
      });
      whenListen(
        auth,
        const Stream<AuthState>.empty(),
        initialState: const AuthState(status: AuthStatus.authenticated),
      );
      whenListen(
        onboarding,
        const Stream<OnboardingState>.empty(),
        initialState: OnboardingState(
          status: OnboardingStatus.ready,
          profile: identity.Profile(userId: 'viewer', handle: 'me'),
          enabledFeatures: const {
            'communities',
            'posts',
            'graph',
            'reports',
            'lists',
            'ui_shell',
          },
        ),
      );
    });

    tearDown(() => pending.close());

    testWidgets('the whole path, one account, one small server', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(400, 1000);
      addTearDown(tester.view.reset);
      final router = GoRouter(
        initialLocation: '/communities',
        routes: [
          GoRoute(
            path: '/communities',
            builder: (_, _) => const CommunitiesScreen(),
          ),
          GoRoute(
            path: '/communities/:id',
            builder: (_, state) =>
                CommunityScreen(communityId: state.pathParameters['id']!),
          ),
          GoRoute(
            path: '/compose',
            builder: (_, state) => ComposerScreen(
              communityId: state.uri.queryParameters['community'] ?? '',
            ),
          ),
          GoRoute(path: '/home', builder: (_, _) => const _HomeFeed()),
        ],
      );
      await tester.pumpWidget(
        MultiRepositoryProvider(
          providers: [
            RepositoryProvider<CommunitiesRepository>.value(value: communities),
            RepositoryProvider<TimelineRepository>.value(value: timeline),
            RepositoryProvider<PostsRepository>.value(value: posts),
            RepositoryProvider<HomeTabsRepository>.value(value: tabs),
            RepositoryProvider<GraphRepository>.value(value: _MockGraph()),
            RepositoryProvider<ModerationRepository>.value(value: moderation),
            RepositoryProvider<UnexpectedErrorReporter>.value(value: (_, _) {}),
          ],
          child: MultiBlocProvider(
            providers: [
              BlocProvider<AuthBloc>.value(value: auth),
              BlocProvider<OnboardingBloc>.value(value: onboarding),
              BlocProvider<PendingPostsCubit>.value(value: pending),
            ],
            child: MaterialApp.router(
              routerConfig: router,
              theme: buildAppTheme(brightness: Brightness.light),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      // 1. Communities: the directory lists it, I am not in it. Join.
      expect(find.text('Explore Communities'), findsOneWidget);
      await tester.tap(find.text('Join'));
      await tester.pumpAndSettle();
      expect(joinedWith, [_id], reason: 'one JoinCommunity');
      expect(find.text('Joined'), findsOneWidget);

      // 2. Open it: member, so Post is offered (no Join).
      await tester.tap(find.text('Chess club').first);
      await tester.pumpAndSettle();
      expect(find.byType(CommunityScreen), findsOneWidget);
      final post = find.widgetWithText(OutlinedButton, 'Post');
      expect(post, findsOneWidget);
      expect(find.text('Join'), findsNothing);

      // 3. Post from the composer: this community is preselected.
      await tester.tap(post);
      await tester.pumpAndSettle();
      expect(find.byType(ComposerScreen), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'e4 is best');
      await tester.pump();
      await tester.tap(find.text('Post'));
      await tester.pumpAndSettle();
      expect(createdIn, [_id], reason: 'CreatePost carried the community');
      // Back on the community page. (The real PostsRepository writes the new
      // post into the cached feeds; this fake server serves it on the next read.)
      expect(find.byType(CommunityScreen), findsOneWidget);

      // 4. Home shows the post with the community label; the label opens it.
      router.go('/home');
      await tester.pumpAndSettle();
      expect(find.text('e4 is best'), findsOneWidget);
      final label = find.descendant(
        of: find.byType(PostCard),
        matching: find.text('Chess club'),
      );
      expect(label, findsOneWidget, reason: 'the context label row');
      await tester.tap(label);
      await tester.pumpAndSettle();

      // 5. The community page lists the post; the member has no hide row.
      expect(find.byType(CommunityScreen), findsOneWidget);
      expect(find.text('e4 is best'), findsOneWidget);
      await tester.tap(find.byTooltip('More options').first);
      await tester.pumpAndSettle();
      expect(find.text('Remove from Community'), findsNothing);
      await tester.tapAt(const Offset(5, 5)); // dismiss the menu
      await tester.pumpAndSettle();

      // 6. The same user becomes a moderator (server side) and reopens the
      // page: hide the post, confirm, and it leaves the feed.
      role = pb.CommunityRole.COMMUNITY_ROLE_MODERATOR;
      router.go('/communities');
      await tester.pumpAndSettle();
      router.go('/communities/$_id');
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('More options').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove from Community'));
      await tester.pumpAndSettle();
      expect(find.text('Remove this post from Chess club?'), findsOneWidget);
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();
      expect(hidden, [postId(9)]);
      expect(find.text('e4 is best'), findsNothing);
      expect(find.text('Undo'), findsOneWidget);

      // 7. As a plain member again: report the community.
      role = pb.CommunityRole.COMMUNITY_ROLE_MEMBER;
      router.go('/communities');
      await tester.pumpAndSettle();
      router.go('/communities/$_id');
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Community options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Report Community'));
      await tester.pumpAndSettle();
      await tester.tap(find.text("It's spam"));
      await tester.pump();
      await tester.ensureVisible(find.text('Send report'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Send report'));
      await tester.pumpAndSettle();
      expect(reported, [
        (
          ReportTargetType.REPORT_TARGET_TYPE_COMMUNITY,
          _id,
          ReportReason.REPORT_REASON_SPAM,
        ),
      ]);
      expect(tester.takeException(), isNull);
    });
  });

  // -------------------------------------------------------- Flag product
  group('flag product communities x lists x ui_shell x reports (real '
      'AppRouter, 900 dp: the rail)', () {
    const user = AppUser(
      uid: 'uid-1',
      email: 'a@example.com',
      emailVerified: true,
      isPasswordProvider: true,
    );

    Future<_MockCommunities> openAt(
      WidgetTester tester,
      Set<String> flags,
      String location,
    ) async {
      final auth = _MockAuth();
      final onboarding = _MockOnboarding();
      final communities = _MockCommunities();
      when(() => communities.enabled).thenReturn(true);
      when(() => communities.cachedMine).thenReturn(null);
      when(
        () => communities.listMyCommunities(
          pageSize: any(named: 'pageSize'),
          pageToken: any(named: 'pageToken'),
        ),
      ).thenAnswer(
        (_) async => const MyCommunities(communities: [], canCreate: false),
      );
      when(
        () => communities.listCommunities(
          pageSize: any(named: 'pageSize'),
          pageToken: any(named: 'pageToken'),
        ),
      ).thenAnswer((_) async => const CommunitiesPage(communities: []));
      when(
        () => communities.listMembers(
          communityId: any(named: 'communityId'),
          filter: any(named: 'filter'),
          pageSize: any(named: 'pageSize'),
          pageToken: any(named: 'pageToken'),
        ),
      ).thenAnswer((_) async => const CommunityMembersPage(members: []));
      when(
        () => communities.listModerationLog(
          communityId: any(named: 'communityId'),
          pageSize: any(named: 'pageSize'),
          pageToken: any(named: 'pageToken'),
        ),
      ).thenAnswer((_) async => const ModerationLogPage(entries: []));
      when(() => communities.getCommunity(any())).thenAnswer(
        (_) async => pb.GetCommunityResponse(
          community: pb.Community(
            communityId: _id,
            name: 'Chess club',
            memberCount: Int64(3),
            viewerRole: pb.CommunityRole.COMMUNITY_ROLE_MEMBER,
          ),
        ),
      );
      whenListen(
        auth,
        const Stream<AuthState>.empty(),
        initialState: const AuthState(
          status: AuthStatus.authenticated,
          user: user,
        ),
      );
      whenListen(
        onboarding,
        const Stream<OnboardingState>.empty(),
        initialState: OnboardingState(
          status: OnboardingStatus.ready,
          profile: identity.Profile(userId: 'uid-1', handle: 'me'),
          enabledFeatures: flags,
        ),
      );
      final timeline = MockTimelineRepository();
      final posts = MockPostsRepository();
      final tabs = _MockTabs();
      final feed = FeedKey.community(_id);
      when(() => posts.removedPosts).thenAnswer((_) => const Stream.empty());
      when(() => timeline.sinceRefresh(any())).thenReturn(null);
      when(() => timeline.sinceRefreshAttempt(any())).thenReturn(null);
      when(() => timeline.rateLimitedFor()).thenReturn(null);
      when(() => timeline.cached(any()))
          .thenAnswer((_) async => snapshotOf([]));
      when(() => timeline.refresh(any()))
          .thenAnswer((_) async => snapshotOf([]));
      when(() => timeline.cached(feed)).thenAnswer((_) async => snapshotOf([]));
      when(() => tabs.changes).thenAnswer((_) => const Stream.empty());
      when(() => tabs.tabs).thenReturn(const []);
      when(() => tabs.saving).thenReturn(false);
      when(() => tabs.isPinned(any(), any())).thenReturn(false);
      when(() => tabs.isFull).thenReturn(false);
      when(() => tabs.writeUnavailable).thenReturn(false);
      final pendingCubit = PendingPostsCubit();
      addTearDown(pendingCubit.close);
      final engagement = EngagementCubit(repository: _MockEngagement());
      addTearDown(engagement.close);
      final appRouter = AppRouter(authBloc: auth, onboardingBloc: onboarding);
      appRouter.router.go(location);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(900, 900);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MultiRepositoryProvider(
          providers: [
            RepositoryProvider<CommunitiesRepository>.value(value: communities),
            RepositoryProvider<GraphRepository>.value(value: _MockGraph()),
            RepositoryProvider<TimelineRepository>.value(value: timeline),
            RepositoryProvider<PostsRepository>.value(value: posts),
            RepositoryProvider<HomeTabsRepository>.value(value: tabs),
            RepositoryProvider<ModerationRepository>.value(
              value: _MockModeration(),
            ),
            RepositoryProvider<ListsRepository>.value(value: _MockLists()),
            RepositoryProvider<UnexpectedErrorReporter>.value(value: (_, _) {}),
          ],
          child: MultiBlocProvider(
            providers: [
              BlocProvider<AuthBloc>.value(value: auth),
              BlocProvider<OnboardingBloc>.value(value: onboarding),
              BlocProvider<EngagementCubit>.value(value: engagement),
              BlocProvider<PendingPostsCubit>.value(value: pendingCubit),
              BlocProvider<ThemeModeCubit>(
                create: (_) => ThemeModeCubit(_NoThemeStore()),
              ),
            ],
            child: MaterialApp.router(routerConfig: appRouter.router),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return communities;
    }

    // The four flags; `posts` and `graph` stay on so a screen can render.
    for (final communitiesOn in [false, true]) {
      for (final listsOn in [false, true]) {
        for (final shellOn in [false, true]) {
          for (final reportsOn in [false, true]) {
            final name =
                'communities=$communitiesOn lists=$listsOn ui_shell=$shellOn '
                'reports=$reportsOn';
            final flags = <String>{
              'posts',
              'graph',
              if (communitiesOn) 'communities',
              if (listsOn) 'lists',
              if (shellOn) 'ui_shell',
              if (reportsOn) 'reports',
            };

            testWidgets('$name: the community page', (tester) async {
              final repo = await openAt(tester, flags, '/communities/$_id');
              expect(tester.takeException(), isNull);
              if (!communitiesOn) {
                expect(find.byType(CommunityScreen), findsNothing);
                verifyNever(() => repo.getCommunity(any()));
                return;
              }
              expect(find.byType(CommunityScreen), findsOneWidget);
              verify(() => repo.getCommunity(_id)).called(1);
              // Report Community: needs both `communities` and `reports`.
              expect(
                find.byTooltip('Community options'),
                reportsOn ? findsOneWidget : findsNothing,
              );
              // Pin to Home does not depend on `lists` (ADR-0031: a community
              // tab is gated by `communities` only).
              expect(find.text('Pin to Home'), findsOneWidget);
            });

            testWidgets('$name: /communities and its sub-routes', (
              tester,
            ) async {
              for (final path in [
                '/communities',
                '/communities/new',
                '/communities/$_id/members',
                '/communities/$_id/moderation-log',
              ]) {
                final repo = await openAt(tester, flags, path);
                expect(tester.takeException(), isNull, reason: path);
                if (path == '/communities') {
                debugPrint('DBG ${path} rail=${find.byType(NavigationRail).evaluate().length} shell=${find.byType(CommunitiesScreen).evaluate().length} icons=${find.byType(Icon).evaluate().map((e) => (e.widget as Icon).icon?.codePoint.toRadixString(16)).toList()}');
                  // The wide-layout rail lists Communities only in the new shell
                  // with the flag on (the page itself sits inside the shell).
                  expect(
                    find.descendant(
                      of: find.byType(NavigationRail),
                      matching: find.byIcon(Icons.groups_outlined),
                    ),
                    communitiesOn && shellOn ? findsOneWidget : findsNothing,
                    reason: 'rail entry',
                  );
                }
                if (communitiesOn) {
                  expect(
                    find.byType(CommunitiesScreen),
                    path == '/communities' ? findsOneWidget : findsNothing,
                    reason: path,
                  );
                } else {
                  expect(find.byType(CommunitiesScreen), findsNothing);
                  verifyNever(
                    () => repo.listMyCommunities(
                      pageSize: any(named: 'pageSize'),
                      pageToken: any(named: 'pageToken'),
                    ),
                  );
                }
              }
            });
          }
        }
      }
    }
  });
}
