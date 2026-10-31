import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/app/session_wiring.dart' show UnexpectedErrorReporter;
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/lists/data/home_tabs_repository.dart';
import 'package:dzeroth/features/lists/data/lists_repository.dart';
import 'package:dzeroth/features/lists/domain/home_tab_entry.dart';
import 'package:dzeroth/features/lists/presentation/list_detail_screen.dart';
import 'package:dzeroth/features/moderation/data/moderation_repository.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/features/timeline/data/timeline_repository.dart';
import 'package:dzeroth/features/timeline/domain/feed_key.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:dzeroth/gen/dzeroth/lists/v1/lists.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/moderation/v1/moderation.pbenum.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/geometry.dart';
import '../../../support/theme_harness.dart';
import '../../../support/timeline_fixtures.dart';

class _MockOnboarding extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

class _MockLists extends Mock implements ListsRepository {}

class _MockTabs extends Mock implements HomeTabsRepository {}

class _MockModeration extends Mock implements ModerationRepository {}

pb.ListInfo _header({String ownerId = 'owner'}) => pb.ListInfo(
  listId: '77',
  name: 'Friends',
  description: 'People I like to read',
  memberCount: 3,
  owner: common.AuthorSnapshot(
    userId: ownerId,
    handle: 'olivia',
    displayName: 'Olivia',
  ),
);

/// W5-48: "Report List" in the List detail overflow menu.
void main() {
  final feed = FeedKey.list('77');
  late MockTimelineRepository timeline;
  late MockPostsRepository posts;
  late _MockLists lists;
  late _MockTabs tabs;
  late _MockModeration moderation;
  late _MockOnboarding onboarding;
  late StreamController<pb.ListInfo> headers;

  setUpAll(() {
    registerFallbackValue(HomeTabKind.list);
    registerFallbackValue(ReportTargetType.REPORT_TARGET_TYPE_LIST);
    registerFallbackValue(ReportReason.REPORT_REASON_SPAM);
  });

  setUp(() {
    timeline = MockTimelineRepository();
    posts = MockPostsRepository();
    lists = _MockLists();
    tabs = _MockTabs();
    moderation = _MockModeration();
    onboarding = _MockOnboarding();
    headers = StreamController<pb.ListInfo>.broadcast(sync: true);
    addTearDown(headers.close);
    when(() => posts.removedPosts).thenAnswer((_) => const Stream.empty());
    when(() => timeline.sinceRefresh(feed)).thenReturn(null);
    when(() => timeline.sinceRefreshAttempt(feed)).thenReturn(null);
    when(() => timeline.rateLimitedFor()).thenReturn(null);
    when(() => timeline.cached(feed)).thenAnswer((_) async => snapshotOf([]));
    when(() => timeline.refresh(feed)).thenAnswer((_) async => snapshotOf([]));
    when(() => lists.header('77')).thenReturn(_header());
    when(() => lists.headerChanges).thenAnswer((_) => headers.stream);
    when(() => tabs.changes).thenAnswer((_) => const Stream.empty());
    when(() => tabs.isPinned(any(), any())).thenReturn(false);
    when(() => tabs.isFull).thenReturn(false);
    when(() => tabs.writeUnavailable).thenReturn(false);
  });

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
    Set<String> features = const {'lists', 'posts', 'reports'},
    MatrixEnv? env,
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
          RepositoryProvider<ListsRepository>.value(value: lists),
          RepositoryProvider<HomeTabsRepository>.value(value: tabs),
          RepositoryProvider<ModerationRepository>.value(value: moderation),
          RepositoryProvider<UnexpectedErrorReporter>.value(value: (_, _) {}),
        ],
        child: BlocProvider<OnboardingBloc>.value(
          value: onboarding,
          child: const ListDetailScreen(listId: '77'),
        ),
      ),
      brightness: env?.brightness ?? Brightness.light,
      size: env?.size ?? const Size(360, 800),
      textScale: env?.textScale ?? 1.0,
      useScaffold: false,
    );
  }

  Finder menu() => find.byTooltip('More options');
  Finder reportItem() => find.text('Report List');
  Finder send() => find.widgetWithText(FilledButton, 'Send report');

  Future<void> openReportSheet(WidgetTester tester) async {
    await tester.tap(menu());
    await tester.pumpAndSettle();
    await tester.tap(reportItem());
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

  forEachThemeAndWidth('non-owner: the menu and the sheet fit', (
    tester,
    env,
  ) async {
    await open(tester, env: env);
    expectNoOverflow(tester);
    expect(menu(), findsOneWidget);
    expect(tester.getSize(menu()).shortestSide, greaterThanOrEqualTo(48));

    await tester.tap(menu());
    await tester.pumpAndSettle();
    expect(reportItem(), findsOneWidget);
    await tester.tap(reportItem());
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Report this List'), findsOneWidget);
    expect(find.text("It's spam"), findsOneWidget);
  }, textScales: kMatrixTextScalesLarge);

  testWidgets('owner: no report entry', (tester) async {
    when(() => lists.header('77')).thenReturn(_header(ownerId: 'viewer'));
    await open(tester);
    expect(menu(), findsNothing);
    expect(find.text('Edit'), findsOneWidget);
  });

  testWidgets('reports flag off: no entry', (tester) async {
    await open(tester, features: const {'lists', 'posts'});
    expect(menu(), findsNothing);
  });

  testWidgets('lists flag off: no entry', (tester) async {
    await open(tester, features: const {'reports', 'posts'});
    expect(menu(), findsNothing);
  });

  testWidgets('sends REPORT_TARGET_TYPE_LIST with the list id, then thanks', (
    tester,
  ) async {
    stubReport();
    await open(tester);
    await openReportSheet(tester);
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
    final type = call.captured[0] as ReportTargetType;
    expect(type.value, 4);
    expect(call.captured[1], '77');
    expect(find.text('Thanks for reporting'), findsOneWidget);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.text('Report sent'), findsOneWidget);
  });

  group('errors stay in the sheet with a friendly text', () {
    Future<void> failWith(WidgetTester tester, AppException error) async {
      stubReport(() async => throw error);
      await open(tester);
      await openReportSheet(tester);
      await sendSpam(tester);
      expect(find.text('Thanks for reporting'), findsNothing);
    }

    testWidgets('NOT_FOUND list not found', (tester) async {
      await failWith(tester, const NotFoundException('list not found'));
      expect(
        find.text("This isn't available to report any more."),
        findsOneWidget,
      );
    });

    testWidgets('reports quota', (tester) async {
      await failWith(
        tester,
        const QuotaExceededException('quota', quota: 'reports'),
      );
      expect(
        find.text(
          "You've reached today's limit for reports. It resets tomorrow.",
        ),
        findsOneWidget,
      );
    });

    testWidgets('own List (VALIDATION target_id)', (tester) async {
      await failWith(
        tester,
        const ValidationException('own list', field: 'target_id'),
      );
      expect(find.text("You can't report your own content."), findsOneWidget);
    });

    testWidgets('FEATURE_DISABLED', (tester) async {
      await failWith(
        tester,
        const FeatureDisabledException('off', feature: 'reports'),
      );
      expect(find.text("Reporting isn't available right now."), findsOneWidget);
    });
  });
}
