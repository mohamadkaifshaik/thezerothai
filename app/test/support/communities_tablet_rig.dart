import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/app/session_wiring.dart' show UnexpectedErrorReporter;
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/feature_flags/ui_shell_feature_flag.dart';
import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/router/main_shell.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/core/theme/theme_mode_cubit.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_event.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_state.dart';
import 'package:dzeroth/features/communities/data/communities_repository.dart';
import 'package:dzeroth/features/communities/presentation/communities_screen.dart';
import 'package:dzeroth/features/communities/presentation/community_members_screen.dart';
import 'package:dzeroth/features/communities/presentation/community_moderation_log_screen.dart';
import 'package:dzeroth/features/communities/presentation/community_screen.dart';
import 'package:dzeroth/features/communities/presentation/create_community_screen.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/graph/presentation/bloc/suggestions_cubit.dart';
import 'package:dzeroth/features/lists/data/home_tabs_repository.dart';
import 'package:dzeroth/features/lists/domain/home_tab_entry.dart';
import 'package:dzeroth/features/messages/presentation/bloc/messages_badge_cubit.dart';
import 'package:dzeroth/features/notifications/presentation/bloc/unread_badge_cubit.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/features/search/data/recent_searches_store.dart';
import 'package:dzeroth/features/search/data/search_repository.dart';
import 'package:dzeroth/features/search/presentation/bloc/trends_cubit.dart';
import 'package:dzeroth/features/timeline/data/timeline_repository.dart';
import 'package:dzeroth/features/timeline/domain/feed_key.dart';
import 'package:dzeroth/shared/widgets/primitives/app_tab_bar.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/communities/v1/communities.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:fixnum/fixnum.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:protobuf/well_known_types/google/protobuf/timestamp.pb.dart'
    as ts;

import 'package:dzeroth/shared/widgets/primitives/app_text_field.dart';

import 'fake_search_repository.dart';
import 'search_field_rig.dart';
import 'suggestions_fixtures.dart';
import 'timeline_fixtures.dart';

class _MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

class _MockAuthBloc extends MockBloc<AuthEvent, AuthState>
    implements AuthBloc {}

class _MockGraph extends Mock implements GraphRepository {}

class _MockTabs extends Mock implements HomeTabsRepository {}

class _MemoryThemeStore implements ThemeModeStore {
  @override
  Future<String?> read() async => null;

  @override
  Future<void> write(String value) async {}
}

/// The communities pages' flags, the context pane's global-set flags and
/// the tablet shell's two.
const kCommunitiesTabletFlags = <String>{
  'communities',
  'posts',
  'search',
  'trends',
  'graph',
  'follow_suggestions',
  kFeatureUiShell,
  kFeatureUiTablet,
};

/// The flag modes the tablet shell distinguishes (tablet plan section 2.3),
/// each with the communities pages' own flags on.
final kCommunitiesFlagModes = <String, Set<String>>{
  'neither': {
    for (final f in kCommunitiesTabletFlags)
      if (f != kFeatureUiShell && f != kFeatureUiTablet) f,
  },
  'ui_shell only': {
    for (final f in kCommunitiesTabletFlags)
      if (f != kFeatureUiTablet) f,
  },
  'ui_tablet only': {
    for (final f in kCommunitiesTabletFlags)
      if (f != kFeatureUiShell) f,
  },
  'ui_shell + ui_tablet': kCommunitiesTabletFlags,
};

/// The rig's community (the page, the members, the log).
const kRigCommunityId = '77';

/// The directory, in order: the caller is a member of the first.
const kRigDirectory = <(String, String)>[
  (kRigCommunityId, 'Chess club'),
  ('78', 'Book club'),
  ('79', 'Running'),
];

/// The reference time of the log's relative times: the clock at first use,
/// passed to the log page as its `now` (no fixed date; the fixed-date guard).
final kRigNow = DateTime.now().toUtc();

/// A `CommunitiesRepository` with a call log: 1 directory, 1 "mine", one
/// community (rules, owner, a moderator), its members and its log. Only the
/// calls the pages make are answered.
class FakeCommunitiesServer extends Mock implements CommunitiesRepository {
  /// Every call, in order: `mine`, `directory`, `get:<id>`, `join:<id>`,
  /// `leave:<id>`, `members:<id>:<filter>`, `log:<id>`, `role:<id>:<user>`,
  /// `search:<id>:<prefix>:<filter>`.
  final calls = <String>[];

  /// Non-null: SearchCommunityMembers fails with it (F36).
  AppException? searchError;

  /// Non-null: SearchCommunityMembers waits for it.
  Completer<void>? holdSearch;

  /// The caller's role in [kRigCommunityId] (GetCommunity's `viewer_role`).
  pb.CommunityRole viewerRole = pb.CommunityRole.COMMUNITY_ROLE_MEMBER;

  /// The community's rules (GetCommunity).
  List<pb.CommunityRule> rules = [
    pb.CommunityRule(title: 'Be kind', text: 'No insults.'),
    pb.CommunityRule(title: 'Stay on topic', text: 'Chess only.'),
  ];

  /// The directory; [kRigDirectory] by default.
  List<pb.Community> directory = [
    for (final (id, name) in kRigDirectory)
      pb.Community(
        communityId: id,
        name: name,
        memberCount: Int64(id == kRigCommunityId ? 5 : 2),
        viewerRole: id == kRigCommunityId
            ? pb.CommunityRole.COMMUNITY_ROLE_MEMBER
            : pb.CommunityRole.COMMUNITY_ROLE_NONE,
      ),
  ];

  /// The community's description (GetCommunity).
  String description = 'Openings, endgames and puzzles';

  /// Non-null: GetCommunity fails with it (after its hold, if any).
  AppException? getError;

  /// Non-null: GetCommunity waits for it (the page's loading state).
  Completer<void>? holdGet;

  /// Non-null: ListModerationLog waits for it (the log's loading state).
  Completer<void>? holdLog;

  /// Non-null: ListModerationLog fails with it (locked, not found).
  AppException? logError;

  /// Non-null: the log a moderator reads, instead of three bans.
  List<pb.ModerationLogEntry>? logEntries;

  int count(String prefix) => calls.where((c) => c.startsWith(prefix)).length;

  pb.Community _community() => pb.Community(
    communityId: kRigCommunityId,
    name: 'Chess club',
    description: description,
    memberCount: Int64(5),
    viewerRole: viewerRole,
  );

  static graph.UserListItem person(String id, String handle, String name) =>
      graph.UserListItem(
        user: common.AuthorSnapshot(
          userId: id,
          handle: handle,
          displayName: name,
        ),
      );

  @override
  bool get enabled => true;

  @override
  MyCommunities? get cachedMine => null;

  @override
  Future<MyCommunities> listMyCommunities({
    int pageSize = 0,
    String pageToken = '',
  }) async {
    calls.add('mine');
    return MyCommunities(
      communities: [
        for (final c in directory)
          if (c.viewerRole != pb.CommunityRole.COMMUNITY_ROLE_NONE) c,
      ],
      canCreate: true,
    );
  }

  @override
  Future<CommunitiesPage> listCommunities({
    int pageSize = 0,
    String pageToken = '',
  }) async {
    calls.add('directory');
    return CommunitiesPage(communities: List.of(directory));
  }

  @override
  Future<pb.GetCommunityResponse> getCommunity(String communityId) async {
    calls.add('get:$communityId');
    await holdGet?.future;
    final error = getError;
    if (error != null) throw error;
    return pb.GetCommunityResponse(
      community: _community(),
      rules: rules,
      owner: person('o1', 'olivia', 'Olivia'),
      moderators: [person('m1', 'mo', 'Mo')],
    );
  }

  @override
  Future<pb.Community> joinCommunity({
    required String idempotencyKey,
    required String communityId,
  }) async {
    calls.add('join:$communityId');
    final c = directory.firstWhere((c) => c.communityId == communityId);
    return c.deepCopy()
      ..viewerRole = pb.CommunityRole.COMMUNITY_ROLE_MEMBER
      ..memberCount = c.memberCount + 1;
  }

  @override
  Future<pb.Community> leaveCommunity({
    required String idempotencyKey,
    required String communityId,
  }) async {
    calls.add('leave:$communityId');
    return _community()..viewerRole = pb.CommunityRole.COMMUNITY_ROLE_NONE;
  }

  @override
  Future<CommunityMembersPage> listMembers({
    required String communityId,
    pb.CommunityMemberFilter filter =
        pb.CommunityMemberFilter.COMMUNITY_MEMBER_FILTER_JOINED,
    int pageSize = 0,
    String pageToken = '',
  }) async {
    calls.add('members:$communityId:${filter.name}');
    if (filter == pb.CommunityMemberFilter.COMMUNITY_MEMBER_FILTER_BANNED) {
      return const CommunityMembersPage(members: []);
    }
    if (filter == pb.CommunityMemberFilter.COMMUNITY_MEMBER_FILTER_MODERATORS) {
      return CommunityMembersPage(
        members: [
          pb.CommunityMember(
            role: pb.CommunityRole.COMMUNITY_ROLE_OWNER,
            user: person('o1', 'olivia', 'Olivia'),
          ),
          pb.CommunityMember(
            role: pb.CommunityRole.COMMUNITY_ROLE_MODERATOR,
            user: person('m1', 'mo', 'Mo'),
          ),
        ],
      );
    }
    return CommunityMembersPage(
      members: [
        pb.CommunityMember(
          role: pb.CommunityRole.COMMUNITY_ROLE_OWNER,
          user: person('o1', 'olivia', 'Olivia'),
        ),
        for (var i = 1; i <= 3; i++)
          pb.CommunityMember(
            role: pb.CommunityRole.COMMUNITY_ROLE_MEMBER,
            user: person('p$i', 'member$i', 'Member $i'),
          ),
      ],
    );
  }

  /// The members whose handle starts with [prefix] (F36): of the owner,
  /// `member1..3` and the moderator `mo`, by handle.
  @override
  Future<List<pb.CommunityMember>> searchMembers({
    required String communityId,
    required String prefix,
    pb.CommunityMemberFilter filter =
        pb.CommunityMemberFilter.COMMUNITY_MEMBER_FILTER_JOINED,
    int limit = 20,
  }) async {
    calls.add('search:$communityId:$prefix:${filter.name}');
    await holdSearch?.future;
    final error = searchError;
    if (error != null) throw error;
    if (filter == pb.CommunityMemberFilter.COMMUNITY_MEMBER_FILTER_BANNED) {
      return const [];
    }
    final all = [
      pb.CommunityMember(
        role: pb.CommunityRole.COMMUNITY_ROLE_MODERATOR,
        user: person('m1', 'mo', 'Mo'),
      ),
      for (var i = 1; i <= 3; i++)
        pb.CommunityMember(
          role: pb.CommunityRole.COMMUNITY_ROLE_MEMBER,
          user: person('p$i', 'member$i', 'Member $i'),
        ),
      pb.CommunityMember(
        role: pb.CommunityRole.COMMUNITY_ROLE_OWNER,
        user: person('o1', 'olivia', 'Olivia'),
      ),
    ];
    return [
      for (final m in all)
        if (m.user.user.handle.startsWith(prefix)) m,
    ]..sort((a, b) => a.user.user.handle.compareTo(b.user.user.handle));
  }

  @override
  Future<pb.SetMemberRoleResponse> setMemberRole({
    required String idempotencyKey,
    required String communityId,
    required String userId,
    required pb.MemberRoleAction action,
  }) async {
    calls.add('role:$communityId:$userId');
    return pb.SetMemberRoleResponse(
      role: pb.CommunityRole.COMMUNITY_ROLE_BANNED,
    );
  }

  @override
  Future<ModerationLogPage> listModerationLog({
    required String communityId,
    int pageSize = 0,
    String pageToken = '',
  }) async {
    calls.add('log:$communityId');
    await holdLog?.future;
    final error = logError;
    if (error != null) throw error;
    final given = logEntries;
    if (given != null) return ModerationLogPage(entries: given);
    if (viewerRole != pb.CommunityRole.COMMUNITY_ROLE_MODERATOR &&
        viewerRole != pb.CommunityRole.COMMUNITY_ROLE_OWNER) {
      return const ModerationLogPage(entries: []);
    }
    final entries = [
      for (var i = 1; i <= 3; i++)
        pb.ModerationLogEntry(
          seq: Int64(i),
          action: pb.ModerationLogAction.MODERATION_LOG_ACTION_BAN,
          actor: common.AuthorSnapshot(userId: 'm1', handle: 'mo'),
          target: common.AuthorSnapshot(userId: 'p$i', handle: 'member$i'),
        )..at = _ts(kRigNow.subtract(Duration(hours: i))),
    ];
    return ModerationLogPage(entries: entries);
  }
}

ts.Timestamp _ts(DateTime t) => ts.Timestamp.fromDateTime(t.toUtc());

/// The real `MainShell` in a real `ShellRoute` around the real communities
/// pages (`CommunitiesScreen`, `CreateCommunityScreen`, `CommunityScreen`,
/// `CommunityMembersScreen`, `CommunityModerationLogScreen`) over a
/// [FakeCommunitiesServer], with the shared cubits of the context pane's
/// global set (`TrendsCubit`, `SuggestionsCubit`) over fakes. `/home`,
/// `/plans/mine` and `/profile/:handle` are stubs.
class CommunitiesTabletRig {
  CommunitiesTabletRig();

  final server = FakeCommunitiesServer();
  final search = FakeSearchRepository()
    ..trendsResult = TrendsResult(
      trends: [for (var i = 1; i <= 3; i++) searchTrend('tag$i', 100 * i, i)],
      computedAt: DateTime.now().subtract(const Duration(hours: 2)),
    );
  final suggestionsRepository = FakeSuggestionsRepository([
    for (var i = 1; i <= 3; i++) suggestedUser(i),
  ]);
  final timeline = MockTimelineRepository();
  final posts = MockPostsRepository();
  late GoRouter router;

  /// `refresh` calls of the community feed (the Posts tab's one open).
  int feedRefreshes = 0;

  /// `pin` calls of the Home tabs (the header's Pin to Home).
  int pinCalls = 0;

  /// The location of the top page (a pushed one too).
  Uri get uri => router.state.uri;

  Future<void> pump(
    WidgetTester tester, {
    String location = AppRouter.communitiesPath,
    double width = 1024,
    double height = 900,
    Set<String> flags = kCommunitiesTabletFlags,
    double textScale = 1,
    Brightness brightness = Brightness.light,
    TextDirection textDirection = TextDirection.ltr,
    bool settle = true,
  }) async {
    registerFallbackValue(const FeedKey.home());
    registerFallbackValue(HomeTabKind.community);
    final onboarding = _MockOnboardingBloc();
    whenListen(
      onboarding,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        status: OnboardingStatus.ready,
        enabledFeatures: flags,
        profile: identity.Profile(
          userId: 'u-alice',
          handle: 'alice',
          displayName: 'Alice A',
        ),
      ),
    );
    final auth = _MockAuthBloc();
    whenListen(
      auth,
      const Stream<AuthState>.empty(),
      initialState: const AuthState(status: AuthStatus.authenticated),
    );
    final unread = UnreadBadgeCubit(0);
    addTearDown(unread.close);
    final messages = MessagesBadgeCubit();
    addTearDown(messages.close);
    final trends = TrendsCubit(repository: search);
    addTearDown(trends.close);
    final suggestions = SuggestionsCubit(repository: suggestionsRepository);
    addTearDown(suggestions.close);
    final graph = _MockGraph();
    when(() => graph.followRequestsUnavailable).thenReturn(false);
    final tabs = _MockTabs();
    when(() => tabs.changes).thenAnswer((_) => const Stream.empty());
    when(() => tabs.isPinned(any(), any())).thenReturn(false);
    when(() => tabs.isFull).thenReturn(false);
    when(() => tabs.writeUnavailable).thenReturn(false);
    when(() => tabs.pin(any(), any(), title: any(named: 'title')))
        .thenAnswer((_) async => pinCalls++);
    when(() => posts.removedPosts).thenAnswer((_) => const Stream.empty());
    when(() => timeline.sinceRefresh(any())).thenReturn(null);
    when(() => timeline.sinceRefreshAttempt(any())).thenReturn(null);
    when(() => timeline.rateLimitedFor()).thenReturn(null);
    when(() => timeline.cached(any())).thenAnswer((_) async => snapshotOf([]));
    when(() => timeline.refresh(any())).thenAnswer((_) async {
      feedRefreshes++;
      return snapshotOf([]);
    });

    Widget stub(String text) => Scaffold(
      appBar: AppBar(title: Text(text)),
      body: Text('$text body'),
    );

    router = GoRouter(
      initialLocation: location,
      routes: [
        ShellRoute(
          builder: (context, state, child) => MainShell(
            location: state.matchedLocation,
            uri: state.uri,
            child: child,
          ),
          routes: [
            GoRoute(
              path: AppRouter.homePath,
              builder: (context, state) => stub('Home stub'),
            ),
            GoRoute(
              path: AppRouter.communitiesPath,
              builder: (context, state) => const CommunitiesScreen(),
            ),
            GoRoute(
              path: AppRouter.communityNewPath,
              builder: (context, state) => const CreateCommunityScreen(),
            ),
            GoRoute(
              path: '/communities/:id',
              builder: (context, state) =>
                  CommunityScreen(communityId: state.pathParameters['id']!),
            ),
            GoRoute(
              path: '/communities/:id/members',
              builder: (context, state) => CommunityMembersScreen(
                communityId: state.pathParameters['id']!,
              ),
            ),
            GoRoute(
              path: '/communities/:id/moderation-log',
              builder: (context, state) => CommunityModerationLogScreen(
                communityId: state.pathParameters['id']!,
                now: kRigNow,
              ),
            ),
            GoRoute(
              path: AppRouter.plansMinePath,
              builder: (context, state) => stub('My plans stub'),
            ),
            GoRoute(
              path: '/profile/:handle',
              builder: (context, state) => stub('Profile stub'),
            ),
          ],
        ),
      ],
    );
    addTearDown(router.dispose);

    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, height);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<CommunitiesRepository>.value(value: server),
          RepositoryProvider<TimelineRepository>.value(value: timeline),
          RepositoryProvider<PostsRepository>.value(value: posts),
          RepositoryProvider<HomeTabsRepository>.value(value: tabs),
          RepositoryProvider<GraphRepository>.value(value: graph),
          RepositoryProvider<SearchRepository>.value(value: search),
          RepositoryProvider<RecentSearchesStore>.value(
            value: FakeRecentSearchesStore(),
          ),
          RepositoryProvider<UnexpectedErrorReporter>.value(value: (_, _) {}),
        ],
        child: MultiBlocProvider(
          providers: [
            BlocProvider<OnboardingBloc>.value(value: onboarding),
            BlocProvider<AuthBloc>.value(value: auth),
            BlocProvider<UnreadBadgeCubit>.value(value: unread),
            BlocProvider<MessagesBadgeCubit>.value(value: messages),
            BlocProvider<TrendsCubit>.value(value: trends),
            BlocProvider<SuggestionsCubit>.value(value: suggestions),
            BlocProvider<ThemeModeCubit>(
              create: (_) => ThemeModeCubit(_MemoryThemeStore()),
            ),
          ],
          child: MaterialApp.router(
            theme: buildAppTheme(brightness: brightness),
            routerConfig: router,
            builder: (context, child) => Directionality(
              textDirection: textDirection,
              child: MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(textScale)),
                child: child!,
              ),
            ),
          ),
        ),
      ),
    );
    // A held load spins forever: [settle] false pumps two frames instead
    // (the first frame, then the one the pages' leases announce).
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
      await tester.pump();
    }
  }

  /// Resizes the window and settles.
  Future<void> resize(
    WidgetTester tester,
    double width, [
    double? height,
  ]) async {
    tester.view.physicalSize = Size(
      width,
      height ?? tester.view.physicalSize.height,
    );
    await tester.pumpAndSettle();
  }
}

/// The route child (the primary pane on the tablet layout, the whole body
/// elsewhere): one of the communities pages, or a stub.
Finder findCommunitiesPage() => find.byWidgetPredicate(
  (w) =>
      w is CommunitiesScreen ||
      w is CreateCommunityScreen ||
      w is CommunityScreen ||
      w is CommunityMembersScreen ||
      w is CommunityModerationLogScreen,
);

/// [finder] inside the route child.
Finder inCommunitiesPage(Finder finder) =>
    find.descendant(of: findCommunitiesPage(), matching: finder);

/// Selects the Communities page's "Explore" tab (R10, F23: phones, tablet
/// band A and desktop; band B has no tabs) and settles.
Future<void> showExploreTab(WidgetTester tester) =>
    tapCommunityTab(tester, 'Explore');

/// Taps the tab [label] of the page's tab bar, scrolled into view first (at
/// large text, or in a narrow window, the bar scrolls; R10 review item 3).
Future<void> tapCommunityTab(WidgetTester tester, String label) async {
  final tab = find.descendant(
    of: find.byType(AppTabBar),
    matching: find.text(label),
  );
  await tester.ensureVisible(tab);
  await tester.pumpAndSettle();
  await tester.tap(tab);
  await tester.pumpAndSettle();
}

/// The text field of the create page's [AppTextField] labelled [label] (R10b:
/// the label is drawn above the field, not inside it).
Finder createFormField(String label) => find.descendant(
  of: find.byWidgetPredicate((w) => w is AppTextField && w.label == label),
  matching: find.byType(TextField),
);
