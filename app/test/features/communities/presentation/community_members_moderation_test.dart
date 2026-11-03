import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/communities/data/communities_repository.dart';
import 'package:dzeroth/features/communities/domain/community_role.dart';
import 'package:dzeroth/features/communities/presentation/community_members_screen.dart';
import 'package:dzeroth/features/communities/presentation/widgets/community_member_actions.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/communities/v1/communities.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:fixnum/fixnum.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/geometry.dart';
import '../../../support/theme_harness.dart';

class _MockOnboarding extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

class _MockCommunities extends Mock implements CommunitiesRepository {}

class _MockGraph extends Mock implements GraphRepository {}

pb.CommunityMember _member(int i, pb.CommunityRole role) => pb.CommunityMember(
  role: role,
  user: graph.UserListItem(
    user: common.AuthorSnapshot(
      userId: 'm$i',
      handle: 'member$i',
      displayName: 'Member $i',
    ),
  ),
);

/// The moderator rows of the members page, by role. The viewer's role
/// is the server's `viewer_role` from GetCommunity; the client derives none.
void main() {
  late _MockCommunities communities;
  late _MockOnboarding onboarding;

  const owner = pb.CommunityRole.COMMUNITY_ROLE_OWNER;
  const moderator = pb.CommunityRole.COMMUNITY_ROLE_MODERATOR;
  const plain = pb.CommunityRole.COMMUNITY_ROLE_MEMBER;
  const banned = pb.CommunityRole.COMMUNITY_ROLE_BANNED;

  setUpAll(() {
    registerFallbackValue(
      pb.CommunityMemberFilter.COMMUNITY_MEMBER_FILTER_JOINED,
    );
    registerFallbackValue(pb.MemberRoleAction.MEMBER_ROLE_ACTION_BAN);
  });

  setUp(() {
    communities = _MockCommunities();
    onboarding = _MockOnboarding();
    whenListen(
      onboarding,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        status: OnboardingStatus.ready,
        profile: identity.Profile(userId: 'viewer', handle: 'me'),
        enabledFeatures: const {'communities', 'graph'},
      ),
    );
  });

  void stubViewer(pb.CommunityRole role) {
    when(() => communities.getCommunity(any())).thenAnswer(
      (_) async => pb.GetCommunityResponse(
        community: pb.Community(communityId: '77', viewerRole: role),
      ),
    );
  }

  void stubLists({
    List<pb.CommunityMember> joined = const [],
    List<pb.CommunityMember> bannedList = const [],
  }) {
    when(
      () => communities.listMembers(
        communityId: any(named: 'communityId'),
        filter: any(named: 'filter'),
        pageSize: any(named: 'pageSize'),
        pageToken: any(named: 'pageToken'),
      ),
    ).thenAnswer((i) async {
      final filter = i.namedArguments[#filter] as pb.CommunityMemberFilter;
      return CommunityMembersPage(
        members:
            filter == pb.CommunityMemberFilter.COMMUNITY_MEMBER_FILTER_BANNED
            ? bannedList
            : joined,
      );
    });
  }

  void stubSetRole({AppException? error, pb.CommunityRole role = banned}) {
    when(
      () => communities.setMemberRole(
        idempotencyKey: any(named: 'idempotencyKey'),
        communityId: any(named: 'communityId'),
        userId: any(named: 'userId'),
        action: any(named: 'action'),
      ),
    ).thenAnswer((_) async {
      if (error != null) throw error;
      return pb.SetMemberRoleResponse(
        role: role,
        community: pb.Community(communityId: '77', memberCount: Int64(2)),
      );
    });
  }

  Future<void> open(WidgetTester tester, {MatrixEnv? env}) => pumpThemed(
    tester,
    MultiRepositoryProvider(
      providers: [
        RepositoryProvider<CommunitiesRepository>.value(value: communities),
        RepositoryProvider<GraphRepository>.value(value: _MockGraph()),
      ],
      child: BlocProvider<OnboardingBloc>.value(
        value: onboarding,
        child: const CommunityMembersScreen(communityId: '77'),
      ),
    ),
    brightness: env?.brightness ?? Brightness.light,
    size: env?.size ?? const Size(360, 800),
    textScale: env?.textScale ?? 1.0,
    useScaffold: false,
  );

  group('the action matrix (pure)', () {
    List<CommunityMemberAction> of(CommunityRole v, CommunityRole t) =>
        communityMemberActions(viewer: v, target: t, isSelf: false);

    test('owner', () {
      expect(of(CommunityRole.owner, CommunityRole.member), [
        CommunityMemberAction.ban,
        CommunityMemberAction.makeModerator,
      ]);
      expect(of(CommunityRole.owner, CommunityRole.moderator), [
        CommunityMemberAction.removeModerator,
      ]);
      expect(of(CommunityRole.owner, CommunityRole.banned), [
        CommunityMemberAction.unban,
      ]);
      expect(of(CommunityRole.owner, CommunityRole.owner), isEmpty);
    });

    test('moderator: ban and unban only, never a moderator or the owner', () {
      expect(of(CommunityRole.moderator, CommunityRole.member), [
        CommunityMemberAction.ban,
      ]);
      expect(of(CommunityRole.moderator, CommunityRole.banned), [
        CommunityMemberAction.unban,
      ]);
      expect(of(CommunityRole.moderator, CommunityRole.moderator), isEmpty);
      expect(of(CommunityRole.moderator, CommunityRole.owner), isEmpty);
    });

    test('member, banned and none viewers get nothing', () {
      for (final viewer in [
        CommunityRole.member,
        CommunityRole.banned,
        CommunityRole.none,
      ]) {
        for (final target in CommunityRole.values) {
          expect(of(viewer, target), isEmpty, reason: '$viewer on $target');
        }
      }
    });

    test('never on yourself', () {
      expect(
        communityMemberActions(
          viewer: CommunityRole.owner,
          target: CommunityRole.member,
          isSelf: true,
        ),
        isEmpty,
      );
    });
  });

  testWidgets('a member viewer sees no moderator rows and no Banned tab', (
    tester,
  ) async {
    stubViewer(plain);
    stubLists(joined: [_member(1, owner), _member(2, plain)]);
    await open(tester);
    expect(find.byTooltip('Moderate @member2'), findsNothing);
    expect(find.text('Banned'), findsNothing);
  });

  testWidgets('a failed GetCommunity means no moderator rows', (tester) async {
    when(() => communities.getCommunity(any()))
        .thenThrow(const NetworkException('offline'));
    stubLists(joined: [_member(2, plain)]);
    await open(tester);
    expect(find.text('Member 2'), findsOneWidget);
    expect(find.byTooltip('Moderate @member2'), findsNothing);
  });

  testWidgets('moderator: Ban only on a plain member, none on the owner', (
    tester,
  ) async {
    stubViewer(moderator);
    stubLists(
      joined: [_member(1, owner), _member(2, moderator), _member(3, plain)],
    );
    await open(tester);
    expect(find.byTooltip('Moderate @member1'), findsNothing);
    expect(find.byTooltip('Moderate @member2'), findsNothing);
    await tester.tap(find.byTooltip('Moderate @member3'));
    await tester.pumpAndSettle();
    expect(find.text('Ban from Community'), findsOneWidget);
    expect(find.text('Make moderator'), findsNothing);
  });

  testWidgets('owner: Make moderator and Remove as moderator', (tester) async {
    stubViewer(owner);
    stubLists(joined: [_member(2, moderator), _member(3, plain)]);
    await open(tester);
    await tester.tap(find.byTooltip('Moderate @member3'));
    await tester.pumpAndSettle();
    expect(find.text('Ban from Community'), findsOneWidget);
    expect(find.text('Make moderator'), findsOneWidget);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Moderate @member2'));
    await tester.pumpAndSettle();
    expect(find.text('Remove as moderator'), findsOneWidget);
    expect(find.text('Ban from Community'), findsNothing);
  });

  testWidgets('Ban: confirm, the row leaves, the server call is made', (
    tester,
  ) async {
    stubViewer(moderator);
    stubLists(joined: [_member(3, plain), _member(4, plain)]);
    stubSetRole();
    await open(tester);
    await tester.tap(find.byTooltip('Moderate @member3'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ban from Community'));
    await tester.pumpAndSettle();
    expect(find.text('Ban @member3?'), findsOneWidget);
    await tester.tap(find.text('Ban'));
    await tester.pumpAndSettle();
    expect(find.text('Member 3'), findsNothing);
    expect(find.text('Member 4'), findsOneWidget);
    expect(find.text('Banned @member3.'), findsOneWidget);
    verify(
      () => communities.setMemberRole(
        idempotencyKey: any(named: 'idempotencyKey'),
        communityId: '77',
        userId: 'm3',
        action: pb.MemberRoleAction.MEMBER_ROLE_ACTION_BAN,
      ),
    ).called(1);
  });

  testWidgets('Cancel sends nothing', (tester) async {
    stubViewer(moderator);
    stubLists(joined: [_member(3, plain)]);
    await open(tester);
    await tester.tap(find.byTooltip('Moderate @member3'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ban from Community'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    verifyNever(
      () => communities.setMemberRole(
        idempotencyKey: any(named: 'idempotencyKey'),
        communityId: any(named: 'communityId'),
        userId: any(named: 'userId'),
        action: any(named: 'action'),
      ),
    );
    expect(find.text('Member 3'), findsOneWidget);
  });

  testWidgets('a failed Ban puts the row back with a sentence', (tester) async {
    stubViewer(moderator);
    stubLists(joined: [_member(3, plain)]);
    stubSetRole(
      error: CommunityForbiddenException(CommunityForbiddenReason.notModerator),
    );
    await open(tester);
    await tester.tap(find.byTooltip('Moderate @member3'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ban from Community'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ban'));
    await tester.pumpAndSettle();
    expect(find.text('Member 3'), findsOneWidget);
    expect(find.text('Only moderators can do that.'), findsOneWidget);
  });

  testWidgets('Make moderator shows the role the server returned', (
    tester,
  ) async {
    stubViewer(owner);
    stubLists(joined: [_member(3, plain)]);
    stubSetRole(role: moderator);
    await open(tester);
    await tester.tap(find.byTooltip('Moderate @member3'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Make moderator'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Make moderator'));
    await tester.pumpAndSettle();
    expect(find.text('Moderator'), findsOneWidget);
    expect(find.text('@member3 is now a moderator.'), findsOneWidget);
  });

  testWidgets('the moderator limit is a friendly sentence', (tester) async {
    stubViewer(owner);
    stubLists(joined: [_member(3, plain)]);
    stubSetRole(
      error: const LimitReachedException('x', quota: 'community_moderators'),
    );
    await open(tester);
    await tester.tap(find.byTooltip('Moderate @member3'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Make moderator'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Make moderator'));
    await tester.pumpAndSettle();
    expect(find.textContaining('most moderators'), findsOneWidget);
    expect(find.text('Moderator'), findsNothing);
  });

  testWidgets('Banned tab lists the banned with Unban', (tester) async {
    stubViewer(moderator);
    stubLists(joined: [_member(3, plain)], bannedList: [_member(9, banned)]);
    stubSetRole(role: pb.CommunityRole.COMMUNITY_ROLE_NONE);
    await open(tester);
    await tester.tap(find.text('Banned'));
    await tester.pumpAndSettle();
    expect(find.text('Member 9'), findsOneWidget);
    await tester.tap(find.byTooltip('Moderate @member9'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Unban'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Unban'));
    await tester.pumpAndSettle();
    expect(find.text('Member 9'), findsNothing);
    expect(find.text('Unbanned @member9.'), findsOneWidget);
  });

  forEachThemeAndWidth('owner view with menus fits', (tester, env) async {
    stubViewer(owner);
    stubLists(
      joined: [_member(1, owner), _member(2, moderator), _member(3, plain)],
    );
    await open(tester, env: env);
    expectNoOverflow(tester);
    expect(find.byTooltip('Moderate @member3'), findsOneWidget);
    expect(find.text('Banned'), findsOneWidget);
  }, textScales: kMatrixTextScalesLarge);
}
