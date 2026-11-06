import 'package:dzeroth/features/beacons/presentation/my_beacons_screen.dart';
import 'package:dzeroth/features/beacons/presentation/widgets/beacon_row.dart';
import 'package:dzeroth/gen/dzeroth/beacons/v1/beacons.pb.dart' as pb;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../../../support/beacons_fixtures.dart';
import '../../../support/beacons_rig.dart';
import '../../../support/fake_beacons_server.dart';
import '../../../support/geometry.dart';

/// `/plans/mine` (R39): window tabs, role chips, rows with the status pill,
/// empty copy, Load more and row navigation.
void main() {
  late FakeBeaconsServer server;
  final now = DateTime.now();

  setUp(() {
    server = FakeBeaconsServer();
  });

  Future<GoRouter> open(WidgetTester tester) => pumpPlansRouter(
    tester,
    beacons: server,
    initialLocation: '/plans/mine',
    routes: [
      GoRoute(path: '/plans', builder: (_, _) => stubPage('plans')),
      GoRoute(path: '/plans/mine', builder: (_, _) => const MyBeaconsScreen()),
      GoRoute(
        path: '/plans/:id',
        builder: (_, state) => stubPage('plan ${state.pathParameters['id']}'),
      ),
    ],
  );

  testWidgets('rows with the status pill; tabs and chips reload; a row opens '
      'the plan', (tester) async {
    server.mine.addAll([
      beaconView(startAt: now.add(const Duration(hours: 1)), canManage: true),
      beaconView(
        startAt: now.subtract(const Duration(days: 1)),
        id: kBeaconIdB,
        title: 'Run',
        status: pb.BeaconStatus.BEACON_STATUS_CANCELLED,
      ),
    ]);
    final router = await open(tester);

    expectNoOverflow(tester);
    expect(find.text('My plans'), findsOneWidget);
    expect(find.byType(BeaconRow), findsNWidgets(2));
    expect(find.text('Cancelled'), findsOneWidget);
    expect(server.calls, ['mine']);

    await tester.tap(find.text('Past'));
    await tester.pumpAndSettle();
    expect(server.calls, ['mine', 'mine']);
    await tester.tap(find.widgetWithText(ChoiceChip, 'Organising'));
    await tester.pumpAndSettle();
    expect(server.calls, ['mine', 'mine', 'mine']);

    await tester.tap(find.text('Coffee'));
    await tester.pumpAndSettle();
    expect(router.state.uri.path, '/plans/$kBeaconIdA');
  });

  testWidgets('empty copy and Load more', (tester) async {
    await open(tester);
    expect(find.text('Nothing here yet'), findsOneWidget);

    for (var i = 0; i < 25; i++) {
      server.mine.add(
        beaconView(
          startAt: now.add(Duration(hours: i + 1)),
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
    await tester.tap(find.text('Load more'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Plan 24'),
      300,
      scrollable: list,
    );
    expect(find.text('Plan 24'), findsOneWidget);
  });
}
