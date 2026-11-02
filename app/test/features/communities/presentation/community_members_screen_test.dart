import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/communities/data/communities_repository.dart';
import 'package:dzeroth/features/communities/presentation/community_members_screen.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/communities/v1/communities.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
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

pb.CommunityMember _member(
  int i, {
  pb.CommunityRole role = pb.CommunityRole.COMMUNITY_ROLE_MEMBER,
}) => pb.CommunityMember(
  role: role,
  user: graph.UserListItem(
    user: common.AuthorSnapshot(
      userId: 'm$i',
      handle: 'member$i',
      displayName: 'Member $i',
    ),
  ),
);

/// W5-32: `/communities/:id/members` at 360 / 600 / 1200 dp, light and dark,
/// text scale 1.0 / 1.3 / 2.0.
void main() {
  late _MockCommunities communities;
  late _MockOnboarding onboarding;

  setUpAll(() {
    registerFallbackValue(
      pb.CommunityMemberFilter.COMMUNITY_MEMBER_FILTER_JOINED,
    );
  });

  setUp(() {
    communities = _MockCommunities();
    when(() => communities.getCommunity(any())).thenAnswer(
      (_) async => pb.GetCommunityResponse(
        community: pb.Community(
          communityId: '77',
          viewerRole: pb.CommunityRole.COMMUNITY_ROLE_MEMBER,
        ),
      ),
    );
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

  void stubMembers(List<pb.CommunityMember> members) {
    when(
      () => communities.listMembers(
        communityId: any(named: 'communityId'),
        filter: any(named: 'filter'),
        pageSize: any(named: 'pageSize'),
        pageToken: any(named: 'pageToken'),
      ),
    ).thenAnswer((_) async => CommunityMembersPage(members: members));
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

  forEachThemeAndWidth('members with role badges fit', (tester, env) async {
    stubMembers([
      _member(1, role: pb.CommunityRole.COMMUNITY_ROLE_OWNER),
      _member(2, role: pb.CommunityRole.COMMUNITY_ROLE_MODERATOR),
      _member(3),
    ]);
    await open(tester, env: env);

    expectNoOverflow(tester);
    expect(find.text('Members'), findsOneWidget);
    expect(find.text('Member 1'), findsOneWidget);
    expect(find.text('Owner'), findsOneWidget);
    expect(find.text('Moderator'), findsOneWidget);
  }, textScales: kMatrixTextScalesLarge);

  testWidgets('empty community: a sentence', (tester) async {
    stubMembers([]);
    await open(tester);
    expect(find.text('No members yet'), findsOneWidget);
  });

  testWidgets('NOT_FOUND shows "This Community is unavailable"', (
    tester,
  ) async {
    when(
      () => communities.listMembers(
        communityId: any(named: 'communityId'),
        filter: any(named: 'filter'),
        pageSize: any(named: 'pageSize'),
        pageToken: any(named: 'pageToken'),
      ),
    ).thenThrow(const NotFoundException('gone'));
    await open(tester);
    expect(find.text('This Community is unavailable'), findsOneWidget);
  });

  testWidgets('a not-yet-served RPC reads as "not available"', (tester) async {
    when(
      () => communities.listMembers(
        communityId: any(named: 'communityId'),
        filter: any(named: 'filter'),
        pageSize: any(named: 'pageSize'),
        pageToken: any(named: 'pageToken'),
      ),
    ).thenThrow(const FeatureDisabledException('no', feature: 'communities'));
    await open(tester);
    expect(find.text("Communities aren't available right now"), findsOneWidget);
  });
}
