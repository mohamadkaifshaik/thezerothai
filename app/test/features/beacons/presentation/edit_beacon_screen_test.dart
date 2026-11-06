import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/beacons/domain/beacons_feature_flag.dart';
import 'package:dzeroth/features/beacons/presentation/edit_beacon_screen.dart';
import 'package:dzeroth/shared/widgets/primitives/app_pill_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../../../support/beacons_fixtures.dart';
import '../../../support/beacons_rig.dart';
import '../../../support/fake_beacons_server.dart';
import '../../../support/geometry.dart';

/// `/plans/:id/edit`: prefilled, the immutable lines read-only, Save only when
/// something changed and open spots cover the people going (Review Focus 4).
void main() {
  late FakeBeaconsServer server;
  final start = DateTime.now().add(const Duration(hours: 2));

  setUp(() {
    server = FakeBeaconsServer();
    server.public.add(
      beaconView(
        startAt: start,
        title: 'Coffee',
        details: 'Bring a book',
        venue: 'Hall',
        openSpots: 3,
        accepted: 2,
        canManage: true,
      ),
    );
  });

  Future<GoRouter> open(WidgetTester tester) => pumpPlansRouter(
    tester,
    beacons: server,
    initialLocation: '/plans/$kBeaconIdA/edit',
    routes: [
      GoRoute(
        path: '/plans/:id',
        builder: (_, state) => stubPage('plan ${state.pathParameters['id']}'),
      ),
      GoRoute(
        path: '/plans/:id/edit',
        builder: (_, state) =>
            EditBeaconScreen(beaconId: state.pathParameters['id']!),
      ),
    ],
  );

  Finder field(String label) => find.widgetWithText(TextField, label);

  bool saveEnabled(WidgetTester tester) =>
      tester
          .widget<AppPillButton>(find.widgetWithText(AppPillButton, 'Save'))
          .onPressed !=
      null;

  testWidgets('prefilled, read-only lines, Save waits for a change', (
    tester,
  ) async {
    await open(tester);

    expectNoOverflow(tester);
    expect(find.text('Edit plan'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Coffee'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Bring a book'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Hall'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    expect(find.textContaining('Starts'), findsOneWidget);
    expect(find.textContaining('60 min'), findsOneWidget);
    expect(find.textContaining('Free'), findsOneWidget);
    expect(find.textContaining('Public'), findsOneWidget);
    expect(find.textContaining("can't be changed"), findsOneWidget);
    expect(saveEnabled(tester), isFalse);

    await tester.enterText(field('Title'), 'Tea');
    await tester.pump();
    expect(saveEnabled(tester), isTrue);
  });

  testWidgets('open spots cannot go below the people going', (tester) async {
    await open(tester);
    await tester.tap(find.byTooltip('Fewer spots'));
    await tester.pump();
    expect(find.text('2'), findsOneWidget);
    expect(saveEnabled(tester), isTrue);
    expect(
      tester
          .widget<IconButton>(
            find.widgetWithIcon(IconButton, Icons.remove_circle_outline),
          )
          .onPressed,
      isNull,
    );
  });

  testWidgets('a server refusal keeps the form with its copy', (tester) async {
    await open(tester);
    // The refusal answers the Save, not the load.
    server.refusals.add(ValidationException('bad', field: 'open_spots'));
    await tester.enterText(field('Title'), 'Tea');
    await tester.pump();
    await tester.tap(find.widgetWithText(AppPillButton, 'Save'));
    await tester.pumpAndSettle();
    expect(
      find.text("Open spots can't go below the people already going."),
      findsOneWidget,
    );
    expect(find.text('Edit plan'), findsOneWidget);
  });

  testWidgets('a valid save sends only the changed fields and goes back to the '
      'plan', (tester) async {
    final router = await open(tester);
    await tester.enterText(field('Title'), ' Tea ');
    await tester.enterText(field('Meeting point'), 'Library');
    await tester.pump();
    await tester.tap(find.widgetWithText(AppPillButton, 'Save'));
    await tester.pumpAndSettle();

    final sent = server.lastUpdate!;
    expect(sent.hasTitle(), isTrue);
    expect(sent.title, 'Tea');
    expect(sent.hasVenue(), isTrue);
    expect(sent.venue, 'Library');
    expect(sent.hasDetails(), isFalse);
    expect(sent.hasOpenSpots(), isFalse);
    expect(server.receivedKeys, hasLength(1));
    expect(router.state.uri.path, '/plans/$kBeaconIdA');
    expect(server.public.single.beacon.title, 'Tea');
    expect(kBeaconTitleMaxLength, 60);
  });
}
