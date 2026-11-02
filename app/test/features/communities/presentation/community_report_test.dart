import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/app/session_wiring.dart' show UnexpectedErrorReporter;
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/communities/data/communities_repository.dart';
import 'package:dzeroth/features/communities/presentation/community_screen.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/lists/data/home_tabs_repository.dart';
import 'package:dzeroth/features/lists/domain/home_tab_entry.dart';
import 'package:dzeroth/features/moderation/data/moderation_repository.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/features/timeline/data/timeline_repository.dart';
import 'package:dzeroth/features/timeline/domain/feed_key.dart';
import 'package:dzeroth/gen/dzeroth/communities/v1/communities.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:dzeroth/gen/dzeroth/moderation/v1/moderation.pbenum.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/theme_harness.dart';
import '../../../support/timeline_fixtures.dart';

class _MockOnboarding extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

class _MockCommunities extends Mock implements CommunitiesRepository {}

class _MockTabs extends Mock implements HomeTabsRepository {}

class _MockGraph extends Mock implements GraphRepository {}

class _MockModeration extends Mock implements ModerationRepository {}

/// W5-35b: "Report Community" in the community header menu.
void main() {
  final feed = FeedKey.community('77');
  late MockTimelineRepository timeline;
  late MockPostsRepository posts;
  late _MockCommunities communities;
  late _MockTabs tabs;
  late _MockModeration moderation;
  late _MockOnboarding onboarding;

  setUpAll(() {
    registerFallbackValue(HomeTabKind.community);
    registerFallbackValue(ReportTargetType.REPORT_TARGET_TYPE_COMMUNITY);
    registerFallbackValue(ReportReason.REPORT_REASON_SPAM);
  });

  setUp(() {
    timeline = MockTimelineRepository();
    posts = MockPostsRepository();
    communities = _MockCommunities();
    tabs = _MockTabs();
    moderation = _MockModeration();
    onboarding = _MockOnboarding();
    when(() => posts.removedPosts).thenAnswer((_) => const Stream.empty());
    when(() => timeline.sinceRefresh(feed)).thenReturn(null);
    when(() => timeline.sinceRefreshAttempt(feed)).thenReturn(null);
    when(() => timeline.rateLimitedFor()).thenReturn(null);
    when(() => timeline.cached(feed)).thenAnswer((_) async => snapshotOf([]));
    when(() => timeline.refresh(feed)).thenAnswer((_) async => snapshotOf([]));
    when(() => tabs.changes).thenAnswer((_) => const Stream.empty());
    when(() => tabs.isPinned(any(), any())).thenReturn(false);
    when(() => tabs.isFull).thenReturn(false);
    when(() => tabs.writeUnavailable).thenReturn(false);
  });

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

  void stubReport([Future<ReportReceipt> Function()? answer]) =>
      when(
        () => moderation.report(
          idempotencyKey: any(named: 'idempotencyKey'),
          targetType: any(named: 'targetType'),
          targetId: any(named: 'targetId'),
          reason: any(named: 'reason'),
          note: any(named: 'note'),
        ),
      ).thenAnswer(
        (_) =>
            (answer ??
            () async =>
                const ReportReceipt(reportId: 'r', alreadyReported: false))(),
      );

  Future<void> open(
    WidgetTester tester, {
    Set<String> features = const {'communities', 'posts', 'reports'},
  }) async {
    whenListen(
      onboarding,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        status: OnboardingStatus.ready,
        profile: identity.Profile(userId: 'viewer', handle: 'me'),
        enabledFeatures: features,
      ),
    );
    await pumpThemed(
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
          value: onboarding,
          child: const CommunityScreen(communityId: '77'),
        ),
      ),
      size: const Size(600, 1600),
      useScaffold: false,
    );
  }

  Finder menu() => find.byTooltip('Community options');
  Finder send() => find.widgetWithText(FilledButton, 'Send report');

  Future<void> openReportSheet(WidgetTester tester) async {
    await tester.tap(menu());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Report Community'));
    await tester.pumpAndSettle();
  }

  Future<void> sendSpam(WidgetTester tester) async {
    await tester.tap(find.text("It's spam"));
    await tester.pump();
    await tester.ensureVisible(send());
    await tester.pumpAndSettle();
    await tester.tap(send());
    await tester.pumpAndSettle();
  }

  for (final role in [
    pb.CommunityRole.COMMUNITY_ROLE_MEMBER,
    pb.CommunityRole.COMMUNITY_ROLE_NONE,
  ]) {
    testWidgets('${role.name}: the menu offers Report Community', (
      tester,
    ) async {
      stubRole(role);
      await open(tester);
      expect(menu(), findsOneWidget);
      expect(tester.getSize(menu()).shortestSide, greaterThanOrEqualTo(48));
      await tester.tap(menu());
      await tester.pumpAndSettle();
      expect(find.text('Report Community'), findsOneWidget);
    });
  }

  testWidgets('owner: no menu', (tester) async {
    stubRole(pb.CommunityRole.COMMUNITY_ROLE_OWNER);
    await open(tester);
    expect(menu(), findsNothing);
  });

  testWidgets('reports flag off: no menu', (tester) async {
    stubRole(pb.CommunityRole.COMMUNITY_ROLE_MEMBER);
    await open(tester, features: const {'communities', 'posts'});
    expect(menu(), findsNothing);
  });

  testWidgets('communities flag off: no menu', (tester) async {
    stubRole(pb.CommunityRole.COMMUNITY_ROLE_MEMBER);
    await open(tester, features: const {'reports', 'posts'});
    expect(menu(), findsNothing);
  });

  testWidgets('sends COMMUNITY with the community id, then thanks', (
    tester,
  ) async {
    stubRole(pb.CommunityRole.COMMUNITY_ROLE_MEMBER);
    stubReport();
    await open(tester);
    await openReportSheet(tester);
    expect(find.text('Report Chess club'), findsOneWidget);
    await sendSpam(tester);

    final call = verify(
      () => moderation.report(
        idempotencyKey: any(named: 'idempotencyKey'),
        targetType: captureAny(named: 'targetType'),
        targetId: captureAny(named: 'targetId'),
        reason: ReportReason.REPORT_REASON_SPAM,
        note: any(named: 'note'),
      ),
    )..called(1);
    expect((call.captured[0] as ReportTargetType).value, 5);
    expect(call.captured[1], '77');
    expect(find.text('Thanks for reporting'), findsOneWidget);
  });

  group('errors stay in the sheet with a friendly text', () {
    Future<void> failWith(WidgetTester tester, AppException error) async {
      stubRole(pb.CommunityRole.COMMUNITY_ROLE_MEMBER);
      stubReport(() async => throw error);
      await open(tester);
      await openReportSheet(tester);
      await sendSpam(tester);
      expect(find.text('Thanks for reporting'), findsNothing);
    }

    testWidgets('NOT_FOUND community not found', (tester) async {
      await failWith(tester, const NotFoundException('community not found'));
      expect(
        find.text("This community isn't available to report any more."),
        findsOneWidget,
      );
    });

    testWidgets('FEATURE_DISABLED feature=communities', (tester) async {
      await failWith(
        tester,
        const FeatureDisabledException('off', feature: 'communities'),
      );
      expect(find.text("Communities aren't available yet."), findsOneWidget);
    });
  });
}
