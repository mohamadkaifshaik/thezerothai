import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/shared/widgets/primitives/app_pill_button.dart';
import 'package:dzeroth/app/session_wiring.dart' show UnexpectedErrorReporter;
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/communities/data/communities_repository.dart';
import 'package:dzeroth/features/communities/presentation/communities_screen.dart';
import 'package:dzeroth/features/communities/presentation/community_members_screen.dart';
import 'package:dzeroth/features/communities/presentation/community_moderation_log_screen.dart';
import 'package:dzeroth/features/communities/presentation/community_screen.dart';
import 'package:dzeroth/features/communities/presentation/create_community_screen.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/lists/data/home_tabs_repository.dart';
import 'package:dzeroth/features/lists/domain/home_tab_entry.dart';
import 'package:dzeroth/features/moderation/data/moderation_repository.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/features/timeline/data/timeline_repository.dart';
import 'package:dzeroth/features/timeline/data/timeline_store.dart';
import 'package:dzeroth/features/timeline/domain/feed_key.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/communities/v1/communities.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as posts_pb;
import 'package:dzeroth/shared/widgets/post/post_card.dart';
import 'package:dzeroth/shared/widgets/post/post_moderation_control.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/geometry.dart';
import '../../../support/posts_fixtures.dart';
import '../../../support/theme_harness.dart';
import '../../../support/timeline_fixtures.dart';

class _MockOnboarding extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

class _MockCommunities extends Mock implements CommunitiesRepository {}

class _MockTabs extends Mock implements HomeTabsRepository {}

class _MockGraph extends Mock implements GraphRepository {}

class _MockModeration extends Mock implements ModerationRepository {}

/// The names every label and header is tried with: long, emoji, RTL, and one
/// with zero-width characters and no spaces to break on.
const _names = <String, String>{
  'long':
      'The Nets Twitter community for everybody who has ever argued about '
      'the optimal opening repertoire at two in the morning',
  'emoji': 'Chess ♟️ club \u{1F680}\u{1F680}\u{1F680}',
  'rtl':
      'نادي الشطرنج '
      'العربي للجميع',
  'zero-width':
      'Unbroken​​NameWithoutAnySpacesThatKeepsGoingAndGoingAndGoing'
      'AndGoingAndGoing',
};

/// The Part B responsive matrix for the states the developers' own
/// tests covered in one cell only or not at all: every state
/// at 360 / 600 / 1200 dp, light and dark, text scale 1.0 / 1.3 / 2.0. The
/// overlays (menus, dialogs, sheets) run at the same text scale as the page
/// (`pumpThemed` sets the platform scale; see the test report, "Harness").
void main() {
  setUpAll(() {
    registerFallbackValue(HomeTabKind.community);
    registerFallbackValue(
      pb.CommunityMemberFilter.COMMUNITY_MEMBER_FILTER_JOINED,
    );
  });

  OnboardingBloc onboardingWith(Set<String> features) {
    final onboarding = _MockOnboarding();
    whenListen(
      onboarding,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        status: OnboardingStatus.ready,
        profile: identity.Profile(userId: 'viewer', handle: 'me'),
        enabledFeatures: features,
      ),
    );
    return onboarding;
  }

  // ----------------------------------------------------------- Communities
  group('CommunitiesScreen states', () {
    late _MockCommunities repo;
    setUp(() {
      repo = _MockCommunities();
      when(() => repo.enabled).thenReturn(true);
    });

    Future<void> open(WidgetTester tester, MatrixEnv env) => pumpThemed(
      tester,
      RepositoryProvider<CommunitiesRepository>.value(
        value: repo,
        child: const CommunitiesScreen(),
      ),
      brightness: env.brightness,
      size: env.size,
      textScale: env.textScale,
      useScaffold: false,
    );

    void stub({Object? mineError, Object? dirError, bool canCreate = true}) {
      when(
        () => repo.listMyCommunities(
          pageSize: any(named: 'pageSize'),
          pageToken: any(named: 'pageToken'),
        ),
      ).thenAnswer((_) async {
        if (mineError != null) throw mineError;
        return MyCommunities(communities: const [], canCreate: canCreate);
      });
      when(
        () => repo.listCommunities(
          pageSize: any(named: 'pageSize'),
          pageToken: any(named: 'pageToken'),
        ),
      ).thenAnswer((_) async {
        if (dirError != null) throw dirError;
        return const CommunitiesPage(communities: []);
      });
    }

    forEachThemeAndWidth('empty sections with the Create entry fit', (
      tester,
      env,
    ) async {
      stub();
      await open(tester, env);
      expectNoOverflow(tester);
      expect(find.byTooltip('Create a Community'), findsOneWidget);
      expect(find.text('No Communities to explore yet.'), findsOneWidget);
    }, textScales: kMatrixTextScalesLarge);

    forEachThemeAndWidth('both sections failed: two Retry buttons fit', (
      tester,
      env,
    ) async {
      stub(
        mineError: const NetworkException('offline'),
        dirError: const NetworkException('offline'),
      );
      await open(tester, env);
      expectNoOverflow(tester);
      expect(find.text('Retry'), findsNWidgets(2));
      for (final retry in find.text('Retry').evaluate()) {
        expect(retry, isNotNull);
      }
    }, textScales: kMatrixTextScalesLarge);

    forEachThemeAndWidth('RPC not served yet: a calm note, no overflow', (
      tester,
      env,
    ) async {
      stub(
        mineError: const FeatureDisabledException('x', feature: 'communities'),
        dirError: const FeatureDisabledException('x', feature: 'communities'),
      );
      await open(tester, env);
      expectNoOverflow(tester);
      expect(find.text('Retry'), findsNothing);
    }, textScales: kMatrixTextScalesLarge);
  });

  // ------------------------------------------------------- Community page
  group('CommunityScreen states', () {
    final feed = FeedKey.community('77');
    late MockTimelineRepository timeline;
    late MockPostsRepository posts;
    late _MockCommunities communities;
    late _MockTabs tabs;
    late _MockModeration moderation;
    late List<String> hidden;
    var pinned = false;

    TimelineEntry communityPost(int n) {
      final view = postView(n, authorId: 'u1', text: 'post $n');
      view.post.community = posts_pb.CommunityRef(id: '77', name: 'Chess club');
      return TimelineEntry.post(postId(n), postId(n), view);
    }

    setUp(() {
      pinned = false;
      hidden = [];
      timeline = MockTimelineRepository();
      posts = MockPostsRepository();
      communities = _MockCommunities();
      tabs = _MockTabs();
      moderation = _MockModeration();
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
      when(() => tabs.isPinned(any(), any())).thenAnswer((_) => pinned);
      when(() => tabs.isFull).thenReturn(false);
      when(() => tabs.writeUnavailable).thenReturn(false);
      when(
        () => communities.hidePost(
          idempotencyKey: any(named: 'idempotencyKey'),
          communityId: any(named: 'communityId'),
          postId: any(named: 'postId'),
        ),
      ).thenAnswer(
        (i) async => hidden.add(i.namedArguments[#postId] as String),
      );
    });

    void stubCommunity({
      pb.CommunityRole role = pb.CommunityRole.COMMUNITY_ROLE_NONE,
      String name = 'Chess club',
      Object? error,
    }) {
      when(() => communities.getCommunity('77')).thenAnswer((_) async {
        if (error != null) throw error;
        return pb.GetCommunityResponse(
          community: pb.Community(
            communityId: '77',
            name: name,
            description: 'Openings, endgames and puzzles',
            memberCount: Int64(1234),
            viewerRole: role,
          ),
          rules: [pb.CommunityRule(title: 'Be kind', text: 'No insults.')],
          owner: graph.UserListItem(
            user: common.AuthorSnapshot(userId: 'o', handle: 'olivia'),
          ),
        );
      });
    }

    Future<void> open(
      WidgetTester tester,
      MatrixEnv env, {
      Set<String> features = const {
        'communities',
        'posts',
        'graph',
        'reports',
        'lists',
        'ui_shell',
      },
    }) => pumpThemed(
      tester,
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<TimelineRepository>.value(value: timeline),
          RepositoryProvider<PostsRepository>.value(value: posts),
          RepositoryProvider<CommunitiesRepository>.value(value: communities),
          RepositoryProvider<HomeTabsRepository>.value(value: tabs),
          RepositoryProvider<GraphRepository>.value(value: _MockGraph()),
          RepositoryProvider<ModerationRepository>.value(value: moderation),
          RepositoryProvider<UnexpectedErrorReporter>.value(value: (_, _) {}),
        ],
        child: BlocProvider<OnboardingBloc>.value(
          value: onboardingWith(features),
          child: const CommunityScreen(communityId: '77'),
        ),
      ),
      brightness: env.brightness,
      size: env.size,
      textScale: env.textScale,
      useScaffold: false,
    );

    for (final name in _names.entries) {
      forEachThemeAndWidth(
        'header of a non-member, ${name.key} name: Join, Pin, Report menu',
        (tester, env) async {
          stubCommunity(name: name.value);
          await open(tester, env);
          expectNoOverflow(tester);
          expect(find.text('Join'), findsOneWidget);
          expect(find.byTooltip('Community options'), findsOneWidget);
          expectMinTarget(tester, find.byTooltip('Community options'));
        },
        textScales: kMatrixTextScalesLarge,
      );
    }

    forEachThemeAndWidth('banned header: the sentence, no Join, no menu items '
        'overflow', (tester, env) async {
      stubCommunity(role: pb.CommunityRole.COMMUNITY_ROLE_BANNED);
      await open(tester, env);
      expectNoOverflow(tester);
      expect(find.text("You can't join this Community"), findsOneWidget);
      expect(find.text('Join'), findsNothing);
    }, textScales: kMatrixTextScalesLarge);

    forEachThemeAndWidth('moderator header: Joined, Post, Moderation log, '
        'Unpin', (tester, env) async {
      pinned = true;
      stubCommunity(role: pb.CommunityRole.COMMUNITY_ROLE_MODERATOR);
      await open(tester, env);
      expectNoOverflow(tester);
      expect(find.text('Moderation log'), findsOneWidget);
      expect(find.text('Unpin from Home'), findsOneWidget);
    }, textScales: kMatrixTextScalesLarge);

    forEachThemeAndWidth('NOT_FOUND: the unavailable view fits', (
      tester,
      env,
    ) async {
      stubCommunity(error: const NotFoundException('gone'));
      await open(tester, env);
      expectNoOverflow(tester);
      expect(find.text('This Community is unavailable'), findsOneWidget);
    }, textScales: kMatrixTextScalesLarge);

    forEachThemeAndWidth('load error with nothing cached: Retry fits', (
      tester,
      env,
    ) async {
      stubCommunity(error: const NetworkException('offline'));
      await open(tester, env);
      expectNoOverflow(tester);
      expect(find.text('Retry'), findsOneWidget);
      expectMinTarget(
        tester,
        find.ancestor(
          of: find.text('Retry'),
          matching: find.byWidgetPredicate(
            (w) => w is ButtonStyleButton || w is AppPillButton,
          ),
        ),
      );
    }, textScales: kMatrixTextScalesLarge);

    forEachThemeAndWidth('Community options menu open', (tester, env) async {
      stubCommunity(role: pb.CommunityRole.COMMUNITY_ROLE_MEMBER);
      await open(tester, env);
      await tester.tap(find.byTooltip('Community options'));
      await tester.pumpAndSettle();
      expectNoOverflow(tester);
      expect(find.text('Report Community'), findsOneWidget);
      expect(
        MediaQuery.textScalerOf(tester.element(find.text('Report Community')))
            .scale(10),
        env.textScale * 10,
        reason: 'the overlay must run at the matrix text scale',
      );
    }, textScales: kMatrixTextScalesLarge);

    forEachThemeAndWidth(
      'Report Community sheet open (COMMUNITY target)',
      (tester, env) async {
        stubCommunity(
          role: pb.CommunityRole.COMMUNITY_ROLE_MEMBER,
          name: _names['long']!,
        );
        await open(tester, env);
        await tester.tap(find.byTooltip('Community options'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Report Community'));
        await tester.pumpAndSettle();
        expectNoOverflow(tester);
        expect(find.text("It's spam"), findsOneWidget);
        expect(find.text('Send report'), findsOneWidget);
      },
      textScales: kMatrixTextScalesLarge,
      height: 900,
    );

    forEachThemeAndWidth(
      'moderator: post menu row and the Remove confirm',
      (tester, env) async {
        stubCommunity(
          role: pb.CommunityRole.COMMUNITY_ROLE_MODERATOR,
          name: 'Chess openings and endgam',
        );
        await open(tester, env);
        // The header is taller than the view at large text; the rows are lazy.
        for (
          var i = 0;
          i < 20 && find.byTooltip('More options').evaluate().isEmpty;
          i++
        ) {
          await tester.drag(
            find.byType(Scrollable).first,
            const Offset(0, -300),
          );
          await tester.pump();
        }
        await tester.tap(find.byTooltip('More options').first);
        await tester.pumpAndSettle();
        expectNoOverflow(tester);
        expect(find.text('Remove from Community'), findsOneWidget);
        await tester.tap(find.text('Remove from Community'));
        await tester.pumpAndSettle();
        expectNoOverflow(tester);
        expect(find.text('Remove'), findsOneWidget);
        expect(find.text('Cancel'), findsOneWidget);
        await tester.tap(find.text('Remove'));
        await tester.pumpAndSettle();
        expectNoOverflow(tester);
        expect(hidden, [postId(2)]);
        expect(find.text('Undo'), findsOneWidget);
      },
      textScales: kMatrixTextScalesLarge,
      height: 900,
    );
  });

  // ------------------------------------------------------------- Members
  group('CommunityMembersScreen states', () {
    late _MockCommunities communities;
    setUp(() => communities = _MockCommunities());

    void stubViewer(pb.CommunityRole role) {
      when(() => communities.getCommunity(any())).thenAnswer(
        (_) async => pb.GetCommunityResponse(
          community: pb.Community(communityId: '77', viewerRole: role),
        ),
      );
    }

    void stubMembers(List<pb.CommunityMember> members, {Object? error}) {
      when(
        () => communities.listMembers(
          communityId: any(named: 'communityId'),
          filter: any(named: 'filter'),
          pageSize: any(named: 'pageSize'),
          pageToken: any(named: 'pageToken'),
        ),
      ).thenAnswer((_) async {
        if (error != null) throw error;
        return CommunityMembersPage(members: members);
      });
    }

    pb.CommunityMember member(int i, String name, pb.CommunityRole role) =>
        pb.CommunityMember(
          role: role,
          user: graph.UserListItem(
            user: common.AuthorSnapshot(
              userId: 'm$i',
              handle: 'member$i',
              displayName: name,
            ),
          ),
        );

    Future<void> open(WidgetTester tester, MatrixEnv env) => pumpThemed(
      tester,
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<CommunitiesRepository>.value(value: communities),
          RepositoryProvider<GraphRepository>.value(value: _MockGraph()),
        ],
        child: BlocProvider<OnboardingBloc>.value(
          value: onboardingWith(const {'communities', 'graph'}),
          child: const CommunityMembersScreen(communityId: '77'),
        ),
      ),
      brightness: env.brightness,
      size: env.size,
      textScale: env.textScale,
      useScaffold: false,
    );

    forEachThemeAndWidth('empty community', (tester, env) async {
      stubViewer(pb.CommunityRole.COMMUNITY_ROLE_MEMBER);
      stubMembers([]);
      await open(tester, env);
      expectNoOverflow(tester);
      expect(find.text('No members yet'), findsOneWidget);
    }, textScales: kMatrixTextScalesLarge);

    forEachThemeAndWidth('NOT_FOUND: the unavailable view', (
      tester,
      env,
    ) async {
      stubViewer(pb.CommunityRole.COMMUNITY_ROLE_MEMBER);
      stubMembers([], error: const NotFoundException('gone'));
      await open(tester, env);
      expectNoOverflow(tester);
      expect(find.text('This Community is unavailable'), findsOneWidget);
    }, textScales: kMatrixTextScalesLarge);

    forEachThemeAndWidth('network error: Retry', (tester, env) async {
      stubViewer(pb.CommunityRole.COMMUNITY_ROLE_MEMBER);
      stubMembers([], error: const NetworkException('offline'));
      await open(tester, env);
      expectNoOverflow(tester);
      expect(find.text('Retry'), findsOneWidget);
    }, textScales: kMatrixTextScalesLarge);

    for (final name in _names.entries) {
      forEachThemeAndWidth(
        'owner opens the member menu and the Ban confirm, ${name.key} name',
        (tester, env) async {
          stubViewer(pb.CommunityRole.COMMUNITY_ROLE_OWNER);
          stubMembers([
            member(1, 'Olivia', pb.CommunityRole.COMMUNITY_ROLE_OWNER),
            member(3, name.value, pb.CommunityRole.COMMUNITY_ROLE_MEMBER),
          ]);
          await open(tester, env);
          expectNoOverflow(tester);
          await tester.tap(find.byTooltip('Moderate @member3'));
          await tester.pumpAndSettle();
          expectNoOverflow(tester);
          expect(find.text('Ban from Community'), findsOneWidget);
          await tester.tap(find.text('Ban from Community'));
          await tester.pumpAndSettle();
          expectNoOverflow(tester);
          expect(find.widgetWithText(FilledButton, 'Ban'), findsOneWidget);
          expect(find.text('Cancel'), findsOneWidget);
        },
        textScales: kMatrixTextScalesLarge,
        height: 900,
      );
    }
  });

  // ------------------------------------------------------ Moderation log
  group('CommunityModerationLogScreen states', () {
    late _MockCommunities communities;
    setUp(() => communities = _MockCommunities());

    Future<void> open(WidgetTester tester, MatrixEnv env, {Object? error}) {
      when(
        () => communities.listModerationLog(
          communityId: any(named: 'communityId'),
          pageSize: any(named: 'pageSize'),
          pageToken: any(named: 'pageToken'),
        ),
      ).thenAnswer((_) async {
        if (error != null) throw error;
        return const ModerationLogPage(entries: []);
      });
      return pumpThemed(
        tester,
        RepositoryProvider<CommunitiesRepository>.value(
          value: communities,
          child: CommunityModerationLogScreen(
            communityId: '77',
            now: DateTime.now(),
          ),
        ),
        brightness: env.brightness,
        size: env.size,
        textScale: env.textScale,
        useScaffold: false,
      );
    }

    forEachThemeAndWidth('empty log', (tester, env) async {
      await open(tester, env);
      expectNoOverflow(tester);
      expect(find.text('Nothing here yet'), findsOneWidget);
    }, textScales: kMatrixTextScalesLarge);

    forEachThemeAndWidth('FORBIDDEN not_moderator: sentence, no Retry', (
      tester,
      env,
    ) async {
      await open(
        tester,
        env,
        error: CommunityForbiddenException(
          CommunityForbiddenReason.notModerator,
        ),
      );
      expectNoOverflow(tester);
      expect(find.text('Only moderators can do that.'), findsOneWidget);
      expect(find.text('Retry'), findsNothing);
    }, textScales: kMatrixTextScalesLarge);

    forEachThemeAndWidth('NOT_FOUND: the unavailable view', (
      tester,
      env,
    ) async {
      await open(tester, env, error: const NotFoundException('gone'));
      expectNoOverflow(tester);
      expect(find.text('This Community is unavailable'), findsOneWidget);
    }, textScales: kMatrixTextScalesLarge);

    forEachThemeAndWidth('network error: Retry', (tester, env) async {
      await open(tester, env, error: const NetworkException('offline'));
      expectNoOverflow(tester);
      expect(find.text('Retry'), findsOneWidget);
    }, textScales: kMatrixTextScalesLarge);
  });

  // -------------------------------------------------------------- Create
  group('CreateCommunityScreen failure', () {
    late _MockCommunities repo;
    setUpAll(() => registerFallbackValue(<pb.CommunityRule>[]));
    setUp(() {
      repo = _MockCommunities();
      when(() => repo.enabled).thenReturn(true);
    });

    forEachThemeAndWidth(
      'a refusal keeps the form and shows its sentence',
      (tester, env) async {
        when(
          () => repo.createCommunity(
            idempotencyKey: any(named: 'idempotencyKey'),
            name: any(named: 'name'),
            description: any(named: 'description'),
            rules: any(named: 'rules'),
          ),
        ).thenThrow(
          CommunityForbiddenException(CommunityForbiddenReason.notCreator),
        );
        await pumpThemed(
          tester,
          RepositoryProvider<CommunitiesRepository>.value(
            value: repo,
            child: const CreateCommunityScreen(),
          ),
          brightness: env.brightness,
          size: env.size,
          textScale: env.textScale,
          useScaffold: false,
        );
        await tester.enterText(
          find.widgetWithText(TextField, 'Name'),
          _names['rtl']!,
        );
        await tester.pump();
        await tester.tap(find.text('Create'));
        await tester.pumpAndSettle();
        expectNoOverflow(tester);
        expect(find.text('Create a Community'), findsOneWidget);
      },
      textScales: kMatrixTextScalesLarge,
      height: 1200,
    );
  });

  // ---------------------------------------------------------- PostCard
  group('PostCard community label and moderator menu', () {
    posts_pb.PostView view(String name, {bool repost = false}) {
      final author = common.AuthorSnapshot(
        userId: 'u1',
        handle: 'alice',
        displayName: 'Alice A',
      );
      return posts_pb.PostView(
        post: posts_pb.Post(
          postId: postId(5),
          text: 'hello from the club',
          author: author,
          kind: repost
              ? posts_pb.PostKind.POST_KIND_REPOST
              : posts_pb.PostKind.POST_KIND_POST,
          embedded: repost
              ? posts_pb.EmbeddedPost(
                  postId: postId(4),
                  text: 'original',
                  author: common.AuthorSnapshot(userId: 'u2', handle: 'bob'),
                )
              : null,
          community: posts_pb.CommunityRef(id: '77', name: name),
        ),
      );
    }

    Future<void> open(
      WidgetTester tester,
      MatrixEnv env,
      posts_pb.PostView v, {
      PostModerationControl? control,
    }) => pumpThemed(
      tester,
      BlocProvider<OnboardingBloc>.value(
        value: onboardingWith(const {'communities', 'posts'}),
        child: SingleChildScrollView(
          child: PostCard(
            view: v,
            now: DateTime.now(),
            viewerUserId: 'viewer',
            graphActionsEnabled: false,
            reportsEnabled: true,
            moderationControl: control,
          ),
        ),
      ),
      brightness: env.brightness,
      size: env.size,
      textScale: env.textScale,
    );

    for (final name in _names.entries) {
      forEachThemeAndWidth('label with a ${name.key} name fits', (
        tester,
        env,
      ) async {
        await open(tester, env, view(name.value));
        expectNoOverflow(tester);
        expect(find.byIcon(Icons.people_outline), findsOneWidget);
        expect(
          find.textContaining('Unbroken', findRichText: true),
          name.key == 'zero-width' ? findsOneWidget : findsNothing,
        );
      }, textScales: kMatrixTextScalesLarge);
    }

    forEachThemeAndWidth('a repost of a community post: "reposted" wins, no '
        'community label', (tester, env) async {
      await open(tester, env, view(_names['long']!, repost: true));
      expectNoOverflow(tester);
      expect(find.textContaining('reposted'), findsOneWidget);
      expect(find.byIcon(Icons.people_outline), findsNothing);
    }, textScales: kMatrixTextScalesLarge);
  });
}
