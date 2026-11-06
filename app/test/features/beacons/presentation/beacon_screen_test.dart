import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/beacons/domain/beacon_labels.dart';
import 'package:dzeroth/features/beacons/presentation/beacon_screen.dart';
import 'package:dzeroth/gen/dzeroth/beacons/v1/beacons.pb.dart' as pb;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../../../support/beacons_fixtures.dart';
import '../../../support/beacons_rig.dart';
import '../../../support/fake_beacons_server.dart';
import '../../../support/geometry.dart';

/// `/plans/:id`: the server's status drives the pill and the organiser's
/// Cancel (R32); the client never derives ENDED from the clock.
void main() {
  late FakeBeaconsServer server;
  final now = DateTime.now();
  final start = now.add(const Duration(hours: 2));

  setUp(() {
    server = FakeBeaconsServer();
  });

  Future<void> open(WidgetTester tester) => pumpPlansRouter(
    tester,
    beacons: server,
    initialLocation: '/plans/$kBeaconIdA',
    routes: [
      GoRoute(path: '/plans', builder: (_, _) => stubPage('plans')),
      GoRoute(
        path: '/plans/:id',
        builder: (_, state) =>
            BeaconScreen(beaconId: state.pathParameters['id']!),
      ),
    ],
  );

  group('TestBeaconScreen_StatusFromServer', () {
    for (final tc
        in <
          ({pb.BeaconStatus status, bool canManage, String? pill, bool cancel})
        >[
          (
            status: pb.BeaconStatus.BEACON_STATUS_OPEN,
            canManage: true,
            pill: null,
            cancel: true,
          ),
          (
            status: pb.BeaconStatus.BEACON_STATUS_FULL,
            canManage: true,
            pill: 'Full',
            cancel: true,
          ),
          (
            status: pb.BeaconStatus.BEACON_STATUS_ENDED,
            canManage: true,
            pill: 'Ended',
            cancel: false,
          ),
          (
            status: pb.BeaconStatus.BEACON_STATUS_CANCELLED,
            canManage: true,
            pill: 'Cancelled',
            cancel: false,
          ),
          (
            status: pb.BeaconStatus.BEACON_STATUS_OPEN,
            canManage: false,
            pill: null,
            cancel: false,
          ),
        ]) {
      testWidgets('${tc.status.name} canManage=${tc.canManage}', (
        tester,
      ) async {
        server.public.add(
          beaconView(
            startAt: start,
            status: tc.status,
            canManage: tc.canManage,
            accepted: 2,
            details: 'Bring a book',
          ),
        );
        await open(tester);

        expectNoOverflow(tester);
        expect(find.text('Coffee'), findsOneWidget);
        if (tc.pill != null) {
          expect(find.text(tc.pill!), findsOneWidget);
        } else {
          expect(find.text('Open'), findsNothing);
        }
        expect(
          find.text('Cancel plan'),
          tc.cancel ? findsOneWidget : findsNothing,
        );
        expect(find.text('2 of 3 seats taken'), findsOneWidget);
        expect(find.text('Bring a book'), findsOneWidget);
        expect(find.text('Hall'), findsOneWidget);
        expect(find.text('@org'), findsOneWidget);
        expect(find.text('Orla'), findsOneWidget);
        expect(find.textContaining('Free'), findsOneWidget);
        expect(find.textContaining('Quiet'), findsOneWidget);
        expect(
          find.text(beaconWhenText(server.public.single.beacon)),
          findsOneWidget,
        );
      });
    }
  });

  testWidgets('a hidden plan shows the moderation notice to its organiser', (
    tester,
  ) async {
    server.public.add(
      beaconView(startAt: start, canManage: true, hidden: true),
    );
    await open(tester);

    expect(
      find.text('Hidden by moderation: only you can see this plan.'),
      findsOneWidget,
    );
  });

  testWidgets('Cancel asks, sends one key and re-renders CANCELLED', (
    tester,
  ) async {
    server.public.add(beaconView(startAt: start, canManage: true));
    await open(tester);

    await tester.tap(find.text('Cancel plan'));
    await tester.pumpAndSettle();
    expect(find.text('Cancel this plan?'), findsOneWidget);
    await tester.tap(find.text('Keep'));
    await tester.pumpAndSettle();
    expect(server.receivedKeys, isEmpty);

    await tester.tap(find.text('Cancel plan'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Cancel plan'));
    await tester.pumpAndSettle();

    expect(server.receivedKeys, hasLength(1));
    expect(find.text('Cancelled'), findsOneWidget);
    expect(find.text('Cancel plan'), findsNothing);
  });

  testWidgets('a refused Cancel keeps the plan and says why', (tester) async {
    server.public.add(beaconView(startAt: start, canManage: true));
    await open(tester);
    server.refusals.add(StateConflictException('ended'));

    await tester.tap(find.text('Cancel plan'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Cancel plan'));
    await tester.pumpAndSettle();

    expect(find.text('This plan has already ended.'), findsOneWidget);
    expect(find.text('Cancelled'), findsNothing);
  });

  testWidgets('an unknown plan is unavailable', (tester) async {
    await open(tester);

    expect(find.text('This plan is unavailable.'), findsOneWidget);
    expect(find.text('Cancel plan'), findsNothing);
  });

  testWidgets('a failed load shows the Plans copy and Try again reloads', (
    tester,
  ) async {
    server.public.add(beaconView(startAt: start, canManage: true));
    server.refusals.add(const FeatureDisabledException('off'));
    await open(tester);

    expect(find.text("Plans aren't available yet."), findsOneWidget);
    expect(find.text('Coffee'), findsNothing);
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(find.text('Coffee'), findsOneWidget);
    expect(server.calls, ['get', 'get']);
  });
}
