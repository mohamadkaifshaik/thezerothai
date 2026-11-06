import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/beacons/presentation/beacon_people_screen.dart';
import 'package:dzeroth/features/beacons/presentation/widgets/participant_row.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/gen/dzeroth/beacons/v1/beacons.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/beacons_fixtures.dart';
import '../../../support/beacons_rig.dart';
import '../../../support/fake_beacons_server.dart';
import '../../../support/geometry.dart';

class _MockGraph extends Mock implements GraphRepository {}

/// `/plans/:id/people` (R38): Going for everyone who may see it, Requests
/// with notes for the organiser, and the organiser's actions.
void main() {
  late FakeBeaconsServer server;
  late _MockGraph graphRepo;
  final start = DateTime.now().add(const Duration(hours: 2));

  setUp(() {
    server = FakeBeaconsServer();
    graphRepo = _MockGraph();
    when(
      () => graphRepo.block(
        userId: any(named: 'userId'),
        idempotencyKey: any(named: 'idempotencyKey'),
      ),
    ).thenAnswer((_) async => graph.Relationship());
  });

  void seed({bool canManage = true, bool accepted = true}) {
    final v = beaconView(
      startAt: start,
      canManage: canManage,
      accepted: 2,
      openSpots: 3,
    );
    if (!canManage && accepted) {
      v.viewer = pb.ViewerState(
        role: pb.ViewerRole.VIEWER_ROLE_PARTICIPANT,
        participantState: pb.ParticipantState.PARTICIPANT_STATE_ACCEPTED,
        canLeave: true,
      );
    }
    server.public.add(v);
    server.going[kBeaconIdA] = [
      participant(userId: 'u1', handle: 'ann', name: 'Ann'),
      participant(userId: 'u2', handle: 'bea', name: 'Bea'),
    ];
    server.requests[kBeaconIdA] = [
      participant(
        userId: 'u3',
        handle: 'cy',
        name: 'Cy',
        state: pb.ParticipantState.PARTICIPANT_STATE_REQUESTED,
        note: 'Can I bring a friend?',
      ),
    ];
  }

  Future<GoRouter> open(WidgetTester tester) => pumpPlansRouter(
    tester,
    beacons: server,
    graph: graphRepo,
    initialLocation: '/plans/$kBeaconIdA/people',
    routes: [
      GoRoute(
        path: '/plans/:id',
        builder: (_, state) => stubPage('plan ${state.pathParameters['id']}'),
      ),
      GoRoute(
        path: '/plans/:id/people',
        builder: (_, state) =>
            BeaconPeopleScreen(beaconId: state.pathParameters['id']!),
      ),
      GoRoute(
        path: '/u/:userId',
        builder: (_, state) =>
            stubPage('profile ${state.pathParameters['userId']}'),
      ),
    ],
  );

  testWidgets('Going shows the rows; a row opens the profile', (tester) async {
    seed(canManage: false);
    final router = await open(tester);

    expectNoOverflow(tester);
    expect(find.text('Going'), findsOneWidget);
    expect(find.text('Requests'), findsNothing);
    expect(find.text('Ann'), findsOneWidget);
    expect(find.text('@bea'), findsOneWidget);
    expect(find.byType(ParticipantRow), findsNWidgets(2));
    expect(find.byTooltip('Participant options'), findsNothing);

    await tester.tap(find.text('Ann'));
    await tester.pumpAndSettle();
    expect(router.state.uri.path, '/u/u1');
  });

  testWidgets('the organiser sees Requests with the note and Accept moves the '
      'row to Going', (tester) async {
    seed();
    await open(tester);

    await tester.tap(find.text('Requests'));
    await tester.pumpAndSettle();
    expect(find.text('Cy'), findsOneWidget);
    expect(find.text('Can I bring a friend?'), findsOneWidget);

    await tester.tap(find.text('Accept'));
    await tester.pumpAndSettle();

    expect(server.calls.where((c) => c == 'respond:accept'), hasLength(1));
    expect(find.text('Cy'), findsNothing);
    await tester.tap(find.text('Going'));
    await tester.pumpAndSettle();
    expect(find.text('Cy'), findsOneWidget);
    expect(find.byType(ParticipantRow), findsNWidgets(3));
  });

  testWidgets('Decline asks first and removes the row', (tester) async {
    seed();
    await open(tester);
    await tester.tap(find.text('Requests'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Request options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Decline'));
    await tester.pumpAndSettle();
    expect(find.text("Decline @cy's request?"), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Decline'));
    await tester.pumpAndSettle();

    expect(server.calls.where((c) => c == 'respond:decline'), hasLength(1));
    expect(find.text('Cy'), findsNothing);
    expect(find.text('No requests yet'), findsOneWidget);
  });

  testWidgets('Decline and block when the block fails: the request is gone and '
      'the failure is said (Review Focus 3)', (tester) async {
    seed();
    when(
      () => graphRepo.block(
        userId: 'u3',
        idempotencyKey: any(named: 'idempotencyKey'),
      ),
    ).thenThrow(NetworkException('offline'));
    await open(tester);
    await tester.tap(find.text('Requests'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Request options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Decline and block'));
    await tester.pumpAndSettle();
    expect(find.text('Decline and block @cy?'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Decline and block'));
    await tester.pumpAndSettle();

    expect(server.calls.where((c) => c == 'respond:decline'), hasLength(1));
    verify(
      () => graphRepo.block(
        userId: 'u3',
        idempotencyKey: any(named: 'idempotencyKey'),
      ),
    ).called(1);
    expect(find.text('Cy'), findsNothing);
    expect(
      find.text('No connection. Check your network and try again.'),
      findsOneWidget,
    );
  });

  testWidgets('Remove asks first and removes a going row', (tester) async {
    seed();
    await open(tester);

    await tester.tap(find.byTooltip('Participant options').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    expect(find.text('Remove @ann?'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Remove'));
    await tester.pumpAndSettle();

    expect(server.calls.where((c) => c == 'remove'), hasLength(1));
    expect(find.text('Ann'), findsNothing);
    expect(find.text('Bea'), findsOneWidget);
  });

  testWidgets('Load more appends', (tester) async {
    seed(canManage: false);
    server.going[kBeaconIdA] = [
      for (var i = 0; i < 25; i++)
        participant(userId: 'p$i', handle: 'p$i', name: 'Person $i'),
    ];
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
      find.text('Person 24'),
      300,
      scrollable: list,
    );
    expect(find.text('Person 24'), findsOneWidget);
    expect(server.calls.where((c) => c == 'people:accepted'), hasLength(2));
  });

  testWidgets('a viewer who is not going sees the gate copy and no list is '
      'read', (tester) async {
    seed(canManage: false, accepted: false);
    await open(tester);

    expect(
      find.text('Only people who are going can see this list.'),
      findsOneWidget,
    );
    expect(find.byType(ParticipantRow), findsNothing);
    expect(find.text('Try again'), findsNothing);
    expect(server.calls, ['get']);
  });
}
