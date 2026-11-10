import 'dart:async';

import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/widgets/app_shell_scope.dart';
import 'package:dzeroth/features/beacons/domain/beacon_labels.dart';
import 'package:dzeroth/features/beacons/domain/beacons_feature_flag.dart';
import 'package:dzeroth/features/beacons/presentation/beacons_screen.dart';
import 'package:dzeroth/features/beacons/presentation/widgets/beacon_row.dart';
import 'package:dzeroth/features/communities/data/communities_repository.dart';
import 'package:dzeroth/gen/dzeroth/beacons/v1/beacons.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/communities/v1/communities.pb.dart' as cpb;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/beacons_fixtures.dart';
import '../../../support/beacons_rig.dart';
import '../../../support/fake_beacons_server.dart';
import '../../../support/geometry.dart';

class _MockCommunities extends Mock implements CommunitiesRepository {}

/// `/plans`: skeleton, rows, empty state, error with retry, "Load more", the
/// audience chips and the New plan entry, over a real cubit and the fake
/// server.
void main() {
  late FakeBeaconsServer server;
  // Tomorrow at noon local: always in the future, and the same time of day
  // whenever the suite runs, so row text (and so row heights) is stable.
  final today = DateTime.now();
  final now = DateTime(today.year, today.month, today.day + 1, 12);
  DateTime start(int hours) => now.add(Duration(hours: hours));

  setUp(() {
    server = FakeBeaconsServer();
  });

  List<GoRoute> routes() => [
    GoRoute(path: '/plans', builder: (_, _) => const BeaconsScreen()),
    GoRoute(
      path: AppRouter.planNewPath,
      builder: (_, _) => stubPage('new plan'),
    ),
    GoRoute(
      path: '/plans/:id',
      builder: (_, state) => stubPage('plan ${state.pathParameters['id']}'),
    ),
  ];

  Future<GoRouter> open(
    WidgetTester tester, {
    CommunitiesRepository? communities,
  }) => pumpPlansRouter(
    tester,
    beacons: server,
    communities: communities,
    // The screen reads the flag: off is the paused state
    // (beacons_screen_paused_test.dart).
    features: const {kFeatureBeacons},
    routes: routes(),
  );

  testWidgets('rows show the activity, title, when, venue and seats', (
    tester,
  ) async {
    final view = beaconView(startAt: start(2), accepted: 1, openSpots: 3);
    server.public.add(view);
    server.public.add(
      beaconView(
        startAt: start(3),
        id: kBeaconIdB,
        title: 'Run',
        activity: pb.BeaconActivity.BEACON_ACTIVITY_SPORTS,
        status: pb.BeaconStatus.BEACON_STATUS_FULL,
      ),
    );
    await open(tester);

    expectNoOverflow(tester);
    expect(find.text('Plans'), findsOneWidget);
    expect(find.text('Coffee'), findsOneWidget);
    expect(find.text('Run'), findsOneWidget);
    expect(find.text(beaconWhenText(view.beacon)), findsOneWidget);
    expect(find.text('Hall'), findsNWidgets(2));
    expect(find.text('1 of 3 seats taken'), findsOneWidget);
    expect(find.text('Full'), findsOneWidget);
    expect(find.text('Open'), findsNothing);
    expect(find.byType(BeaconRow), findsNWidgets(2));
    expect(server.calls, ['list:']);
  });

  group('phone chrome (ADR-0034)', () {
    testWidgets('inside the shell the header leads with the account avatar '
        '(drawer), not Back', (tester) async {
      var opened = 0;
      await pumpPlansRouter(
        tester,
        beacons: server,
        features: const {kFeatureBeacons},
        routes: [
          GoRoute(
            path: '/plans',
            builder: (_, _) => AppShellScope(
              openDrawer: () => opened++,
              child: const BeaconsScreen(),
            ),
          ),
        ],
      );

      expect(find.byTooltip('Back'), findsNothing);
      await tester.tap(find.bySemanticsLabel('Open account menu'));
      expect(opened, 1);
    });

    testWidgets('when a page can be popped, Back stays', (tester) async {
      final router = await pumpPlansRouter(
        tester,
        beacons: server,
        features: const {kFeatureBeacons},
        initialLocation: '/start',
        routes: [
          GoRoute(path: '/start', builder: (_, _) => stubPage('start')),
          GoRoute(
            path: '/plans',
            builder: (_, _) =>
                AppShellScope(openDrawer: () {}, child: const BeaconsScreen()),
          ),
        ],
      );
      unawaited(router.push('/plans'));
      await tester.pumpAndSettle();

      expect(find.byTooltip('Back'), findsOneWidget);
      expect(find.bySemanticsLabel('Open account menu'), findsNothing);
    });

    testWidgets('outside the shell the Back button stays', (tester) async {
      await open(tester);

      expect(find.byTooltip('Back'), findsOneWidget);
      expect(find.bySemanticsLabel('Open account menu'), findsNothing);
    });
  });

  testWidgets('empty state and the New plan entry', (tester) async {
    final router = await open(tester);

    expect(find.text('No plans yet'), findsOneWidget);
    expect(find.text('Create one and invite people along.'), findsOneWidget);
    await tester.tap(find.byTooltip('New plan'));
    await tester.pumpAndSettle();
    expect(router.state.uri.path, AppRouter.planNewPath);
  });

  testWidgets('a row opens the plan', (tester) async {
    server.public.add(beaconView(startAt: start(2)));
    final router = await open(tester);

    await tester.tap(find.text('Coffee'));
    await tester.pumpAndSettle();

    expect(router.state.uri.path, AppRouter.planPath(kBeaconIdA));
    expect(find.text('plan $kBeaconIdA'), findsOneWidget);
  });

  testWidgets('a failed load shows the copy and Try again reloads', (
    tester,
  ) async {
    server.refusals.add(NetworkException('offline'));
    await open(tester);

    expect(
      find.text('No connection. Check your network and try again.'),
      findsOneWidget,
    );
    server.public.add(beaconView(startAt: start(2)));
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(find.text('Coffee'), findsOneWidget);
    expect(server.calls, ['list:', 'list:']);
  });

  testWidgets('Load more appears only with a next page and appends', (
    tester,
  ) async {
    for (var i = 0; i < 25; i++) {
      server.public.add(
        beaconView(
          startAt: start(i + 1),
          id: '12345678901234567${i.toString().padLeft(2, '0')}',
          title: 'Plan $i',
        ),
      );
    }
    await open(tester);

    final list = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(
      find.text('Load more'),
      300,
      scrollable: list,
    );
    // scrollUntilVisible returns once the row is built, which can still be
    // below the viewport; bring it fully on screen so the tap cannot miss.
    await tester.ensureVisible(find.text('Load more'));
    await tester.pumpAndSettle();
    expect(find.text('Plan 24', skipOffstage: false), findsNothing);
    final hitWarning = WidgetController.hitTestWarningShouldBeFatal;
    WidgetController.hitTestWarningShouldBeFatal = true;
    addTearDown(
      () => WidgetController.hitTestWarningShouldBeFatal = hitWarning,
    );
    await tester.tap(find.text('Load more'));
    await tester.pumpAndSettle();
    expect(server.calls, ['list:', 'list:']);
    await tester.scrollUntilVisible(
      find.text('Plan 24'),
      300,
      scrollable: list,
    );
    await tester.ensureVisible(find.text('Plan 24'));
    await tester.pumpAndSettle();
    expect(find.text('Plan 24'), findsOneWidget);
    expect(find.text('Load more', skipOffstage: false), findsNothing);
    expect(server.calls, ['list:', 'list:']);
  });

  testWidgets('no chips without communities; chips with them, and a refused '
      'community shows its copy while Public still loads', (tester) async {
    server.public.add(beaconView(startAt: start(2)));
    await open(tester);
    expect(find.byType(ChoiceChip), findsNothing);

    final communities = _MockCommunities();
    when(() => communities.enabled).thenReturn(true);
    when(() => communities.myCommunities(refresh: any(named: 'refresh')))
        .thenAnswer(
          (_) async => MyCommunities(
            communities: [
              cpb.Community(
                communityId: 'c1',
                name: 'Gardeners',
                viewerRole: cpb.CommunityRole.COMMUNITY_ROLE_MEMBER,
              ),
            ],
            canCreate: false,
          ),
        );
    server.refusals.clear();
    await open(tester, communities: communities);

    expect(find.widgetWithText(ChoiceChip, 'Public'), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, 'Gardeners'), findsOneWidget);
    server.refusals.add(
      CommunityForbiddenException(CommunityForbiddenReason.notMember),
    );
    await tester.tap(find.text('Gardeners'));
    await tester.pumpAndSettle();
    expect(
      find.text('Only members of this community can do that.'),
      findsOneWidget,
    );
    expect(find.byType(BeaconRow), findsNothing);

    await tester.tap(find.text('Public'));
    await tester.pumpAndSettle();
    expect(find.text('Coffee'), findsOneWidget);
  });

  testWidgets('returning from a plan or the New plan form reloads the list', (
    tester,
  ) async {
    server.public.add(beaconView(startAt: start(2)));
    final router = await open(tester);
    await tester.tap(find.text('Coffee'));
    await tester.pumpAndSettle();
    expect(server.calls, ['list:']);

    router.pop();
    await tester.pumpAndSettle();
    expect(server.calls, ['list:', 'list:']);

    await tester.tap(find.byTooltip('New plan'));
    await tester.pumpAndSettle();
    router.pop();
    await tester.pumpAndSettle();
    expect(server.calls, ['list:', 'list:', 'list:']);
    expect(find.text('Coffee'), findsOneWidget);
  });
}
