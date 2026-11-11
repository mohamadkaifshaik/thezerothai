import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/communities/data/communities_repository.dart';
import 'package:dzeroth/features/communities/domain/communities_feature_flag.dart';
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
import 'package:dzeroth/shared/widgets/primitives/app_tab_bar.dart';
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

  /// [moderators] answers the MODERATORS filter (F24, R10); null answers it
  /// with [joined], as before.
  void stubLists({
    List<pb.CommunityMember> joined = const [],
    List<pb.CommunityMember> bannedList = const [],
    List<pb.CommunityMember>? moderators,
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
            : filter ==
                      pb
                          .CommunityMemberFilter
                          .COMMUNITY_MEMBER_FILTER_MODERATORS &&
                  moderators != null
            ? moderators
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

  group('R10: the other tabs and the search follow an action', () {
    /// The [filter] pages asked for since the last count (verify marks
    /// what it counted); 0 when none.
    int listed(pb.CommunityMemberFilter filter) {
      try {
        return verify(
          () => communities.listMembers(
            communityId: any(named: 'communityId'),
            filter: filter,
            pageSize: any(named: 'pageSize'),
            pageToken: any(named: 'pageToken'),
          ),
        ).callCount;
      } on TestFailure {
        return 0;
      }
    }

    const joinedFilter =
        pb.CommunityMemberFilter.COMMUNITY_MEMBER_FILTER_JOINED;
    const bannedFilter =
        pb.CommunityMemberFilter.COMMUNITY_MEMBER_FILTER_BANNED;
    const modsFilter =
        pb.CommunityMemberFilter.COMMUNITY_MEMBER_FILTER_MODERATORS;

    Finder tab(String label) =>
        find.descendant(of: find.byType(AppTabBar), matching: find.text(label));

    void searchOn() => whenListen(
      onboarding,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        status: OnboardingStatus.ready,
        profile: identity.Profile(userId: 'viewer', handle: 'me'),
        enabledFeatures: const {
          'communities',
          'graph',
          kFeatureCommunityMemberSearch,
        },
      ),
    );

    for (final fails in [false, true]) {
      testWidgets(
        fails
            ? 'a Ban from the search results that fails puts the row back'
            : 'a Ban from the search results takes the row out and reloads '
                  'Members',
        (tester) async {
          searchOn();
          stubViewer(moderator);
          stubLists(joined: [_member(3, plain), _member(4, plain)]);
          when(
            () => communities.searchMembers(
              communityId: any(named: 'communityId'),
              prefix: any(named: 'prefix'),
              filter: any(named: 'filter'),
              limit: any(named: 'limit'),
            ),
          ).thenAnswer((_) async => [_member(3, plain)]);
          stubSetRole(
            error: fails
                ? CommunityForbiddenException(
                    CommunityForbiddenReason.notModerator,
                  )
                : null,
          );
          await open(tester);
          expect(listed(joinedFilter), 1);
          await tester.enterText(find.byType(TextField), 'member3');
          await tester.pump(const Duration(milliseconds: 300));
          await tester.pumpAndSettle();
          expect(find.text('Member 3'), findsOneWidget);
          expect(find.text('Member 4'), findsNothing);

          await tester.tap(find.byTooltip('Moderate @member3'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Ban from Community'));
          await tester.pumpAndSettle();
          await tester.tap(find.widgetWithText(FilledButton, 'Ban'));
          await tester.pumpAndSettle();
          if (fails) {
            expect(find.text('Member 3'), findsOneWidget);
            expect(find.text('Only moderators can do that.'), findsOneWidget);
            expect(listed(joinedFilter), 0);
          } else {
            expect(find.text('Member 3'), findsNothing);
            expect(find.text('Banned @member3.'), findsOneWidget);
            // Members (the tab under the search) reloads; Banned was never
            // opened, so it is not asked for.
            expect(listed(joinedFilter), 1);
            expect(listed(bannedFilter), 0);
          }
        },
      );
    }

    testWidgets('Remove as moderator on the Moderators tab drops the row', (
      tester,
    ) async {
      stubViewer(owner);
      stubLists(
        joined: [_member(1, owner), _member(2, moderator)],
        moderators: [_member(1, owner), _member(2, moderator)],
      );
      stubSetRole(role: plain);
      await open(tester);
      await tester.tap(tab('Moderators'));
      await tester.pumpAndSettle();
      expect(find.text('Member 2'), findsOneWidget);
      await tester.tap(find.byTooltip('Moderate @member2'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove as moderator'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
      await tester.pumpAndSettle();
      expect(find.text('Member 2'), findsNothing);
      expect(find.text('Member 1'), findsOneWidget);
      expect(find.text('@member2 is no longer a moderator.'), findsOneWidget);
    });

    for (final opened in [false, true]) {
      testWidgets(
        opened
            ? 'Make moderator on Members reloads the Moderators tab it '
                  'already loaded'
            : 'Make moderator on Members asks nothing for a Moderators tab '
                  'never opened',
        (tester) async {
          stubViewer(owner);
          stubLists(
            joined: [_member(3, plain)],
            moderators: [_member(1, owner)],
          );
          stubSetRole(role: moderator);
          await open(tester);
          if (opened) {
            await tester.tap(tab('Moderators'));
            await tester.pumpAndSettle();
            await tester.tap(tab('Members'));
            await tester.pumpAndSettle();
          }
          expect(listed(modsFilter), opened ? 1 : 0);
          // (Each count is of the calls since the last one: verify marks.)
          expect(listed(joinedFilter), 1);
          await tester.tap(find.byTooltip('Moderate @member3'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Make moderator'));
          await tester.pumpAndSettle();
          await tester.tap(find.widgetWithText(FilledButton, 'Make moderator'));
          await tester.pumpAndSettle();
          expect(find.text('@member3 is now a moderator.'), findsOneWidget);
          expect(listed(modsFilter), opened ? 1 : 0);
          // Members itself is not reloaded: its badge takes the new role.
          expect(listed(joinedFilter), 0);
          expect(find.text('Moderator'), findsOneWidget);
        },
      );
    }
  });
}
