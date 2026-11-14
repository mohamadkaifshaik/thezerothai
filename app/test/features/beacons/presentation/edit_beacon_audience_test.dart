import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/beacons/presentation/beacons_error_messages.dart';
import 'package:dzeroth/features/beacons/presentation/bloc/edit_beacon_cubit.dart';
import 'package:dzeroth/features/beacons/presentation/edit_beacon_screen.dart';
import 'package:dzeroth/gen/dzeroth/beacons/v1/beacons.pb.dart' as pb;
import 'package:dzeroth/shared/widgets/primitives/app_pill_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../../../support/beacons_fixtures.dart';
import '../../../support/beacons_rig.dart';
import '../../../support/fake_beacons_server.dart';
import '../../../support/geometry.dart';

/// F28b: the edit form's "Who can see it" offers only the plan's audience
/// and wider ones (community < public), says why, and sends `public`.
void main() {
  const community = '1234567890123456789';
  late FakeBeaconsServer server;
  final start = DateTime.now().add(const Duration(hours: 2));

  void seed({
    String communityId = '',
    pb.BeaconStatus status = pb.BeaconStatus.BEACON_STATUS_OPEN,
  }) => server.public.add(
    beaconView(
      startAt: start,
      communityId: communityId,
      status: status,
      canManage: true,
    ),
  );

  setUp(() => server = FakeBeaconsServer());

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

  Finder chip(String label) => find.widgetWithText(ChoiceChip, label);

  bool chipSelected(WidgetTester tester, String label) =>
      tester.widget<ChoiceChip>(chip(label)).selected;

  AppPillButton save(WidgetTester tester) =>
      tester.widget<AppPillButton>(find.widgetWithText(AppPillButton, 'Save'));

  Future<void> tapChip(WidgetTester tester, String label) async {
    await tester.ensureVisible(chip(label));
    await tester.pumpAndSettle();
    await tester.tap(chip(label));
    await tester.pump();
  }

  testWidgets('a public plan offers Public alone, with the note', (
    tester,
  ) async {
    seed();
    await open(tester);
    expectNoOverflow(tester);
    expect(find.text('Who can see it'), findsOneWidget);
    expect(chip('Public'), findsOneWidget);
    expect(chipSelected(tester, 'Public'), isTrue);
    expect(chip('Community'), findsNothing);
    expect(find.text(kPlanAudienceWidenNote), findsOneWidget);
    expect(save(tester).onPressed, isNull);
  });

  testWidgets('a community plan offers Community and the wider Public', (
    tester,
  ) async {
    seed(communityId: community);
    await open(tester);
    expectNoOverflow(tester);
    expect(chipSelected(tester, 'Community'), isTrue);
    expect(chipSelected(tester, 'Public'), isFalse);
    expect(find.text(kPlanAudienceWidenNote), findsOneWidget);
    expect(find.text('Who can see it: Community'), findsNothing);
    expect(save(tester).onPressed, isNull);

    await tapChip(tester, 'Public');
    expect(chipSelected(tester, 'Public'), isTrue);
    expect(save(tester).onPressed, isNotNull);
    // Back to Community: nothing to save again.
    await tapChip(tester, 'Community');
    expect(save(tester).onPressed, isNull);
  });

  testWidgets('making it public sends public = true and nothing else', (
    tester,
  ) async {
    seed(communityId: community);
    final router = await open(tester);
    await tapChip(tester, 'Public');
    await tester.tap(find.widgetWithText(AppPillButton, 'Save'));
    await tester.pumpAndSettle();

    final sent = server.lastUpdate!;
    expect(sent.hasPublic(), isTrue);
    expect(sent.public, isTrue);
    expect(sent.hasCommunityId(), isFalse);
    expect(sent.hasTitle(), isFalse);
    expect(sent.hasStartAt(), isFalse);
    expect(server.public.single.beacon.communityId, isEmpty);
    expect(router.state.uri.path, '/plans/$kBeaconIdA');
  });

  testWidgets('a server that ignores public keeps the form with its copy', (
    tester,
  ) async {
    seed(communityId: community);
    server.ignoresAudience = true;
    await open(tester);
    await tapChip(tester, 'Public');
    await tester.tap(find.widgetWithText(AppPillButton, 'Save'));
    await tester.pumpAndSettle();
    expect(find.text(kPlanAudienceNotSaved), findsOneWidget);
    expect(find.text('Edit plan'), findsOneWidget);
  });

  testWidgets('a narrowing refusal reads as the widen-only note', (
    tester,
  ) async {
    seed(communityId: community);
    await open(tester);
    // The refusal answers the Save, not the load.
    server.refusals.add(ValidationException('narrowing', field: 'audience'));
    await tapChip(tester, 'Public');
    await tester.tap(find.widgetWithText(AppPillButton, 'Save'));
    await tester.pumpAndSettle();
    // The note under the chips and the save error.
    expect(find.text(kPlanAudienceWidenNote), findsNWidgets(2));
  });

  testWidgets('a cancelled plan shows the audience read-only, no selector', (
    tester,
  ) async {
    seed(
      communityId: community,
      status: pb.BeaconStatus.BEACON_STATUS_CANCELLED,
    );
    await open(tester);
    expect(chip('Public'), findsNothing);
    expect(find.text(kPlanAudienceWidenNote), findsNothing);
    expect(find.text('Who can see it: Community'), findsOneWidget);
  });
}
