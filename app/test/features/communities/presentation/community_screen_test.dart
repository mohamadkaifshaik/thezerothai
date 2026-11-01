import 'dart:async';

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
import 'package:dzeroth/features/timeline/domain/feed_key.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/communities/v1/communities.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:dzeroth/shared/widgets/primitives/app_pill_button.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/geometry.dart';
import '../../../support/theme_harness.dart';
import '../../../support/timeline_fixtures.dart';

class _MockOnboarding extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

class _MockCommunities extends Mock implements CommunitiesRepository {}

class _MockTabs extends Mock implements HomeTabsRepository {}

class _MockGraph extends Mock implements GraphRepository {}

pb.Community _community({
  pb.CommunityRole role = pb.CommunityRole.COMMUNITY_ROLE_NONE,
  int members = 3,
}) => pb.Community(
  communityId: '77',
  name: 'Chess club',
  description: 'Openings, endgames and puzzles',
  memberCount: Int64(members),
  viewerRole: role,
);

graph.UserListItem _person(String id, String handle, String name) =>
    graph.UserListItem(
      user: common.AuthorSnapshot(
        userId: id,
        handle: handle,
        displayName: name,
      ),
    );

pb.GetCommunityResponse _answer({
  pb.CommunityRole role = pb.CommunityRole.COMMUNITY_ROLE_NONE,
}) => pb.GetCommunityResponse(
  community: _community(role: role),
  rules: [
    pb.CommunityRule(title: 'Be kind', text: 'No insults.'),
    pb.CommunityRule(title: 'Stay on topic', text: 'Chess only.'),
  ],
  owner: _person('o1', 'olivia', 'Olivia'),
  moderators: [_person('m1', 'mo', 'Mo')],
);

/// W5-32: `/communities/:id` at 360 / 600 / 1200 dp, light and dark, text
/// scale 1.0 / 1.3 / 2.0.
void main() {
  final feed = FeedKey.community('77');
  late MockTimelineRepository timeline;
  late MockPostsRepository posts;
  late _MockCommunities communities;
  late _MockTabs tabs;
  late _MockOnboarding onboarding;
  var pinned = false;
  var full = false;

  setUpAll(() {
    registerFallbackValue(HomeTabKind.community);
  });

  setUp(() {
    pinned = false;
    full = false;
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
    when(() => communities.getCommunity('77'))
        .thenAnswer((_) async => _answer());
    when(() => tabs.changes).thenAnswer((_) => const Stream.empty());
    when(() => tabs.isPinned(any(), any())).thenAnswer((_) => pinned);
    when(() => tabs.isFull).thenAnswer((_) => full);
    when(() => tabs.writeUnavailable).thenReturn(false);
    when(() => tabs.pin(any(), any(), title: any(named: 'title')))
        .thenAnswer((_) async {
          pinned = true;
        });
    when(() => tabs.unpin(any(), any())).thenAnswer((_) async {
      pinned = false;
    });
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

  Future<void> open(WidgetTester tester, {MatrixEnv? env}) => pumpThemed(
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
    brightness: env?.brightness ?? Brightness.light,
    size: env?.size ?? const Size(360, 800),
    textScale: env?.textScale ?? 1.0,
    useScaffold: false,
  );

  forEachThemeAndWidth(
    'header for a non-member: name, members, Join, Pin; empty Posts; '
    'no compose entry',
    (tester, env) async {
      final semantics = tester.ensureSemantics();
      await open(tester, env: env);

      expectNoOverflow(tester);
      expect(find.text('Chess club'), findsWidgets);
      expect(find.text('3 members'), findsOneWidget);
      expect(find.text('Join'), findsOneWidget);
      expect(find.text('Pin to Home'), findsOneWidget);
      expect(find.text('No posts yet'), findsOneWidget);
      expect(find.text('Posts'), findsOneWidget);
      expect(find.text('About'), findsOneWidget);
      expect(find.bySemanticsLabel('Join Chess club'), findsOneWidget);
      expect(find.bySemanticsLabel('3 members, see members'), findsOneWidget);
      expect(find.textContaining('Post in'), findsNothing);
      expect(find.byTooltip('Compose'), findsNothing);
      semantics.dispose();
    },
    textScales: kMatrixTextScalesLarge,
  );

  forEachThemeAndWidth('About: description, numbered rules, moderators', (
    tester,
    env,
  ) async {
    await open(tester, env: env);
    await tester.tap(find.text('About'));
    await tester.pumpAndSettle();

    expectNoOverflow(tester);
    expect(find.text('Openings, endgames and puzzles'), findsOneWidget);
    expect(find.text('1.'), findsOneWidget);
    expect(find.text('Be kind'), findsOneWidget);
    expect(find.text('Stay on topic'), findsOneWidget);
    expect(find.text('Olivia'), findsOneWidget);
    expect(find.text('Mo'), findsOneWidget);
  }, textScales: kMatrixTextScalesLarge, height: 3000);

  testWidgets('one GetCommunity and one timeline refresh per open', (
    tester,
  ) async {
    await open(tester);
    verify(() => communities.getCommunity('77')).called(1);
    verify(() => timeline.refresh(feed)).called(1);
  });

  testWidgets('a member sees Joined and the owner badge for an owner', (
    tester,
  ) async {
    when(() => communities.getCommunity('77')).thenAnswer(
      (_) async => _answer(role: pb.CommunityRole.COMMUNITY_ROLE_OWNER),
    );
    final semantics = tester.ensureSemantics();
    await open(tester);

    expect(find.text('Joined'), findsOneWidget);
    expect(find.text('Owner'), findsOneWidget);
    // The owner cannot leave: "Joined" is not a button.
    expect(find.bySemanticsLabel('Joined Chess club'), findsOneWidget);
    expect(find.bySemanticsLabel('Joined Chess club, leave'), findsNothing);
    semantics.dispose();
  });

  testWidgets('Join is optimistic and rolls back with a message', (
    tester,
  ) async {
    final answer = Completer<pb.Community>();
    when(
      () => communities.joinCommunity(
        idempotencyKey: any(named: 'idempotencyKey'),
        communityId: '77',
      ),
    ).thenAnswer((_) => answer.future);
    await open(tester);

    await tester.tap(find.text('Join'));
    await tester.pump();
    expect(find.text('Joined'), findsOneWidget);

    answer.completeError(const NetworkException('offline'));
    await tester.pumpAndSettle();
    expect(find.text('Join'), findsOneWidget);
    expect(find.textContaining('No connection'), findsOneWidget);
  });

  testWidgets('Join succeeds: Joined from the answer', (tester) async {
    when(
      () => communities.joinCommunity(
        idempotencyKey: any(named: 'idempotencyKey'),
        communityId: '77',
      ),
    ).thenAnswer(
      (_) async => _community(role: pb.CommunityRole.COMMUNITY_ROLE_MEMBER),
    );
    await open(tester);

    await tester.tap(find.text('Join'));
    await tester.pumpAndSettle();
    expect(find.text('Joined'), findsOneWidget);
  });

  testWidgets('Leave asks to confirm, then the control reads Join', (
    tester,
  ) async {
    when(() => communities.getCommunity('77')).thenAnswer(
      (_) async => _answer(role: pb.CommunityRole.COMMUNITY_ROLE_MEMBER),
    );
    when(
      () => communities.leaveCommunity(
        idempotencyKey: any(named: 'idempotencyKey'),
        communityId: '77',
      ),
    ).thenAnswer((_) async => _community());
    await open(tester);

    await tester.tap(find.text('Joined'));
    await tester.pumpAndSettle();
    expect(find.text('Leave Chess club?'), findsOneWidget);
    await tester.tap(find.text('Leave'));
    await tester.pumpAndSettle();
    expect(find.text('Join'), findsOneWidget);
  });

  testWidgets('a banned viewer sees the banned sentence, no Join, no Pin', (
    tester,
  ) async {
    when(() => communities.getCommunity('77')).thenAnswer(
      (_) async => _answer(role: pb.CommunityRole.COMMUNITY_ROLE_BANNED),
    );
    final semantics = tester.ensureSemantics();
    await open(tester);

    expect(find.text("You can't join this Community"), findsOneWidget);
    expect(find.text('Join'), findsNothing);
    expect(find.text('Pin to Home'), findsNothing);
    expect(
      find.bySemanticsLabel("You can't join this Community"),
      findsOneWidget,
    );
    semantics.dispose();
  });

  testWidgets('Pin to Home pins, then offers Unpin', (tester) async {
    await open(tester);

    await tester.tap(find.text('Pin to Home'));
    await tester.pumpAndSettle();
    verify(() => tabs.pin(HomeTabKind.community, '77', title: 'Chess club'))
        .called(1);
    expect(find.text('Unpin from Home'), findsOneWidget);
  });

  testWidgets('at the pin cap, Pin is disabled with the reason', (
    tester,
  ) async {
    full = true;
    await open(tester);

    final pin = tester.widget<AppPillButton>(find.widgetWithText(AppPillButton, 'Pin to Home'));
    expect(pin.onPressed, isNull);
    expect(find.textContaining('Unpin one first'), findsOneWidget);
  });

  testWidgets('NOT_FOUND shows "This Community is unavailable"', (
    tester,
  ) async {
    when(() => communities.getCommunity('77'))
        .thenThrow(const NotFoundException('gone'));
    await open(tester);

    expect(find.text('This Community is unavailable'), findsOneWidget);
    expect(find.text('Join'), findsNothing);
  });

  testWidgets('a load error with nothing cached shows Retry', (tester) async {
    var calls = 0;
    when(() => communities.getCommunity('77')).thenAnswer((_) async {
      if (calls++ == 0) throw const NetworkException('offline');
      return _answer();
    });
    await open(tester);

    expect(find.text('Retry'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('Join'), findsOneWidget);
  });
}
